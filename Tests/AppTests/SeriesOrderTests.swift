@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("Series order")
struct SeriesOrderTests {
    static let day: TimeInterval = 86400
    static let base = Date(timeIntervalSince1970: 1_790_000_000)

    func item(_ title: String, daysAgo: Double, episode: Int? = nil, season: Int? = nil) -> FeedItem {
        FeedItem(
            guid: title, title: title, pubDate: Self.base.addingTimeInterval(-daysAgo * Self.day),
            descriptionHTML: "<p>\(title) notes</p>", enclosureURL: URL(string: "https://x/\(title).mp3")!,
            length: 1, duration: 60, episodeNumber: episode, seasonNumber: season
        )
    }

    @Test func ordersBySeasonAndEpisodeAndRewritesDates() {
        let items = [
            item("s2e1", daysAgo: 1, episode: 1, season: 2),
            item("s1e2", daysAgo: 30, episode: 2, season: 1),
            item("s1e1", daysAgo: 40, episode: 1, season: 1),
        ]
        let ordered = FeedWriter.seriesOrdered(items)
        #expect(ordered.map(\.title) == ["s1e1", "s1e2", "s2e1"])
        // The first episode gets the newest date (the iPod lists newest on top), one minute apart.
        #expect(ordered[0].pubDate == Self.base.addingTimeInterval(-1 * Self.day))
        #expect(ordered[1].pubDate == ordered[0].pubDate.addingTimeInterval(-60))
        #expect(ordered[2].pubDate == ordered[0].pubDate.addingTimeInterval(-120))
        #expect(ordered[0].descriptionHTML?.hasPrefix("<p>Originally published ") == true)
        #expect(ordered[0].descriptionHTML?.hasSuffix("<p>s1e1 notes</p>") == true)
    }

    @Test func specialsWithoutSeasonUseTheContinuousNumbering() {
        // Like Total Party Kill: #100 has no season, the others do, numbers are unique across the show.
        let ordered = FeedWriter.seriesOrdered([
            item("101", daysAgo: 10, episode: 101, season: 3),
            item("100", daysAgo: 11, episode: 100),
            item("99", daysAgo: 12, episode: 99, season: 3),
            item("1", daysAgo: 400, episode: 1, season: 1),
        ])
        #expect(ordered.map(\.title) == ["1", "99", "100", "101"])
    }

    @Test func restartingNumbersUseTheSeason() {
        let ordered = FeedWriter.seriesOrdered([
            item("s2e1", daysAgo: 1, episode: 1, season: 2),
            item("s1e3", daysAgo: 5, episode: 3, season: 1),
            item("s1e1", daysAgo: 9, episode: 1, season: 1),
        ])
        #expect(ordered.map(\.title) == ["s1e1", "s1e3", "s2e1"])
    }

    @Test func duplicateNumbersWithoutSeasonsFallBackToDate() {
        let ordered = FeedWriter.seriesOrdered([
            item("b", daysAgo: 1, episode: 1), item("a", daysAgo: 5, episode: 1), item("c", daysAgo: 3, episode: 2),
        ])
        #expect(ordered.map(\.title) == ["a", "c", "b"])
    }

    @Test func fallsBackToDateWithoutNumbers() {
        let ordered = FeedWriter.seriesOrdered([
            item("new", daysAgo: 1), item("old", daysAgo: 9, episode: 7), item("mid", daysAgo: 5),
        ])
        #expect(ordered.map(\.title) == ["old", "mid", "new"])
    }

    @Test func datesAreStableAcrossRenders() {
        let items = [item("a", daysAgo: 3, episode: 1), item("b", daysAgo: 2, episode: 2)]
        #expect(FeedWriter.seriesOrdered(items).map(\.pubDate) == FeedWriter.seriesOrdered(items).map(\.pubDate))
    }

