import CoreLocation
import MapLibre
import MapboxMaps
import UIKit

private let fitSeedZoom = 12.0
private let libreFitIterations = 8

extension JSON {
    var foundation: Any {
        (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) ?? NSNull()
    }
}
extension UIColor {
    nonisolated convenience init(mapColor: String) {
        if mapColor.hasPrefix("rgb") {
            let values = mapColor.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(
                Double.init)
            self.init(
                red: (values.first ?? 96) / 255, green: (values.dropFirst().first ?? 172) / 255,
                blue: (values.dropFirst(2).first ?? 255) / 255, alpha: 1)
        } else {
            let s = mapColor.replacingOccurrences(of: "#", with: "")
            let n = UInt64(s.prefix(6), radix: 16) ?? 0x60acff
            self.init(
                red: CGFloat((n >> 16) & 255) / 255, green: CGFloat((n >> 8) & 255) / 255,
                blue: CGFloat(n & 255) / 255, alpha: 1)
        }
    }
}
struct MapCamera {
    var center: CLLocationCoordinate2D
    var zoom: Double
    var pitch: Double
    var bearing: Double
}
@MainActor
protocol MapEngine: AnyObject {
    var view: UIView { get }
    var camera: MapCamera { get }
    var userCoordinate: CLLocationCoordinate2D? { get }
    var ready: (() -> Void)? { get set }
    var moved: (() -> Void)? { get set }
    func coordinate(_ point: CGPoint) -> CLLocationCoordinate2D
    func point(_ coordinate: CLLocationCoordinate2D) -> CGPoint
    func setCamera(_ camera: MapCamera, animated: Bool)
    func fit(_ bounds: [Double], padding: UIEdgeInsets, animated: Bool)
    func setVisitOpacity(_ opacity: Double)
    func bounds() -> [Double]
    func source(_ id: String, definition: JSON) throws
    func layer(_ definition: JSON) throws
    func remove(_ id: String)
    func image(_ id: String, image: UIImage, bounds: [Double], opacity: Double) throws
    func features(_ point: CGPoint, layers: [String], radius: CGFloat) async -> [JSON]
    func photoIndices(at point: CGPoint) async -> [Int]
    func snapshot() throws -> UIImage
    func addImage(_ image: UIImage, id: String) throws
    func showLocation()
}

extension MapEngine {
    func features(_ point: CGPoint, layers: [String]) async -> [JSON] {
        await features(point, layers: layers, radius: 8)
    }
}

