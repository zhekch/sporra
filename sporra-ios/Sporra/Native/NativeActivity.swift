import SwiftUI

struct NativeActivityCard: View {
    @ObservedObject var store: NativeStore
    @State private var edit = false
    @State private var dragOffset = CGSize.zero
    @ScaledMetric(relativeTo: .headline) private var titleSize = 17
    @ScaledMetric(relativeTo: .caption) private var subtitleSize = 12
    @ScaledMetric(relativeTo: .caption2) private var labelSize = 11
    @ScaledMetric(relativeTo: .subheadline) private var valueSize = 14
    private var route: JSON { store.activity["route"] }
    private var metrics: [String] { ["speed", "elev"].filter { store.activity["graphs"][$0].exists } }
    private var readings: [(String, String)] {
        let summary = store.activity["summary"]
        var values: [(String, String)] = []
        if summary["distance"].exists { values.append(("Distance", summary["distance"].string)) }
        if summary["duration"].exists { values.append(("Duration", summary["duration"].string)) }
        if summary["averageSpeed"].exists { values.append(("Average", summary["averageSpeed"].string)) }
        let ascent = route["elevUp"].exists ? route["elevUp"] : route["ascent"]
        if ascent.double > 0 { values.append(("Ascent", ascent.string + " m")) }
        return values
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(route["name"].text("Activity"))
                        .font(.system(size: titleSize, weight: .semibold)).lineLimit(2)
                    Text([route["sport"].string, nativeDate(route["firstAt"])].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: subtitleSize)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button { store.closeSelection() } label: {
                    Image(systemName: "xmark").font(.system(size: 18, weight: .regular))
                        .frame(width: 32, height: 32).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Close activity")
            }
            .padding(.top, 22).padding(.leading, 22).padding(.trailing, 18)
            .modifier(NativeMapCardDrag(offset: $dragOffset) { swipe in
                switch swipe {
                case .previous: Task { await store.step(-1) }
                case .next: Task { await store.step(1) }
                case .collapse: store.closeSelection()
                default: break
                }
            })
            .accessibilityAction(named: "Previous activity") { Task { await store.step(-1) } }
            .accessibilityAction(named: "Next activity") { Task { await store.step(1) } }

            if store.activity["loading"].bool {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading activity details…").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                }.padding(.horizontal, 22).padding(.top, 12)
            } else if store.activity["detailsError"].exists {
                HStack {
                    Text(store.activity["detailsError"].string).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry") { Task { await store.openActivity(route["id"], preview: route) } }
                }.padding(.horizontal, 22).padding(.top, 12)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 22) {
                    ForEach(readings.indices, id: \.self) { index in reading(readings[index]) }
                    Spacer(minLength: 0)
                }.fixedSize(horizontal: true, vertical: false)
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(readings.indices, id: \.self) { index in reading(readings[index]) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 4)

            if metrics.count > 1 {
                Picker("Activity metric", selection: Binding(
                    get: { store.metric },
                    set: { store.metric = $0; store.sample = nil }
                )) {
                    ForEach(metrics, id: \.self) { metric in
                        Text(metric == "speed" ? "Speed" : "Elevation").tag(metric)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 6)
            } else if let metric = metrics.first {
                Text(metric == "speed" ? "Speed" : "Elevation")
                    .font(.system(size: subtitleSize)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 6)
            }
            if store.activity["graphs"][store.metric].exists {
                NativeActivityGraph(store: store)
                    .padding(.horizontal, 18).padding(.top, 2).padding(.bottom, 10)
            } else { Color.clear.frame(height: 10) }

            Rectangle().fill(.primary.opacity(0.12)).frame(height: 1)
            footer.padding(14)
        }
        .modifier(NativeMapCardSurface())
        .accessibilityAction(named: "Dismiss activity") { store.closeSelection() }
        .offset(dragOffset)
        .sheet(isPresented: $edit) { NavigationStack { NativeActivityEdit(store: store) } }
    }

