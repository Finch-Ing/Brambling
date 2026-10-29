import Fluent
import Vapor

/// Refreshes all enabled shows periodically, one after another (plan §5.1).
/// Also the single entry point for manual refreshes, so one show is never refreshed twice at once.
actor RefreshScheduler {
    private let app: Application
    private var task: Task<Void, Never>?
    private var manualTask: Task<Void, Never>?
    private var isShutDown = false
    private var inFlight: Set<UUID> = []

    init(app: Application) {
        self.app = app
    }

    func start(interval: Duration, initialDelay: Duration = .seconds(10)) {
        guard task == nil else { return }
        let app = app
        task = Task { [weak self] in
            try? await Task.sleep(for: initialDelay)
            while !Task.isCancelled {
                await self?.refreshAll()
                try? await Task.sleep(for: interval)
            }
            app.logger.debug("Refresh scheduler stopped")
        }
        app.logger.info("Refresh scheduler started (every \(interval))")
    }

    /// "Refresh all" from the UI: runs in the background, at most once at a time.
    func refreshAllInBackground() {
        guard !isShutDown, manualTask == nil else { return }
        manualTask = Task { [weak self] in
            await self?.refreshAll()
            await self?.manualRefreshFinished()
        }
    }

    private func manualRefreshFinished() {
        manualTask = nil
    }

    /// Stops the timer and waits for a running "Refresh all", so nothing touches the
    /// database after the app has shut down.
    func stop() async {
        isShutDown = true
        task?.cancel()
        task = nil
        if let manualTask {
            manualTask.cancel()
            await manualTask.value
        }
    }

    func refreshAll() async {
        let shows: [Show]
        do {
            shows = try await Show.query(on: app.db).filter(\.$enabled == true).sort(\.$createdAt).all()
        } catch {
            app.logger.error("Could not load shows for refresh: \(error)")
            return
        }
        for show in shows where !Task.isCancelled {
            // Errors are already recorded on the show and logged by the refresher.
            _ = try? await refresh(show)
        }
    }

    /// Returns `nil` if this show is already being refreshed.
    func refresh(_ show: Show) async throws -> RefreshOutcome? {
        let id = try show.requireID()
        guard inFlight.insert(id).inserted else { return nil }
        defer { inFlight.remove(id) }
        let outcome = try await app.makeShowRefresher().refresh(show)
        await app.jobQueue.kick()
        return outcome
    }
}

struct RefreshSchedulerLifecycle: LifecycleHandler {
    /// Off in tests; shutdown still waits for a manual "Refresh all".
    var startOnBoot: Bool

    func didBootAsync(_ application: Application) async throws {
        guard startOnBoot else { return }
        let minutes = application.appConfig.refreshMinutes
        await application.refreshScheduler.start(interval: .seconds(minutes * 60))
    }

    func shutdownAsync(_ application: Application) async {
        await application.refreshScheduler.stop()
    }
}

extension Application {
    private struct RefreshSchedulerKey: StorageKey {
        typealias Value = RefreshScheduler
    }

    private struct FeedFetcherKey: StorageKey {
        typealias Value = FeedFetcher
    }

    var refreshScheduler: RefreshScheduler {
        get {
            guard let scheduler = storage[RefreshSchedulerKey.self] else { fatalError("RefreshScheduler not configured") }
            return scheduler
        }
        set { storage[RefreshSchedulerKey.self] = newValue }
    }

    /// Defaults to the real HTTP client; tests replace it with a stub.
    var feedFetcher: FeedFetcher {
        get { storage[FeedFetcherKey.self] ?? FeedFetcher(http: VaporHTTPFetcher(client: client)) }
        set { storage[FeedFetcherKey.self] = newValue }
    }

    func makeShowRefresher() -> ShowRefresher {
        ShowRefresher(
            db: db, fetcher: feedFetcher, mediaDirectory: appConfig.mediaDirectory,
            artwork: artworkProcessor, logger: logger
        )
    }
}
