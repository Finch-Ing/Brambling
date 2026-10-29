import Fluent
import FluentSQLiteDriver
import Leaf
import SQLKit
import Vapor

/// Configures the application. Tests pass an explicit `config`; production reads it from the environment.
func configure(_ app: Application, config: AppConfig? = nil) async throws {
    let config = try config ?? AppConfig.fromEnvironment()
    app.appConfig = config

    try config.createDirectories()

    app.databases.use(.sqlite(.file(config.databasePath)), as: .sqlite)
    app.migrations.add(CreateShow())
    app.migrations.add(CreateEpisode())
    app.migrations.add(AddEpisodeCatalogue())
    app.migrations.add(ResetFeedCache())
    app.migrations.add(AddEpisodeSubtitle())
    app.migrations.add(AddSeriesOrder())
    app.migrations.add(CreateAppSetting())
    try await app.autoMigrate()
    try await loadStoredSettings(app)
    // WAL lets the web UI read while the job queue writes. The setting is stored in the DB file.
    if let sql = app.db as? any SQLDatabase {
        try await sql.raw("PRAGMA journal_mode=WAL").run()
    }

    app.ffmpegCapabilities = await FFmpegCapabilities.detect()
    if let version = app.ffmpegCapabilities.version {
        app.logger.info("ffmpeg detected: \(version)")
    } else {
        app.logger.warning("ffmpeg not found on PATH — processing will fail")
    }

    app.http.client.configuration.timeout = .init(connect: .seconds(15), read: .seconds(60))
    app.refreshScheduler = RefreshScheduler(app: app)
    app.jobQueue = JobQueue(app: app)
    app.lifecycle.use(JobQueueLifecycle(startOnBoot: config.runBackgroundJobs))
    app.lifecycle.use(RefreshSchedulerLifecycle(startOnBoot: config.runBackgroundJobs))

    app.views.use(.leaf)
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    try routes(app)
}

/// A processing window saved in the web UI wins over `BRAMBLING_PROCESS_WINDOW`.
private func loadStoredSettings(_ app: Application) async throws {
    guard let stored = try await AppSetting.value(AppSetting.processWindowKey, on: app.db) else { return }
    do {
        app.appConfig.processWindow = try ProcessingWindow(parsing: stored)
    } catch {
        app.logger.warning("Ignoring the stored processing window: \(error)")
    }
}
