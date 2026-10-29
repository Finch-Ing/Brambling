@testable import App
import Foundation
import Testing

private let ffmpegAvailable: Bool = {
    let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
    return paths.contains { FileManager.default.isExecutableFile(atPath: "\($0)/ffmpeg") }
}()

/// Runs the real ffmpeg/ffprobe. Skipped where ffmpeg isn't installed (e.g. a Mac without Homebrew ffmpeg);
/// runs in the Docker image.
@Suite("FFmpeg integration", .enabled(if: ffmpegAvailable))
struct FFmpegIntegrationTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("brambling-ffmpeg-\(UUID())")

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// 4 s tone, 2 s silence, 4 s tone; stereo, 128 kbit/s MP3.
    private func makeSource() async throws -> URL {
        let source = dir.appendingPathComponent("source.mp3")
        let result = try await ProcessRunner.run("ffmpeg", [
            "-hide_banner", "-loglevel", "error", "-y",
            "-filter_complex",
            "sine=f=440:d=4[a];anullsrc=r=44100:cl=mono,atrim=0:2[b];sine=f=660:d=4[c];[a][b][c]concat=n=3:v=0:a=1,pan=stereo|c0=c0|c1=c0",
            "-c:a", "libmp3lame", "-b:a", "128k", "-ar", "44100", source.path,
        ])
        #expect(result.exitCode == 0, "\(result.stderrString)")
        return source
    }

    private func makeArtwork(_ processor: FFmpegProcessor) async throws -> URL {
        let raw = dir.appendingPathComponent("art.png")
        let result = try await ProcessRunner.run("ffmpeg", [
            "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "color=c=red:s=600x400", "-frames:v", "1", raw.path,
        ])
        #expect(result.exitCode == 0, "\(result.stderrString)")
        let jpg = dir.appendingPathComponent("art.jpg")
        try await processor.convertArtwork(source: raw, output: jpg)
        return jpg
    }

    private func videoStreamCount(_ file: URL) async throws -> Int {
        let result = try await ProcessRunner.run("ffprobe", [
            "-v", "error", "-select_streams", "v", "-show_entries", "stream=index", "-of", "csv=p=0", file.path,
        ])
        return result.stdoutString.split(separator: "\n").count
    }

    private func tag(_ name: String, of file: URL) async throws -> String {
        let result = try await ProcessRunner.run("ffprobe", [
            "-v", "error", "-show_entries", "format_tags=\(name)", "-of", "default=nw=1:nk=1", file.path,
        ])
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let tags = EpisodeTags(title: "Test Episode", album: "Test Show", artist: "Tester", date: Date(timeIntervalSince1970: 1_709_294_400))

    @Test func fullChainKeepsQualityAndEmbedsCover() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let processor = FFmpegProcessor()
        let source = try await makeSource()
        let artwork = try await makeArtwork(processor)
        let output = dir.appendingPathComponent("out.mp3")

        let duration = try await processor.process(
            source: source, artwork: artwork, output: output,
            settings: ProcessingSettings(speed: 1.5, smartSpeed: true, voiceBoost: true), tags: Self.tags
        )

        // 10 s of audio, ~1.85 s of silence removed, then 1.5× → about 5.5 s.
        #expect(duration > 4.5 && duration < 6.3, "duration \(duration)")
        let info = try await AudioProbe.probe(output.path)
        #expect(info.codec == "mp3")
        #expect(info.bitRate == 128_000, "same bit rate as the source")
        #expect(info.channels == 2, "no downmix")
        #expect(info.sampleRate == 44100)
        #expect(try await videoStreamCount(output) == 1, "cover embedded")
        #expect(try await tag("title", of: output) == "Test Episode")
        #expect(try await tag("album", of: output) == "Test Show")
        #expect(try await tag("genre", of: output) == "Podcast")
    }

    @Test func passthroughCopiesAudio() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let processor = FFmpegProcessor()
        let source = try await makeSource()
        let output = dir.appendingPathComponent("copy.mp3")

        let duration = try await processor.process(
            source: source, artwork: nil, output: output,
            settings: ProcessingSettings(speed: 1.0, smartSpeed: false, voiceBoost: false), tags: Self.tags
        )
        #expect(abs(duration - 10) < 0.2, "duration \(duration)")
        #expect(try await AudioProbe.probe(output.path).bitRate == 128_000)
        #expect(try await tag("title", of: output) == "Test Episode")
    }

    @Test func artworkIsSquare1400() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let jpg = try await makeArtwork(FFmpegProcessor())
        let result = try await ProcessRunner.run("ffprobe", [
            "-v", "error", "-show_entries", "stream=width,height,codec_name", "-of", "csv=p=0", jpg.path,
        ])
        #expect(result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "mjpeg,1400,1400")
    }
}
