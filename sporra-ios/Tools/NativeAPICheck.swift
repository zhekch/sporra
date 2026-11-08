import Foundation

@main
struct NativeAPICheck {
    static func check(_ ok: Bool, _ message: String) throws {
        guard ok else { throw ServerFailure(status: 0, message: "FAILED: " + message) }
        print("  ok  " + message)
    }
    static func main() async throws {
        let interleaved = ["land", "road", "early-label", "bridge-casing", "bridge", "road-label", "place-label"]
        let safeLabels = NativeLayerOrder.labelsAboveGeometry(orderedIDs: interleaved,
            symbolIDs: ["early-label", "road-label", "place-label"])
        try check(safeLabels == ["road-label", "place-label"],
            "early text below bridge decks cannot anchor routes beneath roads")
        for id in ["activities", "activity-metric-outline", "activity-metric", "track"] {
            let anchor = NativeLayerOrder.anchor(for: id, orderedIDs: interleaved, basemapLabels: safeLabels)
            try check(anchor == "road-label", "\(id) draws above the final road and bridge layers")
            let layer = NativeLayerOrder.mapboxLayer(.object(["id": .string(id), "type": .string("line")]))
            try check(layer["slot"].string == "top" && layer["layout"]["line-z-offset"].double > 0
                && layer["layout"]["line-elevation-reference"].string == "ground",
                "\(id) uses the upper Mapbox slot without terrain draping")
        }
        try check(NativeLayerOrder.labelsAboveGeometry(orderedIDs: ["road", "label", "bridge"],
            symbolIDs: ["label"]).isEmpty, "a basemap ending in road geometry puts routes at the top")
        let orderedLayers = ["land", "visited-blob", "activities", "railway", "place-label", "road-label"]
        let labels: Set<String> = ["place-label", "road-label"]
        for id in ["activities", "railway", "track", "foreground-cells", "place-outline-halo", "place-outline"] {
            let anchor = NativeLayerOrder.anchor(for: id, orderedIDs: orderedLayers, basemapLabels: labels)
            try check(anchor == (NativeLayerOrder.shading.contains(id) ? "activities" : "place-label"),
                "\(id) stays below basemap text and above/below shading as appropriate")
        }
        try check(NativeLayerOrder.anchor(for: "visited-regions", orderedIDs: ["land", "place-label"],
            basemapLabels: labels) == "place-label", "initial shading stays below labels before activities exist")
        let slotted = NativeLayerOrder.mapboxLayer(.object([
            "id": .string("railway"), "type": .string("line"), "paint": .object(["line-width": .number(3)]),
        ]))
        try check(slotted["slot"].string == "middle" && slotted["paint"]["line-width"].int == 3,
            "Mapbox overlays use the slot below all basemap labels without changing their paint")
        for (id, type, property) in [("visited-blob-buffer-1", "raster", "raster-emissive-strength"), ("visited-regions", "fill", "fill-emissive-strength")] {
            let layer = NativeLayerOrder.mapboxLayer(.object(["id": .string(id), "type": .string(type)]))
            try check(layer["paint"][property].double == 1, "night lighting preserves normal visit shading")
            try check(NativeLayerOrder.anchor(for: id, orderedIDs: ["place-outline", "activities"]) == "place-outline", "buffered shading stays below the selected outline")
        }
        for id in ["activities", "activity-metric", "track"] {
            let activity = NativeLayerOrder.mapboxLayer(.object(["id": .string(id), "type": .string("line")]))
            try check(activity["paint"]["line-emissive-strength"].double == 1, "night lighting preserves normal activity colours")
        }
        for id in ["photos", "photos-cluster"] {
            let photo = NativeLayerOrder.mapboxLayer(.object(["id": .string(id), "type": .string("circle")]))
            try check(photo["paint"]["circle-emissive-strength"].double == 1,
                "night lighting preserves photo puck colours")
        }
        let count = NativeLayerOrder.mapboxLayer(.object(["id": .string("photos-count"), "type": .string("symbol")]))
        try check(count["paint"]["text-emissive-strength"].double == 1,
            "photo group counts remain bright in dark 3D")
        try check(NativeLayerOrder.anchor(for: "photos-cluster", orderedIDs: ["visited-blob", "photos-count"]) == "photos-count",
            "photo group counts stay above their puck")
        let outline = NativeLayerOrder.mapboxLayer(.object(["id": .string("place-outline"), "type": .string("line")]))
        try check(outline["layout"]["line-elevation-reference"].string == "ground" && outline["layout"]["line-z-offset"].double > 0,
            "selection outline renders above Mapbox's draped raster shading")
        try check(NativeLayerOrder.anchor(for: "activities", orderedIDs: ["visited-blob", "activity-metric", "place-label"], basemapLabels: ["place-label"]) == "activity-metric",
            "late-arriving base routes stay below the selected metric overlay")
        try check(NativeLayerOrder.anchor(for: "activity-metric-outline", orderedIDs: ["activities", "activity-metric", "sample"]) == "activity-metric",
            "the selected route's black outline sits beneath its metric colours")
        try check(NativeLayerOrder.anchor(for: "activities", orderedIDs: ["activity-metric-outline", "activity-metric"]) == "activity-metric-outline",
            "base routes cannot cover the selected route's outline")
        let routeFeature: (String) -> JSON = { id in .object(["properties": .object(["id": .string(id)])]) }
        let allRoutes: JSON = .object(["type": .string("FeatureCollection"), "features": .array([routeFeature("selected"), routeFeature("other"), routeFeature("selected")])])
        let selectedActivity: JSON = .object([
            "route": .object(["id": .string("selected"), "geom": .array([.array([.array([.number(8),.number(47)]),.array([.number(9),.number(48)])])])]),
            "lines": .object(["speed": .object(["features": .array([.object([
                "properties": .object(["color": .string("#00ff00"), "i": .number(1)]),
                "geometry": .object(["type": .string("LineString"), "coordinates": .array([
                    .array([.number(8), .number(47)]), .array([.number(9), .number(48)])])]),
            ])])])]),
        ])
        try check(ActivityMapSelection.baseRoutes(allRoutes, activity: selectedActivity, solo: true)["features"].array.isEmpty,
            "selecting an activity hides every base route while its metric overlay is shown")
        let visible = ActivityMapSelection.baseRoutes(allRoutes, activity: selectedActivity, solo: false)
        try check(visible["features"].array.count == 1 && visible["features"][0]["properties"]["id"].string == "other",
            "Show all restores other routes without repainting the selected base line")
        try check(ActivityMapSelection.baseRoutes(allRoutes, activity: .null, solo: false) == allRoutes,
            "closing selection restores all routes immediately")
        let loadingActivity: JSON = .object(["route": .object(["id": .string("selected")]), "loading": .bool(true)])
        try check(ActivityMapSelection.baseRoutes(allRoutes, activity: loadingActivity, solo: true) == allRoutes,
            "opening a loading activity keeps its tappable route visible until geometry arrives")
        let metric = ActivityMapSelection.metricOverlay(selectedActivity, metric: "speed")
        try check(metric["features"].array.count == 1 && metric["features"][0]["properties"]["metricOrder"].int == 1,
            "a coloured span has no white underlay that can leak around its edges")
        let a: JSON = .array([.number(8), .number(47)])
        let b: JSON = .array([.number(9), .number(48)])
        let c: JSON = .array([.number(8), .number(49)])
        var bent = selectedActivity
        bent["route"]["geom"] = .array([.array([a, b, c])])
        let missing = ActivityMapSelection.metricOverlay(bent, metric: "speed")["features"].array
        try check(missing.count == 2 && missing[0]["geometry"]["coordinates"] == .array([b, c])
            && missing[0]["properties"]["color"].string == "#ffffff",
            "only the missing side of a bend gets a white fallback")
        var second = bent["lines"]["speed"]["features"][0]
        second["geometry"]["coordinates"] = .array([b, c])
        second["properties"]["color"] = .string("#ff0000")
        second["properties"]["i"] = .number(2)
        bent["lines"]["speed"]["features"] = .array([bent["lines"]["speed"]["features"][0], second])
        let colouredBend = ActivityMapSelection.metricOverlay(bent, metric: "speed")["features"].array
        try check(colouredBend.count == 2 && colouredBend.allSatisfy { $0["properties"]["metricOrder"].int == 1 }
            && colouredBend[1]["properties"]["i"].int == 2,
            "fully coloured bends keep sample hit targets without any white geometry underneath")
        try check(ActivityMapSelection.metricOverlay(.null, metric: "speed")["features"].array.isEmpty,
            "closing selection clears the metric overlay")
        let base = try ServerAPI.address(CommandLine.arguments[1])
        let api = ServerAPI(
            cookieStorage: URLSessionConfiguration.ephemeral.httpCookieStorage!,
            cacheRoot: URL(fileURLWithPath: CommandLine.arguments[2]))
        await api.configure(base)
        try check(
            try ServerAPI.address(" example.com/path ").absoluteString == "https://example.com",
            "normalises server addresses")
        for invalid in ["ftp://example.com", "https://user:secret@example.com", "https://"] {
            do {
                _ = try ServerAPI.address(invalid)
                throw ServerFailure(status: -1, message: "accepted an invalid address")
            } catch let e as ServerFailure {
                try check(e.status != -1, "rejects invalid or credential-bearing addresses")
            }
        }
        do {
            _ = try await api.get("/api/render/cells")
            throw ServerFailure(status: -1, message: "read authenticated data without a session")
        } catch let e as ServerFailure { try check(e.status == 401, "recognises expired sessions") }
        let account = try await api.post(
            "/api/register",
            ["username": .string("native-test"), "password": .string("native-test-password")])
        try check(account["username"].string == "native-test", "registers with the existing server")
        await api.configure(base, account: "native-test")
        let me = try await api.get("/api/me")
        try check(
            me["username"].string == "native-test", "shares the native cookie session after reconfiguration")
        _ = try await api.post(
            "/api/prefs", ["prefs": .object(["heatMode": .string("visits"), "clock": .string("24")])])
        let prefs = try await api.get("/api/prefs")
        try check(prefs["prefs"]["heatMode"].string == "visits", "saves and re-reads account preferences")
        let stroke = try await api.post(
            "/api/render/brush",
            [
                "points": .array([.array([.number(8.54), .number(47.37)])]), "level": .number(0),
                "action": .string("paint"), "size": .number(1),
            ])
        try check(
            !stroke["undo"]["remove"].array.isEmpty, "paints with the server's brush and receives undo keys")
        let cells = try await api.get("/api/render/cells", query: query(["level": "0", "info": "0"]))
        try check(
            !cells["rows"].array.isEmpty && cells["radius"].double > 0,
            "loads blob geometry from server render data")
        let place = try await api.get(
            "/api/render/at", query: query(["lat": "47.37", "lng": "8.54", "level": "0"]))
        try check(place["visited"].bool, "inspects the same visited ground")
        let cachedPlace = await api.cachedGet("/api/render/at", query: [
            URLQueryItem(name: "level", value: "0"), URLQueryItem(name: "lng", value: "8.54"),
            URLQueryItem(name: "lat", value: "47.37"),
        ])
        try check(cachedPlace == place, "place details open from the query-aware cache without network validation")
        let uncachedPlace = await api.cachedGet("/api/render/at", query: query(["lat": "48", "lng": "8.54", "level": "0"]))
        try check(uncachedPlace == nil, "different coordinates cannot reuse unrelated cached place details")
        _ = try await api.post("/api/cells/mutate", ["remove": stroke["undo"]["remove"]])
        let cleared = try await api.get("/api/render/cells", query: query(["level": "0"]))
        try check(cleared["rows"].array.isEmpty, "undo removes only the added cells")
        let now = Int(Date().timeIntervalSince1970) - 10
        let live = try await api.post("/api/device/fixes", [
            "device": .object(["id": .string("native-ios-live-test"), "name": .string("Live test"), "platform": .string("ios")]),
            "fixes": .array([
                .array([.number(47.37), .number(8.54), .number(Double(now))]),
                .array([.number(47.38), .number(8.55), .number(Double(now + 1))]),
            ]),
        ])
        let liveCells = try await api.get("/api/render/cells", query: query(["level": "0", "info": "0"]), fresh: true)
        try check(live["fixes"].int == 2 && liveCells["rows"].array.count >= 2,
            "foreground fixes persist through the device endpoint and appear in cell shading")
        let gpx =
            "<gpx version=\"1.1\"><trk><name>Native test walk</name><trkseg><trkpt lat=\"47.37\" lon=\"8.54\"><ele>400</ele><time>2026-01-01T10:00:00Z</time></trkpt><trkpt lat=\"47.371\" lon=\"8.541\"><ele>410</ele><time>2026-01-01T10:01:00Z</time></trkpt></trkseg></trk></gpx>"
        var body: [String: JSON] = [
            "name": .string("walk.gpx"), "base64": .string(Data(gpx.utf8).base64EncodedString()),
            "includeRoutes": .bool(true), "preview": .bool(true),
        ]
        let preview = try await api.post("/api/import/file", body)
        try check(
            preview["preview"].bool && preview["imported"].int > 0, "reviews file imports without committing")
        body["preview"] = .bool(false)
        _ = try await api.post("/api/import/file", body)
        let routes = try await api.get("/api/routes?fold=1")
        try check(!routes["routes"].array.isEmpty, "commits reviewed activities")
        let activity = try await api.get(
            "/api/render/activity", query: query(["id": routes["routes"][0]["id"].string]))
        try check(
            activity["graphs"]["speed"].exists && activity["graphs"]["elev"].exists
                && activity["samples"].array.count == 2, "uses server metric graphs and aligned samples")
        let days = try await api.get("/api/days")
        try check(!days["days"].object.isEmpty, "loads recorded calendar days")
        let day = days["days"].object.keys.sorted()[0]
        let dayPath = "/api/render/track?day=" + day
        let dayTrack = try await api.get(dayPath)
        let savedDay = await api.cachedGet(dayPath)
        try check(savedDay == dayTrack, "day geometry is available immediately from the account cache")

        for path in [
            "/api/trips", "/api/stats", "/api/render/activity-stats", "/api/sources", "/api/backup",
            "/api/admin/users",
        ] {
            _ = try await api.get(path)
            print("  ok  " + path)
        }
        let other = try await api.post(
            "/api/register",
            ["username": .string("another-native-test"), "password": .string("native-test-password")])
        await api.configure(base, account: other["username"].string)
        let otherCells = try await api.get("/api/render/cells")
        try check(otherCells["rows"].array.isEmpty, "account switching cannot reuse another map's cache")
        do {
            _ = try await api.get("https://example.com/api/me")
            throw ServerFailure(status: -1, message: "allowed foreign origin")
        } catch let e as ServerFailure {
            try check(e.status == 0, "refuses authenticated requests to foreign origins")
        }
        _ = try await api.post("/api/logout")
        do {
            _ = try await api.get("/api/me", fresh: true)
            throw ServerFailure(status: -1, message: "session survived logout")
        } catch let e as ServerFailure { try check(e.status == 401, "logout invalidates the native session") }
        let rail: JSON = .object([
            "id": .string("test"), "type": .string("line"),
            "paint": .object([
                "line-dasharray": .array([
                    .string("match"), .array([.string("get"), .string("kind")]), .string("rail"),
                    .array([.string("literal"), .array([.number(1), .number(2)])]),
                    .array([.string("literal"), .array([.number(3), .number(4)])]),
                ]),
                "line-color": .array([
                    .string("case"), .array([.string("get"), .string("active")]), .string("#ffffff"),
                    .string("#000000"),
                ]),
            ]),
        ])
        let layers = NativeRail.layers(rail)
        try check(
            layers.count == 4 && Set(layers.map { $0["id"].string }).count == 4,
            "splits rail dash and colour branches into unique native layers")
        try check(
            layers.allSatisfy {
                $0["paint"]["line-color"].array.isEmpty
                    && $0["paint"]["line-dasharray"][0] != .string("match")
            }, "rail layers use UIKit-compatible constant values")
        print("Native API checks passed")
    }
}
