import Foundation

/// Per-show audio processing settings.
struct ProcessingSettings: Sendable, Hashable {
    static let speedRange: ClosedRange<Double> = 1.0...3.0
    static let speedStep = 0.05

    var speed: Double
    var smartSpeed: Bool
    var voiceBoost: Bool

    init(speed: Double, smartSpeed: Bool, voiceBoost: Bool) {
        self.speed = Self.clampSpeed(speed)
        self.smartSpeed = smartSpeed
        self.voiceBoost = voiceBoost
    }

    /// Clamps to 1.0…3.0 and snaps to the 0.05 grid, so 1.4999 and 1.5 are the same setting.
    static func clampSpeed(_ speed: Double) -> Double {
        guard speed.isFinite else { return 1.0 }
        let snapped = (speed / speedStep).rounded() * speedStep
        let rounded = (snapped * 100).rounded() / 100
        return min(max(rounded, speedRange.lowerBound), speedRange.upperBound)
    }

    /// Speed formatted for ffmpeg and hashing, e.g. `1.50`.
    var speedString: String { String(format: "%.2f", speed) }

    var changesTempo: Bool { speed != 1.0 }

    /// No audio filters at all: the file can be stream-copied if it's already MP3.
    var isPassthrough: Bool { !changesTempo && !smartSpeed && !voiceBoost }
}

/// ID3 tags written during encode.
struct EpisodeTags: Sendable, Hashable {
    var title: String
    var album: String
    var artist: String?
    var date: Date
}

/// Builds the ffmpeg filter chain and command line from show settings. Pure, no I/O.
enum FilterChain {
    /// Bump whenever the chain or encoding changes; this forces new settings hashes.
    static let pipelineVersion = "2"

    /// SmartSpeed tuning, kept in one place so it can become a per-show "advanced" setting later.
    enum SmartSpeed {
        static let thresholdDB = -45
        static let minimumPause = 0.35
        static let keptSilence = 0.15
    }

    /// Encoder settings, used whenever filters force a re-encode.
    /// Rule: never lower quality than the source. The output keeps the source's channel
    /// layout and is CBR MP3 at the source bit rate (rounded up to the next MP3 bit rate),
    /// so a 128k source stays 128k and a 192k source stays 192k.
    enum Encoder {
        static let codec = "libmp3lame"
        /// MPEG-1 Layer III bit rates in kbit/s (valid for 32/44.1/48 kHz).
        static let bitRates = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
        /// Used when ffprobe can't tell the source bit rate.
        static let fallbackBitRate = 192
        /// AAC/Opus/Vorbis sound better than MP3 at the same bit rate, so give MP3 more room.
        static let efficientCodecs: Set<String> = ["aac", "opus", "vorbis"]
        static let efficientCodecFactor = 1.5
        static let sampleRates = [32000, 44100, 48000]
        static let defaultSampleRate = 44100

        /// Output bit rate in kbit/s.
        static func bitRate(for source: SourceAudioInfo) -> Int {
            guard let sourceBitRate = source.bitRate, sourceBitRate > 0 else { return fallbackBitRate }
            var kbps = Double(sourceBitRate) / 1000
            if let codec = source.codec, efficientCodecs.contains(codec) {
                kbps *= efficientCodecFactor
            }
            // Small tolerance so a "128000" stream that probes as 128003 stays at 128.
            return bitRates.first { Double($0) >= kbps - 0.5 } ?? bitRates.last!
        }

        /// Keep the source rate when MP3 supports it. Always set explicitly, because
        /// `loudnorm` would otherwise output 192 kHz.
        static func sampleRate(for source: SourceAudioInfo) -> Int {
            source.sampleRate.flatMap { sampleRates.contains($0) ? $0 : nil } ?? defaultSampleRate
        }
    }

    /// Voice equalization: gentle on purpose, so voices keep their body and don't sound higher.
    /// Chosen by ear against Overcast (2026-10-27); a 3 kHz presence boost made voices thin.
    enum VoiceBoost {
        static let highpass = "highpass=f=60"
        static let compressor = "acompressor=threshold=-21dB:ratio=2:attack=10:release=200:makeup=2"
        static let loudnorm = "loudnorm=I=-16:TP=-1.5:LRA=11"
    }

    /// Tempo uses `atempo`, not `rubberband`: at podcast speeds rubberband measurably raised
    /// voice pitch (about 3–6 % at 1.2×) while atempo keeps it.
    static func filters(for settings: ProcessingSettings) -> [String] {
        var filters: [String] = []
        if settings.voiceBoost {
            filters.append(VoiceBoost.highpass)
        }
        if settings.smartSpeed {
            filters.append(
                "silenceremove=stop_periods=-1"
                    + ":stop_duration=\(SmartSpeed.minimumPause)"
                    + ":stop_threshold=\(SmartSpeed.thresholdDB)dB"
                    + ":stop_silence=\(SmartSpeed.keptSilence)"
            )
        }
        if settings.voiceBoost {
            filters.append(VoiceBoost.compressor)
        }
        if settings.changesTempo {
            filters.append("atempo=\(settings.speedString)")
        }
        if settings.voiceBoost {
            filters.append(VoiceBoost.loudnorm)
        }
        return filters
    }

    /// Whether the audio stream can be copied without re-encoding.
    /// Only possible for MP3 sources: copying AAC into an .mp3 container would fail.
    static func canStreamCopy(_ settings: ProcessingSettings, source: SourceAudioInfo) -> Bool {
        settings.isPassthrough && source.isMP3
    }

    static func ffmpegArguments(
        input: String,
        artwork: String?,
        output: String,
        settings: ProcessingSettings,
        tags: EpisodeTags,
        source: SourceAudioInfo
    ) -> [String] {
        var args = ["-hide_banner", "-nostdin", "-nostats", "-loglevel", "error", "-y", "-i", input]
        if let artwork {
            args += ["-i", artwork]
        }
        args += ["-map", "0:a:0"]
        if artwork != nil {
            args += ["-map", "1:v:0"]
        }
        // Drop source tags and chapters; silence removal would make chapter timestamps wrong.
        args += ["-map_metadata", "-1", "-map_chapters", "-1"]

        if canStreamCopy(settings, source: source) {
            args += ["-c:a", "copy"]
        } else {
            let filters = filters(for: settings)
            if !filters.isEmpty {
                args += ["-af", filters.joined(separator: ",")]
            }
            args += [
                "-c:a", Encoder.codec,
                "-b:a", "\(Encoder.bitRate(for: source))k",
                "-ar", "\(Encoder.sampleRate(for: source))",
            ]
        }

        if artwork != nil {
            args += [
                "-c:v", "mjpeg", "-disposition:v", "attached_pic",
                "-metadata:s:v", "title=Album cover",
                "-metadata:s:v", "comment=Cover (front)",
            ]
        }

        args += ["-id3v2_version", "3"]
        args += ["-metadata", "title=\(tags.title)"]
        args += ["-metadata", "album=\(tags.album)"]
        if let artist = tags.artist, !artist.isEmpty {
            args += ["-metadata", "artist=\(artist)"]
        }
        args += ["-metadata", "genre=Podcast"]
        args += ["-metadata", "date=\(dateString(tags.date))"]
        args += ["-f", "mp3", output]
        return args
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
