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

    private var queryText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var items: [JSON] {
        queryText.isEmpty
            ? RecentSearchItems.combine(routes: store.recentRoutes, trips: store.recentTrips, prefs: store.prefs)
            : results
    }

    var body: some View {
        Group {
            List {
                if let message = queryText.isEmpty ? store.recentSearchError : error {
                    Text(message).foregroundStyle(.secondary)
                    if queryText.isEmpty { Button("Try again") { Task { await store.prepareRecentSearch(force: true) } } }
                }
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Button {
                        Task {
                            if item["kind"].string == "route" {
                                close()
                                await store.openActivity(item["id"], preview: item)
                                return
                            } else if item["kind"].string == "trip" {
                                await store.selectTrack(trip: item["id"])
                            } else {
                                store.setFocus(item)
                            }
                            close()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: NativeSearchPresentation.icon(item))
                                .font(.title3).foregroundStyle(.white)
                                .frame(width: 28).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item["name"].text(item["kind"].string == "route" ? "Activity" : "Place"))
                                    .foregroundStyle(.primary)
                                if item["kind"].string == "route" {
                                    Text("Activity · \(nativeDate(item["firstAt"]))")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else if item["kind"].string == "trip" {
                                    Text("Trip · \(nativeDateRange(item["start"], item["end"]))")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text(item["country"].text(item["kind"].string.capitalized))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
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
                if items.isEmpty {
                    if queryText.isEmpty && store.recentSearchLoaded && store.recentSearchError == nil {
                        Text("No recent trips or activities").foregroundStyle(.secondary)
                    } else if queryText.count >= 2 && !searching && error == nil {
                        Text("No results").foregroundStyle(.secondary)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle("Search")
        .searchable(text: $text, prompt: "Places, activities, dates")
        .toolbar {
            if #available(iOS 26.0, *) {
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
                ToolbarSpacer(.fixed, placement: .bottomBar)
            }
            ToolbarItem(placement: .bottomBar) {
                NavigationLink {
                    NativeCalendarScreen(store: store, close: close)
                } label: {
                    Image(systemName: "calendar")
                }.accessibilityLabel("Calendar")
            }
        }
        .task { await store.prepareRecentSearch() }
        .task(id: queryText) {
            results = []
            error = nil
            searching = false
            guard queryText.count >= 2 else { return }
            let term = queryText
            searching = true
            do {
                try await Task.sleep(for: .milliseconds(250))
                let response = try await store.api.get("/api/search", query: query(["q": term]))
                try Task.checkCancellation()
                results = response["results"].array
                searching = false
            } catch is CancellationError {
                // The next query owns the loading state and result list.
            } catch {
                guard !Task.isCancelled else { return }
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
        }.navigationTitle("Recorded days").modifier(NativeHistoryTitleStyle())
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
    @State private var sort = "date"
    var body: some View {
        ServerContent(store: store, path: "/api/trips") { data in
            List {
                if !data["home"].exists {
                    Text("Set your home by searching for a place and holding its result.").foregroundStyle(.secondary)
                }
                Picker("Sort by", selection: $sort) {
                    Text("Date").tag("date")
                    Text("Country").tag("country")
                }
                let trips = NativeTripPresentation.visible(data["trips"].array, prefs: store.prefs)
                if sort == "country" {
                    ForEach(NativeTripPresentation.groups(trips), id: \.country) { group in
                        Section(group.country) { tripRows(group.trips) }
                    }
                } else { tripRows(trips) }
                if trips.isEmpty { Text("No trips to show").foregroundStyle(.secondary) }
            }
        }.tint(.white).navigationTitle("Trips")
            .modifier(NativeHistoryTitleStyle())
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
    private func tripRows(_ trips: [JSON]) -> some View {
        ForEach(Array(trips.enumerated()), id: \.offset) { _, trip in
            Button {
                Task {
                    await store.selectTrack(trip: trip["id"])
                    close()
                }
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(store.prefs["tripNames"][trip["id"].string].text(trip["name"].text("Trip")))
                        .font(.headline).foregroundStyle(.white)
                    Text(nativeDateRange(trip["start"], trip["end"]))
                        .font(.caption).foregroundStyle(.white.opacity(0.75))
                }
            }.swipeActions {
                Button("Hide") {
                    var ids = store.prefs["hiddenTrips"].array
                    if !ids.contains(trip["id"]) { ids.append(trip["id"]) }
                    store.save(["hiddenTrips": .array(ids)])
                }
                Button("Rename") {
                    rename = trip
                    name = store.prefs["tripNames"][trip["id"].string].text(trip["name"].string)
                }.tint(.gray)
            }
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
                NavigationLink {
                    NativeActivityStatistics(store: store)
                } label: {
                    Label("Activity statistics", systemImage: "chart.bar")
                }.foregroundStyle(.white)
                Picker("Sort by", selection: $sort) {
                    Text("Date").tag("date")
                    Text("Distance").tag("distance")
                    Text("Name").tag("name")
                }
                let routes = NativeActivityCopies.folded(value["routes"].array).filter {
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
                            close()
                            await store.openActivity(route["id"], preview: route)
                        }
                    } label: {
                        HStack {
                            Image(systemName: NativeSearchPresentation.sportIcon(route["sport"].string))
                                .foregroundStyle(.white).frame(width: 24)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(route["name"].text("Activity")).foregroundStyle(.white)
                                Text("\(nativeDate(route["firstAt"])) · \(route["sport"].string)").font(
                                    .caption
                                ).foregroundStyle(.white.opacity(0.75))
                            }
                            Spacer()
                            Text(String(format: "%.1f km", route["lengthM"].double / 1000)).font(.subheadline)
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    }
                }
                if routes.isEmpty { Text("No activities").foregroundStyle(.white.opacity(0.75)) }
            }
        }.tint(.white).navigationTitle("Activities")
            .modifier(NativeHistoryTitleStyle())
            .searchable(text: $search, prompt: "Name or activity type")
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
            }
        }.navigationTitle("Statistics").modifier(NativeHistoryTitleStyle())
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
struct NativeActivityStatistics: View {
    @ObservedObject var store: NativeStore
    var body: some View {
        List {
            Section("Activity totals") { NativeActivityTotals(store: store) }
        }.navigationTitle("Activity statistics").modifier(NativeHistoryTitleStyle())
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
