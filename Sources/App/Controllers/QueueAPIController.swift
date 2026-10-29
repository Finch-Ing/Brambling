import Fluent
import Vapor

struct QueueAPIController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let api = routes.grouped("api")
        api.get("queue", use: status)
        api.post("queue", "process-now", use: processNow)
        api.post("episodes", ":episodeID", "retry", use: retry)
    }

    @Sendable
    func status(req: Request) async throws -> QueueStatus {
        try await req.application.jobQueue.status()
    }

    /// Ignore the processing window until the queue is empty (plan §5.5).
    @Sendable
    func processNow(req: Request) async throws -> QueueStatus {
        await req.application.jobQueue.processNow()
        return try await req.application.jobQueue.status()
    }

    @Sendable
    func retry(req: Request) async throws -> ShowAPIController.EpisodeDTO {
        guard let id = req.parameters.get("episodeID", as: UUID.self),
              let episode = try await Episode.find(id, on: req.db)
        else { throw Abort(.notFound) }
        try await req.application.shows.retry(episode)
        return try .init(episode)
    }
}
