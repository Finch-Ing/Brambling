@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

/// Forms exactly as a browser submits them: field names percent-encoded (`episodes%5B%5D`).
@Suite("Browser form encoding")
struct BrowserFormTests {
    @Test func checkboxSelectionWithEncodedBrackets() async throws {
        try await withTestContext { ctx in
            await ctx.http.serveFeed(ArchiveTests.feedURL, xml: Fixtures.feed(items: ArchiveTests.items, numbers: ArchiveTests.numbers), etag: "\"v1\"")
            var showID: UUID?
            try await ctx.app.testing().test(.POST, "api/shows", beforeRequest: { req in
                try req.content.encode(ShowAPIController.CreateShowRequest(sourceURL: ArchiveTests.feedURL, keepCount: 2))
            }) { res async throws in
                showID = try res.content.decode(ShowAPIController.ShowDetailDTO.self).show.id
            }
            let id = try #require(showID)
            await ctx.app.jobQueue.waitUntilIdle()
            let ep5 = try #require(try await Episode.query(on: ctx.app.db).filter(\.$sourceGUID == "ep5").first()?.id)

            // Switch to manual via the settings form, as the browser sends it.
            try await ctx.app.testing().test(.POST, "shows/\(id)", beforeRequest: { req in
                req.headers.contentType = .urlEncodedForm
                req.body = .init(string: "titleOverride=&speed=1.00&smartSpeed=on&voiceBoost=on&mode=manual&keepCount=2&enabled=on")
            }) { res async throws in
                #expect(res.status == .seeOther)
            }

            // Deselect a carried-over episode: brackets percent-encoded like every browser does.
            try await ctx.app.testing().test(.POST, "shows/\(id)/archive", beforeRequest: { req in
                req.headers.contentType = .urlEncodedForm
                req.body = .init(string: "action=unkeep&episodes%5B%5D=\(ep5)")
            }) { res async throws in
                #expect(res.status == .seeOther, "\(res.body.string.contains("No episodes selected") ? "server saw no episodes" : "")")
            }
            #expect(try await Episode.find(ep5, on: ctx.app.db)?.status == .available)
        }
    }

    @Test func checkboxesShowTheSelectionAndSaveSetsItExactly() async throws {
        try await withTestContext { ctx in
            await ctx.http.serveFeed(ArchiveTests.feedURL, xml: Fixtures.feed(items: ArchiveTests.items, numbers: ArchiveTests.numbers), etag: "\"v1\"")
            var showID: UUID?
            try await ctx.app.testing().test(.POST, "api/shows", beforeRequest: { req in
                try req.content.encode(ShowAPIController.CreateShowRequest(sourceURL: ArchiveTests.feedURL, keepCount: 2))
            }) { res async throws in
                showID = try res.content.decode(ShowAPIController.ShowDetailDTO.self).show.id
            }
            let id = try #require(showID)
            await ctx.app.jobQueue.waitUntilIdle()
            func episodeID(_ guid: String) async throws -> UUID {
                try #require(try await Episode.query(on: ctx.app.db).filter(\.$sourceGUID == guid).first()?.id)
            }
            let ep1 = try await episodeID("ep1"), ep4 = try await episodeID("ep4"), ep5 = try await episodeID("ep5")

            // Switching to manual: the two downloaded episodes appear checked.
            try await ctx.app.testing().test(.POST, "shows/\(id)", beforeRequest: { req in
                req.headers.contentType = .urlEncodedForm
                req.body = .init(string: "speed=1.00&mode=manual&keepCount=2&enabled=on")
            }) { _ async throws in }
            try await ctx.app.testing().test(.GET, "shows/\(id)") { res async throws in
                let html = res.body.string
                #expect(html.contains("value=\"\(ep5)\" class=\"pick\" checked data-was-selected=\"1\" data-downloaded=\"1\""))
                #expect(html.contains("value=\"\(ep4)\" class=\"pick\" checked"))
                #expect(html.contains("value=\"\(ep1)\" class=\"pick\"  >") || html.contains("value=\"\(ep1)\" class=\"pick\" >"), "unselected → unchecked")
                #expect(html.contains("2 selected"))
            }

            // Save: ep5 stays, ep4 unchecked (downloaded → deleted), ep1 newly checked.
            try await ctx.app.testing().test(.POST, "shows/\(id)/archive", beforeRequest: { req in
                req.headers.contentType = .urlEncodedForm
                req.body = .init(string: "action=save&episodes%5B%5D=\(ep5)&episodes%5B%5D=\(ep1)")
            }) { res async throws in
                #expect(res.status == .seeOther)
                #expect(res.headers.first(name: .location) == "/shows/\(id)?notice=selection-saved#choose")
            }
            await ctx.app.jobQueue.waitUntilIdle()
            let statuses = Dictionary(uniqueKeysWithValues: try await Episode.query(on: ctx.app.db).all().map { ($0.sourceGUID, $0.status) })
            #expect(statuses == ["ep1": .ready, "ep2": .available, "ep3": .available, "ep4": .available, "ep5": .ready])

            // Saving with nothing checked deselects everything.
            try await ctx.app.testing().test(.POST, "shows/\(id)/archive", beforeRequest: { req in
                req.headers.contentType = .urlEncodedForm
                req.body = .init(string: "action=save")
            }) { res async throws in
                #expect(res.status == .seeOther)
            }
            #expect(try await Episode.query(on: ctx.app.db).filter(\.$status != .available).count() == 0)
        }
    }

