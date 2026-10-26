import Foundation

@main
struct OfflineAPICheck {
    static func check(_ ok: Bool, _ message: String) throws {
        guard ok else { throw ServerFailure(status: 0, message: "FAILED: " + message) }
        print("  ok  " + message)
    }
    static func main() async throws {
        let base = try ServerAPI.address(CommandLine.arguments[1])
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        let phase = CommandLine.arguments[3]
        let api = ServerAPI(
            cookieStorage: URLSessionConfiguration.ephemeral.httpCookieStorage!, cacheRoot: root)
        if phase == "seed" {
            await api.configure(base)
            let user = try await api.post(
                "/api/register",
                ["username": .string("offline-test"), "password": .string("offline-test-password")])
            await api.configure(base, account: user["username"].string)
            let prefs = try await api.get("/api/prefs")["prefs"]
            await api.saveAccount(user: user, prefs: prefs, pending: ["clock": .string("24")])
            _ = try await api.post(
                "/api/render/brush",
                [
                    "points": .array([.array([.number(8.54), .number(47.37)])]), "level": .number(0),
                    "size": .number(1), "action": .string("paint"),
                ])
            _ = try await api.get(
                "/api/render/cells", query: query(["level": "0", "info": "0", "fine": "1"]))
            _ = try await api.get("/api/days")
            _ = try await api.get("/api/stats")
            // An unauthenticated server response must remain distinguishable from
            // a network outage, without deleting the saved local account.
            let unauthenticated = ServerAPI(
                cookieStorage: URLSessionConfiguration.ephemeral.httpCookieStorage!, cacheRoot: root)
            await unauthenticated.configure(base, account: user["username"].string)
            do {
                _ = try await unauthenticated.get("/api/me", fresh: true)
                throw ServerFailure(status: -1, message: "accepted missing session")
            } catch let failure as ServerFailure {
                try check(
                    failure.status == 401,
                    "does not mask a server authentication rejection with cached identity")
            }
            let saved = await unauthenticated.savedAccount(for: base)
            try check(
                saved?["user"]["username"].string == "offline-test",
                "an expired session does not destroy the offline account")
            print("Offline seed saved")
            return
        }
        let saved = await api.savedAccount(for: base)
        try check(
            saved?["user"]["username"].string == "offline-test",
            "restores account after process restart without a server")
        try check(saved?["pending"]["clock"].string == "24", "retains pending preferences across launches")
        await api.configure(base, account: "offline-test")
        // No explicit offline flag: a real failed connection must trigger fallback.
        let cells = try await api.get(
            "/api/render/cells", query: query(["fine": "1", "info": "0", "level": "0"]))
        try check(!cells["rows"].array.isEmpty, "falls back to disk when the actual server is stopped")
        let offline = await api.isOffline()
        try check(offline, "reports offline connection state")
        let viewport = try await api.get(
            "/api/render/cells", query: query(["level": "0", "info": "0", "fine": "1", "bbox": "8,47,9,48"]))
        try check(
            viewport["rows"] == cells["rows"], "world snapshots survive a changed viewport and query order")
        let days = try await api.get("/api/days")
        try check(days["days"].exists, "reads saved calendar data without networking")
        _ = try await api.get("/api/stats")
        do {
            _ = try await api.get("/api/render/activity?id=987654")
            throw ServerFailure(status: -1, message: "invented missing activity")
        } catch let failure as ServerFailure {
            try check(
                failure.status == -1009 && failure.message.contains("isn't saved"),
                "explains unavailable uncached content")
        }
        do {
            _ = try await api.post("/api/render/brush")
            throw ServerFailure(status: -1, message: "accepted offline edit")
        } catch let failure as ServerFailure {
            try check(failure.status == -1009, "never pretends offline server mutations succeeded")
        }
        await api.configure(base, account: "another-account")
        await api.setOffline(true)
        do {
            _ = try await api.get("/api/days")
            throw ServerFailure(status: -1, message: "leaked another account's cache")
        } catch let failure as ServerFailure {
            try check(failure.status == -1009, "offline responses remain isolated by account")
        }
        await api.configure(base, account: "offline-test")
        await api.forgetAccount()
        let forgotten = await api.savedAccount(for: base)
        try check(forgotten == nil, "explicit sign-out removes saved identity")
        await api.configure(base, account: "offline-test")
        await api.setOffline(true)
        do {
            _ = try await api.get("/api/days")
            throw ServerFailure(status: -1, message: "retained signed-out data")
        } catch let failure as ServerFailure {
            try check(failure.status == -1009, "explicit sign-out removes saved private responses")
        }
        print("Offline restart checks passed")
    }
}
