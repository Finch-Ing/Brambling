@testable import App
import Testing

@Suite("SettingsHash")
struct SettingsHashTests {
    @Test func isStableAndShort() {
        let settings = ProcessingSettings(speed: 1.5, smartSpeed: true, voiceBoost: true)
        let hash = SettingsHash.make(settings)
        #expect(hash == SettingsHash.make(settings))
        #expect(hash.count == 8)
        let isHex = hash.allSatisfy { $0.isHexDigit }
        #expect(isHex)
    }

    @Test func equivalentSpeedsHashTheSame() {
        let a = ProcessingSettings(speed: 1.5, smartSpeed: true, voiceBoost: false)
        let b = ProcessingSettings(speed: 1.50001, smartSpeed: true, voiceBoost: false)
        #expect(SettingsHash.make(a) == SettingsHash.make(b))
    }

    @Test func independentOfConstructionOrder() {
        var a = ProcessingSettings(speed: 2.0, smartSpeed: false, voiceBoost: false)
        a.voiceBoost = true
        a.smartSpeed = true
        let b = ProcessingSettings(speed: 2.0, smartSpeed: true, voiceBoost: true)
        #expect(SettingsHash.make(a) == SettingsHash.make(b))
    }

    @Test func everySettingChangesTheHash() {
        let base = ProcessingSettings(speed: 1.5, smartSpeed: true, voiceBoost: true)
        let variants = [
            ProcessingSettings(speed: 1.55, smartSpeed: true, voiceBoost: true),
            ProcessingSettings(speed: 1.5, smartSpeed: false, voiceBoost: true),
            ProcessingSettings(speed: 1.5, smartSpeed: true, voiceBoost: false),
        ]
        let hashes = Set([SettingsHash.make(base)] + variants.map { SettingsHash.make($0) }
            + [SettingsHash.make(base, pipelineVersion: "999")])
        #expect(hashes.count == 5)
    }
}
