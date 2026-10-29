import Vapor

/// Rejects state-changing requests that a browser sends on behalf of another website (CSRF).
/// Without it, any page opened on the LAN could post e.g. "delete show" to Brambling.
/// Requests without browser headers (curl, scripts) are allowed.
struct SameOriginMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard request.method != .GET, request.method != .HEAD, request.method != .OPTIONS else {
            return try await next.respond(to: request)
        }
        if let site = request.headers.first(name: "Sec-Fetch-Site"), site == "cross-site" || site == "same-site" {
            throw Abort(.forbidden, reason: "Cross-site request rejected.")
        }
        if let origin = request.headers.first(name: .origin), origin != "null" {
            guard let originHost = URL(string: origin).flatMap(Self.hostAndPort),
                  let host = request.headers.first(name: .host)?.lowercased(),
                  originHost == host || originHost == Self.withoutDefaultPort(host, scheme: URL(string: origin)?.scheme)
            else {
                throw Abort(.forbidden, reason: "Cross-origin request rejected.")
            }
        }
        return try await next.respond(to: request)
    }

    private static func hostAndPort(_ url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    /// `Host: brambling.example:443` vs `Origin: https://brambling.example`.
    private static func withoutDefaultPort(_ host: String, scheme: String?) -> String {
        if scheme == "https", host.hasSuffix(":443") { return String(host.dropLast(4)) }
        if scheme == "http", host.hasSuffix(":80") { return String(host.dropLast(3)) }
        return host
    }
}
