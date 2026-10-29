import Fluent
import Foundation

final class Show: Model, @unchecked Sendable {
    static let schema = "shows"

    @ID(key: .id) var id: UUID?

    /// URL-safe, immutable after creation.
    @Field(key: "slug") var slug: String
    @Field(key: "title") var title: String
    @OptionalField(key: "title_override") var titleOverride: String?

    /// Secret: may contain an access token. Never log it or render it unmasked.
    @Field(key: "source_url") var sourceURL: String
    @OptionalField(key: "site_url") var siteURL: String?
    @OptionalField(key: "author") var author: String?
    @OptionalField(key: "summary") var summary: String?
    @OptionalField(key: "language") var language: String?
    @OptionalField(key: "artwork_source_url") var artworkSourceURL: String?
    /// The artwork URL that produced `art/<slug>.jpg`; differs from `artworkSourceURL` when it needs a refetch.
    @OptionalField(key: "artwork_fetched_url") var artworkFetchedURL: String?

    @Field(key: "speed") var speed: Double
    @Field(key: "smart_speed") var smartSpeed: Bool
    @Field(key: "voice_boost") var voiceBoost: Bool
    @Field(key: "keep_count") var keepCount: Int
    @Field(key: "enabled") var enabled: Bool
    /// Feed order: false = newest first (as published), true = oldest first, for listening to a series in order.
    @Field(key: "series_order") var seriesOrder: Bool

    @OptionalField(key: "etag") var etag: String?
    @OptionalField(key: "last_modified") var lastModified: String?
    @OptionalField(key: "last_refresh_at") var lastRefreshAt: Date?
    @OptionalField(key: "last_error") var lastError: String?

    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    @Children(for: \.$show) var episodes: [Episode]

    init() {}

    init(
        id: UUID? = nil,
        slug: String,
        title: String,
        sourceURL: String,
        speed: Double = 1.0,
        smartSpeed: Bool = true,
        voiceBoost: Bool = true,
        keepCount: Int = 10,
        enabled: Bool = true
    ) {
        self.id = id
        self.slug = slug
        self.title = title
        self.sourceURL = sourceURL
        self.speed = ProcessingSettings.clampSpeed(speed)
        self.smartSpeed = smartSpeed
        self.voiceBoost = voiceBoost
        self.keepCount = keepCount
        self.enabled = enabled
        self.seriesOrder = false
    }

    var displayTitle: String { titleOverride ?? title }

    /// `keepCount == 0`: only hand-picked episodes are kept (plan §5.6).
    var isManualSelection: Bool { keepCount == 0 }

    var processingSettings: ProcessingSettings {
        ProcessingSettings(speed: speed, smartSpeed: smartSpeed, voiceBoost: voiceBoost)
    }
}
