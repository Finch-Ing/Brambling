import Fluent
import Vapor

struct HealthController: RouteCollection {
    struct DiskInfo: Content {
        var freeBytes: Int64?
        var mediaBytes: Int64
        var tmpBytes: Int64
        var minFreeBytes: Int64
        var maxMediaBytes: Int64?
        var blocked: Bool
        var reason: String?
    }

    struct HealthResponse: Content {
        var ok: Bool
        var problems: [String]
        var ffmpegVersion: String?
        var queueLength: Int
        var diskFreeBytes: Int64?
        var disk: DiskInfo
        var queue: QueueStatus
    }

    func boot(routes: any RoutesBuilder) throws {
        routes.get("health", use: health)
    }

    @Sendable
    func health(req: Request) async throws -> HealthResponse {
        let app = req.application
        let config = app.appConfig
        let capabilities = app.ffmpegCapabilities
        // Touches the DB, so a broken database reports as an error.
        let queue = try await app.jobQueue.status()
        let free = app.jobEnvironment.freeBytes(config.dataDirectory)

        var problems: [String] = []
        if capabilities.version == nil { problems.append("ffmpeg not found") }
        if let reason = queue.diskBlockedReason { problems.append("disk guard: \(reason)") }

        let queueLength = ["pending", "downloading", "downloaded", "processing"].reduce(0) { $0 + (queue.counts[$1] ?? 0) }
        return HealthResponse(
            ok: problems.isEmpty,
            problems: problems,
            ffmpegVersion: capabilities.version,
            queueLength: queueLength,
            diskFreeBytes: free,
            disk: DiskInfo(
                freeBytes: free,
                mediaBytes: try await app.jobQueue.mediaBytes(),
                tmpBytes: DiskGuard.directorySize(config.tmpDirectory),
                minFreeBytes: config.diskLimits.minFreeBytes,
                maxMediaBytes: config.diskLimits.maxMediaBytes,
                blocked: queue.diskBlocked,
                reason: queue.diskBlockedReason
            ),
            queue: queue
        )
    }
}
