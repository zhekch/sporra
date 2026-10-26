import Combine
import CoreLocation
import Foundation
import UIKit

@MainActor
final class NativeStore: ObservableObject {
    let api = ServerAPI.shared
    @Published var ready = false
    @Published var user: JSON = .null
    @Published var prefs: JSON = .object([:])
    @Published var error: String?
    @Published var busy = false
    @Published var revision = 0
    @Published var style = "dark"
    @Published var detail = "auto"
    @Published var ground = true
    @Published var activities = true
    @Published var cellInfo = true
    @Published var photos = false
    @Published var rail = false
    @Published var trails = false
    @Published var trailTheme = "hiking"
    @Published var trailStrength = 0.75
    @Published var airportGroups: Set<String> = []
    @Published var hidden: Set<String> = []
    @Published var editing = false
    @Published var brushAction = "paint"
    @Published var brushSize = 1
    @Published var clearingRegion = false
    @Published var undo: JSON = .null
    @Published var activity: JSON = .null
    @Published var metric = "speed"
    @Published var sample: Int?
    @Published var track: JSON = .null
    @Published var trackDay: String?
    @Published var place: JSON = .null
    @Published var focus: JSON = .null
    @Published var cameraCommand = UUID()
    @Published var locationCommand = UUID()
    @Published var snapshotCommand = UUID()
    @Published var shareURL: URL?
    @Published var notice: JSON = .null
    @Published var routeChoices: [JSON] = []
    @Published var solo = false
    @Published var lightClock = Date()
    private var pendingCount = 0
    private var accountEpoch = 0
    private var selectionEpoch = 0
    private var preferenceWork: Task<Void, Error>?
    private var preferenceDebounce: Task<Void, Never>?
    private var queuedPreferences: [String: JSON] = [:]
    private var optimisticPreferences: [String: JSON] = [:]
    var signedIn: Bool { user["username"].exists }
    var mode: String { prefs["heatMode"].text("flat") }
    var accent: String {
        prefs["accents"][style == "voyager" ? "light" : "dark"].text(prefs["accent"].text("#60acff"))
    }
    var opacity: Double {
        prefs["mapOpacities"][mode].exists ? prefs["mapOpacities"][mode].double : (mode == "flat" ? 0.3 : 0.5)
    }
    var token: String { prefs["mapboxToken"].string }
    var useMapbox: Bool { !token.isEmpty && ["mapbox", "satellite"].contains(style) }
    var localKey: String { "native-map:\(AppSettings.shared.serverURL):\(user["username"].string)" }
    func initialize() async {
        defer { ready = true }
        guard let url = AppSettings.shared.baseURL else { return }
        await api.configure(url)
        await perform {
            self.user = try await self.api.get("/api/me", fresh: true)
            if self.signedIn { try await self.restore(url) }
        }
    }
    func login(address: String, username: String, password: String, register: Bool) async {
        await perform {
            let url = try ServerAPI.address(address)
            if AppSettings.shared.baseURL != url { await AppSettings.shared.signOut() }
            await self.api.configure(url)
            let health = try await self.api.get("/api/health", fresh: true)
            guard health["app"].string == "sporra" else {
                throw ServerFailure(status: 0, message: "This address is not a Sporra server.")
            }
            self.user = try await self.api.post(
                register ? "/api/register" : "/api/login",
                [
                    "username": .string(username.trimmingCharacters(in: .whitespacesAndNewlines)),
                    "password": .string(password),
                ])
            AppSettings.shared.serverURL = url.absoluteString
            try await self.restore(url)
        }
    }
    private func restore(_ url: URL) async throws {
        accountEpoch += 1
        await api.configure(url, account: user["username"].string)
        prefs = try await api.get("/api/prefs")["prefs"]
        if let saved = UserDefaults.standard.dictionary(forKey: localKey) {
            style = saved["style"] as? String ?? "dark"
        }
        revision += 1
    }
    func renderQuery(_ level: Int, bbox: String? = nil) -> [URLQueryItem] {
        var q = query(["level": String(level), "mode": mode, "accent": String(accent.prefix(7))])
        if let bbox { q += query(["bbox": bbox]) }
        q += hidden.sorted().map { URLQueryItem(name: "hidden", value: $0) }
        return q
    }
    func patchPrefs(_ patch: [String: JSON]) async throws {
        // Serialise read/merge/write, otherwise two fast switches lose one another.
        let previous = preferenceWork
        let epoch = accountEpoch
        let task = Task { @MainActor in
            _ = try? await previous?.value
            guard self.accountEpoch == epoch, self.signedIn else { throw CancellationError() }
            var current = try await self.api.get("/api/prefs", fresh: true)["prefs"]
            for (key, value) in patch { current[key] = value }
            current["updatedAt"] = .number(Date().timeIntervalSince1970 * 1000)
            _ = try await self.api.post("/api/prefs", ["prefs": current])
            guard self.accountEpoch == epoch else { throw CancellationError() }
            for (key, value) in patch where self.optimisticPreferences[key] == value {
                self.optimisticPreferences.removeValue(forKey: key)
            }
            for (key, value) in self.optimisticPreferences { current[key] = value }
            self.prefs = current
            self.revision += 1
        }
        preferenceWork = task
        try await task.value
    }
    func save(_ patch: [String: JSON]) {
        for (key, value) in patch {
            prefs[key] = value
            queuedPreferences[key] = value
            optimisticPreferences[key] = value
        }
        revision += 1
        preferenceDebounce?.cancel()
        preferenceDebounce = Task {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            let values = queuedPreferences
            queuedPreferences = [:]
            preferenceDebounce = nil
            await perform {
                do { try await self.patchPrefs(values) } catch {
                    for (key, value) in values where self.optimisticPreferences[key] == value {
                        self.optimisticPreferences.removeValue(forKey: key)
                    }
                    if let current = try? await self.api.get("/api/prefs", fresh: true)["prefs"] {
                        self.prefs = current
                        for (key, value) in self.optimisticPreferences { self.prefs[key] = value }
                    }
                    throw error
                }
            }
        }
    }
    func perform(_ work: () async throws -> Void) async {
        pendingCount += 1
        busy = true
        error = nil
        defer {
            pendingCount -= 1
            busy = pendingCount > 0
        }
        do { try await work() } catch is CancellationError {} catch let cancelled as URLError
            where cancelled.code == .cancelled
        {} catch let failure as ServerFailure {
            if failure.status == 401 { await clearSession() }
            error = failure.message
        } catch { self.error = error.localizedDescription }
    }
    func report(_ failure: Error) async {
        if failure is CancellationError || (failure as? URLError)?.code == .cancelled { return }
        if (failure as? ServerFailure)?.status == 401 { await clearSession() }
        error = failure.localizedDescription
    }
    func changed() { revision += 1 }
    func checkAnnouncements() async {
        guard signedIn else { return }
        let epoch = accountEpoch
        guard
            let value = try? await api.post(
                "/api/whats-new", ["quiet": .bool(prefs["whatsNew"].string == "never")]),
            epoch == accountEpoch
        else { return }
        if value["show"].bool { notice = value }
    }
    func setFocus(_ value: JSON) {
        focus = value
        cameraCommand = UUID()
    }
    func openActivity(_ id: JSON) async {
        selectionEpoch += 1
        let epoch = selectionEpoch
        await perform {
            let data = try await self.api.get("/api/render/activity", query: query(["id": id.string]))
            guard epoch == self.selectionEpoch else { return }
            self.track = .null
            self.trackDay = nil
            self.place = .null
            self.activity = data
            self.sample = nil
            if !data["graphs"][self.metric].exists {
                self.metric = data["graphs"]["speed"].exists ? "speed" : "elev"
            }
            self.setFocus(data["route"])
        }
    }
    func closeSelection() {
        selectionEpoch += 1
        activity = .null
        track = .null
        trackDay = nil
        place = .null
        sample = nil
        solo = false
    }
    func selectTrack(day: String? = nil, trip: JSON = .null) async {
        selectionEpoch += 1
        let epoch = selectionEpoch
        await perform {
            let data = try await self.api.get(
                "/api/render/track", query: query(day.map { ["day": $0] } ?? ["trip": trip.string]))
            guard epoch == self.selectionEpoch else { return }
            self.activity = .null
            self.sample = nil
            self.place = .null
            self.track = data
            self.trackDay = day
            self.setFocus(data)
        }
    }
    func step(_ delta: Int) async {
        await perform {
            if let day = self.trackDay {
                let days = try await self.api.get("/api/days")["days"].object.keys.sorted()
                if let i = days.firstIndex(of: day), days.indices.contains(i + delta) {
                    await self.selectTrack(day: days[i + delta])
                }
            } else {
                let isActivity = self.activity.exists
                let items = try await self.api.get(isActivity ? "/api/routes?fold=1" : "/api/trips")[
                    isActivity ? "routes" : "trips"
                ].array.sorted {
                    $0[isActivity ? "firstAt" : "start"].double < $1[isActivity ? "firstAt" : "start"].double
                }
                let id = isActivity ? self.activity["route"]["id"] : self.track["id"]
                if let i = items.firstIndex(where: { $0["id"] == id }), items.indices.contains(i + delta) {
                    if isActivity {
                        await self.openActivity(items[i + delta]["id"])
                    } else {
                        await self.selectTrack(trip: items[i + delta]["id"])
                    }
                }
            }
        }
    }
    func undoEdit() async {
        let saved = undo
        await perform {
            if saved["routeUpdate"].exists {
                let route = saved["routeUpdate"]
                _ = try await self.api.post(
                    "/api/routes/update",
                    [
                        "id": route["id"], "name": route["name"], "source": route["source"],
                        "sport": route["sport"], "place": route["place"],
                    ])
            }
            if saved["route"].exists {
                _ = try await self.api.post("/api/routes", ["routes": .array([saved["route"]])])
            }
            if !saved["remove"].array.isEmpty {
                _ = try await self.api.post("/api/cells/mutate", ["remove": saved["remove"]])
            }
            if !saved["rows"].array.isEmpty {
                _ = try await self.api.post("/api/cells/restore", ["rows": saved["rows"]])
            }
            self.undo = .null
            if saved["routeUpdate"].exists && self.activity["route"]["id"] == saved["routeUpdate"]["id"] {
                await self.openActivity(saved["routeUpdate"]["id"])
            }
            self.changed()
        }
    }
    func sync() async {
        await perform {
            await SyncClient.shared.flush(force: true)
            if TrackingSettings.shared.syncWorkouts { await HealthSync.shared.sync() }
            if TrackingSettings.shared.syncPhotos { await PhotoSync.shared.scan() }
            if let error = TrackingSettings.shared.status.lastError {
                throw ServerFailure(status: 0, message: error)
            }
            await self.api.clearCache()
            self.changed()
        }
    }
    func signOut() async {
        await perform {
            _ = try? await self.api.post("/api/logout")
            await self.clearSession()
        }
    }
    private func clearSession() async {
        accountEpoch += 1
        preferenceWork?.cancel()
        preferenceDebounce?.cancel()
        queuedPreferences = [:]
        optimisticPreferences = [:]
        selectionEpoch += 1
        await api.clearCache()
        await AppSettings.shared.signOut()
        user = .null
        prefs = .object([:])
        undo = .null
        closeSelection()
        hidden = []
        photos = false
        editing = false
        solo = false
        routeChoices = []
        notice = .null
    }
}
