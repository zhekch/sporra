import Charts
import SwiftUI
import UIKit

struct NativeSearch: View {
    @ObservedObject var store: NativeStore
    var close: () -> Void
    @State private var text = ""
    @State private var results: [JSON] = []
    @State private var searching = false
    @State private var error: String?
    var body: some View {
        List {
            if searching { ProgressView("Searching…") }
            if let error { Text(error).foregroundStyle(.secondary) }
            if text.isEmpty {
                NavigationLink("Recorded days", destination: NativeCalendarScreen(store: store, close: close))
                NavigationLink("Trips", destination: NativeTrips(store: store, close: close))
            }
            ForEach(Array(results.enumerated()), id: \.offset) { _, item in
                Button {
                    Task {
                        if item["kind"].string == "route" {
                            await store.openActivity(item["id"])
                        } else if item["kind"].string == "trip" {
                            await store.selectTrack(trip: item["id"])
                        } else {
                            store.setFocus(item)
                        }
                        close()
                    }
                } label: {
                    VStack(alignment: .leading) {
                        Text(item["name"].text("Place"))
                        Text(item["country"].text(item["kind"].string.capitalized)).font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contextMenu {
                    if item["lat"].exists && item["lng"].exists {
                        Button("Set as home") {
                            store.save([
                                "home": .object([
                                    "lat": item["lat"], "lng": item["lng"], "name": item["name"],
                                ])
                            ])
                        }
                    }
                }
            }
            if text.count >= 2 && !searching && results.isEmpty && error == nil {
                Text("No results").foregroundStyle(.secondary)
            }
        }.navigationTitle("Search")
            .searchable(text: $text, prompt: "Places, activities, dates")
            .task(id: text) {
                guard text.count >= 2 else {
                    results = []
                    return
                }
                searching = true
                do {
                    try await Task.sleep(for: .milliseconds(250))
                    let response = try await store.api.get("/api/search", query: query(["q": text]))
                    try Task.checkCancellation()
                    results = response["results"].array
                    error = nil
                    searching = false
                } catch is CancellationError {} catch {
                    self.error = error.localizedDescription
                    searching = false
                }
            }
    }
}

struct NativeCalendarScreen: View {
    @ObservedObject var store: NativeStore
    var close: () -> Void
    @State private var date = Date()
    var body: some View {
        ServerContent(store: store, path: "/api/days") { value in
            ScrollView {
                NativeCalendar(days: Set(value["days"].object.keys), selected: $date) { key in
                    Task {
                        await store.selectTrack(day: key)
                        close()
                    }
                }.frame(minHeight: 380)
            }
        }.navigationTitle("Recorded days")
    }
}
struct NativeCalendar: UIViewRepresentable {
    var days: Set<String>
    @Binding var selected: Date
    var onSelect: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UICalendarView {
        let view = UICalendarView()
        view.calendar = Calendar(identifier: .gregorian)
        view.delegate = context.coordinator
        view.selectionBehavior = UICalendarSelectionSingleDate(delegate: context.coordinator)
        return view
    }
    func updateUIView(_ view: UICalendarView, context: Context) {
        let previous = context.coordinator.parent.days
        context.coordinator.parent = self
        let changed = previous.symmetricDifference(days)
        view.reloadDecorations(
            forDateComponents: changed.compactMap { key in
                let parts = key.split(separator: "-").compactMap { Int($0) }
                return parts.count == 3 ? DateComponents(year: parts[0], month: parts[1], day: parts[2]) : nil
            }, animated: true)
    }
    final class Coordinator: NSObject, UICalendarViewDelegate, UICalendarSelectionSingleDateDelegate {
        var parent: NativeCalendar
        init(_ parent: NativeCalendar) { self.parent = parent }
        func key(_ c: DateComponents) -> String {
            String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        }
        func calendarView(_ calendarView: UICalendarView, decorationFor dateComponents: DateComponents)
            -> UICalendarView.Decoration?
        {
            parent.days.contains(key(dateComponents)) ? .default(color: .systemBlue, size: .medium) : nil
        }
        func dateSelection(
            _ selection: UICalendarSelectionSingleDate, canSelectDate dateComponents: DateComponents?
        ) -> Bool { dateComponents.map { parent.days.contains(key($0)) } ?? false }
        func dateSelection(
            _ selection: UICalendarSelectionSingleDate, didSelectDate dateComponents: DateComponents?
        ) {
            guard let c = dateComponents else { return }
            parent.onSelect(key(c))
        }
    }
}

struct NativeTrips: View {
    @ObservedObject var store: NativeStore
    var close: () -> Void = {}
    @State private var rename: JSON = .null
    @State private var name = ""
    @State private var showHidden = false
    var body: some View {
        ServerContent(store: store, path: "/api/trips") { data in
            List {
                if !data["home"].exists {
                    Text("Set your home by searching for a place and holding its result.").foregroundStyle(
                        .secondary)
                }
                Toggle("Show hidden trips", isOn: $showHidden)
                ForEach(Array(data["trips"].array.enumerated()), id: \.offset) { _, trip in
                    let hidden = store.prefs["hiddenTrips"].array.contains(trip["id"])
                    if !hidden || showHidden {
                        Button {
                            Task {
                                await store.selectTrack(trip: trip["id"])
                                close()
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(
                                    store.prefs["tripNames"][trip["id"].string].text(
                                        trip["name"].text("Trip"))
                                ).font(.headline)
                                Text("\(nativeDate(trip["start"])) – \(nativeDate(trip["end"]))").font(
                                    .caption
                                ).foregroundStyle(.secondary)
                            }.opacity(hidden ? 0.5 : 1)
                        }.swipeActions {
                            Button(hidden ? "Show" : "Hide") {
                                var ids = store.prefs["hiddenTrips"].array
                                if hidden {
                                    ids.removeAll { $0 == trip["id"] }
                                } else {
                                    ids.append(trip["id"])
                                }
                                store.save(["hiddenTrips": .array(ids)])
                            }
                            Button("Rename") {
                                rename = trip
                                name = store.prefs["tripNames"][trip["id"].string].text(trip["name"].string)
                            }.tint(.blue)
                        }
                    }
                }
                if data["trips"].array.isEmpty { Text("No trips yet").foregroundStyle(.secondary) }
            }
        }.navigationTitle("Trips")
            .alert(
                "Trip name", isPresented: Binding(get: { rename.exists }, set: { if !$0 { rename = .null } })
            ) {
                TextField("Name", text: $name)
                Button("Save") {
                    var names = store.prefs["tripNames"]
                    names[rename["id"].string] = .string(name)
                    store.save(["tripNames": names])
                    rename = .null
                }
                Button("Cancel", role: .cancel) { rename = .null }
            }
    }
}

struct NativeActivities: View {
    @ObservedObject var store: NativeStore
    var close: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var sort = "date"
    @State private var search = ""
    var body: some View {
        ServerContent(store: store, path: "/api/routes?fold=1") { value in
            List {
                Picker("Sort by", selection: $sort) {
                    Text("Date").tag("date")
                    Text("Distance").tag("distance")
                    Text("Name").tag("name")
                }
                let routes = value["routes"].array.filter {
                    search.isEmpty || $0["name"].string.localizedCaseInsensitiveContains(search)
                        || $0["sport"].string.localizedCaseInsensitiveContains(search)
                }.sorted {
                    sort == "name"
                        ? $0["name"].string < $1["name"].string
                        : $0[sort == "date" ? "firstAt" : "lengthM"].double
                            > $1[sort == "date" ? "firstAt" : "lengthM"].double
                }
                ForEach(Array(routes.enumerated()), id: \.offset) { _, route in
                    Button {
                        Task {
                            await store.openActivity(route["id"])
                            close()
                        }
                    } label: {
                        HStack {
                            Image(systemName: "figure.outdoor.cycle").foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(route["name"].text("Activity")).foregroundStyle(.primary)
                                Text("\(nativeDate(route["firstAt"])) · \(route["sport"].string)").font(
                                    .caption
                                ).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(String(format: "%.1f km", route["lengthM"].double / 1000)).font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if routes.isEmpty { Text("No activities").foregroundStyle(.secondary) }
            }
        }.navigationTitle("Activities").searchable(text: $search, prompt: "Name or activity type")
    }
}

struct NativeStatistics: View {
    @ObservedObject var store: NativeStore
    @State private var sort = "pct"
    var body: some View {
        ServerContent(store: store, path: "/api/stats") { s in
            List {
                Section("Your world") {
                    LabeledContent("Ground covered", value: String(format: "%.1f km²", s["km2"].double))
                    LabeledContent(
                        "Countries", value: "\(s["countries"].array.count) / \(s["countryTotal"].int)")
                    LabeledContent("Recorded days", value: s["days"].string)
                    LabeledContent("Longest streak", value: "\(s["streakDays"].int) days")
                    LabeledContent("First seen", value: nativeDate(s["firstAt"]))
                    LabeledContent("Last seen", value: nativeDate(s["lastAt"]))
                }
                Section("New ground by year") {
                    NativeYearChart(
                        entries: s["years"].array.map {
                            .object(["year": $0[0], "value": $0[1], "label": .string("\($0[1].int) cells")])
                        })
                }
                Section("Countries") {
                    Picker("Order", selection: $sort) {
                        Text("Share").tag("pct")
                        Text("Area").tag("km2")
                    }
                    ForEach(
                        Array(s["countries"].array.sorted { $0[sort].double > $1[sort].double }.enumerated()),
                        id: \.offset
                    ) { _, country in
                        DisclosureGroup {
                            ForEach(
                                Array(
                                    s["regions"].array.filter { $0["country"] == country["id"] }.sorted {
                                        $0[sort].double > $1[sort].double
                                    }.enumerated()), id: \.offset
                            ) { _, region in coverage(region) }
                        } label: {
                            coverage(country)
                        }
                    }
                }
                Section("Activity totals") {
                    NativeActivityTotals(store: store)
                }
            }
        }.navigationTitle("Statistics")
    }
    private func coverage(_ area: JSON) -> some View {
        HStack {
            Text(area["name"].text(area["id"].string))
            Spacer()
            VStack(alignment: .trailing) {
                Text(String(format: "%.1f km²", area["km2"].double))
                Text(String(format: "%.3f%%", area["pct"].double)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
struct NativeActivityTotals: View {
    @ObservedObject var store: NativeStore
    var body: some View {
        ServerContent(store: store, path: "/api/render/activity-stats") { value in
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Distance", value: value["distance"].string)
                LabeledContent("Duration", value: value["duration"].string)
                NativeYearChart(entries: value["years"].array)

            }
        }
    }
}

struct NativeYearChart: View {
    var entries: [JSON]
    @State private var selected: String?
    var body: some View {
        VStack(alignment: .leading) {
            Chart(Array(entries.enumerated()), id: \.offset) { _, entry in
                BarMark(x: .value("Year", entry["year"].string), y: .value("Value", entry["value"].double))
                    .foregroundStyle(
                        selected == nil || selected == entry["year"].string
                            ? Color.blue : Color.blue.opacity(0.35))
            }.frame(height: 160)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0).onChanged { value in
                                    let x = value.location.x - geometry[proxy.plotAreaFrame].origin.x
                                    selected = proxy.value(atX: x, as: String.self)
                                })
                    }
                }
            if let selected, let entry = entries.first(where: { $0["year"].string == selected }) {
                Text("\(selected) · \(entry["label"].text(entry["value"].string))").font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
