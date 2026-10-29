@testable import App
import Testing

@Suite("AppConfig")
struct AppConfigTests {
    @Test func defaults() throws {
        let config = try AppConfig.fromEnvironment { _ in nil }
        #expect(config.refreshMinutes == 30)
        #expect(config.downloadConcurrency == 2)
        #expect(config.ffmpegConcurrency == 1)
        #expect(config.basicAuth == nil)
    }

    @Test func parsesValuesAndStripsTrailingSlash() throws {
        let env = [
            "BRAMBLING_DATA": "/var/lib/brambling",
            "BRAMBLING_PUBLIC_BASE_URL": "https://brambling.example.com/",
            "BRAMBLING_REFRESH_MINUTES": "15",
            "BRAMBLING_USER": "me",
            "BRAMBLING_PASS": "pw",
        ]
        let config = try AppConfig.fromEnvironment { env[$0] }
        #expect(config.dataDirectory.path == "/var/lib/brambling")
        #expect(config.publicBaseURL.absoluteString == "https://brambling.example.com")
        #expect(config.refreshMinutes == 15)
        #expect(config.basicAuth?.user == "me")
    }

    @Test func rejectsInvalidValues() {
        #expect(throws: ConfigError.self) { try AppConfig.fromEnvironment { $0 == "BRAMBLING_REFRESH_MINUTES" ? "0" : nil } }
        #expect(throws: ConfigError.self) { try AppConfig.fromEnvironment { $0 == "BRAMBLING_PUBLIC_BASE_URL" ? "nope" : nil } }
    }
}
