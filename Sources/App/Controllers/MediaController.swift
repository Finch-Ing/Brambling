import Fluent
import Vapor

/// Processed audio and artwork, with Range support (Apple Podcasts and the iPod sync rely on it).
/// Only files that belong to a database record are served, so nothing else under the data
/// directory is reachable.
struct MediaController: RouteCollection {
    static let audio = HTTPMediaType(type: "audio", subType: "mpeg")

    func boot(routes: any RoutesBuilder) throws {
        routes.get("media", ":slug", ":file", use: media)
        routes.get("art", ":file", use: artwork)
    }

    @Sendable
    func media(req: Request) async throws -> Response {
        guard let slug = req.parameters.get("slug"), Slug.isValid(slug),
              let file = req.parameters.get("file"), Self.isMediaFileName(file),
              let show = try await Show.query(on: req.db).filter(\.$slug == slug).first()
        else { throw Abort(.notFound) }

        // Any status: a reprocessing episode still serves its old file until the new one is ready.
        let known = try await show.$episodes.query(on: req.db).filter(\.$fileName == file).count() > 0
        guard known else { throw Abort(.notFound) }

        let path = req.application.appConfig.mediaDirectory
            .appendingPathComponent(slug, isDirectory: true)
            .appendingPathComponent(file).path
        guard FileManager.default.fileExists(atPath: path) else { throw Abort(.notFound) }
        return try await req.fileio.asyncStreamFile(at: path, mediaType: Self.audio)
    }

    @Sendable
    func artwork(req: Request) async throws -> Response {
        guard let file = req.parameters.get("file"), file.hasSuffix(".jpg") else { throw Abort(.notFound) }
        let slug = String(file.dropLast(4))
        guard Slug.isValid(slug),
              try await Show.query(on: req.db).filter(\.$slug == slug).count() > 0
        else { throw Abort(.notFound) }

        let path = req.application.appConfig.artDirectory.appendingPathComponent("\(slug).jpg").path
        guard FileManager.default.fileExists(atPath: path) else { throw Abort(.notFound) }
        return try await req.fileio.asyncStreamFile(at: path, mediaType: .jpeg)
    }

    /// `<uuid>-<hash>.mp3`, lowercase hex and dashes only.
    static func isMediaFileName(_ name: String) -> Bool {
        guard name.hasSuffix(".mp3"), name.count <= 80 else { return false }
        return name.dropLast(4).allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) || $0 == "-" }
    }
}
