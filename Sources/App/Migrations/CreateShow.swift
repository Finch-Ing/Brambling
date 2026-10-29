import Fluent

struct CreateShow: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Show.schema)
            .id()
            .field("slug", .string, .required)
            .field("title", .string, .required)
            .field("title_override", .string)
            .field("source_url", .string, .required)
            .field("site_url", .string)
            .field("author", .string)
            .field("summary", .string)
            .field("language", .string)
            .field("artwork_source_url", .string)
            .field("artwork_fetched_url", .string)
            .field("speed", .double, .required)
            .field("smart_speed", .bool, .required)
            .field("voice_boost", .bool, .required)
            .field("keep_count", .int, .required)
            .field("enabled", .bool, .required)
            .field("etag", .string)
            .field("last_modified", .string)
            .field("last_refresh_at", .datetime)
            .field("last_error", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "slug")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Show.schema).delete()
    }
}
