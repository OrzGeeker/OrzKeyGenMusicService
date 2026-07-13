import App
import Vapor

@main
struct App {
    static func main() async throws {
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)
        let app = try await Application.make(.detect())
        try configure(app)
        try await app.execute()
        try await app.asyncShutdown()
    }
}
