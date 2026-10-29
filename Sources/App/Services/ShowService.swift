import Fluent
import Vapor

/// Show and episode operations shared by the JSON API and the web UI.
/// Errors are `Abort`s with a user-facing reason; feed URLs in them are always masked.
struct ShowService: Sendable {
    let app: Application

    private var db: any Database { app.db }

    struct NewShow: Sendable {
        var sourceURL: String
        var slug: String?
        var titleOverride: String?
        var speed: Double = 1.0
        var smartSpeed = true
        var voiceBoost = true
        var keepCount = 10
        var enabled = true
    }

    /// Only non-nil fields are changed.
    struct SettingsChange: Sendable {
        var titleOverride: String?
        var speed: Double?
        var smartSpeed: Bool?
        var voiceBoost: Bool?
        var keepCount: Int?
        var enabled: Bool?
        /// true = manual selection (keepCount 0), false = newest `keepCount`.
        var manualSelection: Bool?
        /// true = feed in series order (oldest first).
        var seriesOrder: Bool?
    }

    static let keepCountRange = 0...200

    // MARK: - Feeds

    func fetchFeed(_ url: String) async throws -> (feed: ParsedFeed, etag: String?, lastModified: String?) {
        guard let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""), parsed.host != nil else {
            throw Abort(.unprocessableEntity, reason: "Please enter a full http(s) feed URL.")
        }
        do {
            guard case let .fetched(feed, etag, lastModified) = try await app.feedFetcher.fetch(url) else {
                throw Abort(.badGateway, reason: "The feed server answered 304 to an unconditional request.")
            }
            return (feed, etag, lastModified)
        } catch let abort as any AbortError {
            throw abort
        } catch {
            throw Abort(.unprocessableEntity, reason: SecretMasking.redact(String(describing: error), secrets: [url]))
        }
    }

    // MARK: - Shows

    func create(_ new: NewShow) async throws -> Show {
        if let slug = new.slug, !Slug.isValid(slug) {
            throw Abort(.unprocessableEntity, reason: "The slug may only contain a–z, 0–9 and single dashes (max \(Slug.maxLength) characters).")
        }
        guard Self.keepCountRange.contains(new.keepCount) else {
            throw Abort(.unprocessableEntity, reason: "Newest episodes to keep must be between 0 and 200.")
        }
        let (feed, etag, lastModified) = try await fetchFeed(new.sourceURL)

        let base = new.slug ?? Slug.make(from: new.titleOverride?.trimmed.nilIfEmpty ?? feed.title)
        let db = db
        let slug = try await Slug.unique(base) { candidate in
            try await Show.query(on: db).filter(\.$slug == candidate).count() > 0
        }

        let show = Show(
            slug: slug, title: feed.title, sourceURL: new.sourceURL,
            speed: new.speed, smartSpeed: new.smartSpeed, voiceBoost: new.voiceBoost,
            keepCount: new.keepCount, enabled: new.enabled
        )
        show.titleOverride = new.titleOverride?.trimmed.nilIfEmpty
        show.etag = etag
        show.lastModified = lastModified
        try await show.create(on: db)

        let refresher = app.makeShowRefresher()
        _ = try await refresher.apply(feed, to: show)
        await refresher.updateArtworkIfNeeded(show)
        show.lastRefreshAt = Date()
        try await show.save(on: db)
        app.logger.info("Added show \(show.slug)")
        await app.jobQueue.kick()
        return show
    }

    /// Settings changes only affect episodes processed from now on (plan §5.3); reprocessing is explicit.
    func update(_ show: Show, _ change: SettingsChange) async throws {
        if let keepCount = change.keepCount, !Self.keepCountRange.contains(keepCount) {
            throw Abort(.unprocessableEntity, reason: "Newest episodes to keep must be between 0 and 200.")
        }
        if let titleOverride = change.titleOverride { show.titleOverride = titleOverride.trimmed.nilIfEmpty }
        if let speed = change.speed { show.speed = ProcessingSettings.clampSpeed(speed) }
        if let smartSpeed = change.smartSpeed { show.smartSpeed = smartSpeed }
        if let voiceBoost = change.voiceBoost { show.voiceBoost = voiceBoost }
        let before = show.keepCount
        if change.manualSelection == true {
            try await switchToManualSelection(show)
        } else if let keepCount = change.keepCount {
            // Leaving manual mode needs a real count.
            show.keepCount = change.manualSelection == false ? max(1, keepCount) : keepCount
        }
        if let enabled = change.enabled { show.enabled = enabled }
        if let seriesOrder = change.seriesOrder { show.seriesOrder = seriesOrder }
        try await show.save(on: db)
        if show.keepCount != before {
            // Apply right away instead of waiting for the next refresh.
            try await app.makeShowRefresher().reconcile(show)
        }
        await app.jobQueue.kick()
    }

    /// Replaces the (secret) feed URL after checking that the new one is a readable feed.
    func replaceSource(_ show: Show, with url: String) async throws {
        _ = try await fetchFeed(url)
        show.sourceURL = url
        show.etag = nil
        show.lastModified = nil
        show.lastError = nil
        try await show.save(on: db)
        app.logger.info("Replaced feed URL of \(show.slug)")
        _ = try? await refresh(show)
    }

    func refresh(_ show: Show) async throws -> RefreshOutcome {
        do {
            guard let outcome = try await app.refreshScheduler.refresh(show) else {
                throw Abort(.conflict, reason: "A refresh of this show is already running.")
            }
            return outcome
        } catch let abort as any AbortError {
            throw abort
        } catch {
            throw Abort(.badGateway, reason: show.lastError ?? "Refresh failed")
        }
    }

    /// Plan §5.3: re-run ready episodes whose file was made with other settings.
    /// They keep their old file on disk until the new one is ready.
    func reprocess(_ show: Show) async throws -> Int {
        let hash = SettingsHash.make(show.processingSettings)
        let episodes = try await show.$episodes.query(on: db)
            .filter(\.$status == .ready)
            .filter(\.$settingsHash != hash)
            .all()
        for episode in episodes {
            episode.status = .pending
            episode.attempts = 0
            episode.error = nil
            episode.nextAttemptAt = nil
            try await episode.save(on: db)
        }
        await app.jobQueue.kick()
        return episodes.count
    }

    func delete(_ show: Show) async throws {
        let config = app.appConfig
        let showID = try show.requireID()
        try await Episode.query(on: db).filter(\.$show.$id == showID).delete()
        try await show.delete(on: db)
        try? FileManager.default.removeItem(at: config.mediaDirectory.appendingPathComponent(show.slug, isDirectory: true))
        try? FileManager.default.removeItem(at: config.artDirectory.appendingPathComponent("\(show.slug).jpg"))
        app.logger.info("Deleted show \(show.slug)")
    }

    // MARK: - Episode selection (plan §5.6)

    enum Selection: Sendable {
        case episodes([UUID])
        /// By `itunes:episode` number, optionally within one season.
        case numbers(from: Int, to: Int, season: Int?)
        case all
    }

    struct SelectionResult: Content {
        var changed: Int
        var queued: Int
        var removed: Int
    }

    /// Selects episodes (downloaded, processed, in the feed) or deselects them (file deleted).
    /// Choosing episodes only makes sense in manual mode, so the show switches to it.
    func setKept(_ show: Show, _ selection: Selection, kept: Bool) async throws -> SelectionResult {
        let showID = try show.requireID()
        try await switchToManualSelection(show)
        var query = Episode.query(on: db).filter(\.$show.$id == showID)
        switch selection {
        case let .episodes(ids):
            guard !ids.isEmpty else { throw Abort(.unprocessableEntity, reason: "No episodes selected.") }
            query = query.filter(\.$id ~~ ids)
        case let .numbers(from, to, season):
            guard from <= to else { throw Abort(.unprocessableEntity, reason: "The first episode number must not be larger than the last.") }
            let numbered = try await Episode.query(on: db).filter(\.$show.$id == showID).filter(\.$episodeNumber != nil).count()
            guard numbered > 0 else {
                throw Abort(.unprocessableEntity, reason: "This feed has no episode numbers. Select the episodes in the list instead.")
            }
            query = query.filter(\.$episodeNumber >= from).filter(\.$episodeNumber <= to)
            if let season { query = query.filter(\.$seasonNumber == season) }
        case .all:
            break
        }
        let episodes = try await query.filter(\.$kept != kept).all()
        for episode in episodes {
            episode.kept = kept
            try await episode.save(on: db)
        }
        let (queued, removed) = try await app.makeShowRefresher().reconcile(show)
        await app.jobQueue.kick()
        app.logger.info("\(kept ? "Kept" : "Unkept") \(episodes.count) episode(s) of \(show.slug): \(queued) queued, \(removed) removed")
        return SelectionResult(changed: episodes.count, queued: queued, removed: removed)
    }

    /// Sets the manual selection to exactly `ids` (the checked boxes in the UI): everything else of
    /// this show is deselected, and downloaded episodes that are no longer selected lose their file.
    func setSelection(_ show: Show, to ids: Set<UUID>) async throws -> SelectionResult {
        let showID = try show.requireID()
        try await switchToManualSelection(show)
        let episodes = try await Episode.query(on: db).filter(\.$show.$id == showID).all()
        var changed = 0
        for episode in episodes {
            let selected = episode.id.map(ids.contains) ?? false
            if episode.kept != selected {
                episode.kept = selected
                try await episode.save(on: db)
                changed += 1
            }
        }
        let (queued, removed) = try await app.makeShowRefresher().reconcile(show)
        await app.jobQueue.kick()
        app.logger.info("Selection of \(show.slug) set to \(ids.count) episode(s): \(queued) queued, \(removed) removed")
        return SelectionResult(changed: changed, queued: queued, removed: removed)
    }

    /// Switching from "newest N" to manual selection starts with the episodes the show has now,
    /// so no finished file is thrown away. A selection made earlier is remembered and reused.
    func switchToManualSelection(_ show: Show) async throws {
        guard !show.isManualSelection else { return }
        let showID = try show.requireID()
        let hasSelection = try await Episode.query(on: db).filter(\.$show.$id == showID).filter(\.$kept == true).count() > 0
        if !hasSelection {
            let current = try await Episode.query(on: db).filter(\.$show.$id == showID).filter(\.$status != .available).all()
            for episode in current {
                episode.kept = true
                try await episode.save(on: db)
            }
        }
        show.keepCount = 0
        try await show.save(on: db)
    }

    /// Rough size of the episodes that aren't downloaded yet, from the feed's enclosure lengths.
    func estimatedSizeOfAvailable(_ show: Show) async throws -> (count: Int, bytes: Int64) {
        let available = try await show.$episodes.query(on: db).filter(\.$status == .available).all()
        let known = available.compactMap(\.enclosureLength)
        let average = known.isEmpty ? Int(DiskGuard.unknownSourceSize / 4) : known.reduce(0, +) / known.count
        let total = available.reduce(Int64(0)) { $0 + Int64($1.enclosureLength ?? average) }
        return (available.count, total)
    }

    // MARK: - Episodes

    func retry(_ episode: Episode) async throws {
        guard episode.status == .failed else {
            throw Abort(.conflict, reason: "Only failed episodes can be retried (status is \(episode.status.rawValue)).")
        }
        episode.status = .pending
        episode.attempts = 0
        episode.error = nil
        episode.nextAttemptAt = nil
        try await episode.save(on: db)
        await app.jobQueue.kick()
    }
}

extension Application {
    var shows: ShowService { ShowService(app: self) }
}
