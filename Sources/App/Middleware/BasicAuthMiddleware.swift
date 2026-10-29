import Vapor

/// Optional HTTP Basic Auth for the web UI and the API (`BRAMBLING_USER` / `BRAMBLING_PASS`).
/// Feeds, media, artwork and `/health` stay open so Apple Podcasts works without credentials.
struct BasicAuthMiddleware: AsyncMiddleware {
    let user: String
    let password: String

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        if let auth = request.headers.basicAuthorization,
           Self.constantTimeEquals(auth.username, user),
           Self.constantTimeEquals(auth.password, password) {
            return try await next.respond(to: request)
        }
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .wwwAuthenticate, value: "Basic realm=\"Brambling\", charset=\"UTF-8\"")
        return Response(status: .unauthorized, headers: headers, body: .init(string: "Authentication required"))
    }

    /// Doesn't stop early on the first different byte, so timing doesn't reveal the password.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let a = Array(a.utf8), b = Array(b.utf8)
        var difference = UInt8(a.count == b.count ? 0 : 1)
        for i in 0..<max(a.count, b.count) {
            difference |= (i < a.count ? a[i] : 0) ^ (i < b.count ? b[i] : 0)
        }
        return difference == 0
    }
}
