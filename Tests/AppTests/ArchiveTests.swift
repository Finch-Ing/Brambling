@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("Episode catalogue and archive")
struct ArchiveTests {
    static let feedURL = "https://feeds.example.com/dnd?token=SECRET"
    /// Five episodes, #1 oldest … #5 newest.
    static let items: [(guid: String, date: String)] = (1...5).map { ("ep\($0)", "Mon, 0\($0) Jan 2024 10:00:00 GMT") }
    static let numbers = Dictionary(uniqueKeysWithValues: (1...5).map { ("ep\($0)", (episode: $0 + 299, season: Optional(1))) })

    private func addShow(_ ctx: TestContext, keepCount: Int = 2, numbered: Bool = true) async throws -> UUID {
        await ctx.http.serveFeed(Self.feedURL, xml: Fixtures.feed(items: Self.items, numbers: numbered ? Self.numbers : [:]), etag: "\"v1\"")
        var id: UUID?
        let body = ShowAPIController.CreateShowRequest(sourceURL: Self.feedURL, keepCount: keepCount)
        try await ctx.app.testing().test(.POST, "api/shows", beforeRequest: { req in try req.content.encode(body) }) { res async throws in
            id = try res.content.decode(ShowAPIController.ShowDetailDTO.self).show.id
        }
        await ctx.app.jobQueue.waitUntilIdle()
        return try #require(id)
    }

    private func statuses(_ ctx: TestContext) async throws -> [String: EpisodeStatus] {
        Dictionary(uniqueKeysWithValues: try await Episode.query(on: ctx.app.db).all().map { ($0.sourceGUID, $0.status) })
    }

    private func id(_ ctx: TestContext, _ guid: String) async throws -> UUID {
        try #require(try await Episode.query(on: ctx.app.db).filter(\.$sourceGUID == guid).first()?.id)
    }

    @Test func wholeFeedIsStoredOnlyNewestAreKept() async throws {
        try await withTestContext { ctx in
            _ = try await addShow(ctx)
            #expect(try await statuses(ctx) == ["ep1": .available, "ep2": .available, "ep3": .available, "ep4": .ready, "ep5": .ready])
            let ep3 = try #require(try await Episode.query(on: ctx.app.db).filter(\.$sourceGUID == "ep3").first())
            #expect(ep3.episodeNumber == 302)
            #expect(ep3.seasonNumber == 1)
            #expect(await ctx.downloader.calls.filter { $0.contains("ep3") }.isEmpty, "available episodes are not downloaded")
        }
    }

    @Test func keepSelectedOlderEpisodesViaTheForm() async throws {
        try await withTestContext { ctx in
            let showID = try await addShow(ctx)
            let ep1 = try await id(ctx, "ep1"), ep2 = try await id(ctx, "ep2")

            try await ctx.app.testing().test(.POST, "shows/\(showID)/archive", beforeRequest: { req in
                req.headers.contentType = .urlEncodedForm
                req.body = .init(string: "action=keep&episodes[]=\(ep1)&episodes[]=\(ep2)")
            }) { res async throws in
                #expect(res.status == .seeOther, "\(res.body.string)")
                #expect(res.headers.first(name: .location) == "/shows/\(showID)?notice=kept#choose")
            }
            await ctx.app.jobQueue.waitUntilIdle()
            // Choosing switches the show to manual selection; the episodes it had (ep4, ep5) are carried over.
            #expect(try await Show.find(showID, on: ctx.app.db)?.keepCount == 0)
            #expect(try await statuses(ctx) == ["ep1": .ready, "ep2": .ready, "ep3": .available, "ep4": .ready, "ep5": .ready])

            // In manual mode new episodes in the source are not added.
            await ctx.http.serveFeed(Self.feedURL, xml: Fixtures.feed(items: Self.items + [("ep6", "Sat, 06 Jan 2024 10:00:00 GMT")]), etag: "\"v2\"")
            try await ctx.app.testing().test(.POST, "api/shows/\(showID)/refresh") { _ async throws in }
            await ctx.app.jobQueue.waitUntilIdle()
            #expect(try await statuses(ctx) == ["ep1": .ready, "ep2": .ready, "ep3": .available, "ep4": .ready, "ep5": .ready, "ep6": .available])
        }
    }

