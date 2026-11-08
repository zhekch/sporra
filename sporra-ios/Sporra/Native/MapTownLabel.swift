import Foundation

nonisolated struct MapTownLabel: Sendable {
    let name: String
    let lng: Double
    let lat: Double

    static func isTownClass(_ value: String?) -> Bool {
        ["settlement", "city", "town", "village", "hamlet"].contains(value ?? "")
    }
}
