@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("Web UI")
struct WebUITests {
    static let feedURL = "https://feeds.example.com/private/rss?token=SUPERSECRET123"

    private func serve(_ ctx: TestContext, title: String = "Test Show") async {
        await ctx.http.serveFeed(Self.feedURL, xml: Fixtures.feed(title: title, items: [
            ("a", "Mon, 01 Jan 2024 10:00:00 GMT"),
            ("b", "Tue, 02 Jan 2024 10:00:00 GMT"),
        ]), etag: "\"v1\"")
    }

    /// Preview, then confirm. Returns the redirect location.
    private func addViaUI(_ ctx: TestContext, extra: String = "&smartSpeed=on&voiceBoost=on") async throws -> String {
        var previewID = ""
        try await ctx.app.testing().test(.POST, "shows/preview", beforeRequest: { req in
            try req.content.encode(["sourceURL": Self.feedURL], as: .urlEncodedForm)
        }) { res async throws in
            #expect(res.status == .ok)
            let html = res.body.string
            #expect(!html.contains("SUPERSECRET123"), "token never in the page")
            #expect(html.contains("token=••••"))
            #expect(html.contains("<div class=\"title\">"))
            let match = try #require(html.range(of: #"name="previewID" value="[0-9a-f-]+""#, options: .regularExpression))
            previewID = String(html[match].split(separator: "\"")[3])
        }
        var location = ""
        try await ctx.app.testing().test(.POST, "shows", beforeRequest: { req in
            req.headers.contentType = .urlEncodedForm
            req.body = .init(string: "previewID=\(previewID)&slug=my-show&speed=1.5&keepCount=5\(extra)")
        }) { res async throws in
            #expect(res.status == .seeOther, "\(res.body.string)")
            location = res.headers.first(name: .location) ?? ""
        }
        return location
    }