    @Test func settingSwitchesTheFeedToSeriesOrder() async throws {
        try await withTestContext { ctx in
            await ctx.http.serveFeed(ArchiveTests.feedURL, xml: Fixtures.feed(items: ArchiveTests.items, numbers: ArchiveTests.numbers), etag: "\"v1\"")
            var showID: UUID?
            try await ctx.app.testing().test(.POST, "api/shows", beforeRequest: { req in
                try req.content.encode(ShowAPIController.CreateShowRequest(sourceURL: ArchiveTests.feedURL, keepCount: 3))
            }) { res async throws in
                showID = try res.content.decode(ShowAPIController.ShowDetailDTO.self).show.id
            }
            let id = try #require(showID)
            await ctx.app.jobQueue.waitUntilIdle()

            func feedOrder() async throws -> (type: String, titles: [String], dates: [Date], xml: String) {
                var result: (String, [String], [Date], String) = ("", [], [], "")
                try await ctx.app.testing().test(.GET, "feeds/test-show.xml") { res async throws in
                    let xml = res.body.string
                    let type = xml.components(separatedBy: "<itunes:type>").dropFirst().first?.components(separatedBy: "<").first ?? ""
                    let items = xml.components(separatedBy: "<item>").dropFirst()
                    let titles = items.compactMap { $0.components(separatedBy: "<title>").dropFirst().first?.components(separatedBy: "</title>").first }
                    let dates = items.compactMap { $0.components(separatedBy: "<pubDate>").dropFirst().first?.components(separatedBy: "</pubDate>").first }
                        .compactMap(FeedParser.parseDate)
                    result = (type, titles, dates, xml)
                }
                return result
            }

            var feed = try await feedOrder()
            #expect(feed.type == "episodic")
            #expect(feed.titles == ["Episode ep5", "Episode ep4", "Episode ep3"], "newest first")

            try await ctx.app.testing().test(.POST, "shows/\(id)", beforeRequest: { req in
                req.headers.contentType = .urlEncodedForm
                req.body = .init(string: "speed=1.00&mode=newest&keepCount=3&order=series&enabled=on")
            }) { res async throws in
                #expect(res.status == .seeOther)
            }
            #expect(try await Show.find(id, on: ctx.app.db)?.seriesOrder == true)

            feed = try await feedOrder()
            #expect(feed.type == "serial")
            #expect(feed.titles == ["Episode ep3", "Episode ep4", "Episode ep5"], "oldest first")
            #expect(feed.dates == feed.dates.sorted(by: >), "first episode has the newest date")
            #expect(feed.xml.contains("<itunes:episode>302</itunes:episode>"))
            #expect(feed.xml.contains("<itunes:season>1</itunes:season>"))
            #expect(feed.xml.contains("Originally published"))

            try await ctx.app.testing().test(.GET, "/") { res async throws in
                #expect(res.body.string.contains(">Oldest first<"))
            }
        }
    }

    @Test func listsFollowTheOrderSetting() async throws {
        try await withTestContext { ctx in
            await ctx.http.serveFeed(ArchiveTests.feedURL, xml: Fixtures.feed(items: ArchiveTests.items, numbers: ArchiveTests.numbers), etag: "\"v1\"")
            var showID: UUID?
            try await ctx.app.testing().test(.POST, "api/shows", beforeRequest: { req in
                try req.content.encode(ShowAPIController.CreateShowRequest(sourceURL: ArchiveTests.feedURL, keepCount: 3))
            }) { res async throws in
                showID = try res.content.decode(ShowAPIController.ShowDetailDTO.self).show.id
            }
            let id = try #require(showID)
            await ctx.app.jobQueue.waitUntilIdle()

            /// Episode titles in page order, from the given part of the HTML.
            func titles(_ html: Substring) -> [String] {
                html.components(separatedBy: "<div class=\"ep-title\">").dropFirst()
                    .compactMap { $0.components(separatedBy: "</div>").first }
            }
            func set(_ body: String) async throws {
                try await ctx.app.testing().test(.POST, "shows/\(id)", beforeRequest: { req in
                    req.headers.contentType = .urlEncodedForm
                    req.body = .init(string: "speed=1.00&enabled=on&" + body)
                }) { res async throws in
                    #expect(res.status == .seeOther)
                }
            }
            func page() async throws -> String {
                var html = ""
                try await ctx.app.testing().test(.GET, "shows/\(id)") { res async throws in html = res.body.string }
                return html
            }
            func partial() async throws -> String {
                var html = ""
                try await ctx.app.testing().test(.GET, "shows/\(id)/episodes") { res async throws in html = res.body.string }
                return html
            }

            // Newest first (default).
            #expect(titles(Substring(try await page())) == ["Episode ep5", "Episode ep4", "Episode ep3"])

            // Oldest first: page and live refresh both in series order.
            try await set("mode=newest&keepCount=3&order=series")
            #expect(titles(Substring(try await page())) == ["Episode ep3", "Episode ep4", "Episode ep5"])
            #expect(titles(Substring(try await partial())) == ["Episode ep3", "Episode ep4", "Episode ep5"])

            // Manual selection: the chooser lists the whole feed in series order too.
            try await set("mode=manual&keepCount=3&order=series")
            let html = try await page()
            let chooser = html[html.range(of: "id=\"choose\"")!.upperBound...]
            #expect(titles(chooser) == ["Episode ep1", "Episode ep2", "Episode ep3", "Episode ep4", "Episode ep5"])

            // And back to newest first.
            try await set("mode=manual&keepCount=3&order=newest")
            let newest = try await page()
            #expect(titles(newest[newest.range(of: "id=\"choose\"")!.upperBound...]).first == "Episode ep5")
        }
    }
}
