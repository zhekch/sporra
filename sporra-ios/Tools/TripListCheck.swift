import Foundation

@main
struct TripListCheck {
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ServerFailure(status: 0, message: message) }
        print("  ok  " + message)
    }
    static func main() throws {
        func trip(_ id: Int, _ country: String, _ start: Double) -> JSON {
            .object(["id": .number(Double(id)), "country": .string(country), "start": .number(start)])
        }
        let trips = [trip(1, "Switzerland", 100), trip(2, "Greece", 300), trip(3, "Switzerland", 200), trip(4, "", 400), trip(5, "Greece", 500)]
        let visible = NativeTripPresentation.visible(trips, prefs: .object(["hiddenTrips": .strings(["5"])]))
        try check(visible.map { $0["id"].int } == [4, 2, 3, 1], "date order is newest first and hidden trips stay hidden")
        let groups = NativeTripPresentation.groups(visible)
        try check(groups.map(\.country) == ["Greece", "Switzerland", "Other destinations"], "country order is alphabetical with unknown destinations last")
        try check(groups[1].trips.map { $0["id"].int } == [3, 1], "country groups retain newest-first trip order")
        try check(nativeDateRange(.string("2026-10-27"), .string("2026-10-27")) == "27.10.2026", "a single-day trip displays its date once")
        try check(nativeDateRange(.string("2026-10-27"), .string("2026-10-28")) == "27.10.2026 – 28.10.2026", "multi-day trips keep both dates")
        try check(NativeTripPresentation.visible([], prefs: .null).isEmpty && NativeTripPresentation.groups([]).isEmpty, "empty histories have no country sections")
        print("Trip list checks passed")
    }
}
