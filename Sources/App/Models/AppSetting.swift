import Fluent
import Foundation

/// Settings changed in the web UI. They override the matching environment variable.
final class AppSetting: Model, @unchecked Sendable {
    static let schema = "app_settings"

    /// `HH:MM-HH:MM`, or empty for "any time". Overrides `BRAMBLING_PROCESS_WINDOW`.
    static let processWindowKey = "process_window"

    @ID(custom: "key", generatedBy: .user) var id: String?
    @Field(key: "value") var value: String

    init() {}

    init(key: String, value: String) {
        self.id = key
        self.value = value
    }

    static func value(_ key: String, on db: any Database) async throws -> String? {
        try await AppSetting.find(key, on: db)?.value
    }

    static func set(_ key: String, to value: String, on db: any Database) async throws {
        if let existing = try await AppSetting.find(key, on: db) {
            existing.value = value
            try await existing.save(on: db)
        } else {
            try await AppSetting(key: key, value: value).create(on: db)
        }
    }
}