    @Test func unkeepingDeletesTheFile() async throws {
        try await withTestContext { ctx in
            let showID = try await addShow(ctx)
            let ep1 = try await id(ctx, "ep1")
            _ = try await ctx.app.shows.setKept(try #require(try await Show.find(showID, on: ctx.app.db)), .episodes([ep1]), kept: true)
            await ctx.app.jobQueue.waitUntilIdle()
            let file = try #require(try await Episode.find(ep1, on: ctx.app.db)?.fileName)
            let path = ctx.config.mediaDirectory.appendingPathComponent("test-show/\(file)").path
            #expect(FileManager.default.fileExists(atPath: path))

            try await ctx.app.testing().test(.POST, "shows/\(showID)/archive", beforeRequest: { req in
                req.headers.contentType = .urlEncodedForm
                req.body = .init(string: "action=unkeep&episodes[]=\(ep1)")
            }) { res async throws in
                #expect(res.headers.first(name: .location)?.hasSuffix("notice=unkept#choose") == true)
            }
            let episode = try #require(try await Episode.find(ep1, on: ctx.app.db))
            #expect(episode.status == .available)
            #expect(!episode.kept)
            #expect(episode.fileName == nil)
            #expect(!FileManager.default.fileExists(atPath: path))

            // Manual mode is exclusive: deselecting the newest episode removes it too.
            let ep5 = try await id(ctx, "ep5")
            _ = try await ctx.app.shows.setKept(try #require(try await Show.find(showID, on: ctx.app.db)), .episodes([ep5]), kept: false)
            #expect(try await Episode.find(ep5, on: ctx.app.db)?.status == .available)
        }
    }

    @Test func keepByEpisodeNumberRange() async throws {
        try await withTestContext { ctx in
            let showID = try await addShow(ctx)
            try await ctx.app.testing().test(.POST, "shows/\(showID)/archive/range", beforeRequest: { req in
                req.headers.contentType = .urlEncodedForm
                req.body = .init(string: "action=keep&from=300&to=301&season=")
            }) { res async throws in
                #expect(res.status == .seeOther, "\(res.body.string)")
            }
            await ctx.app.jobQueue.waitUntilIdle()
            #expect(try await statuses(ctx) == ["ep1": .ready, "ep2": .ready, "ep3": .available, "ep4": .ready, "ep5": .ready])

            // Season filter that matches nothing changes nothing.
            let show = try #require(try await Show.find(showID, on: ctx.app.db))
            let result = try await ctx.app.shows.setKept(show, .numbers(from: 300, to: 310, season: 2), kept: true)
            #expect(result.changed == 0)

            try await ctx.app.testing().test(.POST, "shows/\(showID)/archive/range", beforeRequest: { req in
                req.headers.contentType = .urlEncodedForm
                req.body = .init(string: "action=keep&from=310&to=300")
            }) { res async throws in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains("must not be larger"))
            }
        }
    }

    @Test func rangeNeedsEpisodeNumbers() async throws {
        try await withTestContext { ctx in
            let showID = try await addShow(ctx, numbered: false)
            let show = try #require(try await Show.find(showID, on: ctx.app.db))
            await #expect(throws: (any Error).self) {
                _ = try await ctx.app.shows.setKept(show, .numbers(from: 1, to: 2, season: nil), kept: true)
            }
            try await ctx.app.shows.switchToManualSelection(show)
            try await ctx.app.testing().test(.GET, "shows/\(showID)") { res async throws in
                #expect(res.body.string.contains("id=\"choose\""))
                #expect(!res.body.string.contains("archive/range"), "no range form without numbers")
            }
        }
    }

