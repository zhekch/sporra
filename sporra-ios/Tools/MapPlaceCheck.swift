import Foundation
import SporraCore

@main struct MapPlaceCheck {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw ServerFailure(status: 0, message: message) }
    }
    static func main() throws {
        let lng = 8.54
        let lat = 47.37
        let id = HexGrid.cellId(level: 0, lat: lat, lng: lng)
        let key = id.split(separator: "/").dropFirst().joined(separator: "/")
        let facts = MapPlaceFacts(
            context: "account:revision:filters", level: 0, bounds: [8, 47, 9, 48],
            data: .object([
                "rows": .array([.array([.string(key)])])
            ]))
        let cell = facts.place(context: "account:revision:filters", level: 0, lng: lng, lat: lat)
        try check(
            cell["visited"].bool && cell["loading"].bool,
            "known cells display visited status before enrichment")
        try check(
            cell["cellID"].string == id, "selection uses the same canonical cell as rendering")
        let ring = cell["geometry"]["coordinates"][0].array
        try check(
            ring.count == 49 && ring.first == ring.last,
            "selected cell has a closed outline without a server response")
        let selected = HexGrid.parse(cellId: id)!
        let center = HexGrid.cellCenter(level: selected.level, col: selected.col, row: selected.row)
        let radius = HexGrid.radius(level: selected.level) * 0.9
        try check(ring.allSatisfy { point in
            var x = HexGrid.mercatorX(lng: point[0].double)
            x += ((center.x - x) / HexGrid.world).rounded() * HexGrid.world
            let y = HexGrid.mercatorY(lat: point[1].double)
            return abs(hypot(x - center.x, y - center.y) - radius) < 1e-6
        }, "selected cell uses a round Mercator outline centred on the canonical cell")
        try check(
            !facts.place(context: "new filters", level: 0, lng: lng, lat: lat)["visited"].exists,
            "old filters cannot assert visit status")
        try check(
            !facts.place(context: "account:revision:filters", level: 1, lng: lng, lat: lat)[
                "visited"
            ].exists, "old levels cannot assert visit status")
        try check(
            !facts.place(context: "account:revision:filters", level: 0, lng: 10, lat: lat)[
                "visited"
            ].exists, "unloaded viewport stays unknown")
        try check(
            facts.place(context: "account:revision:filters", level: 0, lng: 8.8, lat: lat)[
                "visited"] == .bool(false), "an absent cell in a loaded viewport is unvisited")

        func polygon(_ rings: [[[Double]]]) -> JSON {
            .object([
                "type": .string("Polygon"),
                "coordinates": .array(rings.map { .array($0.map { .array($0.map(JSON.number)) }) }),
            ])
        }
        let geometry = polygon([
            [[8, 47], [9, 47], [9, 48], [8, 48], [8, 47]],
            [[8.1, 47.1], [8.2, 47.1], [8.2, 47.2], [8.1, 47.2], [8.1, 47.1]],
        ])
        let crossing = polygon([[[179, 47], [-179, 47], [-179, 48], [179, 48], [179, 47]]])
        func regionFacts(_ geometry: JSON, bounds: [Double] = [-180, -85, 180, 85]) -> MapPlaceFacts
        {
            MapPlaceFacts(
                context: "regions", level: 6, bounds: bounds,
                data: .object([
                    "infoFeatures": .array([
                        .object([
                            "geometry": geometry,
                            "properties": .object([
                                "name": .string("Known region"), "visited": .bool(true),
                                "covered": .number(12.5),
                            ]),
                        ])
                    ])
                ]))
        }
        let region = regionFacts(geometry).place(context: "regions", level: 6, lng: lng, lat: lat)
        try check(
            region["name"].string == "Known region" && region["geometry"] == geometry
                && region["covered"].double == 12.5,
            "region name, coverage and border are ready without point lookup")
        try check(
            !regionFacts(geometry).place(context: "regions", level: 6, lng: 8.15, lat: 47.15)[
                "visited"
            ].exists, "polygon holes are excluded")
        try check(
            !regionFacts(geometry).place(context: "regions", level: 6, lng: -170, lat: lat)[
                "visited"
            ].exists, "polygon does not select its world complement")
        let wrapped = regionFacts(crossing, bounds: [178, 47, -178, 48])
        for longitude in [179.5, -179.5] {
            try check(
                wrapped.place(context: "regions", level: 6, lng: longitude, lat: lat)["visited"]
                    .bool, "date-line regions work on either side")
        }
        try check(
            !wrapped.place(context: "regions", level: 6, lng: 0, lat: lat)["visited"].exists,
            "wrapped viewport excludes the rest of the world")
        if CommandLine.arguments.count > 1 {
            let raw = try JSONDecoder().decode(
                JSON.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            let features = raw.array.map { region in
                JSON.object([
                    "geometry": region["geometry"],
                    "properties": .object([
                        "name": region["name"], "visited": .bool(true),
                    ]),
                ])
            }
            let world = MapPlaceFacts(
                context: "world", level: 6, bounds: [-180, -85, 180, 85],
                data: .object(["infoFeatures": .array(features)]))
            let start = ContinuousClock.now
            for _ in 0..<100 {
                let selected = world.place(context: "world", level: 6, lng: lng, lat: lat)
                try check(
                    selected["name"].string == "Zürich",
                    "full-world region lookup selects the correct canton")
            }
            let elapsed = start.duration(to: .now)
            let milliseconds =
                Double(elapsed.components.seconds) * 1000
                + Double(elapsed.components.attoseconds) / 1e15
            print(
                String(
                    format: "Full-world hit testing: %d regions, %.3f ms per tap (Mac fixture)",
                    features.count, milliseconds / 100))
        }
        print("Map place facts and selection geometry checks passed")
    }
}
