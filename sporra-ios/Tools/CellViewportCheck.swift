import Foundation

@main struct CellViewportCheck {
    static func check(_ ok: @autoclosure () -> Bool, _ message: String) throws {
        guard ok() else { throw ServerFailure(status: 0, message: message) }
        print("  ok  " + message)
    }
    static func main() async throws {
        let sample = Data(
            "{\"number\":1,\"zero\":0,\"true\":true,\"false\":false,\"null\":null,\"unicode\":\"Zürich\",\"nested\":[[1,2.5,\"x\"]]}"
                .utf8)
        let fast = try JSON.decode(sample)
        let original = try JSONDecoder().decode(JSON.self, from: sample)
        try check(
            fast == original, "fast JSON parsing preserves numeric, boolean, null and nested values"
        )
        let world = 40075016.68557849
        let rows: [JSON] = [
            .array([.string("origin"), .number(0), .number(0), .string("#60acff"), .bool(false)]),
            .array([
                .string("east"), .number(world / 2 - 100), .number(0), .string("#60acff"),
                .bool(false),
            ]),
            .array([
                .string("west"), .number(world / 2 + 100), .number(0), .string("#60acff"),
                .bool(false),
            ]),
            .array([
                .string("far"), .number(world / 4), .number(0), .string("#60acff"), .bool(false),
            ]),
        ]
        let index = CellSpatialIndex(
            .object(["level": .number(0), "radius": .number(50), "rows": .array(rows)]))
        func ids(_ bounds: [Double]) -> Set<String> {
            Set(index.viewport(bounds)["rows"].array.map { $0[0].string })
        }
        try check(ids([-1, -1, 1, 1]) == ["origin"], "viewport index excludes distant cells")
        try check(
            ids([179, -1, -179, 1]) == ["east", "west"],
            "viewport index spans both sides of the date line")
        try check(
            ids([179, -1, 181, 1]) == ["east", "west"],
            "unwrapped camera bounds retain both sides of the date line")
        try check(
            ids([-180, -85, 180, 85]).count == 4, "world viewport retains every cell exactly once")
        try check(ids([-1, 50, 1, 51]).isEmpty, "latitude bounds exclude unrelated cells")
        try check(
            ids([-0.001, 0.02, 0.001, -0.02]).isEmpty,
            "inverted latitude bounds cannot crash the viewport bucket range")
        for invalid: [Double] in [[], [0, 0, 1], [0, .nan, 1, 1], [0, 0, .infinity, 1]] {
            try check(
                index.viewport(invalid)["rows"] == .array([]),
                "invalid viewport returns an empty cell snapshot")
        }

        let api = ServerAPI(
            cookieStorage: URLSessionConfiguration.ephemeral.httpCookieStorage!,
            cacheRoot: URL(fileURLWithPath: CommandLine.arguments[2]))
        let base = try ServerAPI.address(CommandLine.arguments[1])
        await api.configure(base, account: "viewport-test")
        let parameters = query(["level": "0", "info": "0"])
        _ = try await api.get("/api/render/cells", query: parameters)
        let cache = CellViewportCache(api: api)
        let viewport = parameters + query(["bbox": "-1,-1,1,1"])
        let first = await cache.cached(
            query: viewport, scope: "first-account", bounds: [-1, -1, 1, 1])
        try check(
            first?["rows"].array.count == 1, "world download supplies a new viewport immediately")
        let refresh = Task {
            try await cache.load(query: viewport, scope: "first-account", bounds: [-1, -1, 1, 1])
        }
        try await Task.sleep(for: .milliseconds(50))
        let start = ContinuousClock.now
        let duringRefresh = await cache.cached(
            query: viewport, scope: "first-account", bounds: [-1, -1, 1, 1])
        try check(
            duringRefresh != nil && start.duration(to: .now) < .seconds(1),
            "held network revalidation cannot delay cached ground")
        _ = try await refresh.value
        await api.setOffline(true)
        let pan = await cache.cached(
            query: parameters + query(["bbox": "-2,-1,0,1"]), scope: "first-account",
            bounds: [-2, -1, 0, 1])
        try check(
            pan?["rows"].array.count == 1,
            "panning reuses the prepared world index without a network request")
        await api.setOffline(false)
        let coarseQuery = query(["level": "6", "fine": "0", "info": "0"])
        _ = try await api.get("/api/render/regions", query: coarseQuery)
        let fineQuery = query(["level": "6", "fine": "1"])
        let fineRefresh = Task { try await api.regionSnapshot(query: fineQuery) }
        try await Task.sleep(for: .milliseconds(50))
        let regionStart = ContinuousClock.now
        let immediateRegion = await api.cachedRegionSnapshot(query: fineQuery + query(["bbox": "-1,-1,1,1"]))
        try check(immediateRegion != nil && immediateRegion?.fine == false && regionStart.duration(to: .now) < .seconds(1),
            "coarse saved regions display while the fine-boundary request is held")
        _ = try await fineRefresh.value
        let refinedRegion = await api.cachedRegionSnapshot(query: fineQuery)
        try check(refinedRegion?.fine == true, "the completed fine snapshot becomes available for immediate reuse")
        await api.configure(base, account: "different-account")
        let other = await cache.cached(
            query: viewport, scope: "different-account", bounds: [-1, -1, 1, 1])
        try check(other == nil, "prepared geometry never crosses account boundaries")
        print("Cell viewport cache checks passed")
    }
}
