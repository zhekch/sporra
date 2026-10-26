import SwiftUI

struct NativeActivityCard: View {
    @ObservedObject var store: NativeStore
    @State private var edit = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    Task { await store.step(-1) }
                } label: {
                    Image(systemName: "chevron.left")
                }.accessibilityLabel("Previous activity")
                Text(store.activity["route"]["name"].text("Activity")).font(.headline).lineLimit(2).frame(
                    maxWidth: .infinity, alignment: .leading)
                Button {
                    Task { await store.step(1) }
                } label: {
                    Image(systemName: "chevron.right")
                }.accessibilityLabel("Next activity")
                Button {
                    store.closeSelection()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }.accessibilityLabel("Close activity")
            }
            HStack {
                Text(store.activity["summary"]["distance"].string)
                if store.activity["summary"]["duration"].exists {
                    Text(store.activity["summary"]["duration"].string)
                }
                if store.activity["summary"]["averageSpeed"].exists {
                    Text(store.activity["summary"]["averageSpeed"].string)
                }
                Spacer()
                Button {
                    edit = true
                } label: {
                    Image(systemName: "ellipsis.circle")
                }.accessibilityLabel("Edit activity")
            }.font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Button("Focus") { store.setFocus(store.activity["route"]) }
                Spacer()
                Button(store.solo ? "Show all activities" : "Show only this activity") { store.solo.toggle() }
            }.font(.caption)
            if store.activity["graphs"]["speed"].exists || store.activity["graphs"]["elev"].exists {
                Picker("Metric", selection: $store.metric) {
                    if store.activity["graphs"]["speed"].exists { Text("Speed").tag("speed") }
                    if store.activity["graphs"]["elev"].exists { Text("Elevation").tag("elev") }
                }.pickerStyle(.segmented)
                NativeActivityGraph(store: store).frame(height: 90)
            }
        }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
            .sheet(isPresented: $edit) { NavigationStack { NativeActivityEdit(store: store) } }
    }
}

struct NativeActivityGraph: View {
    @ObservedObject var store: NativeStore
    private var graph: JSON { store.activity["graphs"][store.metric] }
    private var points: [JSON] { graph["runs"].array.flatMap(\.array) }
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height - 22
            let minY = graph["min"].double
            let maxY = max(minY + 0.001, graph["max"].double)
            let maxX = max(1, graph["maxX"].double)
            ZStack(alignment: .bottomLeading) {
                Canvas { context, _ in
                    for run in graph["runs"].array {
                        for pair in zip(run.array, run.array.dropFirst()) {
                            var path = Path()
                            path.move(
                                to: CGPoint(
                                    x: pair.0["x"].double / maxX * width,
                                    y: (1 - (pair.0["y"].double - minY) / (maxY - minY)) * height))
                            path.addLine(
                                to: CGPoint(
                                    x: pair.1["x"].double / maxX * width,
                                    y: (1 - (pair.1["y"].double - minY) / (maxY - minY)) * height))
                            context.stroke(
                                path,
                                with: .color(
                                    Color(uiColor: UIColor(mapColor: pair.1["color"].text("#60acff")))),
                                lineWidth: 2)
                        }
                    }
                    if let sample = store.sample, let point = points.first(where: { $0["i"].int == sample }) {
                        let x = point["x"].double / maxX * width
                        var path = Path()
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: height))
                        context.stroke(path, with: .color(.primary.opacity(0.6)), lineWidth: 1)
                    }
                }
                HStack {
                    Text(graph["minLabel"].string)
                    Spacer()
                    if let sample = store.sample {
                        Text(points.first(where: { $0["i"].int == sample })?["label"].string ?? "")
                    }
                    Spacer()
                    Text(graph["maxLabel"].string)
                }.font(.caption2).foregroundStyle(.secondary)
            }.contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { value in
                        let x = min(1, max(0, value.location.x / max(1, width))) * maxX
                        store.sample =
                            points.min { abs($0["x"].double - x) < abs($1["x"].double - x) }?["i"].int
                    }
                )
                .accessibilityElement().accessibilityLabel(
                    "\(store.metric == "speed" ? "Speed" : "Elevation") graph, \(graph["minLabel"].string) to \(graph["maxLabel"].string)"
                )
                .accessibilityAdjustableAction { direction in
                    guard !points.isEmpty else { return }
                    let current = points.firstIndex { $0["i"].int == store.sample } ?? 0
                    let next = min(points.count - 1, max(0, current + (direction == .increment ? 1 : -1)))
                    store.sample = points[next]["i"].int
                }
        }
    }
}

