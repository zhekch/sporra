import Foundation
import SporraCore

/// Facts belong to the viewport and filters that supplied them. A missing cell
/// outside that snapshot is unknown, rather than evidence of an unvisited place.
nonisolated struct MapPlaceFacts: Sendable {
    let context: String
    let level: Int
    let bounds: [Double]
    private let cells: Set<String>
    private struct Region: Sendable {
        let feature: JSON
        let polygons: [[Ring]]

        init(_ feature: JSON) {
            self.feature = feature
            let geometry = feature["geometry"]
            let polygons =
                geometry["type"].string == "Polygon"
                ? [geometry["coordinates"]] : geometry["coordinates"].array
            self.polygons = polygons.map { $0.array.map(Ring.init) }
        }

        func contains(lng: Double, lat: Double) -> Bool {
            polygons.contains { rings in
                guard let outer = rings.first, outer.contains(lng: lng, lat: lat) else {
                    return false
                }
                return !rings.dropFirst().contains { $0.contains(lng: lng, lat: lat) }
            }
        }
    }

    private struct Ring: Sendable {
        let points: [SIMD2<Double>]
        let west: Double
        let east: Double
        let south: Double
        let north: Double

        init(_ ring: JSON) {
            var points: [SIMD2<Double>] = []
            var previous = ring.array.first?[0].double ?? 0
            var west = Double.infinity
            var east = -Double.infinity
            var south = Double.infinity
            var north = -Double.infinity
            for point in ring.array {
                var x = point[0].double
                x += ((previous - x) / 360).rounded() * 360
                let y = point[1].double
                points.append(SIMD2(x, y))
                west = min(west, x)
                east = max(east, x)
                south = min(south, y)
                north = max(north, y)
                previous = x
            }
            self.points = points
            self.west = west
            self.east = east
            self.south = south
            self.north = north
        }

        func contains(lng: Double, lat: Double) -> Bool {
            guard points.count >= 3, lat >= south, lat <= north else { return false }
            // Unwrap continuously once at load time. Taps only inspect rings
            // whose bounds contain them, without decoding JSON coordinates.
            let x = lng + (((west + east) / 2 - lng) / 360).rounded() * 360
            guard x >= west, x <= east else { return false }
            var previous = points.last!
            var inside = false
            for point in points {
                if (previous.y > lat) != (point.y > lat),
                    x < (point.x - previous.x) * (lat - previous.y) / (point.y - previous.y)
                        + previous.x
                {
                    inside.toggle()
                }
                previous = point
            }
            return inside
        }
    }

    private let regions: [Region]

    init(context: String, level: Int, bounds: [Double], data: JSON) {
        self.context = context
        self.level = level
        self.bounds = bounds
        cells = Set(data["rows"].array.map { $0[0].string })
        regions = data["infoFeatures"].array.map(Region.init)
    }

    static func placeholder(level: Int, lng: Double, lat: Double) -> JSON {
        var value: JSON = .object([
            "name": .string(
                level < 6
                    ? "This cell"
                    : level == 6 ? "This region" : level == 7 ? "This country" : "This continent"),
            "lng": .number(lng), "lat": .number(lat), "level": .number(Double(level)),
            "loading": .bool(true),
        ])
        if level < 6 {
            let cell = HexGrid.pointToCell(
                level: level, x: HexGrid.mercatorX(lng: lng), y: HexGrid.mercatorY(lat: lat))
            value["cellID"] = .string(HexGrid.cellId(level: level, col: cell.col, row: cell.row))
            let center = HexGrid.cellCenter(level: level, col: cell.col, row: cell.row)
            let radius = HexGrid.radius(level: level) * 0.9
            var ring = (0..<48).map { step in
                let angle = Double(step) * 2 * Double.pi / 48
                return JSON.array([
                    .number(HexGrid.longitude(x: center.x + radius * cos(angle))),
                    .number(HexGrid.latitude(y: center.y + radius * sin(angle))),
                ])
            }
            ring.append(ring[0])
            value["geometry"] = .object([
                "type": .string("Polygon"), "coordinates": .array([.array(ring)]),
            ])
        }
        return value
    }

    func place(context: String, level: Int, lng: Double, lat: Double) -> JSON {
        var value = Self.placeholder(level: level, lng: lng, lat: lat)
        guard self.context == context, self.level == level, bounds.count == 4,
            lat >= bounds[1], lat <= bounds[3],
            bounds[0] <= bounds[2]
                ? (lng >= bounds[0] && lng <= bounds[2]) : (lng >= bounds[0] || lng <= bounds[2])
        else { return value }
        if level < 6 {
            let id = HexGrid.cellId(level: level, lat: lat, lng: lng)
            value["visited"] = .bool(
                cells.contains(id.split(separator: "/").dropFirst().joined(separator: "/")))
        } else if let region = regions.first(where: { $0.contains(lng: lng, lat: lat) }) {
            for (key, fact) in region.feature["properties"].object { value[key] = fact }
            value["geometry"] = region.feature["geometry"]
        }
        return value
    }

}
