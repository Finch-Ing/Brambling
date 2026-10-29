import Fluent
import SQLKit

/// Adds `itunes:subtitle` and refetches every feed once, so existing episodes get theirs too.
struct AddEpisodeSubtitle: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Episode.schema).field("subtitle", .string).update()
        if let sql = database as? any SQLDatabase {
            try await sql.raw("UPDATE shows SET etag = NULL, last_modified = NULL").run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Episode.schema).deleteField("subtitle").update()
    }
}