    @Test func keepAllShowsAnEstimateAndQueuesEverything() async throws {
        try await withTestContext { ctx in
            let showID = try await addShow(ctx)
            // Newest mode: no chooser on the page.
            try await ctx.app.testing().test(.GET, "shows/\(showID)") { res async throws in
                #expect(!res.body.string.contains("id=\"choose\""))
            }
            try await ctx.app.testing().test(.POST, "shows/\(showID)", beforeRequest: { req in
                req.headers.contentType = .urlEncodedForm
                req.body = .init(string: "mode=manual&keepCount=2&speed=1&enabled=on")
            }) { res async throws in
                #expect(res.status == .seeOther)
            }
            try await ctx.app.testing().test(.GET, "shows/\(showID)") { res async throws in
                let html = res.body.string
                #expect(res.status == .ok)
                #expect(html.contains("id=\"choose\""))
                #expect(html.contains("5 episodes in the source feed · 2 selected"))
                #expect(html.contains("Select all 3 remaining episodes"))
                #expect(html.contains("S1 E302"))
                #expect(html.contains("data-search=\"s1 e302 #302 episode ep3\""))
                #expect(html.contains(">not selected<"))
                #expect(html.contains("value=\"manual\" checked"))
                #expect(!html.contains("SECRET"))
            }
            try await ctx.app.testing().test(.GET, "shows/\(showID)/archive") { res async throws in
                #expect(res.headers.first(name: .location) == "/shows/\(showID)#choose", "old archive URL redirects")
            }
            try await ctx.app.testing().test(.POST, "shows/\(showID)/archive/all") { res async throws in
                #expect(res.status == .seeOther)
            }
            await ctx.app.jobQueue.waitUntilIdle()
            #expect(Set(try await statuses(ctx).values) == [.ready])
            try await ctx.app.testing().test(.GET, "shows/\(showID)") { res async throws in
                #expect(!res.body.string.contains("Select all"))
            }
        }
    }

    @Test func lowerKeepCountAppliesImmediately() async throws {
        try await withTestContext { ctx in
            let showID = try await addShow(ctx, keepCount: 4)
            #expect(try await statuses(ctx).values.filter { $0 == .ready }.count == 4)
            try await ctx.app.testing().test(.PATCH, "api/shows/\(showID)", beforeRequest: { req in
                try req.content.encode(["keepCount": 1])
            }) { _ async throws in }
            #expect(try await statuses(ctx) == ["ep1": .available, "ep2": .available, "ep3": .available, "ep4": .available, "ep5": .ready])
        }
    }

    @Test func apiKeepEndpoint() async throws {
        try await withTestContext { ctx in
            let showID = try await addShow(ctx)
            try await ctx.app.testing().test(.POST, "api/shows/\(showID)/keep", beforeRequest: { req in
                try req.content.encode(ShowAPIController.KeepRequest(action: "keep", fromNumber: 300, toNumber: 300))
            }) { res async throws in
                let result = try res.content.decode(ShowService.SelectionResult.self)
                #expect(result.changed == 1)
                #expect(result.queued == 1)
            }
            try await ctx.app.testing().test(.POST, "api/shows/\(showID)/keep", beforeRequest: { req in
                try req.content.encode(ShowAPIController.KeepRequest(action: "explode"))
            }) { res async throws in
                #expect(res.status == .unprocessableEntity)
            }
        }
    }

    @Test func plainHTTPShowsOneCopyButtonWithTheBrowsersAddress() async throws {
        try await withTestContext { ctx in
            _ = try await addShow(ctx)
            try await ctx.app.testing().test(.GET, "/", headers: ["Host": "192.0.2.10:8080"]) { res async throws in
                let html = res.body.string
                #expect(html.contains("data-url=\"http://192.0.2.10:8080/feeds/test-show.xml\""))
                #expect(html.contains("Copy feed URL"))
                #expect(!html.contains("Copy HTTPS"))
            }
        }
    }

