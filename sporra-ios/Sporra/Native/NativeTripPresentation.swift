import Foundation

nonisolated enum NativeTripPresentation {
    struct Group {
        let country: String
        let trips: [JSON]
    }
    static func visible(_ trips: [JSON], prefs: JSON) -> [JSON] {
        let hidden = Set(prefs["hiddenTrips"].array.map(\.string))
        return trips.filter { !hidden.contains($0["id"].string) }.sorted {
            if $0["start"].double != $1["start"].double { return $0["start"].double > $1["start"].double }
            return $0["id"].string < $1["id"].string
        }
    }
    static func groups(_ trips: [JSON]) -> [Group] {
        let grouped = Dictionary(grouping: trips) { route in
            route["country"].string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return grouped.keys.sorted {
            if $0.isEmpty != $1.isEmpty { return !$0.isEmpty }
            return $0.localizedStandardCompare($1) == .orderedAscending
        }.map { Group(country: $0.isEmpty ? "Other destinations" : $0, trips: grouped[$0] ?? []) }
    }
}
