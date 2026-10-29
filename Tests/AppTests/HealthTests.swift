@testable import App
import Foundation
import Testing
import VaporTesting

@Suite("Health")
struct HealthTests {
    @Test func healthReturnsJSON() async throws {
        let dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("brambling-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let config = try AppConfig.fromEnvironment { $0 == "BRAMBLING_DATA" ? dataDir.path : nil }

        try await withApp(configure: { try await App.configure($0, config: config) }) { app in
            try await app.testing().test(.GET, "health") { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(HealthController.HealthResponse.self)
                #expect(body.queueLength == 0)
                #expect(body.ok == (body.ffmpegVersion != nil))
                #expect(body.diskFreeBytes != nil)
            }
        }
        #expect(FileManager.default.fileExists(atPath: dataDir.appendingPathComponent("brambling.sqlite").path))
    }
}
