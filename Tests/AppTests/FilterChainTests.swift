@testable import App
import Foundation
import Testing

@Suite("FilterChain")
struct FilterChainTests {
    static let speeds: [Double] = [1.0, 1.5, 2.5]
    static let toggles: [(Bool, Bool)] = [(false, false), (true, false), (false, true), (true, true)]

    @Test("Every toggle/speed combination produces the stages in order", arguments: speeds, 0..<4)
    func combinations(speed: Double, toggleIndex: Int) {
        let (smartSpeed, voiceBoost) = Self.toggles[toggleIndex]
        let settings = ProcessingSettings(speed: speed, smartSpeed: smartSpeed, voiceBoost: voiceBoost)

        let filters = FilterChain.filters(for: settings)
        var expected: [String] = []
        if voiceBoost { expected.append("highpass") }
        if smartSpeed { expected.append("silenceremove") }
        if voiceBoost { expected.append("acompressor") }
        if speed != 1.0 { expected.append("atempo") }
        if voiceBoost { expected.append("loudnorm") }

        #expect(filters.map { String($0.prefix { $0 != "=" }) } == expected)
    }

    @Test func tempoUsesTwoDecimals() {
        let settings = ProcessingSettings(speed: 1.5, smartSpeed: false, voiceBoost: false)
        #expect(FilterChain.filters(for: settings) == ["atempo=1.50"])
    }