final class LibreEngine: NSObject, MapEngine, MLNMapViewDelegate {
    let map: MLNMapView
    private var basemapLabelIDs: Set<String> = []
    private var imageSwaps = MapImageSwapState()
    private var frameStartedAt = Date.distantPast
    var ready: (() -> Void)?
    var moved: (() -> Void)?
    var view: UIView { map }
    init(frame: CGRect, styleURL: URL) {
        map = MLNMapView(frame: frame, styleURL: styleURL)
        super.init()
        map.delegate = self
        map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        map.showsUserLocation = [.authorizedAlways, .authorizedWhenInUse].contains(
            CLLocationManager().authorizationStatus)
        map.maximumPitch = 60
        // All occlusion is passed explicitly to fit; ancestor safe-area changes
        // must not introduce a second, changing set of camera insets.
        map.automaticallyAdjustsContentInset = false
        map.contentInset = .zero
    }
    var camera: MapCamera {
        MapCamera(
            center: map.centerCoordinate, zoom: map.zoomLevel, pitch: map.camera.pitch, bearing: map.direction
        )
    }
    var userCoordinate: CLLocationCoordinate2D? { map.userLocation?.location?.coordinate }
    func point(_ coordinate: CLLocationCoordinate2D) -> CGPoint {
        map.convert(coordinate, toPointTo: map)
    }
    func coordinate(_ point: CGPoint) -> CLLocationCoordinate2D { map.convert(point, toCoordinateFrom: map) }
    func setCamera(_ c: MapCamera, animated: Bool) {
        // A second camera update during setCenter's animation can restore the
        // old center. Apply center, zoom, pitch and bearing in one transaction.
        let target = MLNMapCamera(
            lookingAtCenter: c.center,
            altitude: MLNAltitudeForZoomLevel(c.zoom, CGFloat(c.pitch), c.center.latitude, map.bounds.size),
            pitch: CGFloat(c.pitch), heading: c.bearing)
        map.setCamera(target, animated: animated)
    }
    func fit(_ bounds: [Double], padding: UIEdgeInsets, animated: Bool) {
        let east = bounds[2] >= bounds[0] ? bounds[2] : bounds[2] + 360
        let box = MLNCoordinateBounds(sw: .init(latitude: bounds[1], longitude: bounds[0]), ne: .init(latitude: bounds[3], longitude: east))
        let longitude = (bounds[0] + east) / 2
        let center = CLLocationCoordinate2D(latitude: (bounds[1] + bounds[3]) / 2,
            longitude: longitude - floor((longitude + 180) / 360) * 360)
        let current = map.camera
        let seed = MLNMapCamera(lookingAtCenter: center,
            altitude: MLNAltitudeForZoomLevel(fitSeedZoom, current.pitch, center.latitude, map.bounds.size),
            pitch: current.pitch, heading: current.heading)
        // Fit on an independent projection so the existing pitched camera
        // cannot make repeated requests converge toward different answers.
        let projection = map.mapProjection()
        projection.setCamera(seed, with: .zero)
        // The SDK's pitched fit is iterative. Settle it on the projection,
        // then animate the visible map only once to the final camera.
        for _ in 0..<libreFitIterations {
            projection.setVisibleCoordinateBounds(box, edgePadding: padding)
        }
        map.setCamera(projection.camera, withDuration: animated ? 0.45 : 0,
            animationTimingFunction: nil, edgePadding: padding, completionHandler: nil)
    }
    func setVisitOpacity(_ opacity: Double) {
        if let id = imageSwaps.updateOpacity("visited-blob", opacity: opacity) {
            (map.style?.layer(withIdentifier: id) as? MLNRasterStyleLayer)?.rasterOpacity = NSExpression(forConstantValue: opacity)
        }
        for id in ["visited-regions", "foreground-cells"] {
            (map.style?.layer(withIdentifier: id) as? MLNFillStyleLayer)?.fillOpacity = NSExpression(forConstantValue: opacity)
        }
    }
    func bounds() -> [Double] {
        let b = map.visibleCoordinateBounds
        return [b.sw.longitude, b.sw.latitude, b.ne.longitude, b.ne.latitude]
    }
    func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
        basemapLabelIDs = NativeLayerOrder.labelsAboveGeometry(
            orderedIDs: style.layers.map(\.identifier),
            symbolIDs: Set(style.layers.compactMap { ($0 as? MLNSymbolStyleLayer)?.identifier }))
        ready?()
    }
    func mapViewRegionIsChanging(_ mapView: MLNMapView) { moved?() }
    func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) { moved?() }
    func mapViewWillStartRenderingFrame(_ mapView: MLNMapView) { frameStartedAt = Date() }
    func mapViewDidFinishRenderingFrame(_ mapView: MLNMapView, fullyRendered: Bool) {
        for image in imageSwaps.rendered(after: frameStartedAt) {
            MapPerformance.report("image-visible", since: .now, count: image.previous == nil ? 1 : 2)
            (map.style?.layer(withIdentifier: image.id) as? MLNRasterStyleLayer)?.rasterOpacity = NSExpression(forConstantValue: image.opacity)
            if let previous = image.previous { remove(previous) }
        }
    }
    func source(_ id: String, definition: JSON) throws {
        guard let style = map.style else { return }
        if definition["type"].string == "geojson" {
            let shape = try MLNShape(data: definition["data"].data, encoding: String.Encoding.utf8.rawValue)
            if let source = style.source(withIdentifier: id) as? MLNShapeSource {
                source.shape = shape
            } else {
                var options: [MLNShapeSourceOption: Any] = [.simplificationTolerance: 0]
                if definition["cluster"].bool {
                    options[.clustered] = true
                    options[.clusterRadius] = definition["clusterRadius"].int
                    options[.maximumZoomLevelForClustering] = definition["clusterMaxZoom"].int
                    options[.maximumZoomLevel] = definition["maxzoom"].int
                }
                style.addSource(MLNShapeSource(identifier: id, shape: shape, options: options))
            }
        } else if style.source(withIdentifier: id) == nil {
            let tiles = definition["tiles"].array.map(\.string)
            let options: [MLNTileSourceOption: Any] = [
                .minimumZoomLevel: definition["minzoom"].exists ? definition["minzoom"].double : 0,
                .maximumZoomLevel: definition["maxzoom"].exists ? definition["maxzoom"].double : 22,
                .tileSize: definition["tileSize"].exists ? definition["tileSize"].int : 256,
            ]
            if definition["type"].string == "raster" {
                style.addSource(
                    MLNRasterTileSource(identifier: id, tileURLTemplates: tiles, options: options))
            } else if let url = URL(string: definition["url"].string), tiles.isEmpty {
                style.addSource(MLNVectorTileSource(identifier: id, configurationURL: url))
            } else {
                style.addSource(
                    MLNVectorTileSource(identifier: id, tileURLTemplates: tiles, options: options))
            }
        }
    }
    func layer(_ d: JSON) throws {
        guard let style = map.style, let source = style.source(withIdentifier: d["source"].string) else {
            return
        }
        let id = d["id"].string
        let layer: MLNStyleLayer
        if let existing = style.layer(withIdentifier: id) {
            layer = existing
        } else {
            switch d["type"].string {
            case "fill": layer = MLNFillStyleLayer(identifier: id, source: source)
            case "line": layer = MLNLineStyleLayer(identifier: id, source: source)
            case "circle": layer = MLNCircleStyleLayer(identifier: id, source: source)
            case "symbol": layer = MLNSymbolStyleLayer(identifier: id, source: source)
            default: layer = MLNRasterStyleLayer(identifier: id, source: source)
            }
            if let vector = layer as? MLNVectorStyleLayer {
                vector.sourceLayerIdentifier = d["source-layer"].exists ? d["source-layer"].string : nil
                if d["filter"].exists {
                    vector.predicate = NSPredicate(mglJSONObject: d["filter"].foundation)
                }
            }
            if d["minzoom"].exists { layer.minimumZoomLevel = Float(d["minzoom"].double) }
            if d["maxzoom"].exists { layer.maximumZoomLevel = Float(d["maxzoom"].double) }
            if let anchor = NativeLayerOrder.anchor(
                for: id, orderedIDs: style.layers.map(\.identifier), basemapLabels: basemapLabelIDs),
                let label = style.layer(withIdentifier: anchor)
            {
                style.insertLayer(layer, below: label)
            } else {
                style.addLayer(layer)
            }
        }
        let aliases = [
            "line-dasharray": "lineDashPattern", "line-gap-width": "lineGapWidth", "text-field": "text",
            "text-font": "textFontNames", "text-size": "textFontSize", "icon-image": "iconImageName",
            "icon-size": "iconScale", "icon-rotate": "iconRotation", "text-rotate": "textRotation",
            "icon-allow-overlap": "iconAllowsOverlap", "text-allow-overlap": "textAllowsOverlap",
            "icon-ignore-placement": "iconIgnoresPlacement", "text-ignore-placement": "textIgnoresPlacement",
            "text-justify": "textJustification", "text-max-width": "maximumTextWidth",
            "text-max-angle": "maximumTextAngle", "symbol-avoid-edges": "symbolAvoidsEdges",
            "text-keep-upright": "keepsTextUpright", "icon-keep-upright": "keepsIconUpright",
            "text-writing-mode": "textWritingModes",
        ]
        for (key, value) in d["paint"].object.merging(d["layout"].object, uniquingKeysWith: { _, b in b }) {
            if key == "visibility" {
                layer.isVisible = value.string != "none"
                continue
            }
            let pieces = key.split(separator: "-").map(String.init)
            let name =
                aliases[key]
                ?? ((pieces.first ?? "")
                    + pieces.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined())
            let selector = NSSelectorFromString("set" + name.prefix(1).uppercased() + name.dropFirst() + ":")
            guard layer.responds(to: selector) else { continue }
            let expression: NSExpression
            if key.hasSuffix("color"), case .string(let color) = value {
                expression = NSExpression(forConstantValue: UIColor(mapColor: color))
            } else if [
                "text-offset", "icon-offset", "line-translate", "fill-translate", "text-translate",
                "icon-translate",
            ].contains(key), value.array.count == 2, case .number = value[0] {
                expression = NSExpression(
                    forConstantValue: NSValue(cgVector: CGVector(dx: value[0].double, dy: value[1].double)))
            } else if key == "icon-text-fit-padding", value.array.count == 4, case .number = value[0] {
                expression = NSExpression(
                    forConstantValue: NSValue(
                        uiEdgeInsets: UIEdgeInsets(
                            top: value[0].double, left: value[3].double, bottom: value[2].double,
                            right: value[1].double)))
            } else if value[0].string == "literal" {
                expression = NSExpression(forConstantValue: value[1].foundation)
            } else if [
                "line-dasharray", "text-font", "text-offset", "icon-offset", "text-variable-anchor",
                "icon-text-fit-padding",
            ].contains(key), !value.array.isEmpty,
                value.array.first?.string.isEmpty == true || key == "text-font"
            {
                expression = NSExpression(forConstantValue: value.foundation)
            } else {
                expression = NSExpression(mglJSONObject: value.foundation)
            }
            layer.setValue(expression, forKey: name)
        }
    }
    func remove(_ id: String) {
        for buffered in imageSwaps.remove(id) { remove(buffered) }
        guard let style = map.style else { return }
        if let layer = style.layer(withIdentifier: id) { style.removeLayer(layer) }
        if let source = style.source(withIdentifier: id) { style.removeSource(source) }
    }
    func image(_ logical: String, image: UIImage, bounds b: [Double], opacity: Double) throws {
        guard let style = map.style else { return }
        let swap = imageSwaps.begin(logical, opacity: opacity)
        if let discard = swap.discard { remove(discard) }
        let id = swap.image.id
        do {
            let east = b[2] <= b[0] ? b[2] + 360 : b[2]
            let quad = MLNCoordinateQuad(
                topLeft: .init(latitude: b[3], longitude: b[0]),
                bottomLeft: .init(latitude: b[1], longitude: b[0]),
                bottomRight: .init(latitude: b[1], longitude: east),
                topRight: .init(latitude: b[3], longitude: east))
            style.addSource(MLNImageSource(identifier: id, coordinateQuad: quad, image: image))
            try layer(.object([
                "id": .string(id), "source": .string(id), "type": .string("raster"),
                "paint": .object(["raster-opacity": .number(0.0001), "raster-fade-duration": .number(0)]),
            ]))
            (style.layer(withIdentifier: id) as? MLNRasterStyleLayer)?.rasterOpacityTransition = MLNTransition(duration: 0, delay: 0)
            // Local UIImage sources do not reliably emit sourceDidChange.
            // The pixels are already supplied; reveal them after the next frame.
            imageSwaps.prepared(id)
        } catch { remove(id); throw error }
    }
    func features(_ point: CGPoint, layers: [String], radius: CGFloat) async -> [JSON] {
        let layers = layers.filter { map.style?.layer(withIdentifier: $0) != nil }
        guard !layers.isEmpty else { return [] }
        return map.visibleFeatures(
            in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2),
            styleLayerIdentifiers: Set(layers)
        ).compactMap { feature in
            let shape = feature as? MLNShape
            return shape.flatMap {
                try? JSONDecoder().decode(
                    JSON.self, from: $0.geoJSONData(usingEncoding: String.Encoding.utf8.rawValue))
            }
        }
    }
    func photoIndices(at point: CGPoint) async -> [Int] {
        guard let source = map.style?.source(withIdentifier: "photos") as? MLNShapeSource else { return [] }
        let hits = map.visibleFeatures(in: CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16),
            styleLayerIdentifiers: Set(["photos", "photos-cluster"]))
        guard let hit = hits.first else { return [] }
        let leaves: [any MLNFeature]
        if let cluster = hit as? MLNPointFeatureCluster {
            let count = (cluster.attribute(forKey: "point_count") as? NSNumber)?.intValue ?? 0
            leaves = source.leaves(of: cluster, offset: 0, limit: UInt(count))
        } else { leaves = [hit] }
        return leaves.compactMap { ($0.attribute(forKey: "index") as? NSNumber)?.intValue }
    }
    func snapshot() throws -> UIImage {
        let r = UIGraphicsImageRenderer(bounds: map.bounds)
        return r.image { _ in map.drawHierarchy(in: map.bounds, afterScreenUpdates: true) }
    }
    func showLocation() { map.showsUserLocation = true }
    func addImage(_ image: UIImage, id: String) throws {
        map.style?.setImage(
            id.contains("-sdf:") ? image.withRenderingMode(.alwaysTemplate) : image, forName: id)
    }
}

