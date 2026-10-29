@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("Show API + refresh")
struct ShowAPITests {
    static let feedURL = "https://feeds.example.com/private/rss?token=SUPERSECRET123"
    typealias Detail = ShowAPIController.ShowDetailDTO

    private func addShow(_ app: Application, keepCount: Int? = nil) async throws -> Detail {
        var detail: Detail?
        let payload = ShowAPIController.CreateShowRequest(sourceURL: Self.feedURL, keepCount: keepCount)
        try await app.testing().test(.POST, "api/shows", beforeRequest: { req in
            try req.content.encode(payload)
        }) { res async throws in
            #expect(res.status == .created, "\(res.body.string)")
            detail = try res.content.decode(Detail.self)
        }
        return try #require(detail)
    }

    @Test func addingAShowStoresMetadataAndPendingEpisodes() async throws {
        try await withTestApp { app, stub, _ in
            await stub.serveFeed(Self.feedURL, xml: Fixtures.feed(title: "Tom & Jérôme’s Show", items: [
                ("a", "Mon, 01 Jan 2024 10:00:00 GMT"),
                ("b", "Tue, 02 Jan 2024 10:00:00 GMT"),
            ]), etag: "\"v1\"")

            let detail = try await addShow(app)
            #expect(detail.show.slug == "tom-jeromes-show")
            #expect(detail.show.title == "Tom & Jérôme’s Show")
            #expect(detail.show.author == "Tester")
            #expect(detail.show.feedURL == "https://brambling.example/feeds/tom-jeromes-show.xml")
            #expect(!detail.show.sourceURL.contains("SUPERSECRET"), "token must be masked")
            #expect(detail.episodes.map(\.title) == ["Episode b", "Episode a"], "newest first")
            #expect(detail.episodes.allSatisfy { $0.status == .pending })
            #expect(detail.show.episodeCounts == ["pending": 2])

            let show = try #require(try await Show.query(on: app.db).first())
            #expect(show.etag == "\"v1\"")
            #expect(show.lastRefreshAt != nil)
            let episode = try #require(try await Episode.query(on: app.db).filter(\.$sourceGUID == "a").first())
            #expect(episode.enclosureLength == 1000)
            #expect(episode.sourceDuration == 600)
            #expect(episode.settingsHash == SettingsHash.make(show.processingSettings))
        }
    }

    @Test func refreshUsesConditionalGET() async throws {
        try await withTestApp { app, stub, _ in
            await stub.serveFeed(Self.feedURL, xml: Fixtures.feed(items: [("a", "Mon, 01 Jan 2024 10:00:00 GMT")]), etag: "\"v1\"")
            let detail = try await addShow(app)

            try await app.testing().test(.POST, "api/shows/\(detail.show.id)/refresh") { res async throws in
                #expect(res.status == .ok)
                let outcome = try res.content.decode(RefreshOutcome.self)
                #expect(outcome == RefreshOutcome(notModified: true, newEpisodes: 0, pruned: 0))
            }
            let last = try #require(await stub.requests.last)
            #expect(last.headers.first(name: .ifNoneMatch) == "\"v1\"")
            #expect(last.headers.first(name: .userAgent)?.hasPrefix("Brambling") == true)
        }
    }

    @Test func newEpisodesAreAddedAndOldOnesPrunedBeyondKeepCount() async throws {
        try await withTestApp { app, stub, config in
            await stub.serveFeed(Self.feedURL, xml: Fixtures.feed(items: [
                ("a", "Mon, 01 Jan 2024 10:00:00 GMT"),
                ("b", "Tue, 02 Jan 2024 10:00:00 GMT"),
            ]), etag: "\"v1\"")
            let detail = try await addShow(app, keepCount: 2)

            // Pretend "a" was processed already, with a file on disk.
            let a = try #require(try await Episode.query(on: app.db).filter(\.$sourceGUID == "a").first())
            let mediaDir = config.mediaDirectory.appendingPathComponent(detail.show.slug)
            try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
            let file = mediaDir.appendingPathComponent("a.mp3")
            try Data("mp3".utf8).write(to: file)
            a.status = .ready
            a.fileName = "a.mp3"
            a.fileSize = 3
            try await a.save(on: app.db)

            await stub.serveFeed(Self.feedURL, xml: Fixtures.feed(items: [
                ("a", "Mon, 01 Jan 2024 10:00:00 GMT"),
                ("b", "Tue, 02 Jan 2024 10:00:00 GMT"),
                ("c", "Wed, 03 Jan 2024 10:00:00 GMT"),
            ]), etag: "\"v2\"")

            try await app.testing().test(.POST, "api/shows/\(detail.show.id)/refresh") { res async throws in
                let outcome = try res.content.decode(RefreshOutcome.self)
                #expect(outcome == RefreshOutcome(notModified: false, newEpisodes: 1, pruned: 1))
            }

            let episodes = try await Episode.query(on: app.db).all()
            let status = Dictionary(uniqueKeysWithValues: episodes.map { ($0.sourceGUID, $0.status) })
            #expect(status == ["a": .available, "b": .pending, "c": .pending])
            #expect(!FileManager.default.fileExists(atPath: file.path), "pruned file is deleted")
            #expect(episodes.first { $0.sourceGUID == "a" }?.fileName == nil)

            // Raising keepCount brings "a" back for processing.
            try await app.testing().test(.PATCH, "api/shows/\(detail.show.id)", beforeRequest: { req in
                try req.content.encode(["keepCount": 3])
            }) { res async throws in
                #expect(res.status == .ok)
            }
            await stub.serveFeed(Self.feedURL, xml: Fixtures.feed(items: [
                ("a", "Mon, 01 Jan 2024 10:00:00 GMT"),
                ("b", "Tue, 02 Jan 2024 10:00:00 GMT"),
                ("c", "Wed, 03 Jan 2024 10:00:00 GMT"),
            ]), etag: "\"v3\"")
            try await app.testing().test(.POST, "api/shows/\(detail.show.id)/refresh") { res async throws in
                #expect(res.status == .ok)
            }
            let a2 = try #require(try await Episode.query(on: app.db).filter(\.$sourceGUID == "a").first())
            #expect(a2.status == .pending)
        }
    }

