import CoreLocation
import Photos
import SporraCore
import SwiftUI
import UIKit

private let activityTapRadius: CGFloat = 16

nonisolated struct NativeMapImage: @unchecked Sendable { let image: UIImage }

actor NativeBlobPainter {
    private var renderer: BlobRenderer?
    func paint(_ data: JSON, bounds b: [Double], width: Int, height: Int, heat: Bool) async throws -> NativeMapImage {
        try Task.checkCancellation()
        guard await MainActor.run(body: { UIApplication.shared.applicationState == .active }) else {
            throw CancellationError()
        }
        if renderer == nil { renderer = try BlobRenderer() }
        let world = 40075016.68557849
        let west = b[0] / 360 * world
        var east = b[2] / 360 * world
        if east <= west { east += world }
        func mercY(_ lat: Double) -> Double {
            log(tan(.pi / 4 + min(85.051129, max(-85.051129, lat)) * .pi / 360)) * world / (2 * .pi)
        }
        let north = mercY(b[3])
        let south = mercY(b[1])
        let scale = Double(width) / (east - west)
        let unit = max(0.85, data["radius"].double * scale)
        let discs = data["rows"].array.compactMap { row -> BlobDisc? in
            let x = row[1].double + (((west + east) / 2 - row[1].double) / world).rounded() * world
            let y = row[2].double
            guard x >= west - data["radius"].double * 3, x <= east + data["radius"].double * 3,
                y >= south - data["radius"].double * 3, y <= north + data["radius"].double * 3
            else { return nil }
            let color = UIColor(mapColor: row[3].string)
            var r: CGFloat = 0
            var g: CGFloat = 0
            var blue: CGFloat = 0
            var a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &blue, alpha: &a)
            return BlobDisc(
                center: SIMD2(
                    Float((x - west) * scale),
                    Float((north - row[2].double) / (north - south) * Double(height))),
                radius: Float(row[4].bool ? max(unit * 0.9, 2) : unit * 0.9),
                color: SIMD4(Float(r), Float(g), Float(blue), 1))
        }
        guard
            let bytes = renderer?.renderPixels(
                discs: discs, size: (width, height), unit: unit,
                edge: heat ? BlobShaping.heatEdge : BlobShaping.edge, featherPx: 1),
            let provider = CGDataProvider(data: Data(bytes) as CFData),
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw ServerFailure(status: 0, message: "Unable to draw your visited map.") }
        let result = UIImage(cgImage: image)
        return NativeMapImage(image: result)
    }
}

struct NativeMap: UIViewControllerRepresentable {
    @ObservedObject var store: NativeStore
    func makeUIViewController(context: Context) -> NativeMapController { NativeMapController(store: store) }
    func updateUIViewController(_ controller: NativeMapController, context: Context) { controller.update() }
    static func dismantleUIViewController(_ controller: NativeMapController, coordinator: ()) {
        controller.stop()
    }
}

