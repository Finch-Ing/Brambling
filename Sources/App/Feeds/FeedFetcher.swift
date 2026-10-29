import Vapor

/// The bits of an HTTP response the fetcher needs. Lets tests stub the network.
struct HTTPFetchResponse: Sendable {
    var status: HTTPResponseStatus
    var headers: HTTPHeaders
    var body: Data
}

protocol HTTPFetching: Sendable {
    func get(_ url: String, headers: HTTPHeaders) async throws -> HTTPFetchResponse
}

/// Real transport using Vapor's HTTP client (follows redirects).
struct VaporHTTPFetcher: HTTPFetching {
    let client: any Client

    func get(_ url: String, headers: HTTPHeaders) async throws -> HTTPFetchResponse {
        let response = try await client.get(URI(string: url), headers: headers)
        let body = response.body.map { Data($0.readableBytesView) } ?? Data()
        return HTTPFetchResponse(status: response.status, headers: response.headers, body: body)
    }
}

enum FeedFetchResult: Sendable {
    case notModified
    case fetched(ParsedFeed, etag: String?, lastModified: String?)
}

enum FeedFetchError: Error, CustomStringConvertible {
    case httpStatus(UInt)

    var description: String {
        switch self {
        case let .httpStatus(code): "Feed request failed with HTTP \(code)"
        }
    }
}

/// Conditional GET + parse. Never logs or reports the (secret) feed URL.
struct FeedFetcher: Sendable {
    static let userAgent = "Brambling/1.0 (self-hosted podcast proxy)"

    let http: any HTTPFetching

    func fetch(_ url: String, etag: String? = nil, lastModified: String? = nil) async throws -> FeedFetchResult {
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .userAgent, value: Self.userAgent)
        headers.replaceOrAdd(name: .accept, value: "application/rss+xml, application/xml;q=0.9, text/xml;q=0.8, */*;q=0.5")
        if let etag { headers.replaceOrAdd(name: .ifNoneMatch, value: etag) }
        if let lastModified { headers.replaceOrAdd(name: .ifModifiedSince, value: lastModified) }

        let response = try await http.get(url, headers: headers)
        switch response.status.code {
        case 304:
            return .notModified
        case 200..<300:
            let feed = try FeedParser.parse(response.body)
            return .fetched(
                feed,
                etag: response.headers.first(name: .eTag),
                lastModified: response.headers.first(name: .lastModified)
            )
        default:
            throw FeedFetchError.httpStatus(response.status.code)
        }
    }
}