    @Test func emptyIndex() async throws {
        try await withTestContext { ctx in
            try await ctx.app.testing().test(.GET, "/") { res async throws in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("No shows yet."))
            }
        }
    }

    @Test func addShowThroughPreviewAndConfirm() async throws {
        try await withTestContext { ctx in
            await serve(ctx)
            let location = try await addViaUI(ctx)
            #expect(location.hasSuffix("?notice=added"))

            let show = try #require(try await Show.query(on: ctx.app.db).first())
            #expect(show.slug == "my-show")
            #expect(show.speed == 1.5)
            #expect(show.keepCount == 5)
            #expect(show.smartSpeed && show.voiceBoost)
            #expect(show.sourceURL == Self.feedURL)

            try await ctx.app.testing().test(.GET, String(location.dropFirst())) { res async throws in
                let html = res.body.string
                #expect(res.status == .ok)
                #expect(html.contains("Show added."))
                #expect(html.contains("https://brambling.example/feeds/my-show.xml"))
                #expect(html.contains("Episode b"))
                #expect(!html.contains("SUPERSECRET123"))
                #expect(html.contains("hx-get=\"/shows/\(try show.requireID())/episodes\""))
            }
            try await ctx.app.testing().test(.GET, "/") { res async throws in
                #expect(res.body.string.contains("1.50×"))
                #expect(res.body.string.contains("2 in progress"))
            }
        }
    }

    @Test func uncheckedCheckboxesMeanOff() async throws {
        try await withTestContext { ctx in
            await serve(ctx)
            _ = try await addViaUI(ctx, extra: "")
            let show = try #require(try await Show.query(on: ctx.app.db).first())
            #expect(!show.smartSpeed && !show.voiceBoost)

            try await ctx.app.testing().test(.POST, "shows/\(try show.requireID())", beforeRequest: { req in
                req.headers.contentType = .urlEncodedForm
                req.body = .init(string: "titleOverride=Renamed&speed=2&voiceBoost=on&keepCount=3")
            }) { res async throws in
                #expect(res.status == .seeOther)
                #expect(res.headers.first(name: .location)?.hasSuffix("notice=saved") == true)
            }
            try await show.$episodes.load(on: ctx.app.db)
            let updated = try #require(try await Show.find(show.id, on: ctx.app.db))
            #expect(updated.titleOverride == "Renamed")
            #expect(updated.speed == 2)
            #expect(updated.voiceBoost && !updated.smartSpeed)
            #expect(updated.keepCount == 3)
            #expect(!updated.enabled, "unchecked enabled = paused")
        }
    }

    @Test func invalidInputIsShownOnThePage() async throws {
        try await withTestContext { ctx in
            await serve(ctx)
            _ = try await addViaUI(ctx)
            let show = try #require(try await Show.query(on: ctx.app.db).first())
            try await ctx.app.testing().test(.POST, "shows/\(try show.requireID())", beforeRequest: { req in
                req.headers.contentType = .urlEncodedForm
                req.body = .init(string: "keepCount=500&enabled=on")
            }) { res async throws in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains("between 0 and 200"))
            }

            try await ctx.app.testing().test(.POST, "shows/preview", beforeRequest: { req in
                try req.content.encode(["sourceURL": "not a url"], as: .urlEncodedForm)
            }) { res async throws in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains("full http(s) feed URL"))
            }
        }
    }

    @Test func expiredOrUnknownPreviewIsRejected() async throws {
        try await withTestContext { ctx in
            try await ctx.app.testing().test(.POST, "shows", beforeRequest: { req in
                req.headers.contentType = .urlEncodedForm
                req.body = .init(string: "previewID=does-not-exist&slug=x")
            }) { res async throws in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains("preview expired"))
            }
        }
    }

    @Test func htmlIsEscaped() async throws {
        try await withTestContext { ctx in
            await serve(ctx, title: "<script>alert(1)</script> & Co")
            _ = try await addViaUI(ctx)
            try await ctx.app.testing().test(.GET, "/") { res async throws in
                let html = res.body.string
                #expect(!html.contains("<script>alert(1)</script>"))
                #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt; &amp; Co"))
            }
        }
    }

    @Test func episodesPartialAndRetry() async throws {
        try await withTestContext { ctx in
            await ctx.downloader.fail(JobQueueTests.enclosure("a"), times: 10)
            await serve(ctx)
            _ = try await addViaUI(ctx)
            for _ in 0..<3 {
                await ctx.app.jobQueue.waitUntilIdle()
                ctx.world.advance(3 * 3600)
            }
            await ctx.app.jobQueue.waitUntilIdle()
            let show = try #require(try await Show.query(on: ctx.app.db).first())
            let a = try #require(try await Episode.query(on: ctx.app.db).filter(\.$sourceGUID == "a").first())
            #expect(a.status == .failed)

            try await ctx.app.testing().test(.GET, "shows/\(try show.requireID())/episodes") { res async throws in
                let html = res.body.string
                #expect(html.hasPrefix("<div id=\"episodes\""), "partial without layout")
                #expect(html.contains("failed"))
                #expect(html.contains("/episodes/\(try a.requireID())/retry"))
                #expect(!html.contains("<html"))
            }
            try await ctx.app.testing().test(.POST, "episodes/\(try a.requireID())/retry") { res async throws in
                #expect(res.status == .seeOther)
            }
            #expect(try await Episode.find(a.id, on: ctx.app.db)?.status == .pending)
        }
    }

    @Test func settingsPageAndProcessNow() async throws {
        try await withTestContext(configure: { $0.processWindow = try ProcessingWindow(parsing: "01:00-06:00") }) { ctx in
            await serve(ctx)
            _ = try await addViaUI(ctx)
            await ctx.app.jobQueue.waitUntilIdle()
            try await ctx.app.testing().test(.GET, "settings") { res async throws in
                let html = res.body.string
                #expect(html.contains("01:00–06:00"))
                #expect(html.contains("Closed. Next run starts 22 Oct, 01:00."))
                #expect(html.contains("Wed 21 Oct, 12:00"), "server's local time")
                #expect(html.contains("Europe/Berlin"))
                #expect(html.contains("value=\"01:00\"") && html.contains("value=\"06:00\""))
                #expect(html.contains("Process now"))
                #expect(html.contains("Disk usage per show"))
            }
            try await ctx.app.testing().test(.POST, "queue/process-now") { res async throws in
                #expect(res.status == .seeOther)
            }
            await ctx.app.jobQueue.waitUntilIdle()
            #expect(try await Episode.query(on: ctx.app.db).filter(\.$status == .ready).count() == 2)
        }
    }

    @Test func processingWindowCanBeChangedInSettings() async throws {
        try await withTestContext { ctx in
            await serve(ctx)
            _ = try await addViaUI(ctx)
            try await ctx.app.testing().test(.GET, "settings") { res async throws in
                let html = res.body.string
                #expect(html.contains("any time · Episodes are processed right after downloading."))
                #expect(html.contains("value=\"01:00\""), "night window suggested")
            }

            // 12:00 in Berlin: a night window keeps the downloaded episodes waiting.
            try await ctx.app.testing().test(.POST, "settings/window", beforeRequest: { req in
                try req.content.encode(["mode": "window", "start": "23:30", "end": "06:00"], as: .urlEncodedForm)
            }) { res async throws in
                #expect(res.headers.first(name: .location) == "/settings?notice=window-saved")
            }
            #expect(ctx.app.appConfig.processWindow == ProcessingWindow(start: 23 * 60 + 30, end: 6 * 60))
            #expect(try await AppSetting.value(AppSetting.processWindowKey, on: ctx.app.db) == "23:30-06:00")
            await ctx.app.jobQueue.waitUntilIdle()
            #expect(try await Episode.query(on: ctx.app.db).filter(\.$status == .ready).count() == 0)
            try await ctx.app.testing().test(.GET, "settings?notice=window-saved") { res async throws in
                let html = res.body.string
                #expect(html.contains("Processing time saved."))
                #expect(html.contains("23:30–06:00 · Closed. Next run starts 21 Oct, 23:30."))
            }

            // Back to any time: they're processed right away.
            try await ctx.app.testing().test(.POST, "settings/window", beforeRequest: { req in
                try req.content.encode(["mode": "any"], as: .urlEncodedForm)
            }) { res async throws in
                #expect(res.status == .seeOther)
            }
            #expect(ctx.app.appConfig.processWindow == nil)
            #expect(try await AppSetting.value(AppSetting.processWindowKey, on: ctx.app.db) == "")
            await ctx.app.jobQueue.waitUntilIdle()
            #expect(try await Episode.query(on: ctx.app.db).filter(\.$status == .ready).count() == 2)
        }
    }

    @Test func invalidProcessingWindowIsRejected() async throws {
        try await withTestContext(configure: { $0.processWindow = try ProcessingWindow(parsing: "01:00-06:00") }) { ctx in
            for times in [("05:00", "05:00"), ("25:00", "06:00"), ("", "06:00")] {
                try await ctx.app.testing().test(.POST, "settings/window", beforeRequest: { req in
                    try req.content.encode(["mode": "window", "start": times.0, "end": times.1], as: .urlEncodedForm)
                }) { res async throws in
                    #expect(res.status == .unprocessableEntity)
                    #expect(res.body.string.contains("Please enter a start and an end time that differ"))
                }
            }
            #expect(ctx.app.appConfig.processWindow == ProcessingWindow(start: 60, end: 360), "unchanged")
            #expect(try await AppSetting.value(AppSetting.processWindowKey, on: ctx.app.db) == nil)
        }
    }

    @Test func deleteRedirectsToIndex() async throws {
        try await withTestContext { ctx in
            await serve(ctx)
            _ = try await addViaUI(ctx)
            let show = try #require(try await Show.query(on: ctx.app.db).first())
            try await ctx.app.testing().test(.POST, "shows/\(try show.requireID())/delete") { res async throws in
                #expect(res.status == .seeOther)
                #expect(res.headers.first(name: .location) == "/?notice=deleted")
            }
            #expect(try await Show.query(on: ctx.app.db).count() == 0)
        }
    }

    @Test func diskBlockedBannerOnEveryPage() async throws {
        try await withTestContext { ctx in
            ctx.world.freeBytes = 1
            await serve(ctx)
            _ = try await addViaUI(ctx)
            await ctx.app.jobQueue.waitUntilIdle()
            for path in ["/", "settings", "shows/new"] {
                try await ctx.app.testing().test(.GET, path) { res async throws in
                    #expect(res.body.string.contains("Disk guard: downloads and processing are paused"), "\(path)")
                }
            }
        }
    }

    @Test func staticAssetsAreServed() async throws {
        try await withTestContext { ctx in
            try await ctx.app.testing().test(.GET, "app.css") { res async throws in
                #expect(res.status == .ok)
            }
            try await ctx.app.testing().test(.GET, "htmx.min.js") { res async throws in
                #expect(res.status == .ok)
            }
        }
    }
}

