import Fluent
import Foundation

enum EpisodeStatus: String, Codable, Sendable, CaseIterable {
    /// In the source feed but not kept here (outside the newest `keepCount` and not selected).
    case available
    case pending, downloading
    /// Source is in `tmp/`, waiting for the processing window.
    case downloaded
    case processing, ready, failed
}

final class Episode: Model, @unchecked Sendable {
    static let schema = "episodes"

    @ID(key: .id) var id: UUID?

    @Parent(key: "show_id") var show: Show

    @Field(key: "source_guid") var sourceGUID: String
    @Field(key: "title") var title: String
    /// `itunes:subtitle`, a short one-liner many feeds provide.
    @OptionalField(key: "subtitle") var subtitle: String?
    @OptionalField(key: "description_html") var descriptionHTML: String?
    @Field(key: "pub_date") var pubDate: Date

    /// Secret if it contains a token.
    @Field(key: "enclosure_url") var enclosureURL: String
    @OptionalField(key: "enclosure_type") var enclosureType: String?
    /// Bytes from the source `<enclosure length>`; often missing or wrong.
    @OptionalField(key: "enclosure_length") var enclosureLength: Int?
    @OptionalField(key: "source_duration") var sourceDuration: Double?
    /// `itunes:episode` / `itunes:season` from the feed, for display and "keep #300–#310".
    @OptionalField(key: "episode_number") var episodeNumber: Int?
    @OptionalField(key: "season_number") var seasonNumber: Int?
    /// Selected by the user: kept in addition to the newest `keepCount` episodes.
    @Field(key: "kept") var kept: Bool

    @Field(key: "status") var status: EpisodeStatus
    /// Hash of the settings the current/target file is produced with.
    @Field(key: "settings_hash") var settingsHash: String
    @OptionalField(key: "file_name") var fileName: String?
    @OptionalField(key: "file_size") var fileSize: Int?
    @OptionalField(key: "duration") var duration: Double?
    @Field(key: "attempts") var attempts: Int
    /// Retry backoff: not picked up again before this time.
    @OptionalField(key: "next_attempt_at") var nextAttemptAt: Date?
    @OptionalField(key: "error") var error: String?
    @OptionalField(key: "processed_at") var processedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        showID: Show.IDValue,
        sourceGUID: String,
        title: String,
        pubDate: Date,
        enclosureURL: String,
        settingsHash: String,
        status: EpisodeStatus = .pending
    ) {
        self.id = id
        self.$show.id = showID
        self.sourceGUID = sourceGUID
        self.title = title
        self.pubDate = pubDate
        self.enclosureURL = enclosureURL
        self.settingsHash = settingsHash
        self.status = status
        self.attempts = 0
        self.kept = false
    }
}
