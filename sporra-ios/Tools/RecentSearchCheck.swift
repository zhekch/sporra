@main
struct RecentSearchCheck {
    static func main() throws {
        let routes: [JSON] = [
            .object(["id": .number(1), "firstAt": .number(300), "name": .string("Walk")]),
            .object(["id": .number(2), "firstAt": .number(100), "name": .string("Ride")]),
        ]
        let trips: [JSON] = [
            .object(["id": .string("trip"), "start": .number(200), "name": .string("Original")]),
            .object(["id": .string("hidden"), "start": .number(400)]),
        ]
        let prefs: JSON = .object([
            "tripNames": .object(["trip": .string("Holiday")]),
            "hiddenTrips": .array([.string("hidden")]),
        ])
        let items = RecentSearchItems.combine(routes: routes, trips: trips, prefs: prefs)
        guard items.map({ $0["id"].string }) == ["1", "trip", "2"],
            items.map({ $0["kind"].string }) == ["route", "trip", "route"],
            items[1]["name"].string == "Holiday",
            RecentSearchItems.combine(routes: [], trips: [], prefs: .null).isEmpty
        else { throw ServerFailure(status: 0, message: "Recent search feed regression") }
        guard nativeDateRange(.string("2026-10-27"), .string("2026-10-27")) == "27.10.2026",
            nativeDateRange(.string("2026-10-27"), .string("2026-10-28")) == "27.10.2026 – 28.10.2026",
            NativeSearchPresentation.icon(.object(["kind": .string("trip")])) == "suitcase.rolling",
            NativeSearchPresentation.sportIcon("Running") != NativeSearchPresentation.sportIcon("Cycling"),
            NativeSearchPresentation.sportIcon("unknown custom sport") == "figure.mixed.cardio"
        else { throw ServerFailure(status: 0, message: "Search presentation regression") }
        print("Recent search checks passed: mixed chronology, item types, hidden trips, renamed trips, empty history")
    }
}
