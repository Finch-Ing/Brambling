@testable import App
import Fluent
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import Testing
import VaporTesting

@Suite("Feed and media routes")
struct FeedAndMediaTests {
    static let feedURL = "https://feeds.example.com/rss?token=SECRET"

    /// Adds a show with two episodes and runs the (stubbed) queue until both are ready.
    @discardableResult
    private func readyShow(_ ctx: TestContext) async throws -> UUID {
        await ctx.http.serveFeed(Self.feedURL, xml: Fixtures.feed(items: [
            ("a", "Mon, 01 Jan 2024 10:00:00 GMT"),
            ("b", "Tue, 02 Jan 2024 10:00:00 GMT"),
        ]), etag: "\"v1\"")
        var id: UUID?
        try await ctx.app.testing().test(.POST, "api/shows", beforeRequest: { req in
            try req.content.encode(["sourceURL": Self.feedURL])
        }) { res async throws in
            id = try res.content.decode(ShowAPIController.ShowDetailDTO.self).show.id
        }
        await ctx.app.jobQueue.waitUntilIdle()
        return try #require(id)
    }

    private func fileName(_ ctx: TestContext, _ guid: String) async throws -> String {
        let episode = try #require(try await Episode.query(on: ctx.app.db).filter(\.$sourceGUID == guid).first())
        return try #require(episode.fileName)
    }

    @Test func feedListsReadyEpisodesWithAbsoluteURLs() async throws {
        try await withTestContext { ctx in
            try await readyShow(ctx)
            let fileB = try await fileName(ctx, "b")

            try await ctx.app.testing().test(.GET, "feeds/test-show.xml") { res async throws in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .contentType) == "application/rss+xml; charset=utf-8")
                #expect(res.headers.first(name: .eTag) != nil)
                #expect(res.headers.first(name: .lastModified) != nil)
                let xml = res.body.string
                #expect(xml.contains("<title>Test Show</title>"))
                #expect(xml.contains("<itunes:image href=\"https://brambling.example/art/test-show.jpg\"/>"))
                #expect(xml.contains("<enclosure url=\"https://brambling.example/media/test-show/\(fileB)\" length=\"4096\" type=\"audio/mpeg\"/>"))
                #expect(xml.contains("<itunes:duration>00:01:01</itunes:duration>"))
                #expect(xml.components(separatedBy: "<item>").count == 3)
                #expect(!xml.contains("SECRET") && !xml.contains("s3cr3t") && !xml.contains("cdn.example.com"))
                #expect(XMLParser(data: Data(xml.utf8)).parse(), "well-formed")
            }
        }
    }

    @Test func feedOnlyContainsReadyEpisodes() async throws {
        try await withTestContext { ctx in
            try await readyShow(ctx)
            let a = try #require(try await Episode.query(on: ctx.app.db).filter(\.$sourceGUID == "a").first())
            a.status = .pending
            try await a.save(on: ctx.app.db)
            try await ctx.app.testing().test(.GET, "feeds/test-show.xml") { res async throws in
                #expect(res.body.string.components(separatedBy: "<item>").count == 2)
                #expect(!res.body.string.contains("Episode a"))
            }
        }
    }

    @Test func feedSupportsConditionalRequests() async throws {
        try await withTestContext { ctx in
            let showID = try await readyShow(ctx)
            var etag = ""
            var lastModified = ""
            try await ctx.app.testing().test(.GET, "feeds/test-show.xml") { res async throws in
                etag = res.headers.first(name: .eTag) ?? ""
                lastModified = res.headers.first(name: .lastModified) ?? ""
            }

            try await ctx.app.testing().test(.GET, "feeds/test-show.xml", headers: ["If-None-Match": etag]) { res async throws in
                #expect(res.status == .notModified)
                #expect(res.body.readableBytes == 0)
            }
            try await ctx.app.testing().test(.GET, "feeds/test-show.xml", headers: ["If-Modified-Since": lastModified]) { res async throws in
                #expect(res.status == .notModified)
            }

            // Changing something visible in the feed changes the ETag.
            try await ctx.app.testing().test(.PATCH, "api/shows/\(showID)", beforeRequest: { req in
                try req.content.encode(["titleOverride": "Renamed"])
            }) { _ async throws in }
            try await ctx.app.testing().test(.GET, "feeds/test-show.xml", headers: ["If-None-Match": etag]) { res async throws in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .eTag) != etag)
                #expect(res.body.string.contains("<title>Renamed</title>"))
            }
        }
    }

    @Test func mediaSupportsRangeRequests() async throws {
        try await withTestContext { ctx in
            try await readyShow(ctx)
            let file = try await fileName(ctx, "a")

            try await ctx.app.testing().test(.GET, "media/test-show/\(file)") { res async throws in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .contentType) == "audio/mpeg")
                #expect(res.body.readableBytes == 4096)
                #expect(res.headers.first(name: .acceptRanges) == "bytes")
            }
            try await ctx.app.testing().test(.GET, "media/test-show/\(file)", headers: ["Range": "bytes=0-99"]) { res async throws in
                #expect(res.status == .partialContent)
                #expect(res.headers.first(name: .contentRange) == "bytes 0-99/4096")
                #expect(res.body.readableBytes == 100)
            }
            try await ctx.app.testing().test(.GET, "media/test-show/\(file)", headers: ["Range": "bytes=4000-"]) { res async throws in
                #expect(res.status == .partialContent)
                #expect(res.body.readableBytes == 96)
            }
            try await ctx.app.testing().test(.HEAD, "media/test-show/\(file)") { res async throws in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .contentLength) == "4096")
            }
        }
    }

    @Test func artworkIsServed() async throws {
        try await withTestContext { ctx in
            try await readyShow(ctx)
            try await ctx.app.testing().test(.GET, "art/test-show.jpg") { res async throws in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .contentType) == "image/jpeg")
            }
        }
    }

    @Test func onlyKnownFilesAreServed() async throws {
        try await withTestContext { ctx in
            try await readyShow(ctx)
            let file = try await fileName(ctx, "a")
            // A file that exists on disk but has no DB record.
            let stray = ctx.config.mediaDirectory.appendingPathComponent("test-show/0000-abcd.mp3")
            try Data("x".utf8).write(to: stray)

            for path in [
                "media/test-show/0000-abcd.mp3",
                "media/test-show/..%2F..%2Fbrambling.sqlite",
                "media/test-show/../../brambling.sqlite",
                "media/other-show/\(file)",
                "media/Test-Show/\(file)",
                "art/other-show.jpg",
                "art/..%2Fbrambling.sqlite",
                "feeds/other-show.xml",
                "feeds/test-show.rss",
            ] {
                try await ctx.app.testing().test(.GET, path) { res async throws in
                    // ".." paths are already refused (403) by Vapor's FileMiddleware before routing.
                    #expect(res.status == .notFound || res.status == .forbidden, "\(path)")
                    #expect(res.body.readableBytes < 200, "nothing served for \(path)")
                }
            }
        }
    }

    @Test func mediaFileNameRule() {
        #expect(MediaController.isMediaFileName("3a7e8a6a-9ae2-4870-9eef-717901ad2e3a-1a2b3c4d.mp3"))
        #expect(!MediaController.isMediaFileName("../x.mp3"))
        #expect(!MediaController.isMediaFileName("ABC.mp3"))
        #expect(!MediaController.isMediaFileName("abc.m4a"))
    }
}

