import Vapor

/// What the installed ffmpeg can do. Detected once at startup.
struct FFmpegCapabilities: Sendable, Content {
    var version: String?

    static let unavailable = FFmpegCapabilities(version: nil)

    static func detect() async -> FFmpegCapabilities {
        guard let versionResult = try? await ProcessRunner.run("ffmpeg", ["-hide_banner", "-version"], timeout: .seconds(10)),
              versionResult.exitCode == 0
        else {
            return .unavailable
        }
        let firstLine = versionResult.stdoutString.split(separator: "\n").first.map(String.init)
        return FFmpegCapabilities(version: firstLine)
    }
}

extension Application {
    private struct FFmpegCapabilitiesKey: StorageKey {
        typealias Value = FFmpegCapabilities
    }

    var ffmpegCapabilities: FFmpegCapabilities {
        get { storage[FFmpegCapabilitiesKey.self] ?? .unavailable }
        set { storage[FFmpegCapabilitiesKey.self] = newValue }
    }
}
