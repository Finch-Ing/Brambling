import Fluent
import Vapor

/// Everything the queue touches outside the database. Tests replace it with stubs.
struct JobEnvironment: Sendable {
    var downloader: any EpisodeDownloading
    var processor: any AudioProcessing
    var freeBytes: @Sendable (URL) -> Int64?
    var now: @Sendable () -> Date
    var calendar: Calendar
}

/// Snapshot for `/health` and the queue API.
struct QueueStatus: Content {
    var activeDownloads: Int
    var activeProcessing: Int
    var counts: [String: Int]
    var diskBlocked: Bool
    var diskBlockedReason: String?
    var processWindow: String?
    var processWindowOpen: Bool
    var nextProcessWindowOpening: Date?
    var processNowOverride: Bool
}

/// Downloads and processes episodes (plan §5.2–§5.5).
///
/// State lives in the database; the actor only tracks what is running right now.
/// `kick()` makes it look for work; a tick every minute picks up retries, an opening
/// processing window and freed disk space.
actor JobQueue {
    static let backoff: [TimeInterval] = [5 * 60, 30 * 60, 2 * 3600]
    static let maxAttempts = 3
    static let downloadTimeout: Duration = .seconds(30 * 60)
    static let tickInterval: Duration = .seconds(60)
    /// After the disk actually ran full, wait this long before trying again.
    static let diskFullCooldown: TimeInterval = 5 * 60

    private let app: Application
    private var activeDownloads: Set<UUID> = []
    private var activeProcessing: Set<UUID> = []
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var isPumping = false
    private var needsPump = false
    private var tickTask: Task<Void, Never>?
    private var isShutDown = false
    /// Set by `start()`. Without it (tests) the queue only runs inside `waitUntilIdle()`.
    private var autoRun = false
    private(set) var diskBlockedReason: String?
    private var diskFullUntil: Date?
    private(set) var processNowOverride = false

    init(app: Application) {
        self.app = app
    }

    private var config: AppConfig { app.appConfig }
    private var env: JobEnvironment { app.jobEnvironment }
    private var db: any Database { app.db }
    private var logger: Logger { app.logger }

    // MARK: - Lifecycle

    func start() async {
        do {
            try await recover()
        } catch {
            logger.error("Job queue recovery failed: \(error)")
        }
        autoRun = true
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.kick()
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
        logger.info("Job queue started (downloads: \(config.downloadConcurrency), ffmpeg: \(config.ffmpegConcurrency), window: \(config.processWindow?.description ?? "always"))")
    }

    /// Stops the tick, starts nothing new and waits for running jobs, so nothing touches
    /// the database after the app has shut down.
    func shutdown() async {
        isShutDown = true
        tickTask?.cancel()
        tickTask = nil
        while isPumping {
            try? await Task.sleep(for: .milliseconds(5))
        }
        for task in workers.values {
            await task.value
        }
    }

    /// After a restart: nothing is running any more, so put interrupted work back and clean `tmp/`.
    func recover() async throws {
        let interrupted = try await Episode.query(on: db)
            .filter(\.$status ~~ [.downloading, .downloaded, .processing])
            .all()
        var keep = Set<String>()
        for episode in interrupted {
            let id = try episode.requireID()
            let source = sourceFile(id)
            if episode.status != .downloading, FileManager.default.fileExists(atPath: source.path) {
                episode.status = .downloaded
                keep.insert(source.lastPathComponent)
            } else {
                episode.status = .pending
            }
            try await episode.save(on: db)
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: config.tmpDirectory.path)) ?? []
        for file in files where !keep.contains(file) {
            try? FileManager.default.removeItem(at: config.tmpDirectory.appendingPathComponent(file))
        }
        if !interrupted.isEmpty {
            logger.info("Recovered \(interrupted.count) interrupted episode(s)")
        }
    }

    // MARK: - Public controls

    /// Look for work soon. Cheap to call often.
    func kick() {
        guard !isShutDown else { return }
        needsPump = true
        guard autoRun, !isPumping else { return }
        Task { await self.drainPump() }
    }

    /// Ignore the processing window until the queue is empty.
    func processNow() {
        processNowOverride = true
        kick()
    }

    func status() async throws -> QueueStatus {
        let episodes = try await Episode.query(on: db)
            .filter(\.$status ~~ [.pending, .downloading, .downloaded, .processing, .failed])
            .all(\.$status)
        let now = env.now()
        let window = config.processWindow
        return QueueStatus(
            activeDownloads: activeDownloads.count,
            activeProcessing: activeProcessing.count,
            counts: Dictionary(grouping: episodes, by: \.rawValue).mapValues(\.count),
            diskBlocked: diskBlockedReason != nil,
            diskBlockedReason: diskBlockedReason,
            processWindow: window?.description,
            processWindowOpen: window?.contains(now, calendar: env.calendar) ?? true,
            nextProcessWindowOpening: window?.nextOpening(after: now, calendar: env.calendar),
            processNowOverride: processNowOverride
        )
    }

    /// For tests: runs until nothing is running and nothing more can start.
    /// Gives up after 500 rounds so a scheduling bug fails a test instead of hanging it.
    func waitUntilIdle() async {
        for _ in 0..<500 {
            needsPump = true
            await drainPump()
            while isPumping {
                try? await Task.sleep(for: .milliseconds(5))
            }
            let running = Array(workers.values)
            if running.isEmpty, !needsPump || isShutDown { return }
            for task in running {
                await task.value
            }
        }
        logger.error("waitUntilIdle gave up: the queue keeps finding work")
    }

    // MARK: - Scheduling

    private func drainPump() async {
        guard !isPumping, !isShutDown else { return }
        isPumping = true
        while needsPump, !isShutDown {
            needsPump = false
            do {
                try await startDownloads()
                try await startProcessing()
            } catch {
                logger.error("Job queue error: \(error)")
            }
        }
        isPumping = false
    }

    private func eligibleEpisodes(status: EpisodeStatus) async throws -> [Episode] {
        let now = env.now()
        return try await Episode.query(on: db)
            .join(Show.self, on: \Episode.$show.$id == \Show.$id)
            .filter(Show.self, \.$enabled == true)
            .filter(\.$status == status)
            .group(.or) { $0.filter(\.$nextAttemptAt == nil).filter(\.$nextAttemptAt <= now) }
            // Newest first, so the latest episode is ready soonest.
            .sort(\.$pubDate, .descending)
            .all()
    }

    private func startDownloads() async throws {
        guard activeDownloads.count < config.downloadConcurrency else { return }
        for episode in try await eligibleEpisodes(status: .pending) {
            guard activeDownloads.count < config.downloadConcurrency else { return }
            let id = try episode.requireID()
            guard try await diskAllows(need: DiskGuard.downloadNeed(enclosureLength: episode.enclosureLength)) else { return }

            episode.status = .downloading
            try await episode.save(on: db)
            activeDownloads.insert(id)

            let url = episode.enclosureURL
            let target = sourceFile(id)
            let downloader = env.downloader
            spawn(id) {
                let result: Result<Int64, any Error>
                do {
                    result = .success(try await downloader.download(from: url, to: target, timeout: Self.downloadTimeout))
                } catch {
                    result = .failure(error)
                }
                await self.downloadFinished(id, result: result)
            }
        }
    }

    private func startProcessing() async throws {
        guard activeProcessing.count < config.ffmpegConcurrency else { return }

        if processNowOverride, activeProcessing.isEmpty, activeDownloads.isEmpty {
            let open = try await Episode.query(on: db)
                .filter(\.$status ~~ [.pending, .downloading, .downloaded, .processing])
                .count()
            if open == 0 { processNowOverride = false }
        }
        let windowOpen = config.processWindow?.contains(env.now(), calendar: env.calendar) ?? true
        guard windowOpen || processNowOverride else { return }

        for episode in try await eligibleEpisodes(status: .downloaded) {
            guard activeProcessing.count < config.ffmpegConcurrency else { return }
            let id = try episode.requireID()
            let source = sourceFile(id)
            guard let sourceSize = Self.fileSize(source) else {
                // Source vanished (e.g. tmp cleaned by hand): download again.
                episode.status = .pending
                try await episode.save(on: db)
                needsPump = true
                continue
            }
            guard try await diskAllows(need: sourceSize) else { return }

            let show = try await episode.$show.get(on: db)
            let settings = show.processingSettings
            episode.settingsHash = SettingsHash.make(settings)
            episode.status = .processing
            try await episode.save(on: db)
            activeProcessing.insert(id)

            let artwork = config.artDirectory.appendingPathComponent("\(show.slug).jpg")
            let job = ProcessingJob(
                episodeID: id,
                source: source,
                output: config.tmpDirectory.appendingPathComponent("\(id.uuidString.lowercased()).mp3"),
                artwork: FileManager.default.fileExists(atPath: artwork.path) ? artwork : nil,
                settings: settings,
                tags: EpisodeTags(title: episode.title, album: show.displayTitle, artist: show.author, date: episode.pubDate),
                slug: show.slug,
                settingsHash: episode.settingsHash
            )
            let processor = env.processor
            spawn(id) {
                let result: Result<Double, any Error>
                do {
                    result = .success(try await processor.process(
                        source: job.source, artwork: job.artwork, output: job.output,
                        settings: job.settings, tags: job.tags
                    ))
                } catch {
                    result = .failure(error)
                }
                await self.processingFinished(job, result: result)
            }
        }
    }

    private func spawn(_ id: UUID, _ work: @escaping @Sendable () async -> Void) {
        workers[id] = Task.detached(operation: work)
    }

    // MARK: - Completion

    private func downloadFinished(_ id: UUID, result: Result<Int64, any Error>) async {
        defer {
            activeDownloads.remove(id)
            workers[id] = nil
            kick()
        }
        let source = sourceFile(id)
        do {
            guard let episode = try await Episode.find(id, on: db), episode.status == .downloading else {
                // Show deleted or episode pruned meanwhile.
                try? FileManager.default.removeItem(at: source)
                return
            }
            switch result {
            case .success:
                episode.status = .downloaded
                episode.error = nil
                episode.nextAttemptAt = nil
                try await episode.save(on: db)
            case let .failure(error):
                try? FileManager.default.removeItem(at: source)
                if DiskGuard.isOutOfSpace(error) {
                    episode.status = .pending
                    try await episode.save(on: db)
                    diskFullUntil = env.now().addingTimeInterval(Self.diskFullCooldown)
                    setDiskBlocked("disk full during download")
                } else {
                    try await recordFailure(episode, error: error, retryAs: .pending)
                }
            }
        } catch {
            logger.error("Could not record download result: \(error)")
        }
    }

    private func processingFinished(_ job: ProcessingJob, result: Result<Double, any Error>) async {
        let id = job.episodeID
        defer {
            activeProcessing.remove(id)
            workers[id] = nil
            kick()
        }
        do {
            guard let episode = try await Episode.find(id, on: db), episode.status == .processing else {
                try? FileManager.default.removeItem(at: job.output)
                try? FileManager.default.removeItem(at: job.source)
                return
            }
            do {
                let duration = try result.get()
                let directory = config.mediaDirectory.appendingPathComponent(job.slug, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let fileName = "\(id.uuidString.lowercased())-\(job.settingsHash).mp3"
                let destination = directory.appendingPathComponent(fileName)
                try? FileManager.default.removeItem(at: destination)
                // Same volume, so this is an atomic rename.
                try FileManager.default.moveItem(at: job.output, to: destination)

                // A reprocessed episode keeps its old file until now.
                if let old = episode.fileName, old != fileName {
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent(old))
                }
                episode.fileName = fileName
                episode.fileSize = Self.fileSize(destination).map(Int.init)
                episode.duration = duration
                episode.processedAt = env.now()
                episode.status = .ready
                episode.attempts = 0
                episode.error = nil
                episode.nextAttemptAt = nil
                try await episode.save(on: db)
                try? FileManager.default.removeItem(at: job.source)
                logger.info("Processed \(job.slug): \(episode.title)")
            } catch {
                try? FileManager.default.removeItem(at: job.output)
                let sourceExists = FileManager.default.fileExists(atPath: job.source.path)
                if DiskGuard.isOutOfSpace(error) {
                    episode.status = sourceExists ? .downloaded : .pending
                    try await episode.save(on: db)
                    diskFullUntil = env.now().addingTimeInterval(Self.diskFullCooldown)
                    setDiskBlocked("disk full during processing")
                } else {
                    try await recordFailure(episode, error: error, retryAs: sourceExists ? .downloaded : .pending)
                }
            }
        } catch {
            logger.error("Could not record processing result: \(error)")
        }
    }

    private func recordFailure(_ episode: Episode, error: any Error, retryAs retryStatus: EpisodeStatus) async throws {
        episode.attempts += 1
        episode.error = SecretMasking.redact(String(describing: error), secrets: [episode.enclosureURL])
        if episode.attempts >= Self.maxAttempts {
            episode.status = .failed
            episode.nextAttemptAt = nil
            logger.warning("Episode failed after \(episode.attempts) attempts: \(episode.title): \(episode.error ?? "")")
        } else {
            episode.status = retryStatus
            let delay = Self.backoff[min(episode.attempts - 1, Self.backoff.count - 1)]
            episode.nextAttemptAt = env.now().addingTimeInterval(delay)
            logger.warning("Attempt \(episode.attempts) failed for \(episode.title), retrying in \(Int(delay / 60)) min: \(episode.error ?? "")")
        }
        try await episode.save(on: db)
    }

    // MARK: - Disk guard

    private func diskAllows(need: Int64) async throws -> Bool {
        if let until = diskFullUntil, env.now() < until {
            return false
        }
        let usage = DiskGuard.Usage(
            freeBytes: env.freeBytes(config.dataDirectory) ?? .max,
            mediaBytes: try await mediaBytes(),
            tmpBytes: DiskGuard.directorySize(config.tmpDirectory)
        )
        switch DiskGuard.check(need: need, usage: usage, limits: config.diskLimits) {
        case .allowed:
            if diskBlockedReason != nil {
                logger.info("Disk space available again, resuming")
                diskBlockedReason = nil
                diskFullUntil = nil
            }
            return true
        case let .blocked(reason):
            setDiskBlocked(reason)
            return false
        }
    }

    private func setDiskBlocked(_ reason: String) {
        if diskBlockedReason == nil {
            logger.warning("Disk guard: pausing downloads and processing (\(reason))")
        }
        diskBlockedReason = reason
    }

    func mediaBytes() async throws -> Int64 {
        let total = try await Episode.query(on: db).filter(\.$fileName != nil).sum(\.$fileSize)
        return Int64(total ?? 0)
    }

    // MARK: - Helpers

    private func sourceFile(_ id: UUID) -> URL {
        config.tmpDirectory.appendingPathComponent("\(id.uuidString.lowercased()).src")
    }

    private static func fileSize(_ url: URL) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value
    }
}

