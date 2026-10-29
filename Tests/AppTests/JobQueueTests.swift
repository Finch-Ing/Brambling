@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("JobQueue")
struct JobQueueTests {
    static let feedURL = "https://feeds.example.com/rss?token=SECRET"
    static let items: [(guid: String, date: String)] = [
        ("a", "Mon, 01 Jan 2024 10:00:00 GMT"),
        ("b", "Tue, 02 Jan 2024 10:00:00 GMT"),
    ]

    static func enclosure(_ guid: String) -> String { "https://cdn.example.com/\(guid).mp3?token=s3cr3t" }

    @discardableResult
    private func addShow(_ ctx: TestContext, body: [String: String] = [:]) async throws -> UUID {
        await ctx.http.serveFeed(Self.feedURL, xml: Fixtures.feed(items: Self.items), etag: "\"v1\"")
        var id: UUID?
        try await ctx.app.testing().test(.POST, "api/shows", beforeRequest: { req in
            try req.content.encode(["sourceURL": Self.feedURL])
        }) { res async throws in
            #expect(res.status == .created, "\(res.body.string)")
            id = try res.content.decode(ShowAPIController.ShowDetailDTO.self).show.id
        }
        return try #require(id)
    }

    private func episode(_ ctx: TestContext, _ guid: String) async throws -> Episode {
        try #require(try await Episode.query(on: ctx.app.db).filter(\.$sourceGUID == guid).first())
    }

    private func statuses(_ ctx: TestContext) async throws -> [String: EpisodeStatus] {
        let episodes = try await Episode.query(on: ctx.app.db).all()
        return Dictionary(uniqueKeysWithValues: episodes.map { ($0.sourceGUID, $0.status) })
    }

