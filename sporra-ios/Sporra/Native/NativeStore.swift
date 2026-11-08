import Combine
import CoreLocation
import Foundation
import UIKit
import SporraCore

@MainActor
final class NativeStore: ObservableObject {
    private static let offlineRefreshInterval: TimeInterval = 15 * 60
    private var lastOfflineDownload: Date?
    private var mapHasRendered = false
    private var renderedLevel = 0
    private var pendingOfflineDownload = false
    let api = ServerAPI.shared
    @Published var ready = false
    @Published var offline = false
    @Published var connectionNotice = false
    private var connectionNoticeTask: Task<Void, Never>?
    @Published var needsSignIn = false
    @Published var reconnecting = false
    @Published var savingOffline = false
    private var connectionTask: Task<Void, Never>?
    private var reconnectWork: Task<Void, Never>?
    private var reconnectPreferences: Task<Void, Never>?
    private var reconnectID = UUID()
    private var offlineDownload: Task<Void, Never>?
    @Published var user: JSON = .null
    @Published var prefs: JSON = .object([:])
    @Published var error: String?
    @Published var busy = false
    @Published var revision = 0
    @Published var recentRoutes: [JSON] = []
    @Published var recentTrips: [JSON] = []
    @Published var recentSearchLoaded = false
    @Published var recentSearchError: String?
    private var recentSearchTask: Task<Void, Never>?
    private var lastRecentRefresh: Date?
    private var pendingTracks: [String: Task<JSON, Error>] = [:]
    private let activityDetails = ActivityDetailCache(api: .shared)
    private var activitySelectionTask: Task<Void, Never>?
    private var trackPrefetch: Task<Void, Never>?
    private var prefetchedDays: [String] = []
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
    @Published var mapCardLayout = MapCardLayout.empty
    @Published var mapControlsFrame = CGRect.null
    var mapSelectionID: String {
        if activity.exists { return "activity:" + activity["route"]["id"].string }
        if track.exists { return "track:" + (trackDay ?? track["id"].string) }
        if place.exists { return "place:" + placeCardID }
        return "none"
    }
    @Published var cameraCommand = UUID()
    @Published var locationCommand = UUID()
    @Published var locationFocused = false
    @Published private(set) var foregroundCells: Set<String> = []
    @Published var snapshotCommand = UUID()
    @Published var shareURL: URL?
    @Published var notice: JSON = .null
    @Published var routeChoices: [JSON] = []
    @Published var solo = false
    @Published var lightClock = Date()
    private var pendingCount = 0
    private var accountEpoch = 0
    private var selectionEpoch = 0
    private var placeDetails: [(key: String, value: JSON)] = []
    private var steppingSelection = false
    private var preferenceWork: Task<Void, Error>?
    private var preferenceDebounce: Task<Void, Never>?
    private var queuedPreferences: [String: JSON] = [:]
    private var optimisticPreferences: [String: JSON] = [:]
    var signedIn: Bool { user["username"].exists }
    var mode: String { prefs["heatMode"].text("flat") }
    var accent: String {
        prefs["accents"][style == "voyager" ? "light" : "dark"].text(
            prefs["accent"].text("#60acff"))
    }
    var opacity: Double {
        prefs["mapOpacities"][mode].exists
            ? prefs["mapOpacities"][mode].double : (mode == "flat" ? 0.3 : 0.5)
    }
    var token: String { prefs["mapboxToken"].string }
    var useMapbox: Bool { !token.isEmpty && ["mapbox", "satellite"].contains(style) }
    var localKey: String { "native-map:\(AppSettings.shared.serverURL):\(user["username"].string)" }
    func initialize() async {
        connectionTask = Task { [weak self, api] in
            for await unavailable in api.connectionChanges {
                guard let self else { return }
                self.offline = unavailable
                if unavailable { self.editing = false }
            }
        }
        guard let url = AppSettings.shared.baseURL else {
            ready = true
            return
        }
        if let saved = await api.savedAccount(for: url) {
            user = saved["user"]
            prefs = saved["prefs"]
            optimisticPreferences = saved["pending"].object
            await api.configure(url, account: user["username"].string)
            // Restore the map immediately, but let initial reads reach the
            // server while the session check runs in the background.
            restoreCameraPreference()
            ready = true
            Task { await self.prepareRecentSearch() }
            Task { await self.reconnect() }
            return
        }
        await api.configure(url)
        await perform {
            self.user = try await self.api.get("/api/me", fresh: true)
            if self.signedIn { try await self.restore(url) }
        }
        ready = true
    }
    private func restoreCameraPreference() {
        if let saved = UserDefaults.standard.dictionary(forKey: localKey) {
            style = saved["style"] as? String ?? "dark"
        }
    }
    func beginSignIn() {
        user = .null
        needsSignIn = false
    }
    func reconnect(force: Bool = false) async {
        guard signedIn else { return }
        if force {
            connectionNoticeTask?.cancel()
            connectionNotice = true
            reconnectWork?.cancel()
            reconnectWork = nil
            reconnectPreferences?.cancel()
        }
        if let pending = reconnectWork { await pending.value; return }
        let id = UUID()
        reconnectID = id
        let work = Task { await self.checkConnection(id) }
        reconnectWork = work
        await work.value
        if reconnectID == id { reconnectWork = nil }
    }
    private func checkConnection(_ id: UUID) async {
        guard !Task.isCancelled, reconnectID == id else { return }
        reconnecting = true
        defer { if reconnectID == id { reconnecting = false } }
        let epoch = accountEpoch
        do {
            let live = try await api.validateSession()
            guard epoch == accountEpoch, reconnectID == id, !Task.isCancelled else { return }
            guard live["username"] == user["username"] else {
                needsSignIn = true
                offline = true
                await api.setOffline(true)
                return
            }
            user = live
            needsSignIn = false
            offline = false
            connectionNotice = false
            await api.setOffline(false)
            // A verified session refreshes the map immediately; preference
            // reads must not keep Retry spinning behind another slow endpoint.
            changed()
            reconnectPreferences?.cancel()
            reconnectPreferences = Task { [weak self] in
                guard let self else { return }
                do {
                    if !optimisticPreferences.isEmpty { try await patchPrefs(optimisticPreferences) }
                    else {
                        let fresh = try await api.get("/api/prefs", fresh: true)["prefs"]
                        guard epoch == accountEpoch, reconnectID == id, !Task.isCancelled else { return }
                        prefs = fresh
                    }
                    guard epoch == accountEpoch, reconnectID == id, !Task.isCancelled else { return }
                    await persistAccount()
                    changed()
                    downloadOfflineData()
                } catch {
                    guard epoch == accountEpoch, reconnectID == id, !Task.isCancelled else { return }
                    await report(error)
                }
            }
        } catch {
            guard epoch == accountEpoch, reconnectID == id, !Task.isCancelled else { return }
            if (error as? ServerFailure)?.status == 401 {
                needsSignIn = true
                offline = true
                await api.setOffline(true)
            } else if ServerAPI.isUnavailable(error) {
                offline = true
                await api.setOffline(true)
            } else {
                showConnectionNotice()
            }
        }
    }
    private func persistAccount() async {
        await api.saveAccount(user: user, prefs: prefs, pending: optimisticPreferences)
    }
    func prepareRecentSearch(force: Bool = false) async {
        guard signedIn else { return }
        let epoch = accountEpoch
        if !recentSearchLoaded {
            let routes = await api.cachedGet("/api/routes?fold=1")
            let trips = await api.cachedGet("/api/trips")
            guard epoch == accountEpoch else { return }
            if let routes { recentRoutes = routes["routes"].array }
            if let trips { recentTrips = trips["trips"].array }
            recentSearchLoaded = routes != nil && trips != nil
        }
        if offline {
            recentSearchLoaded = true
            recentSearchError = recentRoutes.isEmpty && recentTrips.isEmpty
                ? "Recent trips and activities are not saved on this device yet." : nil
            return
        }
        guard recentSearchTask == nil else { return }
        if !force, let lastRecentRefresh, Date().timeIntervalSince(lastRecentRefresh) < 60 { return }
        recentSearchTask = Task {
            defer { if epoch == accountEpoch { recentSearchTask = nil } }
            // Publish each response as it arrives; a slow trips calculation
            // must never hold back already-available activities.
            async let routes = refreshRecentPart("/api/routes?fold=1", epoch: epoch)
            async let trips = refreshRecentPart("/api/trips", epoch: epoch)
            let (routesOK, tripsOK) = await (routes, trips)
            guard epoch == accountEpoch, !Task.isCancelled else { return }
            recentSearchLoaded = true
            recentSearchError = !routesOK && !tripsOK && recentRoutes.isEmpty && recentTrips.isEmpty
                ? "Recent trips and activities could not be loaded." : nil
            if routesOK || tripsOK { lastRecentRefresh = Date() }
        }
    }
    private func refreshRecentPart(_ path: String, epoch: Int) async -> Bool {
        guard let data = try? await api.get(path, fresh: true), epoch == accountEpoch,
            !Task.isCancelled else { return false }
        if path == "/api/trips" { recentTrips = data["trips"].array }
        else { recentRoutes = data["routes"].array }
        recentSearchError = nil
        return true
    }
    private func resetRecentSearch() {
        reconnectWork?.cancel()
        reconnectPreferences?.cancel()
        reconnectWork = nil
        reconnectID = UUID()
        reconnecting = false
        foregroundCells = []
        resetTrackRequests()
        recentSearchTask?.cancel()
        recentSearchTask = nil
        lastRecentRefresh = nil
        recentRoutes = []
        recentTrips = []
        recentSearchLoaded = false
        recentSearchError = nil
    }
    func mapDidRender(level: Int) {
        renderedLevel = level
        guard !mapHasRendered else { return }
        mapHasRendered = true
        if MapPerformance.enabled {
            let epoch = accountEpoch
            Task(priority: .utility) {
                guard let routes = try? await api.get("/api/routes"), epoch == accountEpoch else { return }
                let sizes = await api.activityStorageSummary(routes: routes["routes"].array)
                for key in sizes.keys.sorted() {
                    MapPerformance.report("activity-storage-" + key, since: .now, count: sizes[key] ?? 0)
                }
            }
        }
        if pendingOfflineDownload { pendingOfflineDownload = false; downloadOfflineData() }
    }
    func downloadOfflineData(force: Bool = false) {
        guard signedIn, !offline, !savingOffline else { return }
        if !force, !mapHasRendered { pendingOfflineDownload = true; return }
        if !force, let lastOfflineDownload,
            Date().timeIntervalSince(lastOfflineDownload) < Self.offlineRefreshInterval
        {
            return
        }
        offlineDownload?.cancel()
        let epoch = accountEpoch
        offlineDownload = Task {
            savingOffline = true
            defer { if epoch == accountEpoch { savingOffline = false } }
            let paths = force ? [
                "/api/routes?fold=1", "/api/render/routes", "/api/days", "/api/trips", "/api/stats",
                "/api/render/activity-stats", "/api/sources",
            ] : ["/api/render/routes", "/api/days"]
            do {
                if !force { try await Task.sleep(for: .seconds(3)) }
                // Prepare zoomed-out shading before large route/history downloads.
                // Coarse boundaries never wait for remote detailed country data.
                for level in 6...8 {
                    try Task.checkCancellation()
                    let parameters = renderQuery(level) + query(["info": "0", "fine": "0"])
                    if !force, await api.hasSavedGet("/api/render/regions", query: parameters) { continue }
                    _ = try await api.get("/api/render/regions", query: parameters)
                    guard epoch == accountEpoch, !(await api.isOffline()) else { return }
                }
                for path in paths {
                    if !force, await api.hasSavedGet(path, query: []) { continue }
                    try Task.checkCancellation()
                    let value = try await api.get(path)
                    guard epoch == accountEpoch else { return }
                    if path == "/api/routes?fold=1" { recentRoutes = value["routes"].array }
                    if path == "/api/trips" { recentTrips = value["trips"].array }
                    guard epoch == accountEpoch, !(await api.isOffline()) else { return }
                }
                // World snapshots make cached visits independent of camera size,
                // orientation and zoom after a cold launch.
                let levels = force ? Array((0...8).reversed())
                    : renderedLevel < 6 ? Array(max(0, renderedLevel - 1)...min(5, renderedLevel + 1)) : [renderedLevel]
                for level in levels {
                    try Task.checkCancellation()
                    let path = level < 6 ? "/api/render/cells" : "/api/render/regions"
                    let parameters = renderQuery(level) + query(["info": "0", "fine": level < 6 || force ? "1" : "0"])
                    if !force, await api.hasSavedGet(path, query: parameters) { continue }
                    if level < 6 || !force { _ = try await api.get(path, query: parameters) }
                    else { _ = try await api.regionSnapshot(query: parameters) }
                    guard epoch == accountEpoch, !(await api.isOffline()) else { return }
                }
                lastOfflineDownload = Date()
            } catch { /* Offline preparation is opportunistic, never a blocking dialog. */  }
        }
    }
    func login(address: String, username: String, password: String, register: Bool) async {
        await perform {
            let url = try ServerAPI.address(address)
            let previousAccount = await self.api.savedAccount(for: url)
            self.accountEpoch += 1
            self.placeDetails = []
            self.resetRecentSearch()
            self.offlineDownload?.cancel()
            self.preferenceDebounce?.cancel()
            self.preferenceWork?.cancel()
            let previousUsername = previousAccount?["user"]["username"].string ?? ""
            let changingAccount = !previousUsername.isEmpty
                && previousUsername != username.trimmingCharacters(in: .whitespacesAndNewlines)
            if AppSettings.shared.baseURL != url || changingAccount { await AppSettings.shared.signOut() }
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
            if previousAccount?["user"]["username"] == self.user["username"] {
                self.optimisticPreferences = previousAccount?["pending"].object ?? [:]
            } else {
                self.optimisticPreferences = [:]
            }
            self.queuedPreferences = [:]
            AppSettings.shared.serverURL = url.absoluteString
            try await self.restore(url)
        }
    }
    private func restore(_ url: URL) async throws {
        accountEpoch += 1
        placeDetails = []
        lastOfflineDownload = nil
        savingOffline = false
        await api.configure(url, account: user["username"].string)
        prefs = try await api.get("/api/prefs")["prefs"]
        restoreCameraPreference()
        offline = false
        needsSignIn = false
        if !optimisticPreferences.isEmpty { try await patchPrefs(optimisticPreferences) }
        await persistAccount()
        Task { await self.prepareRecentSearch() }
        downloadOfflineData()
        revision += 1
    }
    func renderQuery(_ level: Int, bbox: String? = nil) -> [URLQueryItem] {
        var q = query(["level": String(level), "mode": mode, "accent": String(accent.prefix(7))])
        if let bbox { q += query(["bbox": bbox]) }
        q += hidden.sorted().map { URLQueryItem(name: "hidden", value: $0) }
        return q
    }
    func patchPrefs(_ patch: [String: JSON]) async throws {
        let unavailable = await api.isOffline()
        if offline || unavailable {
            for (key, value) in patch {
                prefs[key] = value
                optimisticPreferences[key] = value
            }
            await persistAccount()
            return
        }
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
            await self.persistAccount()
            if patch.keys.contains(where: { $0 != "mapOpacities" }) { self.revision += 1 }
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
        if patch.keys.contains(where: { $0 != "mapOpacities" }) { revision += 1 }
        Task { await self.persistAccount() }
        preferenceDebounce?.cancel()
        preferenceDebounce = Task {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            let values = queuedPreferences
            queuedPreferences = [:]
            preferenceDebounce = nil
            await perform {
                do { try await self.patchPrefs(values) } catch {
                    if ServerAPI.isUnavailable(error) {
                        self.offline = await self.api.isOffline()
                        await self.persistAccount()
                        return
                    }
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
        {} catch { await report(error) }
    }
    private func showConnectionNotice() {
        error = nil
        connectionNotice = true
        connectionNoticeTask?.cancel()
        connectionNoticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            self?.connectionNotice = false
        }
    }
    func report(_ failure: Error) async {
        if failure is CancellationError || (failure as? URLError)?.code == .cancelled { return }
        if (failure as? ServerFailure)?.status == 401 && signedIn {
            needsSignIn = true
            offline = true
            await api.setOffline(true)
            return
        }
        if ServerAPI.isUnavailable(failure) && signedIn {
            offline = await api.isOffline()
            showConnectionNotice()
            return
        }
        if signedIn, ServerAPI.isQuietReadFailure(failure) { showConnectionNotice(); return }
        error = failure.localizedDescription
    }
    func changed() { revision += 1 }
    func checkAnnouncements() async {
        guard signedIn, !offline else { return }
        let epoch = accountEpoch
        guard
            let value = try? await api.post(
                "/api/whats-new", ["quiet": .bool(prefs["whatsNew"].string == "never")]),
            epoch == accountEpoch
        else { return }
        if value["show"].bool { notice = value }
    }
    func recordForegroundFix(_ fix: FixQueue.Fix) {
        guard signedIn else { return }
        foregroundCells.insert(HexGrid.cellId(level: 0, lat: fix.lat, lng: fix.lng))
    }
    func restorePendingCells() {
        foregroundCells.formUnion(FixQueue.shared.head(limit: 50_000).map {
            HexGrid.cellId(level: 0, lat: $0.lat, lng: $0.lng)
        })
    }
    func confirmForegroundCells(_ ids: Set<String>) {
        guard !foregroundCells.isDisjoint(with: ids) else { return }
        foregroundCells.subtract(ids)
    }
    func setFocus(_ value: JSON) {
        locationFocused = false
        focus = value
        cameraCommand = UUID()
    }
    func openActivity(_ id: JSON, preview: JSON = .null, refresh: Bool = false) async {
        if !refresh, activity["route"]["id"].string == id.string, activity["loading"].bool,
            let activitySelectionTask {
            await activitySelectionTask.value
            return
        }
        selectionEpoch += 1
        let epoch = selectionEpoch, account = accountEpoch
        let scope = "\(localKey):\(account)"
        activitySelectionTask?.cancel()
        let clock = ContinuousClock.now
        let metadata = preview.exists ? preview
            : recentRoutes.first { $0["id"].string == id.string }
                ?? (activity["route"]["id"].string == id.string ? activity["route"] : .null)
        track = .null
        trackDay = nil
        place = .null
        solo = true
        sample = nil
        if !refresh { activity = ActivityPresentation.preview(id: id, route: metadata) }
        MapPerformance.report("activity-card", since: clock)
        // This task survives cancellation of the map gesture. Only a new
        // selection, dismissal or account change can make its result obsolete.
        let work = Task { [weak self] in
            guard let self else { return }
            @MainActor func isCurrent() -> Bool {
                !Task.isCancelled && epoch == self.selectionEpoch && account == self.accountEpoch
            }
            var displayed = refresh
            @MainActor func display(_ data: JSON, focus: Bool) {
                self.activity = data
                if !data["graphs"][self.metric].exists {
                    self.metric = data["graphs"]["speed"].exists ? "speed" : "elev"
                }
                if focus && !refresh { self.setFocus(data["route"]) }
                displayed = true
            }
            if !refresh, let cached = await self.activityDetails.cached(id.string, scope: scope) {
                guard isCurrent() else { return }
                display(cached, focus: true)
                MapPerformance.report("activity-cached", since: clock)
                if self.offline { return }
            }
            do {
                let data = try await self.activityDetails.load(id.string, scope: scope, refresh: refresh)
                guard isCurrent() else { return }
                display(data, focus: !displayed)
            } catch {
                guard isCurrent() else { return }
                if !displayed {
                    self.activity["loading"] = .bool(false)
                    self.activity["detailsError"] = .string("Activity details could not be loaded.")
                    await self.report(error)
                }
            }
        }
        activitySelectionTask = work
        await work.value
    }
    var placeCardID: String {
        place["selectionID"].text(place["name"].string + place["code"].string)
    }
    @discardableResult
    func showPlace(_ value: JSON) -> Int {
        closeSelection()
        var value = value
        value["selectionID"] = .string(UUID().uuidString)
        place = value
        return selectionEpoch
    }
    func selectPlace(_ initial: JSON, query: [URLQueryItem]) async {
        let epoch = showPlace(initial)
        let identity = place["selectionID"]
        let selectedAccount = accountEpoch, selectedRevision = revision, selectedHidden = hidden
        func isCurrent() -> Bool {
            epoch == selectionEpoch && !Task.isCancelled && selectedAccount == accountEpoch
                && selectedRevision == revision && selectedHidden == hidden
        }
        let placeID = initial["cellID"].text(initial["area"]["kind"].string + ":" + initial["area"]["id"].string)
        let cacheKey = "\(accountEpoch):\(revision):\(hidden.sorted()):\(initial["level"].string):\(placeID)"
        let reusable = initial["cellID"].exists || initial["area"]["id"].exists
        let memory = reusable ? placeDetails.first { $0.key == cacheKey }?.value : nil
        let cached: JSON?
        if let memory { cached = memory }
        else { cached = await api.cachedGet("/api/render/at", query: query) }
        guard isCurrent() else { return }
        func display(_ data: JSON) {
            var value = data
            // Cells have no server geometry; keep the locally computed ring.
            if !value["geometry"].exists { value["geometry"] = initial["geometry"] }
            value["selectionID"] = identity
            value["loading"] = .bool(false)
            place = value
        }
        if let cached { display(cached) }
        if memory != nil || (cached != nil && offline) { return }
        do {
            let data = try await api.get("/api/render/at", query: query)
            guard isCurrent() else { return }
            if reusable && (!initial["area"]["id"].exists || initial["area"]["id"] == data["area"]["id"]) {
                placeDetails.removeAll { $0.key == cacheKey }
                placeDetails.append((cacheKey, data))
                if placeDetails.count > 32 { placeDetails.removeFirst() }
            }
            display(data)
        } catch {
            guard isCurrent() else { return }
            place["loading"] = .bool(false)
            if cached == nil { place["detailsError"] = .string("Visit details are unavailable. Tap the map to retry.") }
            await report(error)
        }
    }
    func enrichRouteChoices() async {
        var expectedIDs = Set(routeChoices.map { $0["id"].string })
        let selection = selectionEpoch
        let epoch = accountEpoch
        guard !expectedIDs.isEmpty else { return }
        func apply(_ routes: [JSON], aliases: [String: String] = [:]) {
            guard !Task.isCancelled, accountEpoch == epoch, selectionEpoch == selection,
                Set(routeChoices.map { $0["id"].string }) == expectedIDs else { return }
            routeChoices = ActivityChoices.enrich(routeChoices, metadata: routes, aliases: aliases)
            expectedIDs = Set(routeChoices.map { $0["id"].string })
        }
        apply(recentRoutes)
        if let cached = await api.cachedGet("/api/routes?fold=1") { apply(cached["routes"].array, aliases: cached["duplicates"].object.mapValues(\.string)) }
        guard !Task.isCancelled, accountEpoch == epoch, selectionEpoch == selection,
            Set(routeChoices.map { $0["id"].string }) == expectedIDs,
            routeChoices.contains(where: { !$0["firstAt"].exists }), !offline else { return }
        if let fresh = try? await api.get("/api/routes?fold=1") { apply(fresh["routes"].array, aliases: fresh["duplicates"].object.mapValues(\.string)) }
    }
    func closeSelection() {
        activitySelectionTask?.cancel()
        activitySelectionTask = nil
        selectionEpoch += 1
        activity = .null
        track = .null
        trackDay = nil
        place = .null
        sample = nil
        solo = false
    }
    private func trackPath(day: String? = nil, trip: JSON = .null) -> String {
        var parts = URLComponents()
        parts.path = "/api/render/track"
        parts.queryItems = query(day.map { ["day": $0] } ?? ["trip": trip.string])
        return parts.string!
    }
    private func fetchTrack(_ path: String) async throws -> JSON {
        if let pending = pendingTracks[path] { return try await pending.value }
        let epoch = accountEpoch
        let work = Task { try await self.api.get(path, fresh: true) }
        pendingTracks[path] = work
        defer { if epoch == accountEpoch { pendingTracks[path] = nil } }
        let data = try await work.value
        guard epoch == accountEpoch else { throw CancellationError() }
        return data
    }
    func prefetchTrackDays(_ days: [String]) {
        let wanted = Array(days.prefix(12))
        guard !wanted.isEmpty, wanted != prefetchedDays, !offline else { return }
        prefetchedDays = wanted
        trackPrefetch?.cancel()
        let epoch = accountEpoch
        trackPrefetch = Task(priority: .utility) {
            // Keep server work bounded while preparing the first visible days.
            for start in stride(from: 0, to: wanted.count, by: 2) {
                guard !Task.isCancelled, epoch == accountEpoch else { return }
                await withTaskGroup(of: Void.self) { group in
                    for day in wanted[start..<min(start + 2, wanted.count)] {
                        group.addTask { await self.prefetchTrackDay(day, epoch: epoch) }
                    }
                }
            }
        }
    }
    private func prefetchTrackDay(_ day: String, epoch: Int) async {
        guard epoch == accountEpoch, !Task.isCancelled else { return }
        let path = trackPath(day: day)
        if await api.cachedGet(path) != nil { return }
        guard epoch == accountEpoch, !Task.isCancelled else { return }
        _ = try? await fetchTrack(path)
    }
    private func resetTrackRequests() {
        trackPrefetch?.cancel()
        trackPrefetch = nil
        prefetchedDays = []
        for task in pendingTracks.values { task.cancel() }
        pendingTracks = [:]
    }
    func selectTrack(day: String? = nil, trip: JSON = .null) async {
        selectionEpoch += 1
        let epoch = selectionEpoch
        let path = trackPath(day: day, trip: trip)
        await perform {
            let cached = await self.api.cachedGet(path)
            let data: JSON
            if let cached { data = cached }
            else { data = try await self.fetchTrack(path) }
            guard epoch == self.selectionEpoch else { return }
            self.activity = .null
            self.sample = nil
            self.place = .null
            self.track = data
            self.trackDay = day
            self.setFocus(data)
            if day == nil { self.prefetchTrackDays(TrackCardNavigation.days(in: data)) }
            // Cached days open immediately. Revalidate without delaying the tap,
            // and never replace a newer selection with a late response.
            if cached != nil && !self.offline {
                Task {
                    guard let fresh = try? await self.fetchTrack(path), epoch == self.selectionEpoch else { return }
                    self.track = fresh
                    if day == nil { self.prefetchTrackDays(TrackCardNavigation.days(in: fresh)) }
                }
            }
        }
    }
    func step(_ delta: Int) async {
        guard !steppingSelection else { return }
        steppingSelection = true
        defer { steppingSelection = false }
        let epoch = selectionEpoch
        await perform {
            if let day = self.trackDay {
                let data: JSON
                if let cached = await self.api.cachedGet("/api/days") { data = cached }
                else { data = try await self.api.get("/api/days") }
                guard epoch == self.selectionEpoch else { return }
                let days = data["days"].object.keys.sorted()
                if let i = days.firstIndex(of: day), days.indices.contains(i + delta) {
                    await self.selectTrack(day: days[i + delta])
                }
            } else {
                let isActivity = self.activity.exists
                let path = isActivity ? "/api/routes?fold=1" : "/api/trips"
                let data: JSON
                if let cached = await self.api.cachedGet(path) { data = cached }
                else { data = try await self.api.get(path) }
                guard epoch == self.selectionEpoch else { return }
                let items = data[isActivity ? "routes" : "trips"].array.sorted {
                        $0[isActivity ? "firstAt" : "start"].double
                            < $1[isActivity ? "firstAt" : "start"].double
                }
                let id = isActivity ? self.activity["route"]["id"] : self.track["id"]
                if let i = items.firstIndex(where: { $0["id"] == id }),
                    items.indices.contains(i + delta)
                {
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
            if saved["routeUpdate"].exists
                && self.activity["route"]["id"] == saved["routeUpdate"]["id"]
            {
                await self.openActivity(saved["routeUpdate"]["id"], refresh: true)
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
            await self.api.invalidateHTTPCache()
            self.changed()
            self.downloadOfflineData(force: true)
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
        placeDetails = []
        resetRecentSearch()
        offlineDownload?.cancel()
        savingOffline = false
        preferenceWork?.cancel()
        preferenceDebounce?.cancel()
        queuedPreferences = [:]
        optimisticPreferences = [:]
        selectionEpoch += 1
        await api.forgetAccount()
        await AppSettings.shared.signOut()
        offline = false
        needsSignIn = false
        user = .null
        prefs = .object([:])
        undo = .null
        closeSelection()
        hidden = []
        photos = false
        locationFocused = false
        foregroundCells = []
        LocationLogger.shared.setForegroundRecording(false)
        editing = false
        solo = false
        routeChoices = []
        notice = .null
    }
}
