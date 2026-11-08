import Foundation

/// Visit dates can be unknown for saved or hand-marked cells. The server's
/// zero date count does not contradict its separate `visited` flag.
nonisolated func nativeVisitLabel(_ place: JSON) -> String {
    let count = place["visitCount"].int
    if count == 1 {
        return place["visitDates"].array.first.map(nativeDate) ?? "1 visit"
    }
    return count > 1 ? "\(count) visits" : "You have been here"
}

/// Date-only keys are calendar dates, not UTC instants. Parse them separately
/// so their displayed day cannot shift with the device's time zone.
nonisolated func nativeDate(_ value: JSON) -> String {
    nativeDate(value, relativeTo: Date())
}

/// Compare calendar days in the display time zone, so midnight and daylight
/// saving changes do not turn yesterday into today or shift a date-only key.
nonisolated func nativeDate(_ value: JSON, relativeTo now: Date, timeZone: TimeZone = .current) -> String {
    guard value.exists, value != .number(0) else { return "Unknown" }
    let formatter = DateFormatter()
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    formatter.calendar = calendar
    formatter.timeZone = timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.isLenient = false
    let date: Date?
    if value.string.count == 10, value.string.split(separator: "-").count == 3 {
        formatter.dateFormat = "yyyy-MM-dd"
        let parsed = formatter.date(from: value.string)
        date = parsed.flatMap { formatter.string(from: $0) == value.string ? $0 : nil }
    } else if value.double > 0, value.double.isFinite {
        date = Date(timeIntervalSince1970: value.double)
    } else {
        let iso = ISO8601DateFormatter()
        date = iso.date(from: value.string) ?? {
            iso.formatOptions.insert(.withFractionalSeconds)
            return iso.date(from: value.string)
        }()
    }
    guard let date else { return value.string }
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
    switch days {
    case 0: return "Today"
    case -1: return "Yesterday"
    case 1: return "Tomorrow"
    case -6 ... -2: return "\(-days) days ago"
    case 2 ... 6: return "In \(days) days"
    default:
        formatter.dateFormat = "dd.MM.yyyy"
        return formatter.string(from: date)
    }
}

nonisolated func nativeDateRange(_ start: JSON, _ end: JSON) -> String {
    nativeDateRange(start, end, relativeTo: Date())
}

nonisolated func nativeDateRange(_ start: JSON, _ end: JSON, relativeTo now: Date, timeZone: TimeZone = .current) -> String {
    let first = nativeDate(start, relativeTo: now, timeZone: timeZone)
    let last = nativeDate(end, relativeTo: now, timeZone: timeZone)
    return first == last || !end.exists ? first : "\(first) – \(last)"
}

nonisolated func nativeDateTime(_ value: JSON, clock: String) -> String {
    guard value.double > 0 else { return "Unknown" }
    let date = Date(timeIntervalSince1970: value.double)
    let formatter = DateFormatter()
    if clock == "24" {
        formatter.dateFormat = "HH:mm"
    } else if clock == "12" {
        formatter.dateFormat = "h:mm a"
    } else {
        formatter.timeStyle = .short
    }
    return "\(nativeDate(value)), \(formatter.string(from: date))"
}

/// Calendar selections use date-only keys; preserve those without a time-zone conversion.
nonisolated func nativeDayKey(_ value: JSON) -> String? {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    if value.string.count == 10 {
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        guard let date = formatter.date(from: value.string), formatter.string(from: date) == value.string else { return nil }
        return value.string
    }
    let date = value.double > 0 ? Date(timeIntervalSince1970: value.double) : ISO8601DateFormatter().date(from: value.string)
    return date.map { formatter.string(from: $0) }
}