    private func tmpFiles(_ ctx: TestContext) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: ctx.config.tmpDirectory.path)) ?? []).sorted()
    }

    @Test func downloadsAndProcessesEpisodesEndToEnd() async throws {
        try await withTestContext { ctx in
            try await addShow(ctx)
            #expect(FileManager.default.fileExists(atPath: ctx.config.artDirectory.appendingPathComponent("test-show.jpg").path))

            await ctx.app.jobQueue.waitUntilIdle()

            #expect(try await statuses(ctx) == ["a": .ready, "b": .ready])
            let a = try await episode(ctx, "a")
            let id = try a.requireID().uuidString.lowercased()
            #expect(a.fileName == "\(id)-\(a.settingsHash).mp3")
            #expect(a.fileSize == 4096)
            #expect(a.duration == 61)
            #expect(a.processedAt == ctx.world.now)
            let file = ctx.config.mediaDirectory.appendingPathComponent("test-show").appendingPathComponent(a.fileName!)
            #expect(FileManager.default.fileExists(atPath: file.path))
            #expect(tmpFiles(ctx).isEmpty, "sources and outputs are cleaned up")

            let calls = await ctx.processor.calls
            #expect(calls.count == 2)
            #expect(calls.first?.tags.title == "Episode b", "newest first")
            #expect(calls.first?.tags.album == "Test Show")
            #expect(calls.first?.tags.artist == "Tester")
            #expect(calls.first?.artwork?.lastPathComponent == "test-show.jpg")
        }
    }

    @Test func failedDownloadsRetryWithBackoffThenFail() async throws {
        try await withTestContext { ctx in
            await ctx.downloader.fail(Self.enclosure("a"), times: 5)
            let start = ctx.world.now
            try await addShow(ctx)
            await ctx.app.jobQueue.waitUntilIdle()

            var a = try await episode(ctx, "a")
            #expect(a.status == .pending)
            #expect(a.attempts == 1)
            #expect(a.nextAttemptAt == start.addingTimeInterval(5 * 60))
            #expect(a.error == "Download failed with HTTP 503")
            #expect(try await episode(ctx, "b").status == .ready, "other episodes are not blocked")

            // Before the backoff has passed nothing happens.
            ctx.world.advance(60)
            await ctx.app.jobQueue.waitUntilIdle()
            #expect(try await episode(ctx, "a").attempts == 1)

            ctx.world.advance(4 * 60)
            await ctx.app.jobQueue.waitUntilIdle()
            a = try await episode(ctx, "a")
            #expect(a.attempts == 2)
            #expect(a.nextAttemptAt == ctx.world.now.addingTimeInterval(30 * 60))

            ctx.world.advance(30 * 60)
            await ctx.app.jobQueue.waitUntilIdle()
            a = try await episode(ctx, "a")
            #expect(a.status == .failed)
            #expect(a.attempts == 3)

            // Retry resets the episode; the stub still has failures left, so make it succeed.
            await ctx.downloader.fail(Self.enclosure("a"), times: 0)
            try await ctx.app.testing().test(.POST, "api/episodes/\(a.requireID())/retry") { res async throws in
                #expect(res.status == .ok)
            }
            await ctx.app.jobQueue.waitUntilIdle()
            #expect(try await episode(ctx, "a").status == .ready)
        }
    }

    @Test func failedProcessingKeepsTheSourceForTheRetry() async throws {
        try await withTestContext { ctx in
            await ctx.processor.fail(times: 1)
            try await addShow(ctx)
            await ctx.app.jobQueue.waitUntilIdle()

            let b = try await episode(ctx, "b")
            #expect(b.status == .downloaded, "retry needs no new download")
            #expect(b.attempts == 1)
            #expect(b.error?.contains("ffmpeg exited with 1") == true)

            ctx.world.advance(5 * 60)
            await ctx.app.jobQueue.waitUntilIdle()
            #expect(try await statuses(ctx) == ["a": .ready, "b": .ready])
            let downloads = await ctx.downloader.calls.filter { $0 == Self.enclosure("b") }
            #expect(downloads.count == 1)
        }
    }

    @Test func errorsNeverContainTheEnclosureToken() async throws {
        struct LeakyError: Error, CustomStringConvertible {
            var description: String { "GET \(JobQueueTests.enclosure("a")) timed out" }
        }
        actor LeakyDownloader: EpisodeDownloading {
            nonisolated func download(from url: String, to file: URL, timeout: Duration) async throws -> Int64 {
                throw LeakyError()
            }
        }
        try await withTestContext { ctx in
            var env = ctx.app.jobEnvironment
            env.downloader = LeakyDownloader()
            ctx.app.jobEnvironment = env
            try await addShow(ctx)
            await ctx.app.jobQueue.waitUntilIdle()
            let a = try await episode(ctx, "a")
            #expect(a.error?.contains("s3cr3t") == false)
            #expect(a.error?.contains("token=••••") == true)
        }
    }

    @Test func diskGuardBlocksAndResumes() async throws {
        try await withTestContext { ctx in
            ctx.world.freeBytes = 5 * 1_073_741_824 + 100   // just above the 5 GB minimum
            try await addShow(ctx)
            await ctx.app.jobQueue.waitUntilIdle()

            #expect(try await statuses(ctx) == ["a": .pending, "b": .pending])
            #expect(await ctx.downloader.calls.filter { $0.hasSuffix("s3cr3t") }.isEmpty)
            #expect(try await episode(ctx, "a").attempts == 0, "blocked is not a failure")

            try await ctx.app.testing().test(.GET, "health") { res async throws in
                let health = try res.content.decode(HealthController.HealthResponse.self)
                #expect(!health.ok)
                #expect(health.disk.blocked)
                #expect(health.problems.contains { $0.contains("disk guard") })
            }

            ctx.world.freeBytes = 50 * 1_073_741_824
            await ctx.app.jobQueue.waitUntilIdle()
            #expect(try await statuses(ctx) == ["a": .ready, "b": .ready])
            #expect(await ctx.app.jobQueue.diskBlockedReason == nil)
        }
    }

    @Test func diskFullDuringDownloadBlocksWithoutCountingAnAttempt() async throws {
        try await withTestContext { ctx in
            await ctx.downloader.failWithOutOfSpace(true)
            try await addShow(ctx)
            await ctx.app.jobQueue.waitUntilIdle()

            let a = try await episode(ctx, "a")
            #expect(a.status == .pending)
            #expect(a.attempts == 0)
            #expect(await ctx.app.jobQueue.diskBlockedReason != nil)
            let callsWhileFull = await ctx.downloader.calls.count

            // No retry loop: nothing happens during the cooldown, even if the disk looks fine.
            await ctx.downloader.failWithOutOfSpace(false)
            ctx.world.advance(60)
            await ctx.app.jobQueue.waitUntilIdle()
            #expect(await ctx.downloader.calls.count == callsWhileFull)

            ctx.world.advance(5 * 60)
            await ctx.app.jobQueue.waitUntilIdle()
            #expect(try await statuses(ctx) == ["a": .ready, "b": .ready])
            #expect(await ctx.app.jobQueue.diskBlockedReason == nil)
        }
    }

    @Test func maxMediaCapBlocks() async throws {
        try await withTestContext(configure: { $0.diskLimits.maxMediaBytes = 3 * 1_073_741_824 }) { ctx in
            // Unknown enclosure length → 2 × 300 MB estimate fits; then media is full.
            try await addShow(ctx)
            await ctx.app.jobQueue.waitUntilIdle()
            #expect(try await statuses(ctx) == ["a": .ready, "b": .ready])
        }
        try await withTestContext(configure: { $0.diskLimits.maxMediaBytes = 1000 }) { ctx in
            try await addShow(ctx)
            await ctx.app.jobQueue.waitUntilIdle()
            #expect(try await statuses(ctx) == ["a": .pending, "b": .pending])
        }
    }

    @Test func ffmpegOnlyRunsInsideTheWindowUnlessOverridden() async throws {
        try await withTestContext(configure: { $0.processWindow = try ProcessingWindow(parsing: "01:00-06:00") }) { ctx in
            // World clock is 12:00 Berlin: downloads happen, processing waits.
            try await addShow(ctx)
            await ctx.app.jobQueue.waitUntilIdle()
            #expect(try await statuses(ctx) == ["a": .downloaded, "b": .downloaded])
            #expect(await ctx.processor.calls.isEmpty)

            try await ctx.app.testing().test(.GET, "api/queue") { res async throws in
                let status = try res.content.decode(QueueStatus.self)
                #expect(status.processWindow == "01:00–06:00")
                #expect(!status.processWindowOpen)
                #expect(status.counts["downloaded"] == 2)
                #expect(status.nextProcessWindowOpening == ISO8601DateFormatter().date(from: "2026-10-22T01:00:00+02:00"))
            }

            // The window opens at 01:00.
            ctx.world.now = ISO8601DateFormatter().date(from: "2026-10-22T01:00:00+02:00")!
            await ctx.app.jobQueue.waitUntilIdle()
            #expect(try await statuses(ctx) == ["a": .ready, "b": .ready])
        }
    }

    @Test func processNowOverridesTheWindowUntilTheQueueIsEmpty() async throws {
        try await withTestContext(configure: { $0.processWindow = try ProcessingWindow(parsing: "01:00-06:00") }) { ctx in
            try await addShow(ctx)
            await ctx.app.jobQueue.waitUntilIdle()
            #expect(try await statuses(ctx) == ["a": .downloaded, "b": .downloaded])

            try await ctx.app.testing().test(.POST, "api/queue/process-now") { res async throws in
                #expect(try res.content.decode(QueueStatus.self).processNowOverride)
            }
            await ctx.app.jobQueue.waitUntilIdle()
            #expect(try await statuses(ctx) == ["a": .ready, "b": .ready])
            #expect(await ctx.app.jobQueue.processNowOverride == false, "override ends once the queue is empty")
        }
    }

    @Test func pausedShowsAreNotDownloaded() async throws {
        try await withTestContext { ctx in
            let id = try await addShowPaused(ctx)
            await ctx.app.jobQueue.waitUntilIdle()
            #expect(try await statuses(ctx) == ["a": .pending, "b": .pending])

            try await ctx.app.testing().test(.PATCH, "api/shows/\(id)", beforeRequest: { req in
                try req.content.encode(["enabled": true])
            }) { _ async throws in }
            await ctx.app.jobQueue.waitUntilIdle()
            #expect(try await statuses(ctx) == ["a": .ready, "b": .ready])
        }
    }

    private func addShowPaused(_ ctx: TestContext) async throws -> UUID {
        await ctx.http.serveFeed(Self.feedURL, xml: Fixtures.feed(items: Self.items), etag: "\"v1\"")
        var id: UUID?
        let body = ShowAPIController.CreateShowRequest(sourceURL: Self.feedURL, enabled: false)
        try await ctx.app.testing().test(.POST, "api/shows", beforeRequest: { req in
            try req.content.encode(body)
        }) { res async throws in
            id = try res.content.decode(ShowAPIController.ShowDetailDTO.self).show.id
        }
        return try #require(id)
    }

    @Test func reprocessReplacesFilesMadeWithOldSettings() async throws {
        try await withTestContext { ctx in
            let showID = try await addShow(ctx)
            await ctx.app.jobQueue.waitUntilIdle()
            let before = try await episode(ctx, "a")
            let oldFile = try #require(before.fileName)

            try await ctx.app.testing().test(.PATCH, "api/shows/\(showID)", beforeRequest: { req in
                try req.content.encode(["speed": 1.5])
            }) { _ async throws in }
            // Settings changes alone don't touch ready episodes.
            await ctx.app.jobQueue.waitUntilIdle()
            #expect(try await episode(ctx, "a").fileName == oldFile)

            try await ctx.app.testing().test(.POST, "api/shows/\(showID)/reprocess") { res async throws in
                #expect(try res.content.decode(ShowAPIController.ReprocessResult.self).queued == 2)
            }
            await ctx.app.jobQueue.waitUntilIdle()

            let after = try await episode(ctx, "a")
            #expect(after.status == .ready)
            #expect(after.settingsHash == SettingsHash.make(ProcessingSettings(speed: 1.5, smartSpeed: true, voiceBoost: true)))
            #expect(after.fileName != oldFile)
            let dir = ctx.config.mediaDirectory.appendingPathComponent("test-show")
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(oldFile).path), "old file deleted")
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(after.fileName!).path))
            #expect(await ctx.processor.calls.last?.settings.speed == 1.5)

            // Nothing left to reprocess.
            try await ctx.app.testing().test(.POST, "api/shows/\(showID)/reprocess") { res async throws in
                #expect(try res.content.decode(ShowAPIController.ReprocessResult.self).queued == 0)
            }
        }
    }

    @Test func recoveryAfterRestart() async throws {
        try await withTestContext { ctx in
            try await addShow(ctx)
            let a = try await episode(ctx, "a")
            let b = try await episode(ctx, "b")
            a.status = .downloading
            b.status = .processing
            try await a.save(on: ctx.app.db)
            try await b.save(on: ctx.app.db)
            let tmp = ctx.config.tmpDirectory
            let bSource = tmp.appendingPathComponent("\(try b.requireID().uuidString.lowercased()).src")
            try Data("partial".utf8).write(to: tmp.appendingPathComponent("\(try a.requireID().uuidString.lowercased()).src"))
            try Data("complete".utf8).write(to: bSource)
            try Data("stray".utf8).write(to: tmp.appendingPathComponent("leftover.mp3"))

            try await ctx.app.jobQueue.recover()

            #expect(try await statuses(ctx) == ["a": .pending, "b": .downloaded])
            #expect(tmpFiles(ctx) == [bSource.lastPathComponent], "only the finished download is kept")
        }
    }
}