@Suite("Feed base URL")
struct FeedBaseURLTests {
    @Test func linksFollowTheClientsSchemeAndHost() async throws {
        try await withTestContext { ctx in
            await ctx.http.serveFeed("https://feeds.example.com/rss", xml: Fixtures.feed(items: [("a", "Mon, 01 Jan 2024 10:00:00 GMT")]), etag: "\"v1\"")
            try await ctx.app.testing().test(.POST, "api/shows", beforeRequest: { req in
                try req.content.encode(["sourceURL": "https://feeds.example.com/rss"])
            }) { _ async throws in }
            await ctx.app.jobQueue.waitUntilIdle()

            let cases: [(HTTPHeaders, String)] = [
                (["Host": "brambling.example", "X-Forwarded-Proto": "https"], "https://brambling.example/media/"),
                (["Host": "brambling.example", "X-Forwarded-Proto": "http"], "http://brambling.example/media/"),
                (["Host": "192.0.2.10", "X-Forwarded-Proto": "http"], "http://192.0.2.10/media/"),
                (["Host": "brambling.example:443", "X-Forwarded-Proto": "https"], "https://brambling.example/media/"),
                (["Host": "127.0.0.1:8080"], "http://127.0.0.1:8080/media/"),
                (["Host": "evil.com/x@y"], "https://brambling.example/media/"),  // implausible → configured URL
                ([:], "https://brambling.example/media/"),
            ]
            for (headers, expected) in cases {
                try await ctx.app.testing().test(.GET, "feeds/test-show.xml", headers: headers) { res async throws in
                    #expect(res.body.string.contains("<enclosure url=\"\(expected)"), "\(headers)")
                }
            }
        }
    }
}