    @Test func smartSpeedUsesConstants() {
        let settings = ProcessingSettings(speed: 1.0, smartSpeed: true, voiceBoost: false)
        #expect(FilterChain.filters(for: settings) == [
            "silenceremove=stop_periods=-1:stop_duration=0.35:stop_threshold=-45dB:stop_silence=0.15",
        ])
    }

    @Test func speedIsClampedAndSnapped() {
        #expect(ProcessingSettings.clampSpeed(0.5) == 1.0)
        #expect(ProcessingSettings.clampSpeed(5) == 3.0)
        #expect(ProcessingSettings.clampSpeed(1.4999) == 1.5)
        #expect(ProcessingSettings.clampSpeed(1.53) == 1.55)
        #expect(ProcessingSettings.clampSpeed(.nan) == 1.0)
    }

    @Test func passthroughCopiesMP3WithoutFilters() {
        let settings = ProcessingSettings(speed: 1.0, smartSpeed: false, voiceBoost: false)
        #expect(settings.isPassthrough)
        #expect(FilterChain.filters(for: settings).isEmpty)

        let args = arguments(settings, source: Self.mp3Source)
        #expect(args.contains(sequence: ["-c:a", "copy"]))
        #expect(!args.contains("-af"))
        #expect(!args.contains("libmp3lame"))
    }

    @Test func passthroughReencodesNonMP3Sources() {
        let settings = ProcessingSettings(speed: 1.0, smartSpeed: false, voiceBoost: false)
        let source = SourceAudioInfo(codec: "aac", bitRate: 128_000, sampleRate: 44100, channels: 2)
        let args = arguments(settings, source: source)
        #expect(!args.contains(sequence: ["-c:a", "copy"]))
        #expect(!args.contains("-af"))
        #expect(args.contains(sequence: ["-c:a", "libmp3lame", "-b:a", "192k", "-ar", "44100"]))
    }

    @Test func encodeArgumentsIncludeChainTagsAndCover() throws {
        let settings = ProcessingSettings(speed: 2.5, smartSpeed: true, voiceBoost: true)
        let args = arguments(settings, source: Self.mp3Source)

        #expect(args.contains(sequence: ["-i", "in.src", "-i", "art.jpg", "-map", "0:a:0", "-map", "1:v:0"]))
        #expect(args.contains(sequence: ["-map_metadata", "-1", "-map_chapters", "-1"]))
        let chain = args[try #require(args.firstIndex(of: "-af")) + 1]
        #expect(chain.hasPrefix("highpass=f=60,silenceremove="))
        #expect(chain.hasSuffix("acompressor=threshold=-21dB:ratio=2:attack=10:release=200:makeup=2,atempo=2.50,loudnorm=I=-16:TP=-1.5:LRA=11"))
        #expect(!chain.contains("equalizer"), "no presence boost: it made voices sound higher")
        #expect(args.contains(sequence: ["-c:a", "libmp3lame", "-b:a", "128k", "-ar", "44100"]))
        #expect(!args.contains("-ac"), "channel layout of the source is kept")
        #expect(args.contains(sequence: ["-c:v", "mjpeg", "-disposition:v", "attached_pic"]))
        #expect(args.contains(sequence: ["-id3v2_version", "3"]))
        #expect(args.contains("title=Episode & <1>"))
        #expect(args.contains("album=My Show"))
        #expect(args.contains("artist=Jane"))
        #expect(args.contains("genre=Podcast"))
        #expect(args.contains("date=2024-03-01"))
        #expect(args.suffix(3) == ["-f", "mp3", "out.mp3"])
    }

    @Test func noArtworkOmitsVideoStream() {
        let settings = ProcessingSettings(speed: 1.0, smartSpeed: true, voiceBoost: false)
        let args = FilterChain.ffmpegArguments(
            input: "in.src", artwork: nil, output: "out.mp3", settings: settings,
            tags: Self.tags, source: Self.mp3Source
        )
        #expect(!args.contains("1:v:0"))
        #expect(!args.contains("attached_pic"))
    }

    @Test("Bit rate never drops below the source", arguments: [
        (SourceAudioInfo(codec: "mp3", bitRate: 128_000), 128),
        (SourceAudioInfo(codec: "mp3", bitRate: 128_003), 128),
        (SourceAudioInfo(codec: "mp3", bitRate: 192_000), 192),
        (SourceAudioInfo(codec: "mp3", bitRate: 64_000), 64),
        (SourceAudioInfo(codec: "mp3", bitRate: 138_000), 160),
        (SourceAudioInfo(codec: "mp3", bitRate: 400_000), 320),
        (SourceAudioInfo(codec: "aac", bitRate: 64_000), 96),
        (SourceAudioInfo(codec: "aac", bitRate: 256_000), 320),
        (SourceAudioInfo(codec: "opus", bitRate: 48_000), 80),
        (SourceAudioInfo(codec: "flac", bitRate: 900_000), 320),
        (SourceAudioInfo(codec: "mp3", bitRate: nil), 192),
    ])
    func bitRateMatchesSource(source: SourceAudioInfo, expected: Int) {
        #expect(FilterChain.Encoder.bitRate(for: source) == expected)
    }

    @Test func sampleRateKeptWhenMP3SupportsIt() {
        #expect(FilterChain.Encoder.sampleRate(for: SourceAudioInfo(sampleRate: 48000)) == 48000)
        #expect(FilterChain.Encoder.sampleRate(for: SourceAudioInfo(sampleRate: 44100)) == 44100)
        #expect(FilterChain.Encoder.sampleRate(for: SourceAudioInfo(sampleRate: 22050)) == 44100)
        #expect(FilterChain.Encoder.sampleRate(for: SourceAudioInfo(sampleRate: 96000)) == 44100)
        #expect(FilterChain.Encoder.sampleRate(for: SourceAudioInfo()) == 44100)
    }

    static let mp3Source = SourceAudioInfo(codec: "mp3", bitRate: 128_000, sampleRate: 44100, channels: 2)

    static let tags = EpisodeTags(
        title: "Episode & <1>", album: "My Show", artist: "Jane",
        date: Date(timeIntervalSince1970: 1_709_294_400) // 2024-03-01 12:00 UTC
    )

    private func arguments(_ settings: ProcessingSettings, source: SourceAudioInfo) -> [String] {
        FilterChain.ffmpegArguments(
            input: "in.src", artwork: "art.jpg", output: "out.mp3", settings: settings,
            tags: Self.tags, source: source
        )
    }
}

extension Array where Element: Equatable {
    func contains(sequence: [Element]) -> Bool {
        guard sequence.count <= count else { return false }
        return (0...(count - sequence.count)).contains { Array(self[$0..<$0 + sequence.count]) == sequence }
    }
}
