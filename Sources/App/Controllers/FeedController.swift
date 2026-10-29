import Fluent
import Vapor

/// `GET /feeds/<slug>.xml` — the processed show as an RSS feed (plan §7).
struct FeedController: RouteCollection {
    static let contentType = HTTPMediaType(type: "application", subType: "rss+xml", parameters: ["charset": "utf-8"])

    func boot(routes: any RoutesBuilder) throws {
        routes.get("feeds", ":file", use: feed)
    }

    @Sendable
    func feed(req: Request) async throws -> Response {
        guard let file = req.parameters.get("file"), file.hasSuffix(".xml") else { throw Abort(.notFound) }
        let slug = String(file.dropLast(4))
        guard Slug.isValid(slug),
              let show = try await Show.query(on: req.db).filter(\.$slug == slug).first()
        else { throw Abort(.notFound) }

        let config = req.application.appConfig
        let baseURL = Self.baseURL(for: req, fallback: config.publicBaseURL)
        let episodes = try await show.$episodes.query(on: req.db)
            .filter(\.$status == .ready)
            .sort(\.$pubDate, .descending)
            .all()
        let hasArtwork = FileManager.default.fileExists(
            atPath: config.artDirectory.appendingPathComponent("\(show.slug).jpg").path
        )

        let etag = Self.etag(show: show, episodes: episodes, hasArtwork: hasArtwork, baseURL: baseURL)
        let lastModified = ([show.updatedAt] + episodes.map(\.processedAt)).compactMap { $0 }.max()

        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .eTag, value: etag)
        if let lastModified {
            headers.replaceOrAdd(name: .lastModified, value: FeedWriter.rfc822(lastModified))
        }
        // Clients should always revalidate; 304s keep that cheap.
        headers.replaceOrAdd(name: .cacheControl, value: "no-cache")

        if Self.notModified(req.headers, etag: etag, lastModified: lastModified) {
            return Response(status: .notModified, headers: headers)
        }

        headers.contentType = Self.contentType
        let xml = FeedWriter.render(show: show, episodes: episodes, baseURL: baseURL, hasArtwork: hasArtwork)
        return Response(status: .ok, headers: headers, body: .init(string: xml))
    }

    /// Links in the feed use the scheme and host the client used, so a feed fetched over plain HTTP
    /// (or via the IP address) also points to its media over HTTP / the IP. Some podcast apps don't
    /// trust a self-signed certificate or can't resolve `.local`. Falls back to `BRAMBLING_PUBLIC_BASE_URL`.
    static func baseURL(for req: Request, fallback: URL) -> URL {
        guard let host = req.headers.first(name: .host)?.lowercased(), isPlausibleHost(host) else { return fallback }
        let forwarded = req.headers.first(name: "X-Forwarded-Proto")?.split(separator: ",").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        // Without a proxy header the request came straight to Vapor, which only speaks HTTP.
        let scheme = forwarded.flatMap { ["http", "https"].contains($0) ? $0 : nil } ?? "http"
        let defaultPort = scheme == "https" ? ":443" : ":80"
        let cleanHost = host.hasSuffix(defaultPort) ? String(host.dropLast(defaultPort.count)) : host
        return URL(string: "\(scheme)://\(cleanHost)") ?? fallback
    }

    /// `name[:port]` or `[ipv6]:port`; anything else (spaces, slashes, @) falls back to the configured URL.
    static func isPlausibleHost(_ host: String) -> Bool {
        !host.isEmpty && host.count <= 255 && host.allSatisfy { $0.isLetter || $0.isNumber || ".-:[]".contains($0) }
    }

    /// Changes whenever anything that ends up in the feed changes.
    static func etag(show: Show, episodes: [Episode], hasArtwork: Bool, baseURL: URL) -> String {
        var parts = [
            baseURL.absoluteString,
            show.slug,
            String(show.updatedAt?.timeIntervalSince1970 ?? 0),
            hasArtwork ? "art" : "",
        ]
        for episode in episodes {
            parts.append("\(episode.id?.uuidString ?? "")-\(episode.settingsHash)-\(episode.fileSize ?? 0)-\(episode.processedAt?.timeIntervalSince1970 ?? 0)")
        }
        let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
        return "\"" + digest.prefix(8).map { String(format: "%02x", $0) }.joined() + "\""
    }

    /// `If-None-Match` wins over `If-Modified-Since` (RFC 9110).
    static func notModified(_ headers: HTTPHeaders, etag: String, lastModified: Date?) -> Bool {
        if let ifNoneMatch = headers.first(name: .ifNoneMatch) {
            return ifNoneMatch.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == etag || $0.trimmingCharacters(in: .whitespaces) == "*" }
        }
        if let ifModifiedSince = headers.first(name: .ifModifiedSince),
           let since = FeedParser.parseDate(ifModifiedSince),
           let lastModified {
            // HTTP dates have whole seconds.
            return lastModified.timeIntervalSince1970.rounded(.down) <= since.timeIntervalSince1970
        }
        return false
    }
}