    @Test func homepageHasCopyButtonsStatusAndActions() async throws {
        try await withTestContext(configure: { $0.processWindow = try ProcessingWindow(parsing: "01:00-06:00") }) { ctx in
            let showID = try await addShow(ctx)
            try await ctx.app.testing().test(.GET, "/") { res async throws in
                let html = res.body.string
                #expect(html.contains("data-url=\"https://brambling.example/feeds/test-show.xml\""))
                #expect(html.contains("data-url=\"http://brambling.example/feeds/test-show.xml\""))
                #expect(html.contains("Copy HTTPS") && html.contains("Copy HTTP"))
                #expect(html.contains("2 episode(s) waiting for the processing window (opens"), "footer status")
                #expect(html.contains("Process now"))
                #expect(html.contains("Refresh all feeds"))
                #expect(!html.contains("/archive"), "no episode list button on the homepage")
                #expect(html.contains("class=\"add-show\""))
                #expect(html.contains("id=\"status-footer\""))
                #expect(html.contains("id=\"theme-toggle\""))
                #expect(html.contains("Newest 2"))
            }
            try await ctx.app.testing().test(.POST, "queue/process-now", beforeRequest: { req in
                try req.content.encode(["back": "/shows/\(showID)"], as: .urlEncodedForm)
            }) { res async throws in
                #expect(res.headers.first(name: .location) == "/shows/\(showID)?notice=processing-now")
            }
            try await ctx.app.testing().test(.POST, "queue/process-now", beforeRequest: { req in
                try req.content.encode(["back": "//evil.example"], as: .urlEncodedForm)
            }) { res async throws in
                #expect(res.headers.first(name: .location) == "/settings?notice=processing-now", "no open redirect")
            }
            await ctx.app.jobQueue.waitUntilIdle()
            try await ctx.app.testing().test(.GET, "/") { res async throws in
                #expect(res.body.string.contains(">Idle<"))
            }
            try await ctx.app.testing().test(.POST, "shows/refresh-all") { res async throws in
                #expect(res.headers.first(name: .location) == "/?notice=refreshing-all")
            }
        }
    }
}

@Suite("Hand-picked shows (keepCount 0)")
struct HandPickedTests {
    @Test func onlySelectedEpisodesAreProcessedAndInTheFeed() async throws {
        try await withTestContext { ctx in
            await ctx.http.serveFeed(ArchiveTests.feedURL, xml: Fixtures.feed(items: ArchiveTests.items, numbers: ArchiveTests.numbers), etag: "\"v1\"")
            var showID: UUID?
            try await ctx.app.testing().test(.POST, "api/shows", beforeRequest: { req in
                try req.content.encode(ShowAPIController.CreateShowRequest(sourceURL: ArchiveTests.feedURL, keepCount: 0))
            }) { res async throws in
                #expect(res.status == .created, "\(res.body.string)")
                showID = try res.content.decode(ShowAPIController.ShowDetailDTO.self).show.id
            }
            let id = try #require(showID)
            await ctx.app.jobQueue.waitUntilIdle()
            #expect(try await Episode.query(on: ctx.app.db).filter(\.$status != .available).count() == 0, "nothing kept automatically")
            #expect(await ctx.downloader.calls.filter { $0.contains(".mp3") }.isEmpty)

            // Pick #300 and #302 (ep1 and ep3).
            let show = try #require(try await Show.find(id, on: ctx.app.db))
            _ = try await ctx.app.shows.setKept(show, .numbers(from: 300, to: 300, season: nil), kept: true)
            _ = try await ctx.app.shows.setKept(show, .numbers(from: 302, to: 302, season: nil), kept: true)
            await ctx.app.jobQueue.waitUntilIdle()

            try await ctx.app.testing().test(.GET, "feeds/test-show.xml") { res async throws in
                let xml = res.body.string
                #expect(xml.components(separatedBy: "<item>").count == 3, "exactly the two picked episodes")
                #expect(xml.contains("Episode ep1") && xml.contains("Episode ep3"))
                #expect(!xml.contains("Episode ep5"), "newest is not added automatically")
            }
            try await ctx.app.testing().test(.GET, "/") { res async throws in
                #expect(res.body.string.contains("Manual selection"))
            }

            // A new episode in the source doesn't get added either.
            await ctx.http.serveFeed(ArchiveTests.feedURL, xml: Fixtures.feed(items: ArchiveTests.items + [("ep6", "Sat, 06 Jan 2024 10:00:00 GMT")]), etag: "\"v2\"")
            try await ctx.app.testing().test(.POST, "api/shows/\(id)/refresh") { _ async throws in }
            await ctx.app.jobQueue.waitUntilIdle()
            #expect(try await Episode.query(on: ctx.app.db).filter(\.$sourceGUID == "ep6").first()?.status == .available)
        }
    }
}

