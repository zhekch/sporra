import CoreLocation
import MapLibre
import MapboxMaps
import UIKit

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
    var ready: (() -> Void)? { get set }
    var moved: (() -> Void)? { get set }
    func coordinate(_ point: CGPoint) -> CLLocationCoordinate2D
    func setCamera(_ camera: MapCamera, animated: Bool)
    func bounds() -> [Double]
    func source(_ id: String, definition: JSON) throws
    func layer(_ definition: JSON) throws
    func remove(_ id: String)
    func image(_ id: String, image: UIImage, bounds: [Double], opacity: Double) throws
    func features(_ point: CGPoint, layers: [String]) async -> [JSON]
    func snapshot() throws -> UIImage
    func addImage(_ image: UIImage, id: String) throws
    func showLocation()
}

final class LibreEngine: NSObject, MapEngine, MLNMapViewDelegate {
    let map: MLNMapView
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
    }
    var camera: MapCamera {
        MapCamera(
            center: map.centerCoordinate, zoom: map.zoomLevel, pitch: map.camera.pitch, bearing: map.direction
        )
    }
    func coordinate(_ point: CGPoint) -> CLLocationCoordinate2D { map.convert(point, toCoordinateFrom: map) }
    func setCamera(_ c: MapCamera, animated: Bool) {
        map.setCenter(c.center, zoomLevel: c.zoom, direction: c.bearing, animated: animated)
        let camera = map.camera
        camera.pitch = c.pitch
        map.setCamera(camera, animated: animated)
    }
    func bounds() -> [Double] {
        let b = map.visibleCoordinateBounds
        return [b.sw.longitude, b.sw.latitude, b.ne.longitude, b.ne.latitude]
    }
    func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) { ready?() }
    func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) { moved?() }
    func source(_ id: String, definition: JSON) throws {
        guard let style = map.style else { return }
        if definition["type"].string == "geojson" {
            let shape = try MLNShape(data: definition["data"].data, encoding: String.Encoding.utf8.rawValue)
            if let source = style.source(withIdentifier: id) as? MLNShapeSource {
                source.shape = shape
            } else {
                style.addSource(
                    MLNShapeSource(identifier: id, shape: shape, options: [.simplificationTolerance: 0]))
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
            style.addLayer(layer)
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
        guard let style = map.style else { return }
        if let layer = style.layer(withIdentifier: id) { style.removeLayer(layer) }
        if let source = style.source(withIdentifier: id) { style.removeSource(source) }
    }
    func image(_ id: String, image: UIImage, bounds b: [Double], opacity: Double) throws {
        guard let style = map.style else { return }
        let east = b[2] <= b[0] ? b[2] + 360 : b[2]
        let quad = MLNCoordinateQuad(
            topLeft: .init(latitude: b[3], longitude: b[0]),
            bottomLeft: .init(latitude: b[1], longitude: b[0]),
            bottomRight: .init(latitude: b[1], longitude: east),
            topRight: .init(latitude: b[3], longitude: east))
        if let source = style.source(withIdentifier: id) as? MLNImageSource {
            source.image = image
            source.coordinates = quad
        } else {
            style.addSource(MLNImageSource(identifier: id, coordinateQuad: quad, image: image))
        }
        try layer(
            .object([
                "id": .string(id), "source": .string(id), "type": .string("raster"),
                "paint": .object(["raster-opacity": .number(opacity), "raster-fade-duration": .number(0)]),
            ]))
    }
    func features(_ point: CGPoint, layers: [String]) async -> [JSON] {
        map.visibleFeatures(
            in: CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16),
            styleLayerIdentifiers: Set(layers)
        ).compactMap { feature in
            let shape = feature as? MLNShape
            return shape.flatMap {
                try? JSONDecoder().decode(
                    JSON.self, from: $0.geoJSONData(usingEncoding: String.Encoding.utf8.rawValue))
            }
        }
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
        map.mapboxMap.onMapIdle.observe { [weak self] _ in self?.moved?() }.store(in: &observations)
    }
    var camera: MapCamera {
        let c = map.mapboxMap.cameraState
        return MapCamera(center: c.center, zoom: c.zoom, pitch: c.pitch, bearing: c.bearing)
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
    func bounds() -> [Double] {
        let b = map.mapboxMap.coordinateBounds(for: map.bounds)
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
    func layer(_ definition: JSON) throws {
        let id = definition["id"].string
        if map.mapboxMap.layerExists(withId: id) {
            for (key, value) in definition["paint"].object {
                try map.mapboxMap.setLayerProperty(for: id, property: key, value: value.foundation)
            }
        } else {
            try map.mapboxMap.addLayer(
                with: definition.foundation as? [String: Any] ?? [:], layerPosition: nil)
        }
    }
    func remove(_ id: String) {
        if map.mapboxMap.layerExists(withId: id) { try? map.mapboxMap.removeLayer(withId: id) }
        if map.mapboxMap.sourceExists(withId: id) { try? map.mapboxMap.removeSource(withId: id) }
    }
    func image(_ id: String, image: UIImage, bounds b: [Double], opacity: Double) throws {
        let east = b[2] <= b[0] ? b[2] + 360 : b[2]
        let coordinates = [[b[0], b[3]], [east, b[3]], [east, b[1]], [b[0], b[1]]]
        if map.mapboxMap.sourceExists(withId: id) {
            try map.mapboxMap.setSourceProperty(for: id, property: "coordinates", value: coordinates)
        } else {
            try map.mapboxMap.addSource(
                withId: id, properties: ["type": "image", "coordinates": coordinates])
        }
        try map.mapboxMap.updateImageSource(withId: id, image: image)
        try layer(
            .object([
                "id": .string(id), "type": .string("raster"), "source": .string(id),
                "paint": .object(["raster-opacity": .number(opacity), "raster-fade-duration": .number(0)]),
            ]))
    }
    func features(_ point: CGPoint, layers: [String]) async -> [JSON] {
        await withCheckedContinuation { continuation in
            map.mapboxMap.queryRenderedFeatures(
                with: CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16),
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
    func snapshot() throws -> UIImage { try map.snapshot(includeOverlays: true) }
    func showLocation() { map.location.options.puckType = .puck2D() }
    func addImage(_ image: UIImage, id: String) throws {
        try map.mapboxMap.addImage(image, id: id, sdf: id.contains("-sdf:"))
    }
}
