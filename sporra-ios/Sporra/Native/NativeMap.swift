import CoreLocation
import Photos
import SporraCore
import SwiftUI
import UIKit

actor NativeBlobPainter {
    private var renderer: BlobRenderer?
    func paint(_ data: JSON, bounds b: [Double], width: Int, height: Int, heat: Bool) throws -> Data {
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
        let discs = data["rows"].array.map { row -> BlobDisc in
            let x = row[1].double + (((west + east) / 2 - row[1].double) / world).rounded() * world
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
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
            let png = UIImage(cgImage: image).pngData()
        else { throw ServerFailure(status: 0, message: "Unable to draw your visited map.") }
        return png
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
    private var renderKey = ""
    private var overlayKey = ""
    private var loadTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var overlayTask: Task<Void, Never>?
    private var generation = 0
    private var tapGeneration = 0
    private var cameraID = UUID(), locationID = UUID(), snapshotID = UUID()
    private var lastSelection = ""
    private var loaded = false
    private var level = 0
    private var location = CLLocationManager()
    private var wantsLocation = false
    private let painter = NativeBlobPainter()
    private var photos: [PhotoLibrary.Located] = []
    private var routeHits: [String] = ["activities"]
    private var airportHits: [String] = []
    private var railLayers: [String] = []
    private var stroke: [[Double]] = []
    private var brushPan: UIPanGestureRecognizer?
    init(store: NativeStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        location.delegate = self
        update()
    }
    func update() {
        guard isViewLoaded else { return }
        let light = store.prefs["mapboxLight"].text("auto")
        let resolvedLight =
            light == "auto"
            ? Self.sunPhase(store.lightClock, coordinate: location.location?.coordinate) : light
        let key = "\(store.style):\(store.token):\(resolvedLight)"
        if styleKey != key {
            styleKey = key
            install()
            return
        }
        guard loaded, let engine else { return }
        brushPan?.isEnabled = store.editing && !store.clearingRegion
        if cameraID != store.cameraCommand {
            cameraID = store.cameraCommand
            focus(store.focus)
        }
        if locationID != store.locationCommand {
            locationID = store.locationCommand
            locate()
        }
        if snapshotID != store.snapshotCommand {
            snapshotID = store.snapshotCommand
            snapshot()
        }
        let selection =
            "\(store.activity["route"]["id"].string):\(store.metric):\(store.sample ?? -1):\(store.track.data.hashValue):\(store.place.data.hashValue):\(store.focus.data.hashValue)"
        if lastSelection != selection {
            lastSelection = selection
            try? selectionLayers(engine)
        }
        scheduleRender()
        refreshOverlays()
    }
    func stop() {
        generation += 1
        tapGeneration += 1
        loadTask?.cancel()
        renderTask?.cancel()
        overlayTask?.cancel()
        engine?.ready = nil
        engine?.moved = nil
        location.stopUpdatingLocation()
        wantsLocation = false
    }
    private func install() {
        loaded = false
        generation += 1
        loadTask?.cancel()
        renderTask?.cancel()
        overlayTask?.cancel()
        let old = engine?.camera
        engine?.view.removeFromSuperview()
        engine = nil
        renderKey = ""
        overlayKey = ""
        lastSelection = ""
        let key = styleKey
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let new: any MapEngine
                if store.useMapbox {
                    let light = store.prefs["mapboxLight"].text("auto")
                    new = BoxEngine(
                        frame: view.bounds, token: store.token, satellite: store.style == "satellite",
                        light: light == "auto"
                            ? Self.sunPhase(store.lightClock, coordinate: location.location?.coordinate)
                            : light)
                } else {
                    var styleURL: URL
                    if ["satellite", "terrain"].contains(store.style) {
                        let style = try await store.api.get(
                            "/api/render/style", query: query(["name": store.style]))
                        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
                            "sporra-\(store.style).json")
                        try style.data.write(to: url, options: .atomic)
                        styleURL = url
                    } else {
                        styleURL = URL(
                            string:
                                "https://basemaps.cartocdn.com/gl/\(store.style == "voyager" ? "voyager" : "dark-matter")-gl-style/style.json"
                        )!
                    }
                    new = LibreEngine(frame: view.bounds, styleURL: styleURL)
                }
                guard !Task.isCancelled, styleKey == key else { return }
                engine = new
                view.insertSubview(new.view, at: 0)
                new.ready = { [weak self] in
                    self?.loaded = true
                    self?.update()
                }
                new.moved = { [weak self] in
                    self?.remember()
                    self?.scheduleRender()
                }
                let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
                tap.delegate = self
                new.view.addGestureRecognizer(tap)
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
    private func remember() {
        guard let c = engine?.camera else { return }
        UserDefaults.standard.set(
            [
                "style": store.style, "latitude": c.center.latitude, "longitude": c.center.longitude,
                "zoom": c.zoom, "pitch": c.pitch, "bearing": c.bearing,
            ], forKey: store.localKey)
    }
    private func scheduleRender() {
        guard loaded, let engine, view.bounds.width > 0 else { return }
        let b = padded(engine.bounds())
        let zoom = engine.camera.zoom
        level =
            store.detail == "finest"
            ? 0
            : store.detail == "country"
                ? 7 : zoom < 2.75 ? 8 : min(7, max(0, Int(ceil((13.6 - zoom) / log2(3) - 1e-9))))
        let key =
            "\(store.revision):\(store.ground):\(store.activities):\(store.solo):\(store.detail):\(store.mode):\(store.hidden.sorted()):\(b):\(level)"
        guard renderKey != key else { return }
        renderKey = key
        renderTask?.cancel()
        generation += 1
        let epoch = generation
        let currentLevel = level
        renderTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(100))
                let bbox = b.map { String($0) }.joined(separator: ",")
                if store.ground {
                    let data = try await store.api.get(
                        currentLevel < 6 ? "/api/render/cells" : "/api/render/regions",
                        query: store.renderQuery(currentLevel, bbox: bbox)
                            + query(["info": "0", "fine": "1"]))
                    guard !Task.isCancelled, generation == epoch else { return }
                    if currentLevel < 6 {
                        let width = min(1600, max(320, Int(view.bounds.width * 2)))
                        let world = 40075016.68557849
                        func mercY(_ lat: Double) -> Double {
                            log(tan(.pi / 4 + lat * .pi / 360)) * world / (2 * .pi)
                        }
                        let span = (b[2] > b[0] ? b[2] - b[0] : b[2] + 360 - b[0]) / 360 * world
                        let height = min(
                            1600, max(64, Int(Double(width) * (mercY(b[3]) - mercY(b[1])) / span)))
                        let bytes = try await painter.paint(
                            data, bounds: b, width: width, height: height, heat: store.mode != "flat")
                        guard !Task.isCancelled, generation == epoch, let image = UIImage(data: bytes) else {
                            return
                        }
                        try engine.image("visited-blob", image: image, bounds: b, opacity: store.opacity)
                        engine.remove("visited-regions")
                    } else {
                        try geo(
                            engine, id: "visited-regions", data: data, type: "fill",
                            paint: [
                                "fill-color": .array([
                                    .string("to-color"), .array([.string("get"), .string("color")]),
                                ]), "fill-opacity": .number(store.opacity),
                            ])
                        engine.remove("visited-blob")
                    }
                } else {
                    engine.remove("visited-blob")
                    engine.remove("visited-regions")
                }
                var routes = store.activities ? try await store.api.get("/api/render/routes") : Self.empty
                if store.solo, store.activity.exists {
                    routes["features"] = .array(
                        routes["features"].array.filter {
                            $0["properties"]["id"] == self.store.activity["route"]["id"]
                        })
                }
                guard !Task.isCancelled, generation == epoch else { return }
                try geo(
                    engine, id: "activities", data: routes, type: "line",
                    paint: [
                        "line-color": .array([
                            .string("to-color"), .array([.string("get"), .string("color")]),
                        ]), "line-width": .number(3),
                        "line-opacity": .array([.string("get"), .string("alpha")]),
                    ])
                try selectionLayers(engine)
            } catch is CancellationError {} catch {
                if generation == epoch, !Task.isCancelled { await store.report(error) }
            }
        }
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
        filter: JSON = .null
    ) throws {
        try engine.source(id, definition: .object(["type": .string("geojson"), "data": data]))
        var layer: [String: JSON] = [
            "id": .string(id), "source": .string(id), "type": .string(type), "paint": .object(paint),
        ]
        if type == "line" {
            layer["layout"] = .object(["line-cap": .string("round"), "line-join": .string("round")])
        }
        if filter.exists { layer["filter"] = filter }
        try engine.layer(.object(layer))
    }
    private func selectionLayers(_ engine: any MapEngine) throws {
        let data =
            store.activity["lines"][store.metric].exists ? store.activity["lines"][store.metric] : Self.empty
        try geo(
            engine, id: "activity-metric", data: data, type: "line",
            paint: [
                "line-color": .array([.string("to-color"), .array([.string("get"), .string("color")])]),
                "line-width": .number(5),
            ])
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
            engine, id: "place-outline", data: outline, type: "line",
            paint: ["line-color": .string("#ffffff"), "line-width": .number(2)])
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
                    try geo(
                        engine, id: "photos", data: Self.points(features), type: "circle",
                        paint: [
                            "circle-color": .string("#ffffff"), "circle-radius": .number(5),
                            "circle-stroke-color": .string("#464646"), "circle-stroke-width": .number(2),
                        ])
                } else {
                    engine.remove("photos")
                    photos = []
                }
            } catch is CancellationError {} catch { if !Task.isCancelled { await store.report(error) } }
        }
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
    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let engine else { return }
        let point = recognizer.location(in: engine.view)
        let coordinate = engine.coordinate(recognizer.location(in: engine.view))
        tapGeneration += 1
        let tap = tapGeneration
        Task {
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
                let photoHits = await engine.features(point, layers: ["photos"])
                let items = photoHits.compactMap { hit -> PhotoLibrary.Located? in
                    let i = hit["properties"]["index"].int
                    return self.photos.indices.contains(i) ? self.photos[i] : nil
                }
                if !items.isEmpty {
                    self.present(PhotoGalleryController(items: items, at: 0), animated: true)
                    return
                }
                let airports = await engine.features(point, layers: self.airportHits)
                if let first = airports.first {
                    self.store.place = try await self.store.api.get(
                        "/api/render/reference",
                        query: query([
                            "kind": "airport", "group": first["properties"]["group"].string,
                            "index": first["properties"]["index"].string,
                        ]))
                    return
                }
                let metricHits = await engine.features(point, layers: ["activity-metric"])
                if let index = metricHits.first?["properties"]["i"], self.store.activity.exists {
                    self.store.sample = index.int
                    return
                }
                let routes = await engine.features(point, layers: ["activities"])
                let ids = Array(Set(routes.map { $0["properties"]["id"] }.filter(\.exists).map(\.string)))
                if ids.count == 1 {
                    await self.store.openActivity(.string(ids[0]))
                    return
                }
                if ids.count > 1 {
                    let all = try await self.store.api.get("/api/routes?fold=1")["routes"].array
                    self.store.routeChoices = all.filter { ids.contains($0["id"].string) }
                    return
                }
                if self.store.cellInfo {
                    let data = try await self.store.api.get(
                        "/api/render/at",
                        query: self.store.renderQuery(self.level)
                            + query(["lng": String(coordinate.longitude), "lat": String(coordinate.latitude)])
                    )
                    guard tap == self.tapGeneration else { return }
                    self.store.place = data
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
    private func focus(_ value: JSON) {
        guard let engine else { return }
        var c = engine.camera
        let bbox = value["bbox"].array.map(\.double)
        if bbox.count == 4 {
            let span = bbox[2] >= bbox[0] ? bbox[2] - bbox[0] : bbox[2] + 360 - bbox[0]
            c.center = CLLocationCoordinate2D(
                latitude: (bbox[1] + bbox[3]) / 2, longitude: bbox[0] + span / 2)
            c.zoom = max(1, min(16, log2(360 / max(0.001, max(span, (bbox[3] - bbox[1]) * 2))) - 0.5))
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
        if location.authorizationStatus == .notDetermined {
            location.requestWhenInUseAuthorization()
        } else if location.authorizationStatus == .denied || location.authorizationStatus == .restricted {
            store.error = "Allow location access in iOS Settings to find your position."
            wantsLocation = false
        } else {
            location.requestLocation()
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if wantsLocation, [.authorizedAlways, .authorizedWhenInUse].contains(manager.authorizationStatus) {
            manager.requestLocation()
        }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard wantsLocation, let location = locations.last, let engine else { return }
        wantsLocation = false
        engine.showLocation()
        var c = engine.camera
        c.center = location.coordinate
        c.zoom = max(13, c.zoom)
        engine.setCamera(c, animated: true)
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        wantsLocation = false
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
