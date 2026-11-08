import Foundation

nonisolated enum ActivityChoices {
    struct Group {
        let sport: String
        let routes: [JSON]
    }
    /// Rendered hits can repeat the same activity for several segments or tiles.
    static func candidates(hits: [JSON], selected: JSON = .null, metadata: [JSON]) -> [JSON] {
        let rows = hits.map { $0["properties"] } + (selected.exists ? [selected] : [])
        var seen: Set<String> = []
        let unique = rows.filter { $0["id"].exists && seen.insert($0["id"].string).inserted }
        return enrich(unique, metadata: metadata)
    }
    static func enrich(_ choices: [JSON], metadata: [JSON], aliases: [String: String] = [:]) -> [JSON] {
        var known: [String: JSON] = [:]
        for route in metadata { known[route["id"].string] = route }
        var seen: Set<String> = []
        let rows = choices.compactMap { original -> JSON? in
            let id = aliases[original["id"].string] ?? original["id"].string
            guard seen.insert(id).inserted else { return nil }
            return known[id] ?? original
        }
        return NativeActivityCopies.folded(rows).map { row in
            .object(row.object.filter { ["id", "name", "sport", "firstAt", "lengthM"].contains($0.key) })
        }
    }
    static func groups(_ choices: [JSON]) -> [Group] {
        let sorted = choices.sorted {
            if $0["firstAt"].double != $1["firstAt"].double { return $0["firstAt"].double > $1["firstAt"].double }
            return $0["id"].string < $1["id"].string
        }
        var sports: [String] = []
        var rows: [String: [JSON]] = [:]
        for route in sorted {
            let sport = route["sport"].string.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = sport.isEmpty ? "Other activities" : sport
            if rows[name] == nil { sports.append(name) }
            rows[name, default: []].append(route)
        }
        return sports.map { Group(sport: $0, routes: rows[$0] ?? []) }
    }
}

/// Additional tight-clock duplicate rule, also used by the web/server folder.
/// The server's folded list already applies its broader, stricter distance rule.
nonisolated enum NativeActivityCopies {
    private static let startSeconds = 5.0
    private static let lengthTolerance = 0.1
    private static let overlapThreshold = 0.6
    static func aliases(_ routes: [JSON]) -> [String: String] {
        let sorted = routes.filter { $0["firstAt"].double > 0 }.sorted { $0["firstAt"].double < $1["firstAt"].double }
        var aliases: [String: String] = [:]
        for (i, a) in sorted.enumerated() where aliases[a["id"].string] == nil {
            for b in sorted.dropFirst(i + 1) {
                if b["firstAt"].double - a["firstAt"].double > startSeconds { break }
                guard aliases[b["id"].string] == nil, sameOuting(a, b) else { continue }
                let keep = preferred(a, b)
                let hidden = keep["id"] == a["id"] ? b : a
                aliases[hidden["id"].string] = keep["id"].string
                if keep["id"] != a["id"] { break }
            }
        }
        for hidden in Array(aliases.keys) {
            var end = aliases[hidden]!
            var seen: Set<String> = [hidden]
            while let next = aliases[end], seen.insert(end).inserted { end = next }
            aliases[hidden] = end
        }
        return aliases
    }
    static func folded(_ routes: [JSON]) -> [JSON] {
        let hidden = aliases(routes)
        return routes.filter { hidden[$0["id"].string] == nil }
    }
    private static func sameOuting(_ a: JSON, _ b: JSON) -> Bool {
        let length = max(a["lengthM"].double, b["lengthM"].double)
        guard a["id"] != b["id"], length > 0,
            abs(a["lengthM"].double - b["lengthM"].double) / length <= lengthTolerance else { return false }
        let x = (a["bounds"].exists ? a["bounds"] : a["bbox"]).array.map(\.double)
        let y = (b["bounds"].exists ? b["bounds"] : b["bbox"]).array.map(\.double)
        guard x.count == 4, y.count == 4 else { return false }
        let overlap = max(0, min(x[2], y[2]) - max(x[0], y[0])) * max(0, min(x[3], y[3]) - max(x[1], y[1]))
        let area: ([Double]) -> Double = { max(0, $0[2] - $0[0]) * max(0, $0[3] - $0[1]) }
        let union = area(x) + area(y) - overlap
        return union > 0 && overlap / union >= overlapThreshold
    }
    private static func preferred(_ a: JSON, _ b: JSON) -> JSON {
        func rank(_ route: JSON) -> [Double] {
            let sourceRanks: [String: Double] = ["komoot": 3, "apple-health": 2, "strava": 1]
            let source = sourceRanks[route["source"].string] ?? 0
            let seconds = route["lastAt"].double - route["firstAt"].double
            let clock = seconds > 0 && route["lengthM"].double * 3.6 / seconds >= 0.5
            return [source, route["link"].string.isEmpty ? 0 : 1, route["sportGuessed"].bool ? 0 : 1,
                clock ? 1 : 0, route["elevUp"].double > 0 ? 1 : 0, route["points"].double]
        }
        for (left, right) in zip(rank(a), rank(b)) where left != right { return right > left ? b : a }
        return a["id"].double <= b["id"].double ? a : b
    }
}
