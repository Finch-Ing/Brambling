import Foundation

/// What we know about a downloaded source file's audio stream.
struct SourceAudioInfo: Sendable, Hashable {
    var codec: String?
    /// Bits per second.
    var bitRate: Int?
    var sampleRate: Int?
    var channels: Int?

    var isMP3: Bool { codec == "mp3" }
}

/// Reads the first audio stream's properties with ffprobe.
enum AudioProbe {
    static func arguments(for path: String) -> [String] {
        [
            "-v", "error",
            "-select_streams", "a:0",
            "-show_entries", "stream=codec_name,bit_rate,sample_rate,channels:format=bit_rate",
            "-of", "json",
            path,
        ]
    }

    static func probe(_ path: String) async throws -> SourceAudioInfo {
        let result = try await ProcessRunner.run("ffprobe", arguments(for: path), timeout: .seconds(60))
        guard result.exitCode == 0 else {
            throw AudioProbeError.failed(result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return try parse(result.stdout)
    }

    /// ffprobe reports numbers as strings. The stream bit rate is preferred: the format
    /// bit rate also counts embedded cover art, which inflates it for files with big images.
    static func parse(_ json: Data) throws -> SourceAudioInfo {
        struct Output: Decodable {
            struct Stream: Decodable {
                var codec_name: String?
                var bit_rate: String?
                var sample_rate: String?
                var channels: Int?
            }
            struct Format: Decodable {
                var bit_rate: String?
            }
            var streams: [Stream]?
            var format: Format?
        }
        let output = try JSONDecoder().decode(Output.self, from: json)
        guard let stream = output.streams?.first else { throw AudioProbeError.noAudioStream }
        return SourceAudioInfo(
            codec: stream.codec_name,
            bitRate: stream.bit_rate.flatMap { Int($0) } ?? output.format?.bit_rate.flatMap { Int($0) },
            sampleRate: stream.sample_rate.flatMap { Int($0) },
            channels: stream.channels
        )
    }
}

enum AudioProbeError: Error, CustomStringConvertible {
    case failed(String)
    case noAudioStream

    var description: String {
        switch self {
        case let .failed(message): "ffprobe failed: \(message)"
        case .noAudioStream: "source has no audio stream"
        }
    }
}
