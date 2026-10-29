@testable import App
import Foundation
import Testing

@Suite("AudioProbe")
struct AudioProbeTests {
    @Test func parsesStreamValues() throws {
        let json = """
        {"programs":[],"streams":[{"codec_name":"mp3","sample_rate":"44100","channels":2,"bit_rate":"128000"}],
         "format":{"bit_rate":"131072"}}
        """
        let info = try AudioProbe.parse(Data(json.utf8))
        #expect(info == SourceAudioInfo(codec: "mp3", bitRate: 128_000, sampleRate: 44100, channels: 2))
        #expect(info.isMP3)
    }

    @Test func fallsBackToFormatBitRate() throws {
        let json = """
        {"streams":[{"codec_name":"aac","sample_rate":"48000","channels":1}],"format":{"bit_rate":"64000"}}
        """
        let info = try AudioProbe.parse(Data(json.utf8))
        #expect(info.bitRate == 64000)
        #expect(!info.isMP3)
    }

    @Test func noAudioStreamThrows() {
        #expect(throws: AudioProbeError.self) { try AudioProbe.parse(Data(#"{"streams":[]}"#.utf8)) }
    }
}