    @ViewBuilder
    private var footer: some View {
        if #available(iOS 26.0, *) {
            actions.buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.large)
        } else {
            actions.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
        }
    }
    private var actions: some View {
        HStack(spacing: 8) {
            Button { store.setFocus(route) } label: {
                Label("Focus", systemImage: "plus.magnifyingglass")
                    .frame(maxWidth: .infinity)
            }.accessibilityLabel("Focus activity on map")
            Button { store.solo.toggle() } label: {
                Text(store.solo ? "Show all" : "Show this").frame(maxWidth: .infinity)
            }.accessibilityHint(store.solo ? "Show all activities on the map" : "Show only this activity on the map")
            Button { edit = true } label: {
                Text("More info").frame(maxWidth: .infinity)
            }.disabled(store.activity["loading"].bool || store.activity["detailsError"].exists)
        }.font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
    }

    private func reading(_ value: (String, String)) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.0).font(.system(size: labelSize)).foregroundStyle(.secondary)
            Text(value.1).font(.system(size: valueSize, weight: .medium)).lineLimit(1)
        }.accessibilityElement(children: .combine)
    }
}

struct NativeActivityGraph: View {
    @ObservedObject var store: NativeStore
    private var graph: JSON { store.activity["graphs"][store.metric] }
    private var points: [JSON] { graph["runs"].array.flatMap(\.array) }
    private var selected: JSON? { store.sample.flatMap { index in points.first { $0["i"].int == index } } }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(graph["maxLabel"].string).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let selected { Text(selected["label"].string).font(.system(size: 12)) }
            }.frame(minHeight: 14)
            GeometryReader { geometry in
                ZStack {
                    NativeActivityPlot(graph: graph).equatable()
                    if let selected {
                        Canvas { context, size in
                            let point = NativeActivityPlot.position(selected, graph: graph, size: size)
                            let dot = Path(ellipseIn: CGRect(x: point.x - 4.5, y: point.y - 4.5, width: 9, height: 9))
                            context.fill(dot, with: .color(.white))
                            context.stroke(dot, with: .color(.black.opacity(0.54)), lineWidth: 1.5)
                        }.allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                    let x = min(1, max(0, (gesture.location.x - 2) / max(1, geometry.size.width - 4))) * max(1, graph["maxX"].double)
                    store.sample = points.min { abs($0["x"].double - x) < abs($1["x"].double - x) }?["i"].int
                })
            }.frame(height: 72)
                .accessibilityElement().accessibilityLabel(
                    "\(store.metric == "speed" ? "Speed" : "Elevation") graph, \(graph["minLabel"].string) to \(graph["maxLabel"].string)"
                )
                .accessibilityValue(selected?["label"].string ?? "")
                .accessibilityAdjustableAction { direction in
                    guard !points.isEmpty else { return }
                    let current = points.firstIndex { $0["i"].int == store.sample } ?? 0
                    let next = min(points.count - 1, max(0, current + (direction == .increment ? 1 : -1)))
                    store.sample = points[next]["i"].int
                }
            NativeActivityAxis(graph: graph).equatable().frame(height: 20)
        }
    }
}

