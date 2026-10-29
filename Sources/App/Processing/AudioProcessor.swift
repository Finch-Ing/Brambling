import Foundation

protocol AudioProcessing: Sendable {
    /// Encodes `source` into `output` (MP3 with tags and cover) and returns the output duration in seconds.
    func process(
        source: URL, artwork: URL?, output: URL, settings: ProcessingSettings, tags: EpisodeTags
    ) async throws -> Double

    /// Converts any image into a 1400×1400 baseline JPEG.
    func convertArtwork(source: URL, output: URL) async throws
}

enum AudioProcessorError: Error, CustomStringConvertible {
    case ffmpegFailed(code: Int32, stderr: String)
    case noDuration

    var description: String {
        switch self {
        case let .ffmpegFailed(code, stderr):
            // The last lines carry the actual error; ffmpeg can be chatty before that.
            let tail = stderr.split(separator: "\n").suffix(5).joined(separator: " | ")
            return "ffmpeg exited with \(code): \(tail)"
        case .noDuration:
            return "ffprobe could not read the duration of the output"
        }
    }
}

struct FFmpegProcessor: AudioProcessing {
    static let encodeTimeout: Duration = .seconds(3 * 3600)

    func process(
        source: URL, artwork: URL?, output: URL, settings: ProcessingSettings, tags: EpisodeTags
    ) async throws -> Double {
        let info = try await AudioProbe.probe(source.path)
        let arguments = FilterChain.ffmpegArguments(
            input: source.path, artwork: artwork?.path, output: output.path, settings: settings,
            tags: tags, source: info
        )
        try await run("ffmpeg", arguments, timeout: Self.encodeTimeout)
        return try await duration(of: output)
    }

    func convertArtwork(source: URL, output: URL) async throws {
        try await run("ffmpeg", [
            "-hide_banner", "-nostdin", "-loglevel", "error", "-y",
            "-i", source.path,
            "-vf", "scale=1400:1400:force_original_aspect_ratio=increase,crop=1400:1400",
            "-frames:v", "1", "-pix_fmt", "yuvj420p", "-q:v", "2",
            "-f", "mjpeg", output.path,
        ], timeout: .seconds(120))
    }

    func duration(of file: URL) async throws -> Double {
        let result = try await ProcessRunner.run(
            "ffprobe", ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", file.path],
            timeout: .seconds(60)
        )
        guard result.exitCode == 0,
              let seconds = Double(result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)),
              seconds > 0
        else { throw AudioProcessorError.noDuration }
        return seconds
    }

    private func run(_ executable: String, _ arguments: [String], timeout: Duration) async throws {
        let result = try await ProcessRunner.run(executable, arguments, timeout: timeout)
        guard result.exitCode == 0 else {
            throw AudioProcessorError.ffmpegFailed(code: result.exitCode, stderr: result.stderrString)
        }
    }
}
