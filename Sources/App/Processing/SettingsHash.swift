import Vapor

enum SettingsHash {
    /// Short, stable hash of the settings (plus pipeline version) used to produce a file.
    static func make(_ settings: ProcessingSettings, pipelineVersion: String = FilterChain.pipelineVersion) -> String {
        let canonical = [
            "v=\(pipelineVersion)",
            "speed=\(settings.speedString)",
            "ss=\(settings.smartSpeed ? 1 : 0)",
            "vb=\(settings.voiceBoost ? 1 : 0)",
        ].joined(separator: ";")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}
