import Foundation

@main
struct ActivityChoicesCheck {
    static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw ServerFailure(status: 0, message: message) }
        print("  ok  " + message)
    }
    static func main() throws {
        func route(_ id: Int, _ sport: String, _ date: Double) -> JSON {
            .object(["id": .number(Double(id)), "sport": .string(sport), "name": .string("Activity \(id)"), "firstAt": .number(date)])
        }
        func hit(_ row: JSON) -> JSON { .object(["properties": row]) }
        let ski = route(1, "Skiing", 300)
        let oldSki = route(2, "Skiing", 100)
        let ride = route(3, "Cycling", 200)
        let choices = ActivityChoices.candidates(hits: [hit(oldSki), hit(ride), hit(oldSki)], selected: ski, metadata: [])
        try check(choices.count == 3, "multiple segments deduplicate while the selected activity remains a candidate")
        let groups = ActivityChoices.groups(choices)
        try check(groups.map(\.sport) == ["Skiing", "Cycling"], "sport groups follow their newest activity")
        try check(groups[0].routes.map { $0["id"].int } == [1, 2], "activities within a sport are newest first")
        let selectedOnly = ActivityChoices.candidates(hits: [hit(ski)], selected: ski, metadata: [])
        try check(selectedOnly.count == 1, "tapping only the selected activity still allows scrubbing")
        let cold = ActivityChoices.candidates(hits: [hit(.object(["id": .number(1), "name": .string("Saved line"), "sport": .string("Skiing")]))], metadata: [])
        try check(cold.count == 1 && cold[0]["name"].string == "Saved line", "a cold or offline metadata cache cannot discard a map hit")
        let enriched = ActivityChoices.enrich(cold, metadata: [ski, ride])
        try check(enriched.count == 1 && enriched[0]["firstAt"].int == 300, "metadata adds dates without adding activities outside the tap")
        try check(ActivityChoices.groups([.object(["id": .number(9)])]).first?.sport == "Other activities", "untyped activities have an understandable group")
        try check(ActivityChoices.candidates(hits: [hit(.object(["name": .string("No identifier")]))], metadata: []).isEmpty, "unselectable hits cannot become phantom activities")
        func copy(_ id: Int, _ source: String, _ length: Double, _ start: Double = 300) -> JSON {
            .object(["id": .number(Double(id)), "source": .string(source), "firstAt": .number(start),
                "lastAt": .number(start + 2700), "lengthM": .number(length), "sport": .string("Running"),
                "bounds": .array([8, 47, 8.01, 47.01].map(JSON.number))])
        }
        let phone = copy(10, "strava", 2189)
        let watch = copy(11, "apple-health", 2059)
        try check(NativeActivityCopies.folded([phone, watch]).map { $0["id"].int } == [11],
            "matching-start phone/watch recordings with 5.94 percent distance drift merge using source preference")
        try check(NativeActivityCopies.folded([phone, copy(11, "apple-health", 2059, 306)]).count == 2,
            "extra distance slack requires starts within five seconds")
        try check(NativeActivityCopies.folded([phone, copy(11, "apple-health", 1900)]).count == 2,
            "a distance mismatch over ten percent remains a separate activity")
        var elsewhere = watch
        elsewhere["bounds"] = .array([9, 48, 9.01, 48.01].map(JSON.number))
        try check(NativeActivityCopies.folded([phone, elsewhere]).count == 2,
            "simultaneous activities in different places never merge")
        let merged = ActivityChoices.candidates(hits: [hit(phone), hit(watch)], metadata: [phone, watch])
        try check(merged.count == 1 && merged[0]["id"].int == 11 && !merged[0]["bounds"].exists,
            "the picker folds copies before shedding private comparison metadata")
        let aliased = ActivityChoices.enrich([phone], metadata: [watch], aliases: ["10": "11"])
        try check(aliased.count == 1 && aliased[0]["id"].int == 11,
            "server duplicate aliases resolve stale rendered hits to the surviving activity")
        print("Activity chooser checks passed")
    }
}