    @Test func largeSelectionFitsTheBodyLimit() async throws {
        try await withTestContext { ctx in
            await ctx.http.serveFeed(ArchiveTests.feedURL, xml: Fixtures.feed(items: ArchiveTests.items), etag: "\"v1\"")
            var showID: UUID?
            try await ctx.app.testing().test(.POST, "api/shows", beforeRequest: { req in
                try req.content.encode(ShowAPIController.CreateShowRequest(sourceURL: ArchiveTests.feedURL, keepCount: 0))
            }) { res async throws in
                showID = try res.content.decode(ShowAPIController.ShowDetailDTO.self).show.id
            }
            let id = try #require(showID)
            // 600 IDs ≈ 26 KB, like "check all" on a 600-episode show; unknown IDs are simply ignored.
            let body = "action=save" + (0..<600).map { _ in "&episodes%5B%5D=\(UUID())" }.joined()
            #expect(body.utf8.count > 16 * 1024)
            try await ctx.app.testing().test(.POST, "shows/\(id)/archive", beforeRequest: { req in
                req.headers.contentType = .urlEncodedForm
                req.body = .init(string: body)
            }) { res async throws in
                #expect(res.status == .seeOther, "status \(res.status)")
            }
        }
    }

    @Test func listsShowSubtitleAndDescriptionExcerpt() async throws {
        try await withTestContext { ctx in
            await ctx.http.serveFeed(ArchiveTests.feedURL, xml: Fixtures.feed(items: ArchiveTests.items), etag: "\"v1\"")
            var showID: UUID?
            try await ctx.app.testing().test(.POST, "api/shows", beforeRequest: { req in
                try req.content.encode(ShowAPIController.CreateShowRequest(sourceURL: ArchiveTests.feedURL, keepCount: 2))
            }) { res async throws in
                showID = try res.content.decode(ShowAPIController.ShowDetailDTO.self).show.id
            }
            let id = try #require(showID)
            let ep5 = try #require(try await Episode.query(on: ctx.app.db).filter(\.$sourceGUID == "ep5").first())
            ep5.subtitle = "Bonus: <the> live show"
            ep5.descriptionHTML = "<p>The party enters the <b>Abyss</b> &amp; meets Kevin&#8217;s cousin.</p>"
            try await ep5.save(on: ctx.app.db)
            let ep4 = try #require(try await Episode.query(on: ctx.app.db).filter(\.$sourceGUID == "ep4").first())
            ep4.subtitle = "The party enters the Abyss."   // repeats the description's start → not shown
            ep4.descriptionHTML = "<p>The party enters the Abyss. More text follows.</p>"
            try await ep4.save(on: ctx.app.db)

            for mode in ["newest", "manual"] {
                try await ctx.app.testing().test(.POST, "shows/\(id)", beforeRequest: { req in
                    req.headers.contentType = .urlEncodedForm
                    req.body = .init(string: "speed=1.00&mode=\(mode)&keepCount=2&enabled=on")
                }) { _ async throws in }
                try await ctx.app.testing().test(.GET, "shows/\(id)") { res async throws in
                    let html = res.body.string
                    #expect(html.contains("<div class=\"ep-sub\">Bonus: &lt;the&gt; live show</div>"), "\(mode): subtitle, escaped")
                    #expect(html.contains("<div class=\"ep-desc\">The party enters the Abyss &amp; meets Kevin’s cousin.</div>"), "\(mode): excerpt as plain text")
                    #expect(!html.contains("<div class=\"ep-sub\">The party enters the Abyss.</div>"), "\(mode): repeated subtitle hidden")
                    #expect(!html.contains("&lt;b&gt;"), "no HTML tags in the excerpt")
                }
            }
        }
    }
}
