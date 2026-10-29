import Fluent
import SQLKit

/// After `AddEpisodeCatalogue`, existing shows only had their kept episodes stored, and feed servers
/// answer 304 until a new episode appears. Forgetting the cache headers once makes the next refresh
/// fetch the full feed and store the whole back catalogue.
struct ResetFeedCache: AsyncMigration {
    func prepare(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("UPDATE shows SET etag = NULL, last_modified = NULL").run()
        }
    }

    func revert(on database: any Database) async throws {}
}