@Suite("Episode modes")
struct EpisodeModeTests {
    @Test func switchingModesRemembersTheSelection() async throws {
        try await withTestContext { ctx in
            await ctx.http.serveFeed(ArchiveTests.feedURL, xml: Fixtures.feed(items: ArchiveTests.items, numbers: ArchiveTests.numbers), etag: "\"v1\"")
            var showID: UUID?
            try await ctx.app.testing().test(.POST, "api/shows", beforeRequest: { req in
                try req.content.encode(ShowAPIController.CreateShowRequest(sourceURL: ArchiveTests.feedURL, keepCount: 0))
            }) { res async throws in
                showID = try res.content.decode(ShowAPIController.ShowDetailDTO.self).show.id
            }
            let id = try #require(showID)
            let show = try #require(try await Show.find(id, on: ctx.app.db))
            _ = try await ctx.app.shows.setKept(show, .numbers(from: 300, to: 301, season: nil), kept: true)
            await ctx.app.jobQueue.waitUntilIdle()
            func readyGUIDs() async throws -> Set<String> {
                Set(try await Episode.query(on: ctx.app.db).filter(\.$status == .ready).all().map(\.sourceGUID))
            }
            #expect(try await readyGUIDs() == ["ep1", "ep2"])

            // Newest 1: only the newest is kept; the manual selection is not mixed in.
            try await ctx.app.testing().test(.POST, "shows/\(id)", beforeRequest: { req in
                req.headers.contentType = .urlEncodedForm
                req.body = .init(string: "mode=newest&keepCount=1&speed=1&enabled=on")
            }) { _ async throws in }
            await ctx.app.jobQueue.waitUntilIdle()
            #expect(try await readyGUIDs() == ["ep5"])

            // Back to manual: the earlier selection comes back.
            try await ctx.app.testing().test(.POST, "shows/\(id)", beforeRequest: { req in
                req.headers.contentType = .urlEncodedForm
                req.body = .init(string: "mode=manual&keepCount=1&speed=1&enabled=on")
            }) { _ async throws in }
            await ctx.app.jobQueue.waitUntilIdle()
            #expect(try await readyGUIDs() == ["ep1", "ep2"])
        }
    }

    @Test func footerShowsStatusAndDisk() async throws {
        try await withTestContext(configure: { $0.processWindow = try ProcessingWindow(parsing: "01:00-06:00") }) { ctx in
            try await ctx.app.testing().test(.GET, "status/footer") { res async throws in
                let html = res.body.string
                #expect(html.hasPrefix("<footer id=\"status-footer\""))
                #expect(html.contains(">Idle<"))
                #expect(html.contains("100.0 GB free"))
            }
            await ctx.http.serveFeed(ArchiveTests.feedURL, xml: Fixtures.feed(items: ArchiveTests.items), etag: "\"v1\"")
            try await ctx.app.testing().test(.POST, "api/shows", beforeRequest: { req in
                try req.content.encode(ShowAPIController.CreateShowRequest(sourceURL: ArchiveTests.feedURL, keepCount: 2))
            }) { _ async throws in }
            await ctx.app.jobQueue.waitUntilIdle()
            try await ctx.app.testing().test(.GET, "status/footer") { res async throws in
                #expect(res.body.string.contains("2 episode(s) waiting for the processing window (opens"))
            }
            ctx.world.freeBytes = 1
            try await ctx.app.testing().test(.POST, "api/shows/\(try #require(try await Show.query(on: ctx.app.db).first()?.id))/keep", beforeRequest: { req in
                try req.content.encode(ShowAPIController.KeepRequest(action: "keep", all: true))
            }) { _ async throws in }
            await ctx.app.jobQueue.waitUntilIdle()
            try await ctx.app.testing().test(.GET, "status/footer") { res async throws in
                #expect(res.body.string.contains("Paused by the disk guard"))
                #expect(res.body.string.contains("dot warn"))
            }
        }
    }
}