private struct NativeActivityPlot: View, Equatable {
    let graph: JSON
    static func position(_ point: JSON, graph: JSON, size: CGSize) -> CGPoint {
        let minY = graph["min"].double, maxY = graph["max"].double
        return CGPoint(
            x: 2 + point["x"].double / max(1, graph["maxX"].double) * max(0, size.width - 4),
            y: 6 + (1 - (point["y"].double - minY) / (maxY == minY ? 1 : maxY - minY)) * max(0, size.height - 12))
    }
    var body: some View {
        Canvas { context, size in
            for tick in graph["ticks"].array {
                let x = 2 + tick["x"].double / max(1, graph["maxX"].double) * max(0, size.width - 4)
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(.primary.opacity(0.12)), lineWidth: 1)
            }
            for run in graph["runs"].array {
                for pair in zip(run.array, run.array.dropFirst()) {
                    let start = Self.position(pair.0, graph: graph, size: size)
                    let end = Self.position(pair.1, graph: graph, size: size)
                    let color = pair.1["color"].exists
                        ? Color(uiColor: UIColor(mapColor: pair.1["color"].string)) : .white.opacity(0.6)
                    var fill = Path()
                    fill.move(to: start)
                    fill.addLine(to: end)
                    fill.addLine(to: CGPoint(x: end.x, y: size.height - 1))
                    fill.addLine(to: CGPoint(x: start.x, y: size.height - 1))
                    fill.closeSubpath()
                    context.fill(fill, with: .color(color.opacity(0.15)))
                    var line = Path()
                    line.move(to: start)
                    line.addLine(to: end)
                    context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}

private struct NativeActivityAxis: View, Equatable {
    let graph: JSON
    var body: some View {
        Canvas { context, size in
            func text(_ value: String) -> GraphicsContext.ResolvedText {
                context.resolve(Text(value).font(.system(size: 11)).foregroundColor(.secondary))
            }
            let low = text(graph["minLabel"].string)
            context.draw(low, at: CGPoint(x: 0, y: 3), anchor: .topLeading)
            var right = low.measure(in: CGSize(width: .infinity, height: size.height)).width + 8
            for tick in graph["ticks"].array {
                let label = text(tick["label"].string)
                let width = label.measure(in: CGSize(width: .infinity, height: size.height)).width
                let x = 2 + tick["x"].double / max(1, graph["maxX"].double) * max(0, size.width - 4)
                guard x - width / 2 >= right, x + width / 2 <= size.width else { continue }
                context.draw(label, at: CGPoint(x: x, y: 3), anchor: .top)
                right = x + width / 2 + 4
            }
        }.accessibilityHidden(true)
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
                            await store.openActivity(route["id"], refresh: true)
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
                                await store.openActivity(previous["id"], refresh: true)
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
    @State private var dragOffset = CGSize.zero
    private var singleVisit: Bool { store.place["visitCount"].int == 1 }
    private var canExpand: Bool {
        !singleVisit && (store.place["visitDates"].array.count > 1
            || store.place["covered"].exists || !store.place["links"].array.isEmpty)
    }
    private var subtitle: String {
        if store.place["visited"].bool {
            return nativeVisitLabel(store.place)
        }
        return store.place["visited"].exists
            ? "Not visited yet" : store.place["subtitle"].text(store.place["loading"].bool ? "Loading visit details…" : store.place["code"].string)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.place["name"].text(store.place["title"].text("This place")))
                        .font(.title3.weight(.semibold)).lineLimit(2)
                    if singleVisit, let value = store.place["visitDates"].array.first, let day = nativeDayKey(value) {
                        Button { Task { await store.selectTrack(day: day) } } label: {
                            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                        }.buttonStyle(.plain)
                    } else {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if store.place["loading"].bool {
                    ProgressView().controlSize(.small).accessibilityLabel("Loading visit details")
                }
                if canExpand {
                    NativeMapCardButton(
                        title: expanded ? "Hide visit details" : "Show visit details",
                        icon: expanded ? "chevron.down" : "chevron.up"
                    ) { withAnimation { expanded.toggle() } }
                }
                NativeMapCardButton(title: "Close place", icon: "xmark") {
                    store.closeSelection()
                }
            }
            .modifier(NativeMapCardDrag(offset: $dragOffset, horizontal: false) { swipe in
                switch swipe {
                case .expand: if canExpand { withAnimation { expanded = true } }
                case .collapse:
                    if expanded { withAnimation { expanded = false } }
                    else { store.closeSelection() }
                default: break
                }
            })
            if store.place["detailsError"].exists {
                Text(store.place["detailsError"].string).font(.caption).foregroundStyle(.secondary)
            }
            if (expanded && canExpand) || (!canExpand && store.place["rows"].exists) {
                ForEach(Array(store.place["rows"].array.enumerated()), id: \.offset) { _, row in
                    LabeledContent(row[0].string, value: row[1].string).font(.caption)
                }
                if !store.place["links"].array.isEmpty {
                    HStack {
                        ForEach(Array(store.place["links"].array.enumerated()), id: \.offset) { _, link in
                            if let url = URL(string: link["url"].string),
                                ["https", "http"].contains(url.scheme ?? "")
                            {
                                Link(link["label"].string, destination: url).font(.caption)
                            }
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
                if !singleVisit && !store.place["visitDates"].array.isEmpty {
                    ScrollView { visitDates }
                        .frame(height: min(308, CGFloat(store.place["visitDates"].array.count) * 44))
                        .clipped()
                }
            }
        }.padding(16).modifier(NativeMapCardSurface())
            .offset(dragOffset)
            .onChange(of: store.placeCardID) { _ in expanded = false }
    }

    private var visitDates: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(store.place["visitDates"].array.enumerated()), id: \.offset) { _, value in
                Button {
                    guard let day = nativeDayKey(value) else { return }
                    Task { await store.selectTrack(day: day) }
                } label: {
                    HStack {
                        Text(nativeDate(value)).font(.subheadline)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(nativeDayKey(value) == nil)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
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
