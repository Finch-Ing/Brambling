import Fluent
import Vapor

struct RefreshOutcome: Sendable, Content, Equatable {
    var notModified: Bool
    var newEpisodes: Int
    var pruned: Int
}

/// One refresh of one show (plan §5.1): conditional GET, metadata upsert, new episodes, pruning.
/// Artwork and enqueueing follow in M3.
struct ShowRefresher: Sendable {
    let db: any Database
    let fetcher: FeedFetcher
    let mediaDirectory: URL
    var artwork: ArtworkProcessor?
    let logger: Logger
    var now: @Sendable () -> Date = { Date() }

    @discardableResult
    func refresh(_ show: Show) async throws -> RefreshOutcome {
        do {
            let result = try await fetcher.fetch(show.sourceURL, etag: show.etag, lastModified: show.lastModified)
            let outcome: RefreshOutcome
            switch result {
            case .notModified:
                outcome = RefreshOutcome(notModified: true, newEpisodes: 0, pruned: 0)
            case let .fetched(feed, etag, lastModified):
                show.etag = etag
                show.lastModified = lastModified
                outcome = try await apply(feed, to: show)
            }
            await updateArtworkIfNeeded(show)
            show.lastRefreshAt = now()
            show.lastError = nil
            try await show.save(on: db)
            logger.info("Refreshed \(show.slug): \(outcome.notModified ? "not modified" : "\(outcome.newEpisodes) new, \(outcome.pruned) pruned")")
            return outcome
        } catch {
            // Errors can echo the request URL, which may carry a token.
            let message = SecretMasking.redact(String(describing: error), secrets: [show.sourceURL])
            show.lastRefreshAt = now()
            show.lastError = message
            try? await show.save(on: db)
            logger.warning("Refresh of \(show.slug) failed: \(message)")
            throw error
        }
    }

    /// Artwork problems are logged but never fail a refresh. Caller saves the show.
    func updateArtworkIfNeeded(_ show: Show) async {
        guard let artwork, artwork.needsUpdate(for: show) else { return }
        do {
            try await artwork.update(show)
        } catch {
            let message = show.artworkSourceURL.map { SecretMasking.redact(String(describing: error), secrets: [$0]) }
            logger.warning("Artwork for \(show.slug) failed: \(message ?? String(describing: error))")
        }
    }

    /// Applies a parsed feed: metadata, every item as an episode (the full catalogue, plan §5.6),
    /// then `reconcile` decides which ones are kept.
    func apply(_ feed: ParsedFeed, to show: Show) async throws -> RefreshOutcome {
        show.title = feed.title
        show.siteURL = feed.link
        show.author = feed.author
        show.summary = feed.description
        show.language = feed.language
        show.artworkSourceURL = feed.artworkURL

        let showID = try show.requireID()
        let items = Self.dated(feed.items, now: now())

        // No transaction on purpose: SQLite answers "busy" when a read transaction tries to
        // upgrade to a write while the job queue is writing. Each save commits on its own, and a
        // refresh is idempotent, so the next one repairs anything a failed one left behind.
        let existing = try await Episode.query(on: db).filter(\.$show.$id == showID).all()
        let byGUID = Dictionary(existing.map { ($0.sourceGUID, $0) }, uniquingKeysWith: { first, _ in first })

        var created: [Episode] = []
        for (item, pubDate) in items {
            if let episode = byGUID[item.guid] {
                // Keep metadata fresh (private feeds rotate enclosure tokens), but only write real changes:
                // big feeds would otherwise rewrite hundreds of rows on every refresh.
                if Self.update(episode, from: item, pubDate: pubDate) {
                    try await episode.save(on: db)
                }
            } else {
                let episode = Episode(
                    showID: showID, sourceGUID: item.guid, title: item.title, pubDate: pubDate,
                    enclosureURL: item.enclosureURL, settingsHash: SettingsHash.make(show.processingSettings),
                    status: .available
                )
                _ = Self.update(episode, from: item, pubDate: pubDate)
                created.append(episode)
            }
        }
        if !created.isEmpty {
            // One statement for all new rows; a big back catalogue can be a thousand episodes.
            for batch in stride(from: 0, to: created.count, by: 200) {
                try await created[batch..<min(batch + 200, created.count)].create(on: db)
            }
        }

        let (queued, removed) = try await reconcile(show)
        return RefreshOutcome(notModified: false, newEpisodes: queued, pruned: removed)
    }

