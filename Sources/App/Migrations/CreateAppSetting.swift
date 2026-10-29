import Fluent

/// Key/value store for settings changed in the web UI (first one: the processing window).
struct CreateAppSetting: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(AppSetting.schema)
            .field("key", .string, .identifier(auto: false))
            .field("value", .string, .required)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(AppSetting.schema).delete()
    }
}
