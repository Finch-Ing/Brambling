import Fluent
import Vapor

/// JSON API for shows. Used until the web UI exists (M5) and for scripting afterwards.
struct ShowAPIController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let shows = routes.grouped("api", "shows")
        shows.get(use: index)
        shows.post(use: create)
        shows.post("preview", use: preview)
        shows.group(":showID") { show in
            show.get(use: detail)
            show.patch(use: update)
            show.delete(use: delete)
            show.post("refresh", use: refresh)
            show.post("reprocess", use: reprocess)
            show.post("keep", use: keep)
        }
    }

    // MARK: - DTOs

    struct ShowDTO: Content {
        var id: UUID
        var slug: String
        var title: String
        var titleOverride: String?
        /// Masked: tokens are never returned.
        var sourceURL: String
        var feedURL: String
        var siteURL: String?
        var author: String?
        var artworkSourceURL: String?
        var speed: Double
        var smartSpeed: Bool
        var voiceBoost: Bool
        var keepCount: Int
        var enabled: Bool
        var seriesOrder: Bool
        var lastRefreshAt: Date?
        var lastError: String?
        var episodeCounts: [String: Int]

        init(_ show: Show, episodes: [Episode], baseURL: URL) throws {
            id = try show.requireID()
            slug = show.slug
            title = show.displayTitle
            titleOverride = show.titleOverride
            sourceURL = SecretMasking.mask(url: show.sourceURL)
            feedURL = FeedWriter.feedURL(slug: show.slug, baseURL: baseURL).absoluteString
            siteURL = show.siteURL
            author = show.author
            artworkSourceURL = show.artworkSourceURL
            speed = show.speed
            smartSpeed = show.smartSpeed
            voiceBoost = show.voiceBoost
            keepCount = show.keepCount
            enabled = show.enabled
            seriesOrder = show.seriesOrder
            lastRefreshAt = show.lastRefreshAt
            lastError = show.lastError
            episodeCounts = Dictionary(grouping: episodes, by: \.status.rawValue).mapValues(\.count)
        }
    }

    struct EpisodeDTO: Content {
        var id: UUID
        var title: String
        var pubDate: Date
        var status: EpisodeStatus
        var settingsHash: String
        var sourceDuration: Double?
        var fileSize: Int?
        var duration: Double?
        var attempts: Int
        var error: String?
        var kept: Bool
        var episodeNumber: Int?
        var seasonNumber: Int?

        init(_ episode: Episode) throws {
            id = try episode.requireID()
            title = episode.title
            pubDate = episode.pubDate
            status = episode.status
            settingsHash = episode.settingsHash
            sourceDuration = episode.sourceDuration
            fileSize = episode.fileSize
            duration = episode.duration
            attempts = episode.attempts
            error = episode.error
            kept = episode.kept
            episodeNumber = episode.episodeNumber
            seasonNumber = episode.seasonNumber
        }
    }

    struct ShowDetailDTO: Content {
        var show: ShowDTO
        var episodes: [EpisodeDTO]
    }

    struct CreateShowRequest: Content, Validatable {
        var sourceURL: String
        var slug: String?
        var titleOverride: String?
        var speed: Double?
        var smartSpeed: Bool?
        var voiceBoost: Bool?
        var keepCount: Int?
        var enabled: Bool?

        static func validations(_ validations: inout Validations) {
            validations.add("sourceURL", as: String.self, is: .url)
            validations.add("keepCount", as: Int.self, is: .range(0...200), required: false)
            validations.add("speed", as: Double.self, is: .range(1.0...3.0), required: false)
        }
    }

    struct UpdateShowRequest: Content, Validatable {
        var titleOverride: String?
        /// true = feed oldest first (series order).
        var seriesOrder: Bool?
        var speed: Double?
        var smartSpeed: Bool?
        var voiceBoost: Bool?
        var keepCount: Int?
        var enabled: Bool?

        static func validations(_ validations: inout Validations) {
            validations.add("keepCount", as: Int.self, is: .range(0...200), required: false)
            validations.add("speed", as: Double.self, is: .range(1.0...3.0), required: false)
        }
    }

    struct PreviewRequest: Content {
        var sourceURL: String
    }

    struct PreviewDTO: Content {
        struct Item: Content {
            var title: String
            var pubDate: Date?
            var duration: Double?
        }

        var title: String
        var suggestedSlug: String
        var author: String?
        var artworkURL: String?
        var episodeCount: Int
        var latest: [Item]
    }

    // MARK: - Handlers

    @Sendable
    func index(req: Request) async throws -> [ShowDTO] {
        let shows = try await Show.query(on: req.db).with(\.$episodes).sort(\.$createdAt).all()
        return try shows.map { try ShowDTO($0, episodes: $0.episodes, baseURL: req.application.appConfig.publicBaseURL) }
    }

    @Sendable
    func detail(req: Request) async throws -> ShowDetailDTO {
        try await detailDTO(for: try await findShow(req), on: req)
    }

    @Sendable
    func preview(req: Request) async throws -> PreviewDTO {
        let body = try req.content.decode(PreviewRequest.self)
        let feed = try await req.application.shows.fetchFeed(body.sourceURL).feed
        let items = feed.items.sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
        return PreviewDTO(
            title: feed.title,
            suggestedSlug: Slug.make(from: feed.title),
            author: feed.author,
            artworkURL: feed.artworkURL,
            episodeCount: feed.items.count,
            latest: items.prefix(3).map { .init(title: $0.title, pubDate: $0.pubDate, duration: $0.duration) }
        )
    }

    @Sendable
    func create(req: Request) async throws -> Response {
        try CreateShowRequest.validate(content: req)
        let body = try req.content.decode(CreateShowRequest.self)
        let show = try await req.application.shows.create(.init(
            sourceURL: body.sourceURL,
            slug: body.slug,
            titleOverride: body.titleOverride,
            speed: body.speed ?? 1.0,
            smartSpeed: body.smartSpeed ?? true,
            voiceBoost: body.voiceBoost ?? true,
            keepCount: body.keepCount ?? 10,
            enabled: body.enabled ?? true
        ))
        return try await detailDTO(for: show, on: req).encodeResponse(status: .created, for: req)
    }

    @Sendable
    func update(req: Request) async throws -> ShowDetailDTO {
        try UpdateShowRequest.validate(content: req)
        let body = try req.content.decode(UpdateShowRequest.self)
        let show = try await findShow(req)
        try await req.application.shows.update(show, .init(
            titleOverride: body.titleOverride, speed: body.speed, smartSpeed: body.smartSpeed,
            voiceBoost: body.voiceBoost, keepCount: body.keepCount, enabled: body.enabled,
            seriesOrder: body.seriesOrder
        ))
        return try await detailDTO(for: show, on: req)
    }

    @Sendable
    func refresh(req: Request) async throws -> RefreshOutcome {
        try await req.application.shows.refresh(try await findShow(req))
    }

    struct ReprocessResult: Content {
        var queued: Int
    }

    @Sendable
    func reprocess(req: Request) async throws -> ReprocessResult {
        ReprocessResult(queued: try await req.application.shows.reprocess(try await findShow(req)))
    }

    struct KeepRequest: Content {
        /// "keep" or "unkeep".
        var action: String
        var episodeIDs: [UUID]?
        var fromNumber: Int?
        var toNumber: Int?
        var season: Int?
        var all: Bool?
    }

    /// Select episodes beyond the newest `keepCount` (e.g. #300–#310 of a long back catalogue).
    @Sendable
    func keep(req: Request) async throws -> ShowService.SelectionResult {
        let body = try req.content.decode(KeepRequest.self)
        guard body.action == "keep" || body.action == "unkeep" else {
            throw Abort(.unprocessableEntity, reason: "action must be \"keep\" or \"unkeep\"")
        }
        let selection: ShowService.Selection
        if body.all == true {
            selection = .all
        } else if let from = body.fromNumber, let to = body.toNumber {
            selection = .numbers(from: from, to: to, season: body.season)
        } else {
            selection = .episodes(body.episodeIDs ?? [])
        }
        return try await req.application.shows.setKept(try await findShow(req), selection, kept: body.action == "keep")
    }

    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        try await req.application.shows.delete(try await findShow(req))
        return .noContent
    }

    // MARK: - Helpers

    private func findShow(_ req: Request) async throws -> Show {
        guard let id = req.parameters.get("showID", as: UUID.self),
              let show = try await Show.find(id, on: req.db)
        else { throw Abort(.notFound) }
        return show
    }

    private func detailDTO(for show: Show, on req: Request) async throws -> ShowDetailDTO {
        let episodes = try await show.$episodes.query(on: req.db).sort(\.$pubDate, .descending).all()
        return ShowDetailDTO(
            show: try ShowDTO(show, episodes: episodes, baseURL: req.application.appConfig.publicBaseURL),
            episodes: try episodes.map(EpisodeDTO.init)
        )
    }
}