    /// Two exclusive modes (plan §5.6): `keepCount > 0` keeps the newest `keepCount` episodes;
    /// `keepCount == 0` (manual selection) keeps exactly the episodes the user selected (`kept`).
    /// The selection is remembered while the show is in "newest" mode.
    /// Newly kept episodes are queued; episodes that are no longer kept lose their file and become `available`.
    /// Returns (queued, removed).
    @discardableResult
    func reconcile(_ show: Show) async throws -> (queued: Int, removed: Int) {
        let showID = try show.requireID()
        let episodes = try await Episode.query(on: db)
            .filter(\.$show.$id == showID)
            .sort(\.$pubDate, .descending)
            .all()
        let newest = Set(episodes.prefix(max(0, show.keepCount)).compactMap(\.id))
        let settingsHash = SettingsHash.make(show.processingSettings)
        let mediaDirectory = mediaDirectory.appendingPathComponent(show.slug, isDirectory: true)

        var queued = 0
        var removed = 0
        for episode in episodes {
            let keep = show.isManualSelection ? episode.kept : newest.contains(episode.id ?? UUID())
            if keep, episode.status == .available {
                episode.status = .pending
                episode.settingsHash = settingsHash
                episode.attempts = 0
                episode.error = nil
                episode.nextAttemptAt = nil
                try await episode.save(on: db)
                queued += 1
            } else if !keep, episode.status != .available {
                if let fileName = episode.fileName {
                    try? FileManager.default.removeItem(at: mediaDirectory.appendingPathComponent(fileName))
                }
                episode.status = .available
                episode.fileName = nil
                episode.fileSize = nil
                episode.attempts = 0
                episode.error = nil
                episode.nextAttemptAt = nil
                try await episode.save(on: db)
                removed += 1
            }
        }
        return (queued, removed)
    }

    /// Copies feed metadata onto an episode; returns whether anything changed.
    static func update(_ episode: Episode, from item: ParsedItem, pubDate: Date) -> Bool {
        var changed = false
        func set<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<Episode, T>, _ value: T) {
            if episode[keyPath: keyPath] != value {
                episode[keyPath: keyPath] = value
                changed = true
            }
        }
        set(\.title, item.title)
        set(\.subtitle, item.subtitle)
        set(\.descriptionHTML, item.descriptionHTML)
        set(\.pubDate, pubDate)
        set(\.enclosureURL, item.enclosureURL)
        set(\.enclosureType, item.enclosureType)
        set(\.enclosureLength, item.enclosureLength)
        set(\.sourceDuration, item.duration)
        set(\.episodeNumber, item.episodeNumber)
        set(\.seasonNumber, item.seasonNumber)
        return changed
    }

    /// De-duplicated by GUID; items without a date keep their feed order by getting `now - index` seconds.
    static func dated(_ items: [ParsedItem], now: Date) -> [(ParsedItem, Date)] {
        var seen = Set<String>()
        return items.enumerated().compactMap { index, item -> (ParsedItem, Date)? in
            guard seen.insert(item.guid).inserted else { return nil }
            return (item, item.pubDate ?? now.addingTimeInterval(-Double(index)))
        }
    }

    /// Newest `keepCount` items by date, de-duplicated by GUID. Items without a date keep their
    /// feed order by getting `now - index` seconds.
    static func window(of items: [ParsedItem], keepCount: Int, now: Date) -> [(ParsedItem, Date)] {
        Array(dated(items, now: now).sorted { $0.1 > $1.1 }.prefix(max(0, keepCount)))
    }
}
