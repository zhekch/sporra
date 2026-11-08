import Foundation

nonisolated enum NativeSearchPresentation {
    static func icon(_ item: JSON) -> String {
        switch item["kind"].string {
        case "trip": return "suitcase.rolling"
        case "route": return sportIcon(item["sport"].string)
        default: return "mappin.circle"
        }
    }
    static func sportIcon(_ sport: String) -> String {
        switch sport.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "walking", "walk": return "figure.walk"
        case "running", "run", "trail running": return "figure.run"
        case "hiking", "hike": return "figure.hiking"
        case "cycling", "mountain cycling", "biking", "bike", "ride": return "figure.outdoor.cycle"
        case "swimming", "swim": return "figure.pool.swim"
        case "skiing", "ski": return "figure.skiing.downhill"
        case "ski touring", "cross-country skiing": return "figure.skiing.crosscountry"
        case "snowboarding", "snowboard": return "figure.snowboarding"
        case "paddling", "paddle", "rowing", "kayaking", "canoeing": return "figure.rower"
        case "sailing", "sail": return "sailboat"
        case "driving", "drive": return "car"
        case "train": return "tram"
        case "flying", "flight": return "airplane"
        default: return "figure.mixed.cardio"
        }
    }
}
