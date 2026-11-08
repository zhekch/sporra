import Foundation

@main
struct ConnectionAPICheck {
    static func check(_ ok: Bool, _ message: String) throws {
        guard ok else { throw ServerFailure(status: 0, message: "FAILED: " + message) }
        print("  ok  " + message)
    }
    static func main() async throws {
        try check(ServerAPI.isQuietReadFailure(ServerFailure(status: 0, message: "Unable to read the server response.")),
            "unreadable server responses use a quiet offline notice")
        try check(ServerAPI.isQuietReadFailure(ServerFailure(status: 503, message: "Unavailable", isReadFailure: true)),
            "temporary read failures do not need a modal alert")
        try check(!ServerAPI.isQuietReadFailure(ServerFailure(status: 500, message: "Edit failed")),
            "editing failures retain their actionable error")
        try check(!ServerAPI.isQuietReadFailure(ServerFailure(status: 401, message: "Sign in", isReadFailure: true)),
            "authentication failures stay distinct from transient reads")
        let api = ServerAPI(cacheRoot: URL(fileURLWithPath: CommandLine.arguments[2]))
        await api.configure(
            try ServerAPI.address(CommandLine.arguments[1]), account: "connection-test")
        let slow = try await api.get("/api/render/slow")
        try check(slow["ok"].bool, "render taking more than five seconds completes")
        for path in ["/api/render/error", "/api/render/interrupted"] {
            do {
                _ = try await api.get(path)
                throw ServerFailure(status: -1, message: "accepted failed endpoint")
            } catch let error as ServerFailure where error.status == -1 { throw error } catch {}
            let offline = await api.isOffline()
            try check(!offline, "\(path) does not mark a reachable server offline")
        }
        await api.setOffline(true)
        let recovered = try await api.get("/api/render/uncached")
        try check(recovered["ok"].bool, "uncached reads attempt the network while offline")
        let offline = await api.isOffline()
        try check(!offline, "successful recovery clears offline state")
        let pendingProbe = Task { try await api.validateSession() }
        try await Task.sleep(for: .milliseconds(50))
        let cancellation = ContinuousClock.now
        pendingProbe.cancel()
        do {
            _ = try await pendingProbe.value
            throw ServerFailure(status: -1, message: "cancelled retry probe completed")
        } catch let failure as ServerFailure where failure.status == -1 { throw failure } catch {}
        try check(cancellation.duration(to: .now) < .seconds(1), "Retry cancels a held session check immediately")
        let probe = try await api.validateSession()
        try check(probe["ok"].bool, "a fresh retry succeeds without relaunching the app")
        await api.setOffline(true)
        _ = try await api.get("/api/me", fresh: true)
        let stillOffline = await api.isOffline()
        try check(!stillOffline, "fresh session check restores connectivity")
        print("Connection regression checks passed")
    }
}