private struct ProcessingJob: Sendable {
    var episodeID: UUID
    var source: URL
    var output: URL
    var artwork: URL?
    var settings: ProcessingSettings
    var tags: EpisodeTags
    var slug: String
    var settingsHash: String
}

struct JobQueueLifecycle: LifecycleHandler {
    /// Off in tests: the queue then only runs when kicked, but still shuts down cleanly.
    var startOnBoot: Bool

    func didBootAsync(_ application: Application) async throws {
        if startOnBoot {
            await application.jobQueue.start()
        }
    }

    func shutdownAsync(_ application: Application) async {
        await application.jobQueue.shutdown()
    }
}

extension Application {
    private struct JobQueueKey: StorageKey {
        typealias Value = JobQueue
    }

    private struct JobEnvironmentKey: StorageKey {
        typealias Value = JobEnvironment
    }

    var jobQueue: JobQueue {
        get {
            guard let queue = storage[JobQueueKey.self] else { fatalError("JobQueue not configured") }
            return queue
        }
        set { storage[JobQueueKey.self] = newValue }
    }

    /// Real downloader, ffmpeg and clock by default; tests replace it.
    var jobEnvironment: JobEnvironment {
        get {
            storage[JobEnvironmentKey.self] ?? JobEnvironment(
                downloader: HTTPEpisodeDownloader(client: http.client.shared),
                processor: FFmpegProcessor(),
                freeBytes: { DiskGuard.freeBytes(at: $0) },
                now: { Date() },
                calendar: .current
            )
        }
        set { storage[JobEnvironmentKey.self] = newValue }
    }

    var artworkProcessor: ArtworkProcessor {
        let env = jobEnvironment
        return ArtworkProcessor(
            downloader: env.downloader, processor: env.processor,
            artDirectory: appConfig.artDirectory, tmpDirectory: appConfig.tmpDirectory
        )
    }
}