final class NativeMapController: UIViewController, CLLocationManagerDelegate, UIGestureRecognizerDelegate {
    let store: NativeStore
    private var engine: (any MapEngine)?
    private var styleKey = ""
    private var renderState = MapRenderState()
    private var overlayKey = ""
    private var foregroundCellKey = ""
    private var knownVisitedCells: Set<String> = []
    private var loadTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var routeTask: Task<Void, Never>?
    private var routeData = ActivityMapSelection.empty
    private var routeAccount = ""
    private var cameraRefreshTask: Task<Void, Never>?
    private var routeState = MapRenderState()
    private let cells = CellViewportCache(api: .shared)
    private let regions = RegionSnapshotCache(api: .shared)
    private var paintedViewport: (content: String, bounds: [Double], zoom: Double)?
    private var lastPaint: (bounds: [Double], data: JSON, heat: Bool)?
    private var appliedOpacity: Double?
    private var pendingFocus: (value: JSON, selection: String)?
    private var focusTask: Task<Void, Never>?
    private var focusReadiness = MapFocusReadiness()
    private var regionMemory: [String: (data: JSON, fine: Bool)] = [:]
    private let startup = ContinuousClock.now
    private var overlayTask: Task<Void, Never>?
    private var tapGeneration = 0
    private var tapTask: Task<Void, Never>?
    private var placeFacts: MapPlaceFacts?
    private var cameraID = UUID(), locationID = UUID(), snapshotID = UUID()
    private struct Selection: Equatable {
        let metric: JSON
        let track: JSON
        let outline: JSON
        let focus: JSON
        let sample: JSON
    }
    private var lastSelection: Selection?
    private var loaded = false
    private var level = 0
    private var location = CLLocationManager()
    private var wantsLocation = false
    private var lastFocusedCoordinate: CLLocationCoordinate2D?
    private let painter = NativeBlobPainter()
    private var photos: [PhotoLibrary.Located] = []
    private var routeHits: [String] = ["activities"]
    private var airportHits: [String] = []
    private var railLayers: [String] = []
    private var stroke: [[Double]] = []
    private var brushPan: UIPanGestureRecognizer?
    init(store: NativeStore) {
        self.store = store
        // Commands are events. Mounting the map must not export or request GPS.
        cameraID = store.cameraCommand
        locationID = store.locationCommand
        snapshotID = store.snapshotCommand
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        location.delegate = self
        NotificationCenter.default.addObserver(
            self, selector: #selector(suspendRendering),
            name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(resumeRendering),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        update()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyPendingFocus()
        // The style may finish loading before the map has usable bounds.
        scheduleRender()
    }
    @objc private func suspendRendering() {
        focusTask?.cancel()
        focusTask = nil
        focusReadiness.reset()
        renderState.invalidate()
        routeState.invalidate()
        paintedViewport = nil
        lastPaint = nil
        appliedOpacity = nil
        renderTask?.cancel()
        routeTask?.cancel()
        cameraRefreshTask?.cancel()
        cameraRefreshTask = nil
    }
    @objc private func resumeRendering() {
        // Redraw even at the same camera position, without depending on a
        // successful server reconnect or a camera movement to trigger it.
        renderState.invalidate()
        routeState.invalidate()
        paintedViewport = nil
        lastPaint = nil
        appliedOpacity = nil
        lastSelection = nil
        if engine == nil { styleKey = "" }
        update()
    }
    func update() {
        guard isViewLoaded else { return }
        let light = store.prefs["mapboxLight"].text("auto")
        let resolvedLight =
            light == "auto"
            ? Self.sunPhase(store.lightClock, coordinate: location.location?.coordinate) : light
        let key = "\(store.style):\(store.token):\(resolvedLight):\(store.useMapbox && store.offline)"
        if styleKey != key {
            styleKey = key
            install()
            return
        }
        guard loaded, let engine else { return }
        brushPan?.isEnabled = store.editing && !store.clearingRegion && !store.offline
        if cameraID != store.cameraCommand {
            cameraID = store.cameraCommand
            focusTask?.cancel()
            focusTask = nil
            focusReadiness.reset()
            pendingFocus = (store.focus, store.mapSelectionID)
        }
        applyPendingFocus()
        if appliedOpacity != store.opacity {
            engine.setVisitOpacity(store.opacity)
            appliedOpacity = store.opacity
        }
        if locationID != store.locationCommand {
            locationID = store.locationCommand
            locate()
        }
        if snapshotID != store.snapshotCommand {
            snapshotID = store.snapshotCommand
            snapshot()
        }
        let selection = Selection(
            metric: store.activity["lines"][store.metric], track: store.track["track"],
            outline: store.place["geometry"], focus: store.focus,
            sample: store.sample.map { store.activity["samples"][$0] } ?? .null)
        if lastSelection != selection {
            lastSelection = selection
            try? selectionLayers(engine)
        }
        refreshForegroundCells()
        scheduleRender()
        refreshOverlays()
    }
    func stop() {
        focusTask?.cancel()
        focusTask = nil
        focusReadiness.reset()
        NotificationCenter.default.removeObserver(self)
        renderState.invalidate()
        routeState.invalidate()
        paintedViewport = nil
        lastPaint = nil
        appliedOpacity = nil
        tapGeneration += 1
        tapTask?.cancel()
        loadTask?.cancel()
        renderTask?.cancel()
        routeTask?.cancel()
        cameraRefreshTask?.cancel()
        cameraRefreshTask = nil
        overlayTask?.cancel()
        engine?.ready = nil
        engine?.moved = nil
        location.stopUpdatingLocation()
        wantsLocation = false
    }
    private static var offlineStyle: JSON {
        .object([
            "version": .number(8), "sources": .object([:]),
            "layers": .array([
                .object([
                    "id": .string("offline-background"), "type": .string("background"),
                    "paint": .object(["background-color": .string("#20252b")]),
                ])
            ]),
        ])
    }
    private func install() {
        focusTask?.cancel()
        focusTask = nil
        focusReadiness.reset()
        tapGeneration += 1
        tapTask?.cancel()
        placeFacts = nil
        loaded = false
        renderState.invalidate()
        routeState.invalidate()
        paintedViewport = nil
        lastPaint = nil
        appliedOpacity = nil
        loadTask?.cancel()
        renderTask?.cancel()
        routeTask?.cancel()
        cameraRefreshTask?.cancel()
        cameraRefreshTask = nil
        overlayTask?.cancel()
        let old = engine?.camera
        engine?.ready = nil
        engine?.moved = nil
        engine?.view.removeFromSuperview()
        engine = nil
        overlayKey = ""
        foregroundCellKey = ""
        lastSelection = nil
        let key = styleKey
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let new: any MapEngine
                if store.useMapbox && !store.offline {
                    let light = store.prefs["mapboxLight"].text("auto")
                    new = BoxEngine(
                        frame: view.bounds, token: store.token, satellite: store.style == "satellite",
                        light: light == "auto"
                            ? Self.sunPhase(store.lightClock, coordinate: location.location?.coordinate)
                            : light)
                } else {
                    var styleURL: URL
                    if ["satellite", "terrain"].contains(store.style) {
                        let style: JSON
                        do {
                            style = try await store.api.get(
                                "/api/render/style", query: query(["name": store.style]))
                        } catch {
                            guard store.offline else { throw error }
                            style = Self.offlineStyle
                        }
                        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
                            "sporra-\(store.style).json")
                        try style.data.write(to: url, options: .atomic)
                        styleURL = url
                    } else {
                        let remote = URL(
                            string:
                                "https://basemaps.cartocdn.com/gl/\(store.style == "voyager" ? "voyager" : "dark-matter")-gl-style/style.json"
                        )!
                        let local = FileManager.default.temporaryDirectory.appendingPathComponent(
                            "sporra-\(store.style).json")
                        do {
                            let bytes = try await store.api.publicResource(remote)
                            try bytes.write(to: local, options: .atomic)
                        } catch {
                            guard store.offline else { throw error }
                            let fallback = Self.offlineStyle
                            try fallback.data.write(to: local, options: .atomic)
                        }
                        styleURL = local
                    }
                    new = LibreEngine(frame: view.bounds, styleURL: styleURL)
                }
                guard !Task.isCancelled, styleKey == key else { return }
                engine = new
                view.insertSubview(new.view, at: 0)
                new.ready = { [weak self] in
                    self?.loaded = true
                    self?.renderState.invalidate()
                    self?.overlayKey = ""
                    self?.foregroundCellKey = ""
                    self?.lastSelection = nil
                    self?.update()
                }
                new.moved = { [weak self] in self?.mapMoved() }
                if let box = new as? BoxEngine {
                    box.tapped = { [weak self] point, town in self?.handleTap(point, town: town) }
                } else {
                    let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
                    tap.delegate = self
                    new.view.addGestureRecognizer(tap)
                }
                let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
                pan.minimumNumberOfTouches = 1
                pan.maximumNumberOfTouches = 1
                pan.delegate = self
                pan.isEnabled = store.editing
                new.view.addGestureRecognizer(pan)
                brushPan = pan
                for recognizer in new.view.gestureRecognizers ?? []
                where recognizer !== pan && recognizer is UIPanGestureRecognizer {
                    recognizer.require(toFail: pan)
                }
                let saved = UserDefaults.standard.dictionary(forKey: store.localKey)
                let initial =
                    old
                    ?? MapCamera(
                        center: CLLocationCoordinate2D(
                            latitude: saved?["latitude"] as? Double ?? 25,
                            longitude: saved?["longitude"] as? Double ?? 0),
                        zoom: saved?["zoom"] as? Double ?? 1.5, pitch: saved?["pitch"] as? Double ?? 0,
                        bearing: saved?["bearing"] as? Double ?? 0)
                new.setCamera(initial, animated: false)
            } catch { if !Task.isCancelled { await store.report(error) } }
        }
    }
    private func mapMoved() {
        guard cameraRefreshTask == nil else { return }
        cameraRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            guard let self else { return }
            cameraRefreshTask = nil
            remember()
            updateLocationFocus()
            refreshForegroundCells()
            scheduleRender()
        }
    }
    private func remember() {
        guard let c = engine?.camera else { return }
        UserDefaults.standard.set(
            [
                "style": store.style, "latitude": c.center.latitude, "longitude": c.center.longitude,
                "zoom": c.zoom, "pitch": c.pitch, "bearing": c.bearing,
            ], forKey: store.localKey)
    }
    private func refreshForegroundCells() {
        guard loaded, let engine else { return }
        let b = padded(engine.bounds())
        let key = "\(store.foregroundCells.hashValue):\(store.ground):\(store.hidden):\(store.accent):\(b)"
        guard foregroundCellKey != key else { return }
        guard store.ground, !store.hidden.contains("iphone"), !store.foregroundCells.isEmpty else {
            engine.remove("foreground-cells")
            foregroundCellKey = key
            return
        }
        let features: [JSON] = store.foregroundCells.compactMap { id in
            guard !knownVisitedCells.contains(id), let cell = HexGrid.parse(cellId: id) else { return nil }
            let center = HexGrid.cellCenter(level: 0, col: cell.col, row: cell.row)
            let rawLng = HexGrid.longitude(x: center.x)
            let shift = floor((rawLng + 180) / 360) * 360
            let lng = rawLng - shift
            let lat = HexGrid.latitude(y: center.y)
            guard lat >= b[1], lat <= b[3],
                b[0] <= b[2] ? (lng >= b[0] && lng <= b[2]) : (lng >= b[0] || lng <= b[2])
            else { return nil }
            var ring = HexGrid.corners(of: cell).map {
                JSON.array([.number($0.lng - shift), .number($0.lat)])
            }
            if let first = ring.first { ring.append(first) }
            return .object([
                "type": .string("Feature"), "properties": .object([:]),
                "geometry": .object(["type": .string("Polygon"), "coordinates": .array([.array(ring)])]),
            ])
        }
        do {
            // This preview is local and independent of network render requests.
            // The durable queue uploads it, then server shading replaces it.
            try geo(engine, id: "foreground-cells", data: Self.points(features), type: "fill",
                paint: ["fill-color": .string(store.accent), "fill-opacity": .number(store.opacity)])
            foregroundCellKey = key
        } catch { /* A style reload will retry on the next update. */ }
    }
    private func scheduleRender() {
        guard loaded, let engine, view.bounds.width > 0, view.bounds.height > 0,
            UIApplication.shared.applicationState == .active else { return }
        scheduleRoutes(engine)
        let visible = engine.bounds()
        let b = padded(visible)
        let zoom = engine.camera.zoom
        level = store.detail == "finest" ? 0 : store.detail == "country" ? 7
            : store.detail == "regions" ? 6 : zoom < 2.75 ? 8
            : min(7, max(0, Int(ceil((13.6 - zoom) / log2(3) - 1e-9))))
        let content = "\(store.localKey):\(store.revision):\(store.ground):\(store.detail):\(store.mode):\(store.accent):\(store.hidden.sorted()):\(level)"
        if let painted = paintedViewport, painted.content == content,
            abs(painted.zoom - zoom) < 0.25, MapViewport.contains(painted.bounds, visible) { return }
        guard let request = renderState.begin(content + ":\(b)") else { return }
        renderTask?.cancel()
        let currentLevel = level
        let factsContext = placeFactsContext
        let parameters = store.renderQuery(currentLevel, bbox: b.map { String($0) }.joined(separator: ","))
            + query(["fine": "1", "info": "0"])
        let scope = store.localKey
        let regionScope = "\(scope):\(store.revision)"
        let regionKey = "\(regionScope):\(currentLevel):\(store.mode):\(store.accent):\(store.hidden.sorted())"
        renderTask = Task { [weak self] in
            guard let self else { return }
            let clock = ContinuousClock.now
            MapPerformance.report("ground-request", since: clock, count: currentLevel)
            var displayed = false
            defer { renderState.finish(request, displayed: displayed) }
            do {
                guard store.ground else {
                    engine.remove("visited-blob")
                    engine.remove("visited-regions")
                    paintedViewport = nil
                    lastPaint = nil
                    displayed = true
                    return
                }
                if currentLevel < 6, let cached = await cells.cached(query: parameters, scope: scope, bounds: b) {
                    guard !Task.isCancelled, renderState.isCurrent(request) else { return }
                    try await displayGround(cached, engine: engine, level: currentLevel, bounds: b,
                        zoom: zoom, content: content, factsContext: factsContext, request: request)
                    displayed = true
                    MapPerformance.report("ground-cached", since: clock, count: cached["rows"].array.count)
                }
                let cachedRegion: (data: JSON, fine: Bool)?
                if currentLevel < 6 { cachedRegion = nil }
                else if let memory = regionMemory[regionKey] { cachedRegion = memory }
                else if let saved = await regions.cached(query: parameters, scope: regionScope) {
                    cachedRegion = (saved, false)
                } else if store.offline {
                    // Fine region geometry is retained by the current offline download.
                    cachedRegion = await store.api.cachedRegionSnapshot(query: parameters)
                } else { cachedRegion = nil }
                if let cached = cachedRegion {
                    guard !Task.isCancelled, renderState.isCurrent(request) else { return }
                    try await displayGround(cached.data, engine: engine, level: currentLevel, bounds: b,
                        zoom: zoom, content: content, factsContext: factsContext, request: request)
                    displayed = true
                    retainRegion(cached.data, fine: cached.fine, key: regionKey)
                    MapPerformance.report("regions-cached", since: clock)
                }
                try await Task.sleep(for: .milliseconds(displayed ? 150 : 40))
                let data: JSON
                if currentLevel < 6 { data = try await cells.load(query: parameters, scope: scope, bounds: b) }
                else {
                    if cachedRegion?.fine != true {
                        // Detailed boundaries can require remote country downloads.
                        // A coarse map must be visible throughout that work.
                        let coarse = try await regions.load(query: parameters, scope: regionScope)
                        guard !Task.isCancelled, renderState.isCurrent(request) else { return }
                        try await displayGround(coarse, engine: engine, level: currentLevel, bounds: b,
                            zoom: zoom, content: content, factsContext: factsContext, request: request)
                        displayed = true
                        retainRegion(coarse, fine: false, key: regionKey)
                        MapPerformance.report("regions-coarse", since: clock)
                    }
                    // Loading tap facts can scan the entire visit history and
                    // duplicate boundary geometry. Fetch those only on selection.
                    if currentLevel == 8 { return }
                    try await Task.sleep(for: .milliseconds(350))
                    data = try await store.api.get("/api/render/regions", query: parameters)
                }
                guard !Task.isCancelled, renderState.isCurrent(request) else { return }
                if currentLevel >= 6 { retainRegion(data, fine: true, key: regionKey) }
                try await displayGround(data, engine: engine, level: currentLevel, bounds: b,
                    zoom: zoom, content: content, factsContext: factsContext, request: request)
                displayed = true
                MapPerformance.report("ground-network", since: clock, count: data["rows"].array.count)
            } catch is CancellationError {} catch {
                if !Task.isCancelled {
                    MapPerformance.report("ground-error", since: clock, count: (error as? ServerFailure)?.status ?? (error as NSError).code)
                }
                if renderState.isCurrent(request), !Task.isCancelled, !displayed { await store.report(error) }
            }
        }
    }
    private func retainRegion(_ data: JSON, fine: Bool, key: String) {
        if regionMemory[key] == nil, regionMemory.count >= 3, let oldest = regionMemory.keys.first { regionMemory[oldest] = nil }
        regionMemory[key] = (data, fine)
    }
    private func displayGround(_ data: JSON, engine: any MapEngine, level: Int, bounds b: [Double],
        zoom: Double, content: String, factsContext: String, request: MapRenderState.Request) async throws {
        let unchanged = lastPaint.map { (level >= 6 || $0.bounds == b) && $0.data == data && $0.heat == (store.mode != "flat") } ?? false
        let clock = ContinuousClock.now
        if unchanged {
            // A reconnect can advance the revision without changing geometry.
            // Refresh its fact context while preserving the already drawn sheet.
        } else if level < 6 {
            let width = min(1600, max(320, Int(view.bounds.width * 2)))
            let world = 40075016.68557849
            func mercY(_ lat: Double) -> Double { log(tan(.pi / 4 + lat * .pi / 360)) * world / (2 * .pi) }
            let span = (b[2] > b[0] ? b[2] - b[0] : b[2] + 360 - b[0]) / 360 * world
            let height = min(1600, max(64, Int(Double(width) * (mercY(b[3]) - mercY(b[1])) / span)))
            let painted = try await painter.paint(data, bounds: b, width: width, height: height, heat: store.mode != "flat")
            guard !Task.isCancelled, renderState.isCurrent(request) else { throw CancellationError() }
            MapPerformance.report("ground-opacity", since: .now, count: Int(store.opacity * 1000))
            try engine.image("visited-blob", image: painted.image, bounds: b, opacity: store.opacity)
            engine.remove("visited-regions")
            if level == 0 {
                let confirmed = Set(data["rows"].array.map { "0/" + $0[0].string })
                knownVisitedCells = confirmed
                store.confirmForegroundCells(confirmed)
            }
        } else {
            try geo(engine, id: "visited-regions", data: data, type: "fill", paint: [
                "fill-color": .array([.string("to-color"), .array([.string("get"), .string("color")])]),
                "fill-opacity": .number(store.opacity),
            ])
            engine.remove("visited-blob")
        }
        paintedViewport = (content, b, zoom)
        lastPaint = (b, data, store.mode != "flat")
        store.mapDidRender(level: level)
        MapPerformance.report("ground-paint", since: clock, count: data["rows"].array.count)
        MapPerformance.report("ground-since-mount", since: startup)
        let facts = await Task.detached(priority: .utility) {
            MapPlaceFacts(context: factsContext, level: level, bounds: b, data: data)
        }.value
        guard !Task.isCancelled, renderState.isCurrent(request) else { throw CancellationError() }
        placeFacts = facts
    }
    private func scheduleRoutes(_ engine: any MapEngine) {
        if routeAccount != store.localKey { routeAccount = store.localKey; routeData = Self.empty }
        let key = "\(store.localKey):\(store.revision):\(store.activities):\(store.solo):\(store.activity["route"]["geom"].array.isEmpty):\(store.activity["route"]["id"].string):\(store.hidden.sorted())"
        guard let request = routeState.begin(key) else { return }
        routeTask?.cancel()
        try? displayRoutes(routeData, engine: engine)
        routeTask = Task { [weak self] in
            guard let self else { return }
            var displayed = false
            defer { routeState.finish(request, displayed: displayed) }
            do {
                guard store.activities else { try displayRoutes(Self.empty, engine: engine); displayed = true; return }
                if let cached = await store.api.cachedGet("/api/render/routes"), routeState.isCurrent(request), !Task.isCancelled {
                    routeData = cached
                    try displayRoutes(cached, engine: engine)
                    displayed = true
                }
                let fresh = try await store.api.get("/api/render/routes")
                guard routeState.isCurrent(request), !Task.isCancelled else { return }
                routeData = fresh
                try displayRoutes(fresh, engine: engine)
                displayed = true
            } catch is CancellationError {} catch {
                if routeState.isCurrent(request), !Task.isCancelled, !displayed { await store.report(error) }
            }
        }
    }
    private func displayRoutes(_ input: JSON, engine: any MapEngine) throws {
        let data = store.activities ? ActivityMapSelection.baseRoutes(input, activity: store.activity, solo: store.solo) : Self.empty
        try geo(engine, id: "activities", data: data, type: "line", paint: [
            "line-color": .array([.string("to-color"), .array([.string("get"), .string("color")])]),
            "line-width": .number(3), "line-opacity": .array([.string("get"), .string("alpha")]),
        ])
    }
    private func padded(_ original: [Double]) -> [Double] {
        var b = original
        let span = b[2] >= b[0] ? b[2] - b[0] : b[2] + 360 - b[0]
        let lat = (b[3] - b[1]) * 0.15
        b[1] = max(-85.051129, b[1] - lat)
        b[3] = min(85.051129, b[3] + lat)
        if span * 1.3 >= 360 {
            b[0] = -180
            b[2] = 180
        } else {
            func wrap(_ n: Double) -> Double { n - floor((n + 180) / 360) * 360 }
            b[0] = wrap(b[0] - span * 0.15)
            b[2] = wrap(b[2] + span * 0.15)
        }
        return b
    }
    static let empty: JSON = .object(["type": .string("FeatureCollection"), "features": .array([])])
    private func geo(
        _ engine: any MapEngine, id: String, data: JSON, type: String, paint: [String: JSON],
        filter: JSON = .null, layout: [String: JSON] = [:]
    ) throws {
        try engine.source(id, definition: .object(["type": .string("geojson"), "data": data]))
        var layer: [String: JSON] = [
            "id": .string(id), "source": .string(id), "type": .string(type), "paint": .object(paint),
        ]
        if type == "line" {
            layer["layout"] = .object(["line-cap": .string("round"), "line-join": .string("round")])
        }
        if !layout.isEmpty { layer["layout"] = .object((layer["layout"]?.object ?? [:]).merging(layout, uniquingKeysWith: { _, value in value })) }
        if filter.exists { layer["filter"] = filter }
        try engine.layer(.object(layer))
    }
    private func selectionLayers(_ engine: any MapEngine) throws {
        let data = ActivityMapSelection.metricOverlay(store.activity, metric: store.metric)
        try geo(engine, id: "activity-metric-outline", data: data, type: "line",
            paint: ["line-color": .string("#000000"), "line-width": .number(8)])
        try geo(
            engine, id: "activity-metric", data: data, type: "line",
            paint: [
                "line-color": .array([.string("to-color"), .array([.string("get"), .string("color")])]),
                "line-width": .number(5),
            ], layout: ["line-sort-key": .array([.string("get"), .string("metricOrder")])])
        try geo(
            engine, id: "track", data: store.track["track"].exists ? store.track["track"] : Self.empty,
            type: "line", paint: ["line-color": .string("#ffd94f"), "line-width": .number(4)],
            filter: .array([.string("=="), .string("$type"), .string("LineString")]))
        try geo(
            engine, id: "track-points", data: store.track["track"].exists ? store.track["track"] : Self.empty,
            type: "circle", paint: ["circle-color": .string("#ffd94f"), "circle-radius": .number(3)],
            filter: .array([.string("=="), .string("$type"), .string("Point")]))
        let outline: JSON =
            store.place["geometry"].exists
            ? Self.points([
                .object([
                    "type": .string("Feature"), "properties": .object([:]),
                    "geometry": store.place["geometry"],
                ])
            ]) : Self.empty
        try geo(
            engine, id: "place-outline-halo", data: outline, type: "line",
            paint: ["line-color": .string("#20252b"), "line-width": .number(6)])
        try geo(
            engine, id: "place-outline", data: outline, type: "line",
            paint: ["line-color": .string("#ffffff"), "line-width": .number(3)])
        var pin = Self.empty
        if store.focus["lat"].exists && store.focus["lng"].exists {
            pin = Self.points([
                .object([
                    "type": .string("Feature"), "properties": .object([:]),
                    "geometry": .object([
                        "type": .string("Point"),
                        "coordinates": .array([store.focus["lng"], store.focus["lat"]]),
                    ]),
                ])
            ])
        }
        try geo(
            engine, id: "search-pin", data: pin, type: "circle",
            paint: [
                "circle-color": .string("#ff6c4f"), "circle-radius": .number(7),
                "circle-stroke-color": .string("#ffffff"), "circle-stroke-width": .number(2),
            ])
        var marker = Self.empty
        if let index = store.sample {
            let sample = store.activity["samples"][index]
            if sample["lng"].exists && sample["lat"].exists {
                marker = Self.points([
                    .object([
                        "type": .string("Feature"), "properties": .object([:]),
                        "geometry": .object([
                            "type": .string("Point"), "coordinates": .array([sample["lng"], sample["lat"]]),
                        ]),
                    ])
                ])
            }
        }
        try geo(
            engine, id: "sample", data: marker, type: "circle",
            paint: [
                "circle-color": .string("#ffffff"), "circle-stroke-color": .string("#202020"),
                "circle-stroke-width": .number(2), "circle-radius": .number(6),
            ])
    }
    private static func points(_ features: [JSON]) -> JSON {
        .object(["type": .string("FeatureCollection"), "features": .array(features)])
    }
    private func refreshOverlays() {
        guard loaded, let engine else { return }
        let key =
            "\(styleKey):\(store.photos):\(store.rail):\(store.prefs["railGroups"]):\(store.prefs["railTechnical"]):\(store.trails):\(store.trailTheme):\(store.trailStrength):\(store.airportGroups.sorted()):\(store.track["from"].string):\(store.track["to"].string)"
        guard overlayKey != key else { return }
        overlayKey = key
        overlayTask?.cancel()
        overlayTask = Task {
            do {
                for id in airportHits {
                    engine.remove(id + "-labels")
                    engine.remove(id)
                }
                airportHits = []
                for group in store.airportGroups.sorted() {
                    let id = "airports-" + group
                    let data = try await store.api.get(
                        "/api/render/reference", query: query(["kind": "airports", "group": group]))
                    try Task.checkCancellation()
                    try geo(
                        engine, id: id, data: data, type: "circle",
                        paint: [
                            "circle-radius": .number(4), "circle-color": .string("#d5c2ff"),
                            "circle-stroke-width": .number(1), "circle-stroke-color": .string("#32254d"),
                        ])
                    try engine.layer(
                        .object([
                            "id": .string(id + "-labels"), "source": .string(id), "type": .string("symbol"),
                            "minzoom": .number(7),
                            "layout": .object([
                                "text-field": .array([.string("get"), .string("code")]),
                                "text-size": .number(11), "text-offset": .array([.number(0), .number(1)]),
                            ]),
                            "paint": .object([
                                "text-color": .string("#d5c2ff"), "text-halo-color": .string("#232323"),
                                "text-halo-width": .number(1),
                            ]),
                        ]))
                    airportHits.append(id)
                }
                engine.remove("trails")
                if store.trails, let base = AppSettings.shared.baseURL {
                    let url =
                        base.appendingPathComponent("api/trails/tile/\(store.trailTheme)").absoluteString
                        + "/{z}/{x}/{y}.png"
                    try engine.source(
                        "trails",
                        definition: .object([
                            "type": .string("raster"), "tiles": .strings([url]), "tileSize": .number(256),
                            "maxzoom": .number(16),
                        ]))
                    try engine.layer(
                        .object([
                            "id": .string("trails"), "source": .string("trails"), "type": .string("raster"),
                            "paint": .object(["raster-opacity": .number(store.trailStrength)]),
                        ]))
                }
                for id in railLayers.reversed() { engine.remove(id) }
                railLayers = []
                if store.rail {
                    let data = try await store.api.get(
                        "/api/render/reference",
                        query: query([
                            "kind": "rail", "native": "1",
                            "technical": store.prefs["railTechnical"].bool ? "1" : "0",
                            "theme": store.style == "voyager" ? "light" : "dark",
                        ]))
                    try Task.checkCancellation()
                    for (id, source) in data["sources"].object { try engine.source(id, definition: source) }
                    try await installSprites(data["sprites"], engine: engine)
                    for original in data["layers"].array {
                        let group = original["metadata"]["sporra:group"].string
                        let defaultOn = !["linenumbers", "symbols", "milestones"].contains(group)
                        let on =
                            store.prefs["railGroups"][group].exists
                            ? store.prefs["railGroups"][group].bool : defaultOn
                        guard group.isEmpty || on else { continue }
                        for layer in NativeRail.layers(original) {
                            try engine.layer(layer)
                            railLayers.append(layer["id"].string)
                        }
                    }
                }
                if store.photos {
                    let status = await PhotoLibrary.authorize()
                    guard status == .authorized || status == .limited else {
                        throw ServerFailure(
                            status: 0,
                            message: "Allow photo access in iOS Settings to show photographs on the map.")
                    }
                    if photos.isEmpty { photos = await Task.detached { PhotoLibrary.located() }.value }
                    try Task.checkCancellation()
                    let from = store.track["from"].double
                    let to = store.track["to"].double
                    let features = photos.enumerated().filter { _, photo in
                        !store.track.exists || (Double(photo.t) >= from && Double(photo.t) < to)
                    }.map { i, p in
                        JSON.object([
                            "type": .string("Feature"), "properties": .object(["index": .number(Double(i))]),
                            "geometry": .object([
                                "type": .string("Point"),
                                "coordinates": .array([.number(p.lng), .number(p.lat)]),
                            ]),
                        ])
                    }
                    try installPhotos(features, engine: engine)
                } else {
                    engine.remove("photos-count")
                    engine.remove("photos-cluster")
                    engine.remove("photos")
                    photos = []
                }
            } catch is CancellationError {} catch { if !Task.isCancelled { await store.report(error) } }
        }
    }
    private func installPhotos(_ features: [JSON], engine: any MapEngine) throws {
        try engine.source("photos", definition: .object([
            "type": .string("geojson"), "data": Self.points(features),
            "cluster": .bool(true), "clusterRadius": .number(44), "clusterMaxZoom": .number(23), "maxzoom": .number(24),
        ]))
        let single: JSON = .array([.string("!"), .array([.string("has"), .string("point_count")])])
        let group: JSON = .array([.string("has"), .string("point_count")])
        for (id, filter, radius) in [
            ("photos", single, JSON.number(6)),
            ("photos-cluster", group, .array([.string("step"), .array([.string("get"), .string("point_count")]),
                .number(10), .number(10), .number(13), .number(50), .number(16),
                .number(250), .number(19), .number(1000), .number(23)])),
        ] {
            try engine.layer(.object([
                "id": .string(id), "source": .string("photos"), "type": .string("circle"), "filter": filter,
                "paint": .object(["circle-color": .string("#ffffff"), "circle-radius": radius,
                    "circle-stroke-color": .string("#000000"), "circle-stroke-width": .number(1.4),
                    "circle-opacity": .number(1)]),
            ]))
        }
        try engine.layer(.object([
            "id": .string("photos-count"), "source": .string("photos"), "type": .string("symbol"), "filter": group,
            "layout": .object([
                "text-field": .array([.string("to-string"), .array([.string("get"), .string("point_count_abbreviated")])]),
                "text-size": .number(12), "text-allow-overlap": .bool(true), "text-ignore-placement": .bool(true),
            ]),
            "paint": .object(["text-color": .string("#000000"), "text-halo-width": .number(0)]),
        ]))
    }
    private func installSprites(_ sprites: JSON, engine: any MapEngine) async throws {
        for sprite in sprites.array {
            let prefix = sprite["id"].string
            guard let indexURL = URL(string: sprite["url"].string + ".json"),
                let imageURL = URL(string: sprite["url"].string + ".png")
            else { continue }
            let indexData = try await store.api.publicResource(indexURL)
            let index = try JSONDecoder().decode(JSON.self, from: indexData)
            let imageData = try await store.api.publicResource(imageURL)
            guard let atlas = UIImage(data: imageData)?.cgImage else { continue }
            for (name, item) in index.object {
                guard
                    let crop = atlas.cropping(
                        to: CGRect(
                            x: item["x"].double, y: item["y"].double, width: item["width"].double,
                            height: item["height"].double))
                else { continue }
                try engine.addImage(
                    UIImage(cgImage: crop, scale: max(1, item["pixelRatio"].double), orientation: .up),
                    id: prefix.isEmpty ? name : prefix + ":" + name)
            }
        }
    }
    private var placeFactsContext: String {
        "\(store.localKey):\(store.revision):\(store.hidden.sorted())"
    }
    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let engine else { return }
        handleTap(recognizer.location(in: engine.view))
    }
    private func handleTap(_ point: CGPoint, town: MapTownLabel? = nil) {
        guard let engine else { return }
        let coordinate = engine.coordinate(point)
        tapGeneration += 1
        let tap = tapGeneration
        let tappedLevel = level
        let factsContext = placeFactsContext
        var initial = placeFacts?.place(context: factsContext, level: tappedLevel, lng: coordinate.longitude, lat: coordinate.latitude)
            ?? MapPlaceFacts.placeholder(level: tappedLevel, lng: coordinate.longitude, lat: coordinate.latitude)
        if tappedLevel == 0, !store.hidden.contains("iphone"), store.foregroundCells.contains(initial["cellID"].string) {
            initial["visited"] = .bool(true)
        }
        tapTask?.cancel()
        tapTask = Task {
            await store.perform {
                if self.store.editing {
                    let value = try await self.store.api.post(
                        self.store.clearingRegion ? "/api/render/region-clear" : "/api/render/brush",
                        [
                            "lng": .number(coordinate.longitude), "lat": .number(coordinate.latitude),
                            "points": .array([
                                .array([.number(coordinate.longitude), .number(coordinate.latitude)])
                            ]), "level": .number(Double(min(self.level, 5))),
                            "action": .string(self.store.brushAction),
                            "size": .number(Double(self.store.brushSize)),
                        ])
                    self.store.undo = value["undo"]
                    self.store.changed()
                    return
                }
                if let town, self.store.cellInfo {
                    await self.store.selectTown(town)
                    return
                }
                let photoIndices = self.store.photos ? await engine.photoIndices(at: point) : []
                try Task.checkCancellation()
                var items: [PhotoLibrary.Located] = Set(photoIndices).compactMap { i -> PhotoLibrary.Located? in
                    guard self.photos.indices.contains(i) else { return nil }
                    return self.photos[i]
                }
                items.sort { a, b in
                    if a.t == b.t { return a.id < b.id }
                    return a.t > b.t
                }
                if !items.isEmpty {
                    if items.count == 1 {
                        self.present(PhotoGalleryController(items: items, at: 0), animated: true)
                    } else {
                        let grid = UIHostingController(rootView: NativePhotoGrid(items: items) { [weak controller = self] index in
                            guard let presenter = controller?.presentedViewController else { return }
                            presenter.present(PhotoGalleryController(items: items, at: index), animated: true)
                        })
                        grid.sheetPresentationController?.detents = [.medium(), .large()]
                        grid.sheetPresentationController?.prefersGrabberVisible = true
                        self.present(grid, animated: true)
                    }
                    return
                }
                let metricHits = self.store.activity.exists
                    ? await engine.features(point, layers: ["activity-metric"], radius: activityTapRadius) : []
                try Task.checkCancellation()
                let routes = self.store.activities
                    ? await engine.features(point, layers: ["activities"], radius: activityTapRadius) : []
                try Task.checkCancellation()
                guard tap == self.tapGeneration else { return }
                let selected = !metricHits.isEmpty ? self.store.activity["route"] : JSON.null
                let choices = ActivityChoices.candidates(hits: routes, selected: selected, metadata: self.store.recentRoutes)
                if choices.count > 1 {
                    self.store.closeSelection()
                    self.store.routeChoices = choices
                    return
                }
                if let choice = choices.first {
                    if choice["id"].string == self.store.activity["route"]["id"].string, !metricHits.isEmpty {
                        if let hit = metricHits.first(where: { $0["properties"]["i"].exists }) {
                            self.store.sample = hit["properties"]["i"].int
                        }
                    } else {
                        await self.store.openActivity(choice["id"], preview: choice)
                    }
                    return
                }
                let airports = await engine.features(point, layers: self.airportHits)
                try Task.checkCancellation()
                if let first = airports.first {
                    let airport = try await self.store.api.get(
                        "/api/render/reference",
                        query: query([
                            "kind": "airport", "group": first["properties"]["group"].string,
                            "index": first["properties"]["index"].string,
                        ]))
                    try Task.checkCancellation()
                    self.store.showPlace(airport)
                    return
                }
                if self.store.cellInfo {
                    guard tap == self.tapGeneration, factsContext == self.placeFactsContext else { return }
                    // The same cell has one cache key even when tapped at
                    // different pixels. Keep the outline in the tapped world copy.
                    var lng = coordinate.longitude, lat = coordinate.latitude
                    if let cell = HexGrid.parse(cellId: initial["cellID"].string) {
                        let center = HexGrid.cellCenter(level: cell.level, col: cell.col, row: cell.row)
                        let rawLng = HexGrid.longitude(x: center.x)
                        lng = rawLng - floor((rawLng + 180) / 360) * 360
                        lat = HexGrid.latitude(y: center.y)
                    }
                    await self.store.selectPlace(initial, query: self.store.renderQuery(tappedLevel)
                        + query(["lng": String(lng), "lat": String(lat)]))
                }
            }
        }
    }
    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        guard let engine else { return }
        let p = engine.coordinate(recognizer.location(in: engine.view))
        if recognizer.state == .began { stroke = [] }
        if recognizer.state == .began || recognizer.state == .changed {
            if stroke.count < 2000 { stroke.append([p.longitude, p.latitude]) }
        }
        if recognizer.state == .ended {
            let points = stroke
            stroke = []
            Task {
                await store.perform {
                    let result = try await self.store.api.post(
                        "/api/render/brush",
                        [
                            "points": .array(points.map { .array($0.map(JSON.number)) }),
                            "level": .number(Double(min(self.level, 5))),
                            "action": .string(self.store.brushAction),
                            "size": .number(Double(self.store.brushSize)),
                        ])
                    self.store.undo = result["undo"]
                    self.store.changed()
                }
            }
        }
    }
    private func focusSnapshot(_ engine: any MapEngine) -> MapFocusSnapshot {
        MapFocusSnapshot(bounds: engine.view.bounds, card: store.mapCardLayout, controls: store.mapControlsFrame)
    }
    private func applyPendingFocus() {
        guard loaded, let pending = pendingFocus, let engine,
            engine.view.bounds.width > 0, engine.view.bounds.height > 0 else { return }
        guard pending.selection == "none" || pending.selection == store.mapSelectionID else {
            focusTask?.cancel()
            focusTask = nil
            pendingFocus = nil
            focusReadiness.reset()
            return
        }
        guard focusTask == nil else { return }
        let command = cameraID
        focusTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let current = self.pendingFocus, self.cameraID == command,
                    self.loaded, let active = self.engine,
                    current.selection == "none" || current.selection == self.store.mapSelectionID else { return }
                let cardReady = current.selection == "none"
                    || (self.store.mapCardLayout.id == current.selection && self.store.mapCardLayout.frame.height > 0)
                let activityReady = !current.selection.hasPrefix("activity:") || !self.store.activity["loading"].bool
                let layout = self.focusSnapshot(active)
                if self.focusReadiness.ready(layout, contentReady: cardReady && activityReady,
                    now: ProcessInfo.processInfo.systemUptime) {
                    // Resolve activity data at execution time: the loading card's
                    // preview can have different geometry from the loaded route.
                    let target = current.selection.hasPrefix("activity:") ? self.store.activity["route"] : current.value
                    self.pendingFocus = nil
                    self.focusTask = nil
                    self.focusReadiness.reset()
                    MapPerformance.report("focus-card-height", since: .now, count: Int(layout.card.frame.height))
                    self.focus(target)
                    return
                }
                do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
            }
        }
    }
    private func focusPadding(_ engine: any MapEngine) -> UIEdgeInsets {
        let card = store.mapCardLayout.id == store.mapSelectionID && store.mapSelectionID != "none"
            ? engine.view.convert(store.mapCardLayout.frame, from: nil) : CGRect.null
        let controls = store.mapControlsFrame.isNull ? CGRect.null : engine.view.convert(store.mapControlsFrame, from: nil)
        let safe = engine.view.window?.safeAreaInsets ?? view.safeAreaInsets
        let insets = MapFocusLayout.insets(bounds: engine.view.bounds, safeTop: safe.top, safeBottom: safe.bottom, card: card, controls: controls)
        return UIEdgeInsets(top: insets.top, left: insets.left, bottom: insets.bottom, right: insets.right)
    }
    private func focus(_ value: JSON) {
        guard let engine else { return }
        var c = engine.camera
        let bbox = value["bbox"].array.map(\.double)
        if bbox.count == 4 {
            engine.fit(bbox, padding: focusPadding(engine), animated: true)
            return
        } else if value["lat"].exists && value["lng"].exists {
            c.center = CLLocationCoordinate2D(latitude: value["lat"].double, longitude: value["lng"].double)
            c.zoom = 12
        } else if !value["geom"].array.isEmpty {
            let points = value["geom"].array.flatMap(\.array)
            let xs = points.map { $0[0].double }
            let ys = points.map { $0[1].double }
            if let w = xs.min(), let e = xs.max(), let s = ys.min(), let n = ys.max() {
                focus(.object(["bbox": .array([w, s, e, n].map(JSON.number))]))
            }
            return
        } else {
            return
        }
        engine.setCamera(c, animated: true)
    }
    private func locate() {
        wantsLocation = true
        switch location.authorizationStatus {
        case .notDetermined:
            location.requestWhenInUseAuthorization()
        case .denied, .restricted:
            wantsLocation = false
            store.locationFocused = false
            store.error = "Allow location access in iOS Settings to find your position."
        case .authorizedAlways, .authorizedWhenInUse:
            // The map SDK already tracks the puck. Use that position without
            // waiting for a separate manager to acquire another GPS fix.
            if let coordinate = engine?.userCoordinate,
                CLLocationCoordinate2DIsValid(coordinate)
            {
                centerOnLocation(coordinate)
            } else if let fix = location.location, fix.horizontalAccuracy >= 0,
                abs(fix.timestamp.timeIntervalSinceNow) < 60
            {
                centerOnLocation(fix.coordinate)
            } else {
                location.requestLocation()
            }
        @unknown default:
            wantsLocation = false
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if [.authorizedAlways, .authorizedWhenInUse].contains(manager.authorizationStatus) {
            engine?.showLocation()
        } else {
            store.locationFocused = false
        }
        if wantsLocation { locate() }
    }
    private func centerOnLocation(_ coordinate: CLLocationCoordinate2D) {
        guard let engine, CLLocationCoordinate2DIsValid(coordinate) else { return }
        wantsLocation = false
        lastFocusedCoordinate = coordinate
        store.locationFocused = true
        engine.showLocation()
        var camera = engine.camera
        camera.center = coordinate
        camera.zoom = max(13, camera.zoom)
        engine.setCamera(camera, animated: true)
    }
    private func updateLocationFocus() {
        guard [.authorizedAlways, .authorizedWhenInUse].contains(location.authorizationStatus),
            let engine,
            let coordinate = engine.userCoordinate ?? location.location?.coordinate ?? lastFocusedCoordinate,
            CLLocationCoordinate2DIsValid(coordinate)
        else {
            if store.locationFocused { store.locationFocused = false }
            return
        }
        let point = engine.point(coordinate)
        let bounds = engine.view.bounds
        // Measure in screen points so this behaves consistently at every zoom.
        let centered = point.x.isFinite && point.y.isFinite
            && hypot(point.x - bounds.midX, point.y - bounds.midY) <= 16
        if store.locationFocused != centered { store.locationFocused = centered }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard wantsLocation,
            let fix = locations.last(where: { $0.horizontalAccuracy >= 0 })
        else { return }
        centerOnLocation(fix.coordinate)
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard wantsLocation else { return }
        if let coordinate = engine?.userCoordinate, CLLocationCoordinate2DIsValid(coordinate) {
            centerOnLocation(coordinate)
            return
        }
        wantsLocation = false
        store.locationFocused = false
        store.error = error.localizedDescription
    }
    private func snapshot() {
        do {
            guard let image = try engine?.snapshot(), let data = image.pngData() else { return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Sporra-map.png")
            try data.write(to: url, options: .atomic)
            store.shareURL = url
        } catch { store.error = error.localizedDescription }
    }
    private static func sunPhase(_ when: Date, coordinate: CLLocationCoordinate2D?) -> String {
        let rad = Double.pi / 180
        let lat = coordinate?.latitude ?? 0
        let lon = coordinate?.longitude ?? Double(TimeZone.current.secondsFromGMT(for: when)) / 240
        let d = when.timeIntervalSince1970 / 86400 + 2440587.5 - 2_451_545
        let anomaly = (357.529 + 0.98560028 * d) * rad
        let ecliptic = (280.459 + 0.98564736 * d + 1.915 * sin(anomaly) + 0.02 * sin(2 * anomaly)) * rad
        let obliquity = (23.439 - 0.00000036 * d) * rad
        let declination = asin(sin(obliquity) * sin(ecliptic))
        let ascension = atan2(cos(obliquity) * sin(ecliptic), cos(ecliptic)) / rad
        let raw =
            (18.697374558 + 24.06570982441908 * d).truncatingRemainder(dividingBy: 24) * 15 + lon - ascension
        let hourAngle = raw - 360 * floor((raw + 180) / 360)
        let elevation =
            asin(sin(lat * rad) * sin(declination) + cos(lat * rad) * cos(declination) * cos(hourAngle * rad))
            / rad
        if elevation >= 6 { return "day" }
        if elevation <= -6 { return "night" }
        return hourAngle < 0 ? "dawn" : "dusk"
    }
}
