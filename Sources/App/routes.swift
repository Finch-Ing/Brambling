import Vapor

func routes(_ app: Application) throws {
    // Open: Apple Podcasts and monitoring must reach these without credentials.
    try app.register(collection: HealthController())
    try app.register(collection: FeedController())
    try app.register(collection: MediaController())

    // UI and API: optional Basic Auth, and no cross-site form posts.
    var protected: any RoutesBuilder = app.grouped(SameOriginMiddleware())
    if let auth = app.appConfig.basicAuth {
        protected = protected.grouped(BasicAuthMiddleware(user: auth.user, password: auth.password))
    }
    try protected.register(collection: ShowAPIController())
    try protected.register(collection: QueueAPIController())
    try protected.register(collection: WebController())
}
