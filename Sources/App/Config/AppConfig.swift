import Foundation
import Vapor

/// Runtime configuration, read from `BRAMBLING_*` environment variables.
struct AppConfig: Sendable {
    struct BasicAuth: Sendable {
        var user: String
        var password: String
    }

    var dataDirectory: URL
    var publicBaseURL: URL
    var refreshMinutes: Int
    var downloadConcurrency: Int
    var ffmpegConcurrency: Int
    var basicAuth: BasicAuth?
    var diskLimits: DiskGuard.Limits
    /// `nil` = ffmpeg may run any time.
    var processWindow: ProcessingWindow?
    /// Periodic refresh and job queue. Off in tests.
    var runBackgroundJobs = true

    var databasePath: String { dataDirectory.appendingPathComponent("brambling.sqlite").path }
    var mediaDirectory: URL { dataDirectory.appendingPathComponent("media", isDirectory: true) }
    var artDirectory: URL { dataDirectory.appendingPathComponent("art", isDirectory: true) }
    var tmpDirectory: URL { dataDirectory.appendingPathComponent("tmp", isDirectory: true) }

    static func fromEnvironment() throws -> AppConfig {
        try fromEnvironment(Environment.get)
    }

    /// Testable variant that takes a lookup function instead of reading the process environment.
    static func fromEnvironment(_ get: (String) -> String?) throws -> AppConfig {
        let dataPath = get("BRAMBLING_DATA") ?? "./data"
        let baseString = get("BRAMBLING_PUBLIC_BASE_URL") ?? "http://127.0.0.1:8080"
        guard let baseURL = URL(string: baseString.hasSuffix("/") ? String(baseString.dropLast()) : baseString),
              baseURL.scheme != nil, baseURL.host != nil
        else {
            throw ConfigError.invalidValue("BRAMBLING_PUBLIC_BASE_URL", baseString)
        }

        func int(_ key: String, default value: Int, min: Int = 1) throws -> Int {
            guard let raw = get(key) else { return value }
            guard let parsed = Int(raw), parsed >= min else { throw ConfigError.invalidValue(key, raw) }
            return parsed
        }

        func gigabytes(_ key: String) throws -> Int64? {
            guard let raw = get(key), !raw.isEmpty else { return nil }
            guard let value = Double(raw), value >= 0 else { throw ConfigError.invalidValue(key, raw) }
            return Int64(value * 1_073_741_824)
        }

        let window: ProcessingWindow?
        do {
            window = try ProcessingWindow(parsing: get("BRAMBLING_PROCESS_WINDOW") ?? "")
        } catch {
            throw ConfigError.invalidValue("BRAMBLING_PROCESS_WINDOW", get("BRAMBLING_PROCESS_WINDOW") ?? "")
        }

        var auth: BasicAuth?
        if let user = get("BRAMBLING_USER"), !user.isEmpty,
           let pass = get("BRAMBLING_PASS"), !pass.isEmpty {
            auth = BasicAuth(user: user, password: pass)
        }

        return AppConfig(
            dataDirectory: URL(fileURLWithPath: dataPath, isDirectory: true).standardizedFileURL,
            publicBaseURL: baseURL,
            refreshMinutes: try int("BRAMBLING_REFRESH_MINUTES", default: 30),
            downloadConcurrency: try int("BRAMBLING_DOWNLOAD_CONCURRENCY", default: 2),
            ffmpegConcurrency: try int("BRAMBLING_FFMPEG_CONCURRENCY", default: 1),
            basicAuth: auth,
            diskLimits: DiskGuard.Limits(
                minFreeBytes: try gigabytes("BRAMBLING_MIN_FREE_GB") ?? 5 * 1_073_741_824,
                maxMediaBytes: try gigabytes("BRAMBLING_MAX_MEDIA_GB")
            ),
            processWindow: window
        )
    }

    func createDirectories() throws {
        for dir in [dataDirectory, mediaDirectory, artDirectory, tmpDirectory] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

enum ConfigError: Error, CustomStringConvertible {
    case invalidValue(String, String)

    var description: String {
        switch self {
        case let .invalidValue(key, value): "Invalid value for \(key): \(value)"
        }
    }
}

extension Application {
    private struct AppConfigKey: StorageKey {
        typealias Value = AppConfig
    }

    var appConfig: AppConfig {
        get {
            guard let config = storage[AppConfigKey.self] else { fatalError("AppConfig not set; call configure(_:) first") }
            return config
        }
        set { storage[AppConfigKey.self] = newValue }
    }
}