struct NativeActivityEdit: View {
    @ObservedObject var store: NativeStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var sport = ""
    @State private var source = ""
    @State private var place = ""
    @State private var confirmDelete = false
    @State private var previous: JSON = .null
    var body: some View {
        Form {
            Section("Activity") {
                LabeledContent(
                    "Started",
                    value: nativeDateTime(
                        store.activity["route"]["firstAt"], clock: store.prefs["clock"].string))
                LabeledContent(
                    "Finished",
                    value: nativeDateTime(
                        store.activity["route"]["lastAt"], clock: store.prefs["clock"].string))
                if store.activity["route"]["ascent"].exists {
                    LabeledContent("Ascent", value: "\(store.activity["route"]["ascent"].int) m")
                }
                TextField("Name", text: $name)
                TextField("Type", text: $sport)
                TextField("Source", text: $source)
                TextField("Place", text: $place)
                if let url = URL(string: store.activity["route"]["link"].string),
                    ["http", "https"].contains(url.scheme ?? "")
                {
                    Link("Original activity", destination: url)
                }
            }
            Section {
                Button("Save changes") {
                    Task {
                        await store.perform {
                            let route = store.activity["route"]
                            previous = route
                            _ = try await store.api.post(
                                "/api/routes/update",
                                [
                                    "id": route["id"], "name": .string(name), "sport": .string(sport),
                                    "source": .string(source), "place": .string(place),
                                ])
                            store.undo = .object(["routeUpdate": route])
                            await store.openActivity(route["id"])
                            store.changed()
                        }
                    }
                }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || store.busy)
                if previous.exists {
                    Button("Undo changes") {
                        Task {
                            await store.perform {
                                _ = try await store.api.post(
                                    "/api/routes/update",
                                    [
                                        "id": previous["id"], "name": previous["name"],
                                        "sport": previous["sport"], "source": previous["source"],
                                        "place": previous["place"],
                                    ])
                                await store.openActivity(previous["id"])
                                previous = .null
                                fill()
                                store.changed()
                            }
                        }
                    }
                }
                Button("Delete activity", role: .destructive) { confirmDelete = true }
            }
        }.navigationTitle("Activity details")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear(perform: fill)
            .confirmationDialog(
                "Delete this activity?", isPresented: $confirmDelete, titleVisibility: .visible
            ) {
                Button("Delete activity", role: .destructive) {
                    Task {
                        await store.perform {
                            let result = try await store.api.post(
                                "/api/routes/delete", ["id": store.activity["route"]["id"]])
                            store.undo = .object(["route": result["route"]])
                            store.closeSelection()
                            store.changed()
                            dismiss()
                        }
                    }
                }
            }
    }
    private func fill() {
        let r = store.activity["route"]
        name = r["name"].string
        sport = r["sport"].string
        source = r["source"].string
        place = r["place"].string
    }
}

struct NativePlaceCard: View {
    @ObservedObject var store: NativeStore
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.place["name"].text(store.place["title"].text("This place"))).font(.headline)
                    Text(
                        store.place["visited"].bool
                            ? "\(store.place["visitCount"].int) visits"
                            : store.place["visited"].exists
                                ? "Not visited yet" : store.place["subtitle"].text(store.place["code"].string)
                    ).font(.subheadline).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.up")
                }.accessibilityLabel("Visit details")
                Button {
                    store.place = .null
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }.accessibilityLabel("Close place")
            }
            if expanded || store.place["rows"].exists {
                ForEach(Array(store.place["rows"].array.enumerated()), id: \.offset) { _, row in
                    LabeledContent(row[0].string, value: row[1].string).font(.caption)
                }
                HStack {
                    ForEach(Array(store.place["links"].array.enumerated()), id: \.offset) { _, link in
                        if let url = URL(string: link["url"].string),
                            ["https", "http"].contains(url.scheme ?? "")
                        {
                            Link(link["label"].string, destination: url).font(.caption)
                        }
                    }
                }
                if store.place["covered"].exists {
                    Text(
                        String(
                            format: "%.2f km² · %.3f%% covered", store.place["covered"].double,
                            store.place["coveredPct"].double)
                    ).font(.subheadline)
                }
                if !store.place["visitDates"].array.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading) {
                            ForEach(Array(store.place["visitDates"].array.enumerated()), id: \.offset) {
                                _, value in Text(nativeDate(value)).font(.subheadline)
                            }
                        }
                    }.frame(maxHeight: 150)
                }
            }
        }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
    }
}

struct NativeActivityStyles: View {
    @ObservedObject var store: NativeStore
    var body: some View {
        ServerContent(store: store, path: "/api/routes?fold=1") { value in
            let sports = Set(value["routes"].array.map { $0["sport"].text("\0none") }).sorted()
            Form {
                Toggle(
                    "Colour each activity",
                    isOn: Binding(
                        get: { store.prefs["routeView"]["rainbow"].bool },
                        set: { v in
                            var view = store.prefs["routeView"]
                            view["rainbow"] = .bool(v)
                            store.save(["routeView": view])
                        }))
                Button("Randomise colours") {
                    Task {
                        await store.perform {
                            let result = try await store.api.post(
                                "/api/render/activity-palette", ["keys": .strings(sports)])
                            var view = store.prefs["routeView"]
                            view["colors"] = result["colors"]
                            view["rainbow"] = .bool(false)
                            try await store.patchPrefs(["routeView": view])
                        }
                    }
                }
                ForEach(sports, id: \.self) { sport in
                    Section(sport == "\0none" ? "Other" : sport) {
                        Toggle(
                            "Visible",
                            isOn: Binding(
                                get: { !store.prefs["routeView"]["hidden"].array.contains(.string(sport)) },
                                set: { on in
                                    var view = store.prefs["routeView"]
                                    var hidden = view["hidden"].array.filter { $0 != .string(sport) }
                                    if !on { hidden.append(.string(sport)) }
                                    view["hidden"] = .array(hidden)
                                    store.save(["routeView": view])
                                }))
                        ColorPicker(
                            "Colour",
                            selection: Binding(
                                get: {
                                    Color(
                                        uiColor: UIColor(
                                            mapColor: store.prefs["routeView"]["colors"][sport].text(
                                                "#ff9147")))
                                },
                                set: { color in
                                    var view = store.prefs["routeView"]
                                    var colors = view["colors"]
                                    colors[sport] = .string(color.nativeHex)
                                    view["colors"] = colors
                                    store.save(["routeView": view])
                                }), supportsOpacity: false)
                    }
                }
            }
        }.navigationTitle("Activity colours")
    }
}