    @Test func failedRefreshStoresMaskedError() async throws {
        try await withTestApp { app, stub, _ in
            await stub.serveFeed(Self.feedURL, xml: Fixtures.feed(items: [("a", "Mon, 01 Jan 2024 10:00:00 GMT")]), etag: "\"v1\"")
            let detail = try await addShow(app)
            await stub.set(Self.feedURL) { _ in HTTPFetchResponse(status: .forbidden, headers: [:], body: Data()) }

            try await app.testing().test(.POST, "api/shows/\(detail.show.id)/refresh") { res async throws in
                #expect(res.status == .badGateway)
                #expect(res.body.string.contains("403"))
            }
            let show = try #require(try await Show.query(on: app.db).first())
            #expect(show.lastError?.contains("403") == true)
            #expect(show.lastError?.contains("SUPERSECRET") == false)
        }
    }

    @Test func invalidFeedIsRejectedWithoutLeakingTheToken() async throws {
        try await withTestApp { app, stub, _ in
            await stub.set(Self.feedURL) { _ in
                HTTPFetchResponse(status: .ok, headers: [:], body: Data("<html>login</html>".utf8))
            }
            try await app.testing().test(.POST, "api/shows", beforeRequest: { req in
                try req.content.encode(["sourceURL": Self.feedURL])
            }) { res async throws in
                #expect(res.status == .unprocessableEntity)
                #expect(!res.body.string.contains("SUPERSECRET"))
            }
            #expect(try await Show.query(on: app.db).count() == 0)
        }
    }

    @Test func previewAndUniqueSlugs() async throws {
        try await withTestApp { app, stub, _ in
            await stub.serveFeed(Self.feedURL, xml: Fixtures.feed(items: [
                ("a", "Mon, 01 Jan 2024 10:00:00 GMT"),
                ("b", "Tue, 02 Jan 2024 10:00:00 GMT"),
            ]), etag: "\"v1\"")

            try await app.testing().test(.POST, "api/shows/preview", beforeRequest: { req in
                try req.content.encode(["sourceURL": Self.feedURL])
            }) { res async throws in
                let preview = try res.content.decode(ShowAPIController.PreviewDTO.self)
                #expect(preview.title == "Test Show")
                #expect(preview.suggestedSlug == "test-show")
                #expect(preview.episodeCount == 2)
                #expect(preview.latest.first?.title == "Episode b")
            }

            let first = try await addShow(app)
            let second = try await addShow(app)
            #expect(first.show.slug == "test-show")
            #expect(second.show.slug == "test-show-2")

            try await app.testing().test(.POST, "api/shows", beforeRequest: { req in
                try req.content.encode(["sourceURL": Self.feedURL, "slug": "Not Valid!"])
            }) { res async throws in
                #expect(res.status == .unprocessableEntity)
            }
        }
    }

    @Test func deleteRemovesShowEpisodesAndFiles() async throws {
        try await withTestApp { app, stub, config in
            await stub.serveFeed(Self.feedURL, xml: Fixtures.feed(items: [("a", "Mon, 01 Jan 2024 10:00:00 GMT")]), etag: "\"v1\"")
            let detail = try await addShow(app)
            let mediaDir = config.mediaDirectory.appendingPathComponent(detail.show.slug)
            try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)

            try await app.testing().test(.DELETE, "api/shows/\(detail.show.id)") { res async throws in
                #expect(res.status == .noContent)
            }
            #expect(try await Show.query(on: app.db).count() == 0)
            #expect(try await Episode.query(on: app.db).count() == 0)
            #expect(!FileManager.default.fileExists(atPath: mediaDir.path))
        }
    }
}
