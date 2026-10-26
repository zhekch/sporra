import Foundation

@main
struct NativeAPICheck {
    static func check(_ ok: Bool, _ message: String) throws {
        guard ok else { throw ServerFailure(status: 0, message: "FAILED: " + message) }
        print("  ok  " + message)
    }
    static func main() async throws {
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
        _ = try await api.post("/api/cells/mutate", ["remove": stroke["undo"]["remove"]])
        let cleared = try await api.get("/api/render/cells", query: query(["level": "0"]))
        try check(cleared["rows"].array.isEmpty, "undo removes only the added cells")
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
