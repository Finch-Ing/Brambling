import Fluent
import Leaf
import Vapor

/// The web UI (plan §8): server-rendered Leaf pages, HTMX only for the episode table polling.
struct WebController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get(use: index)
        routes.get("shows", "new", use: newShow)
        routes.post("shows", "preview", use: preview)
        routes.post("shows", use: create)
        routes.post("shows", "refresh-all", use: refreshAll)
        routes.group("shows", ":showID") { show in
            show.get(use: detail)
            show.get("archive", use: archive)
            // A full selection can be hundreds of IDs; the default 16 KB body limit is too small.
            show.on(.POST, "archive", body: .collect(maxSize: "1mb"), use: keepSelected)
            show.post("archive", "range", use: keepRange)
            show.post("archive", "all", use: keepAll)
            show.get("episodes", use: episodesPartial)
            show.post(use: update)
            show.post("refresh", use: refresh)
            show.post("reprocess", use: reprocess)
            show.post("source", use: replaceSource)
            show.post("delete", use: delete)
        }
        routes.post("episodes", ":episodeID", "retry", use: retry)
        routes.get("settings", use: settings)
        routes.post("settings", "window", use: saveWindow)
        routes.get("status", "footer", use: footerPartial)
        routes.post("queue", "process-now", use: processNow)
    }

    // MARK: - View models

    struct Footer: Encodable {
        var state: String
        /// idle / ok / busy / warn — drives the dot's color.
        var stateClass: String
        var disk: String
    }

    struct Layout: Encodable {
        var diskBlockedReason: String?
        var footer: Footer
        /// Status line on the homepage and show pages.
        var queueSummary: String
        var windowLabel: String?
        var windowClosed: Bool
        var processNowActive: Bool
    }

    /// `/status/footer` renders footer.leaf with the same shape as a page's layout.
    struct FooterPartial: Encodable {
        struct OnlyFooter: Encodable { var footer: Footer }
        var layout: OnlyFooter
    }

    struct ShowView: Encodable {
        var id: UUID
        var slug: String
        var title: String
        var sourceTitle: String
        var titleOverride: String?
        var hasArtwork: Bool
        var speedLabel: String
        var speedValue: String
        var smartSpeed: Bool
        var voiceBoost: Bool
        var keepCount: Int
        /// Manual selection mode (keepCount 0).
        var manual: Bool
        /// What the "newest N" field shows, also while in manual mode.
        var newestCount: Int
        var seriesOrder: Bool
        var enabled: Bool
        var lastRefresh: String
        var lastError: String?
        var feedURL: String
        /// For podcast apps that don't accept the HTTPS certificate; `nil` when the UI is plain HTTP anyway.
        var plainFeedURL: String?
        var totalCount: Int
        var maskedSourceURL: String
        var diskUsage: String
        var readyCount: Int
        var workingCount: Int
        var failedCount: Int
    }

    struct EpisodeView: Encodable {
        var id: UUID
        var title: String
        /// Only when it adds something beyond the description's start.
        var subtitle: String?
        /// Plain-text start of the description; the list shows two lines of it.
        var excerpt: String?
        var date: String
        var statusLabel: String
        var statusClass: String
        var canRetry: Bool
        var duration: String
        var size: String
        var error: String?
    }

    struct IndexPage: Encodable {
        var pageTitle = "Shows"
        var layout: Layout
        var notice: String?
        var error: String?
        var showRefreshAll = true
        var backPath = "/"
        var hasShows: Bool
        var shows: [ShowView]
    }

    struct PreviewView: Encodable {
        struct Item: Encodable {
            var title: String
            var date: String
            var duration: String
        }

        var id: String
        var title: String
        var author: String?
        var artworkURL: String?
        var episodeCount: Int
        var maskedURL: String
        var suggestedSlug: String
        var latest: [Item]
    }

    struct NewPage: Encodable {
        var pageTitle = "Add show"
        var layout: Layout
        var notice: String?
        var error: String?
        /// Only echoed back after a failed preview; never the stored URL of a successful one.
        var sourceURLInput: String?
        var preview: PreviewView?
    }

    struct ShowPage: Encodable {
        var pageTitle: String
        var layout: Layout
        var notice: String?
        var error: String?
        var show: ShowView
        var showID: UUID
        var backPath: String
        var episodes: [EpisodeView]
        var hasEpisodes: Bool
        var manual: Bool
        var outdatedCount: Int
        /// Only in manual mode: the full source feed to choose from.
        var chooser: Chooser?
    }

    struct Chooser: Encodable {
        var totalCount: Int
        var keptCount: Int
        var availableCount: Int
        var availableSize: String
        var hasNumbers: Bool
        var hasSeasons: Bool
        var episodes: [ArchiveEpisodeView]
    }

    struct ArchiveEpisodeView: Encodable {
        var id: UUID
        /// Has a processed file that deselecting would delete.
        var downloaded: Bool
        var numberLabel: String
        var title: String
        var subtitle: String?
        var excerpt: String?
        var date: String
        var duration: String
        var statusLabel: String
        var statusClass: String
        var kept: Bool
        var inNewest: Bool
        var searchText: String
    }


    struct EpisodesPartial: Encodable {
        var showID: UUID
        var episodes: [EpisodeView]
        var hasEpisodes: Bool
        var manual: Bool
    }

    struct SettingsPage: Encodable {
        struct Window: Encodable {
            var configured: Bool
            var label: String
            var state: String
            /// `HH:MM` for the time inputs; a sensible night window when none is set.
            var start: String
            var end: String
            /// The server's clock, which the window is measured against.
            var localTime: String
            var timeZone: String
            /// Milliseconds since 1970, so the page's clock can keep ticking.
            var nowMillis: Int64
        }

        struct Queue: Encodable {
            var summary: String
            var processNowOverride: Bool
        }

        struct Disk: Encodable {
            var free: String
            var media: String
            var tmp: String
            var minFree: String
            var maxMedia: String
        }

        struct ShowUsage: Encodable {
            var id: UUID
            var title: String
            var readyCount: Int
            var size: String
        }

        var pageTitle = "Settings"
        var layout: Layout
        var notice: String?
        var error: String?
        var window: Window
        var queue: Queue
        var refreshMinutes: Int
        var downloadConcurrency: Int
        var ffmpegConcurrency: Int
        var ffmpegVersion: String
        var publicBaseURL: String
        var disk: Disk
        var hasShows: Bool
        var perShow: [ShowUsage]
    }

    // MARK: - Pages

    @Sendable
    func index(req: Request) async throws -> View {
        let shows = try await Show.query(on: req.db).with(\.$episodes).sort(\.$createdAt).all()
        let views = try shows.map { try showView($0, episodes: $0.episodes, req: req) }
        return try await req.view.render("index", IndexPage(
            layout: await layout(req), notice: notice(req), hasShows: !views.isEmpty, shows: views
        ))
    }

    @Sendable
    func newShow(req: Request) async throws -> View {
        try await req.view.render("new", NewPage(layout: await layout(req)))
    }

    struct PreviewForm: Content {
        var sourceURL: String
    }

    @Sendable
    func preview(req: Request) async throws -> Response {
        let form = try req.content.decode(PreviewForm.self)
        let url = form.sourceURL.trimmed
        do {
            let feed = try await req.application.shows.fetchFeed(url).feed
            let id = await req.application.previewStore.put(url)
            let items = feed.items.sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
            let view = PreviewView(
                id: id,
                title: feed.title,
                author: feed.author,
                artworkURL: feed.artworkURL,
                episodeCount: feed.items.count,
                maskedURL: SecretMasking.mask(url: url),
                suggestedSlug: Slug.make(from: feed.title),
                latest: items.prefix(3).map { .init(title: $0.title, date: Format.date($0.pubDate), duration: Format.duration($0.duration)) }
            )
            return try await req.view.render("new", NewPage(layout: await layout(req), preview: view)).encodeResponse(for: req)
        } catch let abort as any AbortError {
            let page = NewPage(layout: await layout(req), error: abort.reason, sourceURLInput: url)
            return try await req.view.render("new", page).encodeResponse(status: .unprocessableEntity, for: req)
        }
    }

    struct CreateForm: Content {
        var previewID: String
        var mode: String?
        var slug: String?
        var titleOverride: String?
        var speed: Double?
        var smartSpeed: String?
        var voiceBoost: String?
        var keepCount: Int?
    }

    @Sendable
    func create(req: Request) async throws -> Response {
        let form = try req.content.decode(CreateForm.self)
        guard let url = await req.application.previewStore.get(form.previewID) else {
            let page = NewPage(layout: await layout(req), error: "The preview expired. Please enter the feed URL again.")
            return try await req.view.render("new", page).encodeResponse(status: .unprocessableEntity, for: req)
        }
        do {
            let show = try await req.application.shows.create(.init(
                sourceURL: url,
                slug: form.slug?.trimmed.nilIfEmpty,
                titleOverride: form.titleOverride,
                speed: form.speed ?? 1.0,
                smartSpeed: form.smartSpeed != nil,
                voiceBoost: form.voiceBoost != nil,
                keepCount: form.mode == "manual" ? 0 : max(1, form.keepCount ?? 10)
            ))
            await req.application.previewStore.remove(form.previewID)
            return req.redirect(to: "/shows/\(try show.requireID())?notice=added")
        } catch let abort as any AbortError {
            let page = NewPage(layout: await layout(req), error: abort.reason)
            return try await req.view.render("new", page).encodeResponse(status: .unprocessableEntity, for: req)
        }
    }

    @Sendable
    func detail(req: Request) async throws -> View {
        try await renderShow(try await findShow(req), req: req, notice: notice(req))
    }

    @Sendable
    func episodesPartial(req: Request) async throws -> View {
        let show = try await findShow(req)
        let episodes = try await visibleEpisodes(show, req: req)
        return try await req.view.render("episodes", EpisodesPartial(
            showID: try show.requireID(), episodes: episodes.map { episodeView($0, req: req) },
            hasEpisodes: !episodes.isEmpty, manual: show.isManualSelection
        ))
    }

    struct SettingsForm: Content {
        var mode: String?
        var order: String?
        var titleOverride: String?
        var speed: Double?
        var smartSpeed: String?
        var voiceBoost: String?
        var keepCount: Int?
        var enabled: String?
    }

    @Sendable
    func update(req: Request) async throws -> Response {
        let show = try await findShow(req)
        let form = try req.content.decode(SettingsForm.self)
        // Unchecked checkboxes aren't sent at all, so absence means "off".
        return try await perform(req, show: show, notice: "saved") {
            try await req.application.shows.update(show, .init(
                titleOverride: form.titleOverride ?? "",
                speed: form.speed,
                smartSpeed: form.smartSpeed != nil,
                voiceBoost: form.voiceBoost != nil,
                keepCount: form.keepCount,
                enabled: form.enabled != nil,
                manualSelection: form.mode.map { $0 == "manual" },
                seriesOrder: form.order.map { $0 == "series" }
            ))
        }
    }

    @Sendable
    func refresh(req: Request) async throws -> Response {
        let show = try await findShow(req)
        return try await perform(req, show: show, notice: "refreshed") {
            _ = try await req.application.shows.refresh(show)
        }
    }

    @Sendable
    func reprocess(req: Request) async throws -> Response {
        let show = try await findShow(req)
        return try await perform(req, show: show, notice: "reprocessing") {
            _ = try await req.application.shows.reprocess(show)
        }
    }

    @Sendable
    func replaceSource(req: Request) async throws -> Response {
        let show = try await findShow(req)
        let form = try req.content.decode(PreviewForm.self)
        return try await perform(req, show: show, notice: "source-replaced") {
            try await req.application.shows.replaceSource(show, with: form.sourceURL.trimmed)
        }
    }

    @Sendable
    func delete(req: Request) async throws -> Response {
        let show = try await findShow(req)
        try await req.application.shows.delete(show)
        return req.redirect(to: "/?notice=deleted")
    }

    @Sendable
    func retry(req: Request) async throws -> Response {
        guard let id = req.parameters.get("episodeID", as: UUID.self),
              let episode = try await Episode.find(id, on: req.db)
        else { throw Abort(.notFound) }
        let show = try await episode.$show.get(on: req.db)
        return try await perform(req, show: show, notice: "retrying") {
            try await req.application.shows.retry(episode)
        }
    }

    @Sendable
    func settings(req: Request) async throws -> View {
        try await renderSettings(req)
    }

    struct WindowForm: Content {
        /// "any" or "window".
        var mode: String
        var start: String?
        var end: String?
    }

    /// Saves the processing window; it applies right away and overrides `BRAMBLING_PROCESS_WINDOW`.
    @Sendable
    func saveWindow(req: Request) async throws -> Response {
        let form = try req.content.decode(WindowForm.self)
        let window: ProcessingWindow?
        do {
            window = form.mode == "any" ? nil : try ProcessingWindow(parsing: "\(form.start ?? "")-\(form.end ?? "")")
        } catch {
            let message = "Please enter a start and an end time that differ, e.g. 01:00 and 06:00."
            return try await renderSettings(req, error: message).encodeResponse(status: .unprocessableEntity, for: req)
        }
        let stored = window.map { String(format: "%02d:%02d-%02d:%02d", $0.start / 60, $0.start % 60, $0.end / 60, $0.end % 60) } ?? ""
        try await AppSetting.set(AppSetting.processWindowKey, to: stored, on: req.db)
        req.application.appConfig.processWindow = window
        req.logger.info("Processing window set to \(window?.description ?? "any time")")
        // An opened (or removed) window may let waiting episodes start now.
        await req.application.jobQueue.kick()
        return req.redirect(to: "/settings?notice=window-saved")
    }

    private func renderSettings(_ req: Request, error: String? = nil) async throws -> View {
        let app = req.application
        let config = app.appConfig
        let status = try await app.jobQueue.status()
        let env = app.jobEnvironment
        let now = env.now()
        let timeZone = env.calendar.timeZone

        var windowState = "Episodes are processed right after downloading."
        if let window = config.processWindow {
            windowState = status.processWindowOpen
                ? "Open now, until \(Self.clock(window.end))."
                : "Closed. Next run starts \(Format.dateTime(window.nextOpening(after: now, calendar: env.calendar), timeZone: timeZone))."
        }
        let working = ["pending", "downloading", "downloaded", "processing"].reduce(0) { $0 + (status.counts[$1] ?? 0) }
        var summary = "\(working) episode(s) waiting or in progress"
        if status.activeDownloads + status.activeProcessing > 0 {
            summary += " · running: \(status.activeDownloads) download(s), \(status.activeProcessing) ffmpeg"
        }
        if let failed = status.counts["failed"], failed > 0 { summary += " · \(failed) failed" }

        let shows = try await Show.query(on: req.db).with(\.$episodes).sort(\.$createdAt).all()
        let perShow = try shows.map { show -> SettingsPage.ShowUsage in
            let files = show.episodes.filter { $0.fileName != nil }
            return .init(
                id: try show.requireID(), title: show.displayTitle,
                readyCount: show.episodes.filter { $0.status == .ready }.count,
                size: Format.bytes(Int64(files.compactMap(\.fileSize).reduce(0, +)))
            )
        }

        return try await req.view.render("settings", SettingsPage(
            layout: await layout(req),
            notice: notice(req),
            error: error,
            window: .init(
                configured: config.processWindow != nil,
                label: config.processWindow?.description ?? "any time",
                state: windowState,
                start: Self.clock(config.processWindow?.start ?? 60),
                end: Self.clock(config.processWindow?.end ?? 360),
                localTime: Self.localTime(now, timeZone: timeZone),
                timeZone: timeZone.identifier,
                nowMillis: Int64(now.timeIntervalSince1970 * 1000)
            ),
            queue: .init(summary: summary, processNowOverride: status.processNowOverride),
            refreshMinutes: config.refreshMinutes,
            downloadConcurrency: config.downloadConcurrency,
            ffmpegConcurrency: config.ffmpegConcurrency,
            // "ffmpeg version 7.1.5-0+deb13u1 Copyright (c) …" → "7.1.5-0+deb13u1"
            ffmpegVersion: app.ffmpegCapabilities.version.map { line in
                line.split(separator: " ").dropFirst(2).first.map(String.init) ?? line
            } ?? "not found",
            publicBaseURL: config.publicBaseURL.absoluteString,
            disk: .init(
                free: Format.bytes(env.freeBytes(config.dataDirectory)),
                media: Format.bytes(try await app.jobQueue.mediaBytes()),
                tmp: Format.bytes(DiskGuard.directorySize(config.tmpDirectory)),
                minFree: Format.bytes(config.diskLimits.minFreeBytes),
                maxMedia: config.diskLimits.maxMediaBytes.map { Format.bytes($0) } ?? "none"
            ),
            hasShows: !perShow.isEmpty,
            perShow: perShow
        ))
    }

    /// Minutes since midnight → `HH:MM`.
    static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// "Tue 28 Oct, 17:42" in the server's time zone.
    static func localTime(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE d MMM, HH:mm"
        return formatter.string(from: date)
    }

    struct BackForm: Content {
        var back: String?
    }

    @Sendable
    func processNow(req: Request) async throws -> Response {
        await req.application.jobQueue.processNow()
        let back = (try? req.content.decode(BackForm.self))?.back ?? "/settings"
        // Only local paths, so the form can't be abused as an open redirect.
        let target = back.hasPrefix("/") && !back.hasPrefix("//") && !back.contains("?") ? back : "/settings"
        return req.redirect(to: "\(target)?notice=processing-now")
    }

    /// Refreshes all feeds in the background; the page doesn't wait for slow feed servers.
    @Sendable
    func refreshAll(req: Request) async throws -> Response {
        await req.application.refreshScheduler.refreshAllInBackground()
        return req.redirect(to: "/?notice=refreshing-all")
    }

    // MARK: - Archive (plan §5.6)

    /// The chooser now lives on the show page.
    @Sendable
    func archive(req: Request) async throws -> Response {
        req.redirect(to: "/shows/\(try await findShow(req).requireID())#choose")
    }

    @Sendable
    func footerPartial(req: Request) async throws -> View {
        try await req.view.render("footer", FooterPartial(layout: .init(footer: await footer(req))))
    }

    struct KeepSelectedForm: Content {
        var action: String
        var episodes: [UUID]?
    }

    /// `action=save` (the checkboxes = the new selection) or `keep` / `unkeep` for the listed episodes.
    @Sendable
    func keepSelected(req: Request) async throws -> Response {
        let show = try await findShow(req)
        let form = try req.content.decode(KeepSelectedForm.self)
        if form.action == "save" {
            let id = try show.requireID()
            _ = try await req.application.shows.setSelection(show, to: Set(form.episodes ?? []))
            return req.redirect(to: "/shows/\(id)?notice=selection-saved#choose")
        }
        return try await performSelection(req, show: show, action: form.action, selection: .episodes(form.episodes ?? []))
    }

    struct KeepRangeForm: Content {
        var action: String
        var from: Int
        var to: Int
        /// Text, because the empty "any season" field is sent as `season=`.
        var season: String?
    }

    @Sendable
    func keepRange(req: Request) async throws -> Response {
        let show = try await findShow(req)
        let form = try req.content.decode(KeepRangeForm.self)
        return try await performSelection(req, show: show, action: form.action, selection: .numbers(from: form.from, to: form.to, season: form.season.flatMap { Int($0.trimmed) }))
    }

    @Sendable
    func keepAll(req: Request) async throws -> Response {
        let show = try await findShow(req)
        return try await performSelection(req, show: show, action: "keep", selection: .all)
    }

    private func performSelection(_ req: Request, show: Show, action: String, selection: ShowService.Selection) async throws -> Response {
        let id = try show.requireID()
        do {
            guard action == "keep" || action == "unkeep" else { throw Abort(.badRequest, reason: "Unknown action.") }
            _ = try await req.application.shows.setKept(show, selection, kept: action == "keep")
            return req.redirect(to: "/shows/\(id)?notice=\(action == "keep" ? "kept" : "unkept")#choose")
        } catch let abort as any AbortError {
            return try await renderShow(show, req: req, error: abort.reason).encodeResponse(status: abort.status, for: req)
        }
    }

    private func chooser(_ show: Show, episodes: [Episode], req: Request) async throws -> Chooser {
        let estimate = try await req.application.shows.estimatedSizeOfAvailable(show)
        let views = episodes.map { episode -> ArchiveEpisodeView in
            let base = episodeView(episode, req: req)
            var number = ""
            if let n = episode.episodeNumber {
                number = episode.seasonNumber.map { "S\($0) E\(n)" } ?? "\(n)"
            }
            return ArchiveEpisodeView(
                id: base.id,
                downloaded: episode.fileName != nil,
                numberLabel: number,
                title: episode.title,
                subtitle: base.subtitle,
                excerpt: base.excerpt,
                date: base.date,
                duration: base.duration,
                statusLabel: episode.status == .available ? "not selected" : base.statusLabel,
                statusClass: base.statusClass,
                kept: episode.kept,
                inNewest: false,
                searchText: [number, episode.episodeNumber.map { "#\($0)" }, episode.title, base.subtitle]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ").lowercased()
            )
        }
        return Chooser(
            totalCount: episodes.count,
            keptCount: episodes.filter(\.kept).count,
            availableCount: estimate.count,
            availableSize: Format.bytes(estimate.bytes),
            hasNumbers: episodes.contains { $0.episodeNumber != nil },
            hasSeasons: Set(episodes.compactMap(\.seasonNumber)).count > 1,
            episodes: views
        )
    }

    // MARK: - Helpers

    static let notices: [String: String] = [
        "added": "Show added. Episodes are being downloaded and processed.",
        "saved": "Settings saved. They apply to episodes processed from now on.",
        "refreshed": "Feed refreshed.",
        "reprocessing": "Episodes queued for reprocessing.",
        "source-replaced": "Feed URL replaced.",
        "deleted": "Show deleted.",
        "retrying": "Episode queued again.",
        "processing-now": "Processing now, ignoring the window until the queue is empty.",
        "window-saved": "Processing time saved. It applies right away.",
        "refreshing-all": "Refreshing all feeds in the background.",
        "selection-saved": "Selection saved. New episodes are downloaded and processed; deselected ones were removed.",
        "kept": "Episodes selected. They are downloaded and processed now (or in the processing window).",
        "unkept": "Episodes deselected. Their files were deleted.",
    ]

    /// Notices are fixed texts picked by a code, so a crafted link can't inject a message.
    private func notice(_ req: Request) -> String? {
        req.query[String.self, at: "notice"].flatMap { Self.notices[$0] }
    }

    /// Runs an action; on success redirects back to the show, on a user error re-renders it with the message.
    private func perform(
        _ req: Request, show: Show, notice: String, _ action: () async throws -> Void
    ) async throws -> Response {
        do {
            try await action()
            return req.redirect(to: "/shows/\(try show.requireID())?notice=\(notice)")
        } catch let abort as any AbortError {
            return try await renderShow(show, req: req, error: abort.reason).encodeResponse(status: abort.status, for: req)
        }
    }

    private func renderShow(_ show: Show, req: Request, notice: String? = nil, error: String? = nil) async throws -> View {
        let all = Self.displayOrder(try await show.$episodes.query(on: req.db).sort(\.$pubDate, .descending).all(), for: show)
        let visible = all.filter { $0.status != .available }
        let hash = SettingsHash.make(show.processingSettings)
        return try await req.view.render("show", ShowPage(
            pageTitle: show.displayTitle,
            layout: await layout(req),
            notice: notice,
            error: error,
            show: try showView(show, episodes: all, req: req),
            showID: try show.requireID(),
            backPath: "/shows/\(try show.requireID())",
            episodes: visible.map { episodeView($0, req: req) },
            hasEpisodes: !visible.isEmpty,
            manual: show.isManualSelection,
            outdatedCount: visible.filter { $0.status == .ready && $0.settingsHash != hash }.count,
            chooser: show.isManualSelection ? try await chooser(show, episodes: all, req: req) : nil
        ))
    }

    private func visibleEpisodes(_ show: Show, req: Request) async throws -> [Episode] {
        Self.displayOrder(try await show.$episodes.query(on: req.db)
            .filter(\.$status != .available)
            .sort(\.$pubDate, .descending)
            .all(), for: show)
    }

    /// Lists follow the feed: newest first, or the series order when the show is set to "oldest first".
    static func displayOrder(_ episodes: [Episode], for show: Show) -> [Episode] {
        show.seriesOrder ? SeriesOrder.sorted(episodes) : episodes
    }

    private func findShow(_ req: Request) async throws -> Show {
        guard let id = req.parameters.get("showID", as: UUID.self),
              let show = try await Show.find(id, on: req.db)
        else { throw Abort(.notFound) }
        return show
    }

    private func layout(_ req: Request) async -> Layout {
        let app = req.application
        let queue = app.jobQueue
        let status = try? await queue.status()
        let counts = status?.counts ?? [:]
        let waiting = (counts["pending"] ?? 0) + (counts["downloading"] ?? 0) + (counts["downloaded"] ?? 0)
        var parts: [String] = []
        if let processing = counts["processing"], processing > 0 { parts.append("\(processing) processing") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        if let failed = counts["failed"], failed > 0 { parts.append("\(failed) failed") }

        var windowLabel: String?
        var windowClosed = false
        if let window = app.appConfig.processWindow, let status {
            windowClosed = !status.processWindowOpen
            windowLabel = windowClosed
                ? "\(window) (closed, opens \(Format.dateTime(status.nextProcessWindowOpening)))"
                : "\(window) (open)"
        }
        return Layout(
            diskBlockedReason: await queue.diskBlockedReason,
            footer: await footer(req),
            queueSummary: parts.isEmpty ? "All caught up" : parts.joined(separator: " · "),
            windowLabel: windowLabel,
            windowClosed: windowClosed,
            processNowActive: status?.processNowOverride ?? false
        )
    }

    /// One line for the status bar: what Brambling is doing right now, plus free disk space.
    private func footer(_ req: Request) async -> Footer {
        let app = req.application
        let config = app.appConfig
        let env = app.jobEnvironment
        let disk = env.freeBytes(config.dataDirectory).map { "\(Format.bytes($0)) free" } ?? ""
        guard let status = try? await app.jobQueue.status() else {
            return Footer(state: "Status unavailable", stateClass: "warn", disk: disk)
        }
        if let reason = status.diskBlockedReason {
            return Footer(state: "Paused by the disk guard: \(reason)", stateClass: "warn", disk: disk)
        }
        let counts = status.counts
        if let processing = try? await Episode.query(on: req.db).filter(\.$status == .processing).with(\.$show).first() {
            return Footer(state: "Processing “\(processing.title)” (\(processing.show.displayTitle))", stateClass: "busy", disk: disk)
        }
        if let downloading = counts["downloading"], downloading > 0 {
            return Footer(state: "Downloading \(downloading) episode(s)", stateClass: "busy", disk: disk)
        }
        let downloaded = counts["downloaded"] ?? 0
        if downloaded > 0, !status.processWindowOpen, !status.processNowOverride {
            return Footer(
                state: "\(downloaded) episode(s) waiting for the processing window (opens \(Format.dateTime(status.nextProcessWindowOpening)))",
                stateClass: "idle", disk: disk
            )
        }
        let waiting = (counts["pending"] ?? 0) + downloaded
        if waiting > 0 {
            return Footer(state: "\(waiting) episode(s) waiting", stateClass: "idle", disk: disk)
        }
        if let failed = counts["failed"], failed > 0 {
            return Footer(state: "Idle · \(failed) failed episode(s)", stateClass: "warn", disk: disk)
        }
        return Footer(state: "Idle", stateClass: "ok", disk: disk)
    }

    private func showView(_ show: Show, episodes: [Episode], req: Request) throws -> ShowView {
        let config = req.application.appConfig
        let working: Set<EpisodeStatus> = [.pending, .downloading, .downloaded, .processing]
        let mediaBytes = episodes.filter { $0.fileName != nil }.compactMap(\.fileSize).reduce(0, +)
        let readyCount = episodes.filter { $0.status == .ready }.count
        // The address the browser used, so the copied URL works from the same network (e.g. http://<host-ip>:8080).
        let baseURL = FeedController.baseURL(for: req, fallback: config.publicBaseURL)
        let feedURL = FeedWriter.feedURL(slug: show.slug, baseURL: baseURL).absoluteString
        return ShowView(
            id: try show.requireID(),
            slug: show.slug,
            title: show.displayTitle,
            sourceTitle: show.title,
            titleOverride: show.titleOverride,
            hasArtwork: FileManager.default.fileExists(atPath: config.artDirectory.appendingPathComponent("\(show.slug).jpg").path),
            speedLabel: Format.speed(show.speed),
            speedValue: String(format: "%.2f", show.speed),
            smartSpeed: show.smartSpeed,
            voiceBoost: show.voiceBoost,
            keepCount: show.keepCount,
            manual: show.isManualSelection,
            newestCount: show.isManualSelection ? 10 : show.keepCount,
            seriesOrder: show.seriesOrder,
            enabled: show.enabled,
            lastRefresh: Format.relative(show.lastRefreshAt, now: req.application.jobEnvironment.now()),
            lastError: show.lastError,
            feedURL: feedURL,
            plainFeedURL: feedURL.hasPrefix("https://") ? feedURL.replacingOccurrences(of: "https://", with: "http://") : nil,
            totalCount: episodes.count,
            maskedSourceURL: SecretMasking.mask(url: show.sourceURL),
            diskUsage: "\(readyCount) episode(s), \(Format.bytes(Int64(mediaBytes)))",
            readyCount: readyCount,
            workingCount: episodes.filter { working.contains($0.status) }.count,
            failedCount: episodes.filter { $0.status == .failed }.count
        )
    }

    private func episodeView(_ episode: Episode, req: Request) -> EpisodeView {
        let config = req.application.appConfig
        let env = req.application.jobEnvironment
        let label: String
        let cssClass: String
        switch episode.status {
        case .pending:
            label = episode.attempts > 0 ? "retry \(Format.dateTime(episode.nextAttemptAt))" : "waiting"
            cssClass = episode.attempts > 0 ? "warn" : ""
        case .downloading: label = "downloading"; cssClass = ""
        case .downloaded:
            if let window = config.processWindow, !window.contains(env.now(), calendar: env.calendar) {
                label = "waiting for processing window (\(window))"
            } else {
                label = episode.attempts > 0 ? "retry \(Format.dateTime(episode.nextAttemptAt))" : "downloaded"
            }
            cssClass = episode.attempts > 0 ? "warn" : ""
        case .processing: label = "processing"; cssClass = ""
        case .ready: label = "ready"; cssClass = "ok"
        case .failed: label = "failed"; cssClass = "err"
        case .available: label = "not kept"; cssClass = ""
        }
        let excerpt = PlainText.excerpt(episode.descriptionHTML)
        return EpisodeView(
            id: episode.id ?? UUID(),
            title: episode.title,
            subtitle: PlainText.subtitle(episode.subtitle, addsTo: excerpt) ? episode.subtitle?.trimmed : nil,
            excerpt: excerpt,
            date: Format.date(episode.pubDate),
            statusLabel: label,
            statusClass: cssClass,
            canRetry: episode.status == .failed,
            duration: Format.duration(episode.duration ?? episode.sourceDuration),
            size: Format.bytes(episode.fileSize.map(Int64.init)),
            error: episode.error
        )
    }
}