final class BoxEngine: MapEngine {
    let map: MapboxMaps.MapView
    var ready: (() -> Void)?
    var moved: (() -> Void)?
    var view: UIView { map }
    private var observations: [AnyCancelable] = []
    private var imageSwaps = MapImageSwapState()
    init(frame: CGRect, token: String, satellite: Bool, light: String) {
        MapboxOptions.accessToken = token
        map = MapboxMaps.MapView(
            frame: frame,
            mapInitOptions: MapInitOptions(
                styleURI: StyleURI(
                    rawValue: satellite
                        ? "mapbox://styles/mapbox/standard-satellite" : "mapbox://styles/mapbox/standard")))
        map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if [.authorizedAlways, .authorizedWhenInUse].contains(CLLocationManager().authorizationStatus) {
            map.location.options.puckType = .puck2D()
        }
        map.mapboxMap.onStyleLoaded.observe { [weak self] _ in
            guard let self else { return }
            try? self.map.mapboxMap.setStyleImportConfigProperty(
                for: "basemap", config: "lightPreset", value: light)
            self.ready?()
        }.store(in: &observations)
        map.mapboxMap.onCameraChanged.observe { [weak self] _ in self?.moved?() }.store(in: &observations)
        map.mapboxMap.onRenderFrameFinished.observe { [weak self] event in
            guard let self else { return }
            for image in self.imageSwaps.rendered(after: event.timeInterval.begin) {
                MapPerformance.report("image-visible", since: .now, count: image.previous == nil ? 1 : 2)
                do {
                    try self.map.mapboxMap.setLayerProperty(for: image.id, property: "raster-opacity", value: image.opacity)
                } catch { if MapPerformance.enabled { print("[sporra-map] image opacity update failed") } }
                if let previous = image.previous { self.remove(previous) }
            }
        }.store(in: &observations)
    }
    var camera: MapCamera {
        let c = map.mapboxMap.cameraState
        return MapCamera(center: c.center, zoom: c.zoom, pitch: c.pitch, bearing: c.bearing)
    }
    var userCoordinate: CLLocationCoordinate2D? { map.location.latestLocation?.coordinate }
    func point(_ coordinate: CLLocationCoordinate2D) -> CGPoint {
        map.mapboxMap.point(for: coordinate)
    }
    func coordinate(_ point: CGPoint) -> CLLocationCoordinate2D { map.mapboxMap.coordinate(for: point) }
    func setCamera(_ c: MapCamera, animated: Bool) {
        let options = CameraOptions(center: c.center, zoom: c.zoom, bearing: c.bearing, pitch: c.pitch)
        if animated {
            map.camera.ease(to: options, duration: 0.45)
        } else {
            map.mapboxMap.setCamera(to: options)
        }
    }
    func fit(_ bounds: [Double], padding: UIEdgeInsets, animated: Bool) {
        let east = bounds[2] >= bounds[0] ? bounds[2] : bounds[2] + 360
        let coordinates = [
            CLLocationCoordinate2D(latitude: bounds[1], longitude: bounds[0]),
            CLLocationCoordinate2D(latitude: bounds[3], longitude: east),
            CLLocationCoordinate2D(latitude: bounds[3], longitude: bounds[0]),
            CLLocationCoordinate2D(latitude: bounds[1], longitude: east),
        ]
        let longitude = (bounds[0] + east) / 2
        let center = CLLocationCoordinate2D(latitude: (bounds[1] + bounds[3]) / 2,
            longitude: longitude - floor((longitude + 180) / 360) * 360)
        // A fixed starting transform makes Globe fitting independent of the
        // current zoom/center, instead of converging over repeated Focus taps.
        let camera = CameraOptions(center: center, padding: .zero, zoom: fitSeedZoom,
            bearing: self.camera.bearing, pitch: self.camera.pitch)
        guard let target = try? map.mapboxMap.camera(for: coordinates, camera: camera,
            coordinatesPadding: padding, maxZoom: Double(map.mapboxMap.cameraBounds.maxZoom), offset: nil) else { return }
        map.camera.cancelAnimations()
        if animated { map.camera.ease(to: target, duration: 0.45) }
        else { map.mapboxMap.setCamera(to: target) }
    }
    func setVisitOpacity(_ opacity: Double) {
        if let id = imageSwaps.updateOpacity("visited-blob", opacity: opacity) {
            try? map.mapboxMap.setLayerProperty(for: id, property: "raster-opacity", value: opacity)
        }
        for id in ["visited-regions", "foreground-cells"] where map.mapboxMap.layerExists(withId: id) {
            try? map.mapboxMap.setLayerProperty(for: id, property: "fill-opacity", value: opacity)
        }
    }
    func bounds() -> [Double] {
        // The CGRect overload only projects two screen corners. After rotation,
        // bottom-left can be north of top-right and is no longer southwest.
        let camera = map.mapboxMap.cameraState
        let b = map.mapboxMap.coordinateBoundsUnwrapped(for: CameraOptions(
            center: camera.center, padding: camera.padding, zoom: camera.zoom,
            bearing: camera.bearing, pitch: camera.pitch))
        return [b.southwest.longitude, b.southwest.latitude, b.northeast.longitude, b.northeast.latitude]
    }
    func source(_ id: String, definition: JSON) throws {
        if map.mapboxMap.sourceExists(withId: id) {
            if definition["type"].string == "geojson" {
                try map.mapboxMap.setSourceProperty(
                    for: id, property: "data", value: definition["data"].foundation)
            }
        } else {
            try map.mapboxMap.addSource(
                withId: id, properties: definition.foundation as? [String: Any] ?? [:])
        }
    }
    func layer(_ input: JSON) throws {
        let definition = NativeLayerOrder.mapboxLayer(input)
        let id = definition["id"].string
        if map.mapboxMap.layerExists(withId: id) {
            for (key, value) in definition["paint"].object {
                try map.mapboxMap.setLayerProperty(for: id, property: key, value: value.foundation)
            }
        } else {
            let anchor = NativeLayerOrder.anchor(for: id,
                orderedIDs: map.mapboxMap.allLayerIdentifiers.map(\.id).filter {
                    // Cross-slot positions cannot order Standard's layers.
                    NativeLayerOrder.mapboxSlot(for: $0) == definition["slot"].string
                })
            try map.mapboxMap.addLayer(
                with: definition.foundation as? [String: Any] ?? [:],
                layerPosition: anchor.map { .below($0) })
        }
    }
    func remove(_ id: String) {
        for buffered in imageSwaps.remove(id) { remove(buffered) }
        if map.mapboxMap.layerExists(withId: id) { try? map.mapboxMap.removeLayer(withId: id) }
        if map.mapboxMap.sourceExists(withId: id) { try? map.mapboxMap.removeSource(withId: id) }
    }
    func image(_ logical: String, image: UIImage, bounds b: [Double], opacity: Double) throws {
        let swap = imageSwaps.begin(logical, opacity: opacity)
        if let discard = swap.discard { remove(discard) }
        let id = swap.image.id
        do {
            let east = b[2] <= b[0] ? b[2] + 360 : b[2]
            let coordinates = [[b[0], b[3]], [east, b[3]], [east, b[1]], [b[0], b[1]]]
            try map.mapboxMap.addSource(withId: id, properties: ["type": "image", "coordinates": coordinates])
            try map.mapboxMap.updateImageSource(withId: id, image: image)
            try layer(.object([
                "id": .string(id), "type": .string("raster"), "source": .string(id),
                "paint": .object([
                    "raster-opacity": .number(0.0001), "raster-fade-duration": .number(0),
                    "raster-opacity-transition": .object(["duration": .number(0), "delay": .number(0)]),
                ]),
            ]))
            // updateImageSource has accepted the local pixels. No network
            // source-data event is needed before the next frame can show them.
            imageSwaps.prepared(id)
        } catch { remove(id); throw error }
    }
    func features(_ point: CGPoint, layers: [String], radius: CGFloat) async -> [JSON] {
        let layers = layers.filter { map.mapboxMap.layerExists(withId: $0) }
        guard !layers.isEmpty else { return [] }
        return await withCheckedContinuation { continuation in
            map.mapboxMap.queryRenderedFeatures(
                with: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2),
                options: RenderedQueryOptions(layerIds: layers, filter: nil)
            ) { result in
                let features = (try? result.get()) ?? []
                continuation.resume(
                    returning: features.compactMap {
                        try? JSONDecoder().decode(
                            JSON.self, from: JSONEncoder().encode($0.queriedFeature.feature))
                    })
            }
        }
    }
    func photoIndices(at point: CGPoint) async -> [Int] {
        let hits = await features(point, layers: ["photos", "photos-cluster"])
        guard let hit = hits.first else { return [] }
        if !hit["properties"]["cluster_id"].exists {
            return hit["properties"]["index"].exists ? [hit["properties"]["index"].int] : []
        }
        guard let feature = try? JSONDecoder().decode(Feature.self, from: hit.data) else { return [] }
        return await withCheckedContinuation { continuation in
            map.mapboxMap.getGeoJsonClusterLeaves(forSourceId: "photos", feature: feature,
                limit: UInt64(max(0, hit["properties"]["point_count"].int)), offset: 0) { result in
                let leaves = (try? result.get().features) ?? []
                let indices = leaves.compactMap { leaf -> Int? in
                    guard let data = try? JSONEncoder().encode(leaf),
                        let json = try? JSONDecoder().decode(JSON.self, from: data),
                        json["properties"]["index"].exists else { return nil }
                    return json["properties"]["index"].int
                }
                continuation.resume(returning: indices)
            }
        }
    }
    func snapshot() throws -> UIImage { try map.snapshot(includeOverlays: true) }
    func showLocation() { map.location.options.puckType = .puck2D() }
    func addImage(_ image: UIImage, id: String) throws {
        try map.mapboxMap.addImage(image, id: id, sdf: id.contains("-sdf:"))
    }
}
