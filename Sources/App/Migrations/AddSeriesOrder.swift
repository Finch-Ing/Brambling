import Fluent

/// Per-show feed order: newest first (default) or oldest first for series.
struct AddSeriesOrder: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Show.schema).field("series_order", .bool, .required, .sql(.default(false))).update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Show.schema).deleteField("series_order").update()
    }
}
