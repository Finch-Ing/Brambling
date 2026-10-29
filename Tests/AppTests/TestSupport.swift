@testable import App
import Foundation
import Testing
import Vapor
import VaporTesting

/// Serves canned responses per URL and records the requests it saw.
actor StubHTTP: HTTPFetching {
    struct Request: Sendable {
        var url: String
        var headers: HTTPHeaders
    }

    private var responses: [String: @Sendable (HTTPHeaders) -> HTTPFetchResponse] = [:]
    private(set) var requests: [Request] = []

    func set(_ url: String, _ respond: @escaping @Sendable (HTTPHeaders) -> HTTPFetchResponse) {
        responses[url] = respond
    }

    /// Serves `xml` with an ETag and answers 304 when the client sends it back.
    func serveFeed(_ url: String, xml: String, etag: String) {
        set(url) { headers in
            if headers.first(name: .ifNoneMatch) == etag {
                return HTTPFetchResponse(status: .notModified, headers: [:], body: Data())
            }
            return HTTPFetchResponse(status: .ok, headers: ["ETag": etag], body: Data(xml.utf8))
        }
    }

    nonisolated func get(_ url: String, headers: HTTPHeaders) async throws -> HTTPFetchResponse {
        try await respond(url, headers)
    }

    private func respond(_ url: String, _ headers: HTTPHeaders) throws -> HTTPFetchResponse {
        requests.append(Request(url: url, headers: headers))
        guard let respond = responses[url] else {
            return HTTPFetchResponse(status: .notFound, headers: [:], body: Data())
        }
        return respond(headers)
    }
}

/// Mutable clock and disk space for queue tests.
final class TestWorld: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = ISO8601DateFormatter().date(from: "2026-10-21T12:00:00+02:00")!
    private var _freeBytes: Int64 = 100 * 1_073_741_824

    var now: Date {
        get { lock.withLock { _now } }
        set { lock.withLock { _now = newValue } }
    }

    var freeBytes: Int64 {
        get { lock.withLock { _freeBytes } }
        set { lock.withLock { _freeBytes = newValue } }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { _now = _now.addingTimeInterval(seconds) }
    }

    static var berlin: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }
}

/// Writes fake audio; can be told to fail a number of times per URL.
actor StubDownloader: EpisodeDownloading {
    private var failures: [String: Int] = [:]
    private var outOfSpace = false
    private(set) var calls: [String] = []

    func fail(_ url: String, times: Int) { failures[url] = times }
    func failWithOutOfSpace(_ value: Bool) { outOfSpace = value }

    nonisolated func download(from url: String, to file: URL, timeout: Duration) async throws -> Int64 {
        try await perform(url, file)
    }

    private func perform(_ url: String, _ file: URL) throws -> Int64 {
        calls.append(url)
        if outOfSpace { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) }
        if let remaining = failures[url], remaining > 0 {
            failures[url] = remaining - 1
            throw DownloadError.httpStatus(503)
        }
        let data = Data(repeating: 0xFF, count: 4096)
        try data.write(to: file)
        return Int64(data.count)
    }
}

/// Copies source to output instead of running ffmpeg; records what it was asked to do.
actor StubProcessor: AudioProcessing {
    struct Call: Sendable {
        var settings: ProcessingSettings
        var tags: EpisodeTags
        var artwork: URL?
    }

    private var failuresRemaining = 0
    private(set) var calls: [Call] = []

    func fail(times: Int) { failuresRemaining = times }

    nonisolated func process(
        source: URL, artwork: URL?, output: URL, settings: ProcessingSettings, tags: EpisodeTags
    ) async throws -> Double {
        try await perform(source, artwork, output, settings, tags)
    }

    private func perform(_ source: URL, _ artwork: URL?, _ output: URL, _ settings: ProcessingSettings, _ tags: EpisodeTags) throws -> Double {
        calls.append(Call(settings: settings, tags: tags, artwork: artwork))
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw AudioProcessorError.ffmpegFailed(code: 1, stderr: "Invalid data found when processing input")
        }
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.copyItem(at: source, to: output)
        return 61
    }

    nonisolated func convertArtwork(source: URL, output: URL) async throws {
        try Data("jpeg".utf8).write(to: output)
    }
}

struct TestContext {
    var app: Application
    var http: StubHTTP
    var config: AppConfig
    var world: TestWorld
    var downloader: StubDownloader
    var processor: StubProcessor
}

/// App with a temp data directory, no background jobs and stubbed network, ffmpeg, clock and disk.
func withTestContext(
    configure adjust: (inout AppConfig) throws -> Void = { _ in },
    _ test: (TestContext) async throws -> Void
) async throws {
    let dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("brambling-test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: dataDir) }
    var config = try AppConfig.fromEnvironment {
        switch $0 {
        case "BRAMBLING_DATA": dataDir.path
        case "BRAMBLING_PUBLIC_BASE_URL": "https://brambling.example"
        default: nil
        }
    }
    config.runBackgroundJobs = false
    try adjust(&config)

    let http = StubHTTP()
    let world = TestWorld()
    let downloader = StubDownloader()
    let processor = StubProcessor()
    try await withApp(configure: { app in
        try await App.configure(app, config: config)
        app.feedFetcher = FeedFetcher(http: http)
        app.jobEnvironment = JobEnvironment(
            downloader: downloader,
            processor: processor,
            freeBytes: { _ in world.freeBytes },
            now: { world.now },
            calendar: TestWorld.berlin
        )
    }) { app in
        try await test(TestContext(app: app, http: http, config: config, world: world, downloader: downloader, processor: processor))
    }
}

/// Shorthand used by the M2 tests.
func withTestApp(
    _ test: (Application, StubHTTP, AppConfig) async throws -> Void
) async throws {
    try await withTestContext { ctx in
        try await test(ctx.app, ctx.http, ctx.config)
    }
}

enum Fixtures {
    static func feed(title: String = "Test Show", items: [(guid: String, date: String)], numbers: [String: (episode: Int, season: Int?)] = [:]) -> String {
        let itemXML = items.map { item -> String in
            let number = numbers[item.guid].map { n in
                "<itunes:episode>\(n.episode)</itunes:episode>" + (n.season.map { "<itunes:season>\($0)</itunes:season>" } ?? "")
            } ?? ""
            return """
              <item>
                <title>Episode \(item.guid)</title>
                <guid>\(item.guid)</guid>
                <pubDate>\(item.date)</pubDate>
                \(number)
                <enclosure url="https://cdn.example.com/\(item.guid).mp3?token=s3cr3t" length="1000" type="audio/mpeg"/>
                <itunes:duration>10:00</itunes:duration>
              </item>
            """
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
        <channel>
          <title>\(FeedWriter.escape(title))</title>
          <link>https://example.com</link>
          <description>About testing</description>
          <itunes:author>Tester</itunes:author>
          <itunes:image href="https://cdn.example.com/art.jpg"/>
        \(itemXML)
        </channel>
        </rss>
        """
    }
}
