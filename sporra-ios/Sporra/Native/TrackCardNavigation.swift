import Foundation

nonisolated enum TrackCardNavigation {
    enum Swipe: Equatable { case previous, next, expand, collapse, none }
    static func swipe(x: Double, y: Double) -> Swipe {
        if abs(x) >= 40 && abs(x) > abs(y) * 1.3 { return x < 0 ? .next : .previous }
        if abs(y) >= 36 && abs(y) > abs(x) * 1.3 { return y < 0 ? .expand : .collapse }
        return .none
    }
    static func dismissesActivity(x: Double, y: Double, predictedY: Double, withinGraph: Bool) -> Bool {
        !withinGraph && y >= 24 && y > abs(x) * 1.3 && (y >= 60 || predictedY >= 120)
    }
    static func dayLabel(_ key: String) -> String {
        nativeDate(.string(key))
    }
    static func days(in trip: JSON, recorded: [String] = []) -> [String] {
        let known = Set(trip["spots"].array.flatMap { $0["days"].array.map(\.string) })
        if !known.isEmpty { return known.sorted() }
        let first = trip["firstDay"].string
        guard !first.isEmpty, trip["days"].int > 0 else { return [] }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let start = formatter.date(from: first) else { return [] }
        let last = formatter.string(
            from: start.addingTimeInterval(Double(trip["days"].int - 1) * 86400))
        return recorded.filter { $0 >= first && $0 <= last }.sorted()
    }
}
