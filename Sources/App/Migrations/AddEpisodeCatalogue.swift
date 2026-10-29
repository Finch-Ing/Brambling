import Fluent
import SQLKit

/// Full feed catalogue (plan §5.6): episodes outside the kept window are stored as `available`,
/// can be kept individually, and carry their episode/season numbers.
struct AddEpisodeCatalogue: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // SQLite adds one column per ALTER TABLE.
        try await database.schema(Episode.schema).field("kept", .bool, .required, .sql(.default(false))).update()
        try await database.schema(Episode.schema).field("episode_number", .int).update()
        try await database.schema(Episode.schema).field("season_number", .int).update()
        // "pruned" became "available".
        if let sql = database as? any SQLDatabase {
            try await sql.raw("UPDATE episodes SET status = 'available' WHERE status = 'pruned'").run()
        }
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("UPDATE episodes SET status = 'pruned' WHERE status = 'available'").run()
        }
        try await database.schema(Episode.schema).deleteField("season_number").update()
        try await database.schema(Episode.schema).deleteField("episode_number").update()
        try await database.schema(Episode.schema).deleteField("kept").update()
    }
}
