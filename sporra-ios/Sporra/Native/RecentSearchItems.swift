/// The empty search view is one chronological feed, with the same trip names
/// and visibility preferences as the Trips screen.
nonisolated enum RecentSearchItems {
    static func combine(routes: [JSON], trips: [JSON], prefs: JSON) -> [JSON] {
        let hidden = Set(prefs["hiddenTrips"].array.map(\.string))
        let activities = NativeActivityCopies.folded(routes).map { route -> JSON in
            var item = route
            item["kind"] = .string("route")
            return item
        }
        let journeys = trips.filter { !hidden.contains($0["id"].string) }.map { trip -> JSON in
            var item = trip
            item["kind"] = .string("trip")
            item["name"] = .string(prefs["tripNames"][trip["id"].string].text(trip["name"].text("Trip")))
            return item
        }
        return Array((activities + journeys).sorted {
            let left = $0[$0["kind"].string == "route" ? "firstAt" : "start"].double
            let right = $1[$1["kind"].string == "route" ? "firstAt" : "start"].double
            if left != right { return left > right }
            return ($0["kind"].string, $0["id"].string) < ($1["kind"].string, $1["id"].string)
        }.prefix(50))
    }
}
