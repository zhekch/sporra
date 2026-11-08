import Foundation

@main
struct TrackCardCheck {
    static func main() throws {
        func check(_ ok: Bool, _ message: String) throws {
            guard ok else { throw ServerFailure(status: 0, message: message) }
        }
        try check(TrackCardNavigation.swipe(x: -65, y: 4) == .next, "left swipe advances")
        try check(TrackCardNavigation.swipe(x: 65, y: -4) == .previous, "right swipe goes back")
        try check(TrackCardNavigation.swipe(x: 5, y: -60) == .expand, "swipe up expands days")
        try check(TrackCardNavigation.swipe(x: 5, y: 60) == .collapse, "swipe down collapses days")
        try check(TrackCardNavigation.swipe(x: 10, y: 5) == .none, "small movements are ignored")
        try check(
            TrackCardNavigation.swipe(x: 50, y: 50) == .none, "ambiguous diagonals are ignored")
        try check(
            TrackCardNavigation.dayLabel("2026-10-20") == "20.10.2026", "day labels use dd.MM.yyyy")
        try check(
            TrackCardNavigation.dayLabel("2026-01-03") == "03.01.2026",
            "day labels preserve leading zeroes")
        try check(nativeDate(.string("2026-10-07")) == "07.10.2026", "place visit dates use dd.MM.yyyy")
        try check(nativeDate(.string("2026-01-25")) == "25.01.2026", "January visit dates are formatted")
        try check(nativeDate(.string("2024-02-29")) == "29.02.2024", "leap-day visits are formatted")
        try check(nativeDate(.string("2026-10-07T12:00:00Z")) == "07.10.2026", "timestamp visits use the same date format")
        try check(nativeDate(.null) == "Unknown", "missing dates retain their fallback")
        let now = ISO8601DateFormatter().date(from: "2026-11-08T11:00:00Z")!
        let zurich = TimeZone(identifier: "Europe/Zurich")!
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        func label(_ text: String, zone: TimeZone = TimeZone(identifier: "Europe/Zurich")!, now reference: Date? = nil) -> String {
            nativeDate(.string(text), relativeTo: reference ?? now, timeZone: zone)
        }
        try check(label("2026-11-08") == "Today", "today uses a relative label")
        try check(label("2026-11-07") == "Yesterday", "yesterday uses a relative label")
        try check(label("2026-11-06") == "2 days ago", "recent days stay relative")
        try check(label("2026-11-02") == "6 days ago", "relative labels cover the recent week")
        try check(label("2026-11-01") == "01.11.2026", "older dates stay explicit")
        try check(label("2026-11-09") == "Tomorrow", "nearby future dates are clear")
        try check(label("2026-11-08T00:30:00Z", zone: losAngeles) == "Yesterday", "instants use the displayed local day")
        try check(label("2026-11-08", zone: losAngeles) == "Today", "date-only visits never shift time zones")
        try check(label("2026-11-08T00:30:00.123Z") == "Today", "fractional ISO timestamps are supported")
        let afterDST = ISO8601DateFormatter().date(from: "2026-10-25T23:30:00Z")!
        try check(label("2026-10-25", zone: zurich, now: afterDST) == "Yesterday", "calendar days survive a 25-hour daylight-saving day")
        try check(label("2026-02-30") == "2026-02-30", "invalid dates keep the fallback")
        try check(nativeDateRange(.string("2026-11-07"), .string("2026-11-08"), relativeTo: now, timeZone: zurich) == "Yesterday – Today", "trip ranges share the relative-date rules")
        try check(nativeDateRange(.string("2026-11-08"), .string("2026-11-08"), relativeTo: now, timeZone: zurich) == "Today", "same-day trips show one relative date")
        let today = nativeDayKey(.number(Date().timeIntervalSince1970))!
        try check(TrackCardNavigation.dayLabel(today) == "Today", "day track titles use relative dates too")
        try check(nativeDateTime(.number(Date().timeIntervalSince1970), clock: "24").hasPrefix("Today, "), "date/time labels retain the time alongside the relative date")
        for level in 0...8 {
            let undated: JSON = .object([
                "visited": .bool(true), "visitCount": .number(0),
                "visitDates": .array([]), "level": .number(Double(level)),
            ])
            try check(nativeVisitLabel(undated) == "You have been here",
                "visited cells and regions without dates never display zero visits at level \(level)")
        }
        try check(nativeVisitLabel(.object(["visited": .bool(true)])) == "You have been here",
            "locally known visits without a server count keep their visited label")
        try check(nativeVisitLabel(.object(["visitCount": .number(1)])) == "1 visit",
            "a single visit without a date keeps its count")
        try check(nativeVisitLabel(.object([
            "visitCount": .number(1), "visitDates": .strings(["2026-10-07"]),
        ])) == "07.10.2026", "a single dated visit shows its day")
        try check(nativeVisitLabel(.object(["visitCount": .number(3)])) == "3 visits",
            "multiple recorded visits keep their count")
        try check(nativeDayKey(.string("2026-10-27")) == "2026-10-27", "visit taps preserve the recorded calendar day")
        try check(nativeDayKey(.string("2026-02-30")) == nil, "invalid visit days cannot open a track")
        try check(nativeDayKey(.null) == nil, "missing visit dates cannot open a track")
        try check(TrackCardNavigation.dismissesActivity(x: 3, y: 70, predictedY: 80, withinGraph: false), "swiping the card down dismisses it")
        try check(TrackCardNavigation.dismissesActivity(x: 3, y: 30, predictedY: 150, withinGraph: false), "a deliberate downward flick dismisses the card")
        try check(!TrackCardNavigation.dismissesActivity(x: 70, y: 30, predictedY: 150, withinGraph: false), "horizontal navigation does not dismiss the card")
        try check(!TrackCardNavigation.dismissesActivity(x: 3, y: 70, predictedY: 150, withinGraph: true), "graph scrubbing never triggers card dismissal")
        try check(!TrackCardNavigation.dismissesActivity(x: 3, y: 5, predictedY: 150, withinGraph: false), "a tiny movement does not dismiss the card")
        let trip: JSON = .object([
            "firstDay": .string("2026-10-01"), "days": .number(3),
        ])
        try check(
            TrackCardNavigation.days(
                in: trip,
                recorded: [
                    "2026-09-30", "2026-10-04", "2026-10-03", "2026-10-01",
                ]) == ["2026-10-01", "2026-10-03"], "only recorded days within the trip appear")
        let spots: JSON = .object([
            "spots": .array([
                .object(["days": .strings(["2026-10-03", "2026-10-01"])]),
                .object(["days": .strings(["2026-10-03"])]),
            ])
        ])
        try check(
            TrackCardNavigation.days(in: spots) == ["2026-10-01", "2026-10-03"],
            "trip's own day keys work without a network request")
        print(
            "Track card checks passed: swipe directions, gesture thresholds, trip day scope, offline day keys"
        )
    }
}