@Suite("Middleware")
struct MiddlewareTests {
    @Test func basicAuthProtectsUIAndAPIButNotFeeds() async throws {
        try await withTestContext(configure: { $0.basicAuth = .init(user: "me", password: "pw") }) { ctx in
            for path in ["/", "settings", "api/shows"] {
                try await ctx.app.testing().test(.GET, path) { res async throws in
                    #expect(res.status == .unauthorized, "\(path)")
                    #expect(res.headers.first(name: .wwwAuthenticate)?.hasPrefix("Basic") == true)
                }
            }
            var good = HTTPHeaders()
            good.basicAuthorization = .init(username: "me", password: "pw")
            try await ctx.app.testing().test(.GET, "/", headers: good) { res async throws in
                #expect(res.status == .ok)
            }
            var bad = HTTPHeaders()
            bad.basicAuthorization = .init(username: "me", password: "nope")
            try await ctx.app.testing().test(.GET, "/", headers: bad) { res async throws in
                #expect(res.status == .unauthorized)
            }
            // Open routes.
            try await ctx.app.testing().test(.GET, "health") { res async throws in
                #expect(res.status == .ok)
            }
            try await ctx.app.testing().test(.GET, "feeds/none.xml") { res async throws in
                #expect(res.status == .notFound, "not 401")
            }
        }
    }

