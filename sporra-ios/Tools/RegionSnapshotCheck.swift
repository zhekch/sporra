import Foundation

@main struct RegionSnapshotCheck {
    static func check(_ ok: Bool, _ message: String) throws {
        guard ok else { throw ServerFailure(status: 0, message: message) }
        print("  ok  " + message)
    }
    static func main() async throws {
        let api = ServerAPI(cacheRoot: URL(fileURLWithPath: CommandLine.arguments[2]))
        await api.configure(try ServerAPI.address(CommandLine.arguments[1]), account: "region-test")
        let cache = RegionSnapshotCache(api: api)
        let parameters = query(["level": "7", "fine": "1", "info": "1", "bbox": "0,0,1,1"])
        let first = Task { try await cache.load(query: parameters, scope: "account:1") }
        try await Task.sleep(for: .milliseconds(100))
        first.cancel()
        let moved = query(["level": "7", "fine": "1", "bbox": "1,1,2,2"])
        let second = try await cache.load(query: moved, scope: "account:1")
        try check(second["sequence"].int == 1, "camera cancellation and movement share one region aggregation")
        try check(second["coarse"].bool && second["geometryOnly"].bool && second["global"].bool,
            "immediate shading requests global coarse geometry without visit facts or fine downloads")
        let clock = ContinuousClock.now
        let cached = await cache.cached(query: parameters, scope: "account:1")
        try check(cached == second && clock.duration(to: .now) < .milliseconds(100),
            "returning to countries reuses the prepared snapshot immediately")
        _ = try await first.value
        let updated = try await cache.load(query: parameters, scope: "account:2")
        try check(updated["sequence"].int == 2, "a new history revision refreshes the snapshot")
        let interrupted = Task { try await cache.load(query: query(["level": "6"]), scope: "account:2") }
        try await Task.sleep(for: .milliseconds(100))
        await api.configure(try ServerAPI.address(CommandLine.arguments[1]), account: "other-account")
        let other = await cache.cached(query: query(["level": "6"]), scope: "other-account")
        try check(other == nil, "an in-flight result is never exposed to a new account scope")
        do {
            _ = try await interrupted.value
            throw ServerFailure(status: -1, message: "obsolete scope completed")
        } catch let failure as ServerFailure where failure.status == -1 { throw failure } catch {}
        print("Region transition checks passed")
    }
}
