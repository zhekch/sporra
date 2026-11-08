import Foundation

@main struct ActivityDetailCheck {
    static func check(_ ok: Bool, _ message: String) throws {
        guard ok else { throw ServerFailure(status: 0, message: message) }
        print("  ok  " + message)
    }
    static func main() async throws {
        let base = try ServerAPI.address(CommandLine.arguments[1])
        let api = ServerAPI(cacheRoot: URL(fileURLWithPath: CommandLine.arguments[2]))
        await api.configure(base, account: "activity-test")
        let cache = ActivityDetailCache(api: api)
        let preview = ActivityPresentation.preview(id: .number(100), route: .object([
            "name": .string("Morning walk"), "lengthM": .number(1500),
        ]))
        try check(preview["loading"].bool && preview["route"]["id"].int == 100
            && preview["route"]["name"].string == "Morning walk"
            && preview["summary"]["distance"].string == "1.5 km",
            "an uncached card immediately has its selected identity, title and known distance")
        let unknown = ActivityPresentation.preview(id: .number(101), route: .null)
        try check(unknown["loading"].bool && !unknown["summary"]["distance"].exists,
            "missing metadata never invents activity readings")
        let firstTap = Task { try await cache.load("100", scope: "first") }
        try await Task.sleep(for: .milliseconds(100))
        firstTap.cancel()
        let repeatedTap = try await cache.load("100", scope: "first")
        try check(repeatedTap["sequence"].int == 1,
            "cancelling and repeating a tap shares the original slow request")
        _ = try await firstTap.value
        let refresh = Task { try await cache.load("100", scope: "first") }
        try await Task.sleep(for: .milliseconds(100))
        let clock = ContinuousClock.now
        let saved = await cache.cached("100", scope: "first")
        try check(saved == repeatedTap && clock.duration(to: .now) < .milliseconds(100),
            "saved details remain immediately available while network validation is held")
        _ = try await refresh.value
        let disk = ActivityDetailCache(api: api)
        let restored = await disk.cached("100", scope: "first")
        try check(restored?["sequence"].int == 2, "details survive a new cache instance without networking")
        let beforeEdit = Task { try await cache.load("102", scope: "first") }
        try await Task.sleep(for: .milliseconds(100))
        let edited = try await cache.load("102", scope: "first", refresh: true)
        try check(edited["sequence"].int == 2, "editing replaces an older in-flight detail request")
        do {
            _ = try await beforeEdit.value
            throw ServerFailure(status: -1, message: "obsolete response completed")
        } catch let failure as ServerFailure where failure.status == -1 { throw failure } catch {}
        await api.configure(base, account: "other-account")
        let other = await cache.cached("100", scope: "other")
        try check(other == nil, "activity details remain isolated after an account change")
        print("Activity detail checks passed")
    }
}