    @Test func constantTimeCompare() {
        #expect(BasicAuthMiddleware.constantTimeEquals("abc", "abc"))
        #expect(!BasicAuthMiddleware.constantTimeEquals("abc", "abd"))
        #expect(!BasicAuthMiddleware.constantTimeEquals("abc", "abcd"))
        #expect(!BasicAuthMiddleware.constantTimeEquals("", "a"))
    }

    @Test func crossSitePostsAreRejected() async throws {
        try await withTestContext { ctx in
            let cases: [(HTTPHeaders, HTTPStatus)] = [
                (["Origin": "https://evil.example", "Host": "brambling.example"], .forbidden),
                (["Sec-Fetch-Site": "cross-site", "Host": "brambling.example"], .forbidden),
                (["Sec-Fetch-Site": "same-site", "Host": "brambling.example"], .forbidden),
                (["Origin": "https://brambling.example", "Host": "brambling.example", "Sec-Fetch-Site": "same-origin"], .seeOther),
                (["Origin": "http://localhost:8080", "Host": "localhost:8080"], .seeOther),
                (["Origin": "https://brambling.example", "Host": "brambling.example:443"], .seeOther),
                ([:], .seeOther),  // curl / scripts
            ]
            for (headers, expected) in cases {
                try await ctx.app.testing().test(.POST, "queue/process-now", headers: headers) { res async throws in
                    #expect(res.status == expected, "\(headers)")
                }
            }
            // GETs are never blocked.
            try await ctx.app.testing().test(.GET, "/", headers: ["Origin": "https://evil.example", "Sec-Fetch-Site": "cross-site"]) { res async throws in
                #expect(res.status == .ok)
            }
        }
    }
}
