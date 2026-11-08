/// Base routes and the selected metric overlay are complementary: the selected
/// route must never be painted twice, even while an HTTP refresh is pending.
nonisolated enum ActivityMapSelection {
    private struct Span: Hashable {
        let x1: Double, y1: Double, x2: Double, y2: Double
        init(_ first: JSON, _ last: JSON) {
            x1 = first[0].double; y1 = first[1].double
            x2 = last[0].double; y2 = last[1].double
        }
    }
    static let empty: JSON = .object(["type": .string("FeatureCollection"), "features": .array([])])

    static func baseRoutes(_ routes: JSON, activity: JSON, solo: Bool) -> JSON {
        guard activity.exists else { return routes }
        if activity["route"]["geom"].array.isEmpty && (activity["loading"].bool || activity["detailsError"].exists) { return routes }
        if solo { return empty }
        var result = routes
        let selected = activity["route"]["id"].string
        result["features"] = .array(
            routes["features"].array.filter { $0["properties"]["id"].string != selected })
        return result
    }

    static func metricOverlay(_ activity: JSON, metric: String) -> JSON {
        guard activity.exists else { return empty }
        let metricFeatures = activity["lines"][metric]["features"].array
        var covered: Set<Span> = []
        for feature in metricFeatures {
            let points = feature["geometry"]["coordinates"].array
            guard feature["geometry"]["type"].string == "LineString", points.count >= 2 else { continue }
            for index in 1..<points.count { covered.insert(Span(points[index - 1], points[index])) }
        }
        var features: [JSON] = []
        for segment in activity["route"]["geom"].array {
            let points = segment.array
            guard points.count >= 2 else { continue }
            for index in 1..<points.count {
                guard !covered.contains(Span(points[index - 1], points[index])) else { continue }
                // A continuous white underlay has different joins from the
                // short metric spans and can peek out along coloured bends.
                // Only paint white where a metric span is actually absent.
                features.append(.object([
                    "type": .string("Feature"),
                    "properties": .object(["color": .string("#ffffff"), "metricOrder": .number(0)]),
                    "geometry": .object(["type": .string("LineString"),
                        "coordinates": .array([points[index - 1], points[index]])]),
                ]))
            }
        }
        features += metricFeatures.map { original in
            var feature = original
            feature["properties"]["metricOrder"] = .number(1)
            return feature
        }
        return .object(["type": .string("FeatureCollection"), "features": .array(features)])
    }
}
