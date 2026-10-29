import Fluent

struct CreateEpisode: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // `status` is stored as the raw string of `EpisodeStatus`.
        try await database.schema(Episode.schema)
            .id()
            .field("show_id", .uuid, .required, .references(Show.schema, "id", onDelete: .cascade))
            .field("source_guid", .string, .required)
            .field("title", .string, .required)
            .field("description_html", .string)
            .field("pub_date", .datetime, .required)
            .field("enclosure_url", .string, .required)
            .field("enclosure_type", .string)
            .field("enclosure_length", .int)
            .field("source_duration", .double)
            .field("status", .string, .required)
            .field("settings_hash", .string, .required)
            .field("file_name", .string)
            .field("file_size", .int)
            .field("duration", .double)
            .field("attempts", .int, .required)
            .field("next_attempt_at", .datetime)
            .field("error", .string)
            .field("processed_at", .datetime)
            .unique(on: "show_id", "source_guid")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Episode.schema).delete()
    }
}
