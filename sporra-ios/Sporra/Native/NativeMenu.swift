import CoreLocation
import SwiftUI

struct NativeMenu: View {
    @ObservedObject var store: NativeStore
    var close: () -> Void = {}
    @State private var opacity = 0.3
    @State private var color = Color.blue
    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Basemap", selection: $store.style) {
                    Text("Dark").tag("dark")
                    Text("Light").tag("voyager")
                    Text("Terrain").tag("terrain")
                    Text("Satellite").tag("satellite")
                    if !store.token.isEmpty { Text("3D").tag("mapbox") }
                }
                Picker("Detail", selection: $store.detail) {
                    Text("Automatic").tag("auto")
                    Text("Finest").tag("finest")
                    Text("Country").tag("country")
                }
                Picker(
                    "Colour by",
                    selection: Binding(get: { store.mode }, set: { store.save(["heatMode": .string($0)]) })
                ) {
                    Text("Single colour").tag("flat")
                    Text("Visits").tag("visits")
                    Text("First visit").tag("oldest")
                    Text("Source").tag("type")
                }
                if store.mode == "flat" {
                    ColorPicker("Visited colour", selection: $color, supportsOpacity: false).onChange(
                        of: color
                    ) { value in
                        let hex = value.nativeHex
                        var accents = store.prefs["accents"]
                        accents[store.style == "voyager" ? "light" : "dark"] = .string(hex)
                        store.save(["accent": .string(hex), "accents": accents])
                    }
                }
                VStack(alignment: .leading) {
                    HStack {
                        Text("Opacity")
                        Spacer()
                        Text(opacity, format: .percent.precision(.fractionLength(0))).foregroundStyle(
                            .secondary)
                    }
                    Slider(value: $opacity, in: 0...1) { editing in
                        if !editing {
                            var values = store.prefs["mapOpacities"]
                            values[store.mode] = .number(opacity)
                            store.save(["mapOpacities": values])
                        }
                    }.accessibilityLabel("Map opacity")
                }
            }
            Section("Your map") {
                Toggle("Visited areas", isOn: $store.ground)
                Toggle("Activities", isOn: $store.activities)
                Toggle("Tap places for details", isOn: $store.cellInfo)
                Toggle("Photographs on this iPhone", isOn: $store.photos)
                Toggle("Editing", isOn: $store.editing).disabled(store.offline)
                NavigationLink("Activities", destination: NativeActivities(store: store, close: close))
                NavigationLink("Trips", destination: NativeTrips(store: store, close: close))
                NavigationLink("Statistics", destination: NativeStatistics(store: store))
                NavigationLink("Activity colours", destination: NativeActivityStyles(store: store))
            }
            Section("Reference layers") {
                Toggle("Railways", isOn: $store.rail)
                if store.rail {
                    NavigationLink("Railway options") {
                        Form {
                            Toggle("Technical infrastructure", isOn: prefBool("railTechnical"))
                            ForEach(
                                ["tracks", "stations", "platforms", "linenumbers", "symbols", "milestones"],
                                id: \.self
                            ) { group in
                                Toggle(
                                    group.capitalized,
                                    isOn: Binding(
                                        get: {
                                            store.prefs["railGroups"][group].exists
                                                ? store.prefs["railGroups"][group].bool
                                                : !["linenumbers", "symbols", "milestones"].contains(group)
                                        },
                                        set: { on in
                                            var groups = store.prefs["railGroups"]
                                            groups[group] = .bool(on)
                                            store.save(["railGroups": groups])
                                        }))
                            }
                        }.navigationTitle("Railways")
                    }
                }
                Toggle("Waymarked trails", isOn: $store.trails)
                if store.trails {
                    Picker("Trail type", selection: $store.trailTheme) {
                        ForEach(["hiking", "cycling", "mtb", "riding", "skating", "slopes"], id: \.self) {
                            Text($0.capitalized).tag($0)
                        }
                    }
                    Slider(value: $store.trailStrength, in: 0...1) { Text("Trail strength") }
                }
                NavigationLink("Airports") {
                    Form {
                        ForEach(["airline", "airfields", "helipads", "closed"], id: \.self) { group in
                            Toggle(
                                group.capitalized,
                                isOn: Binding(
                                    get: { store.airportGroups.contains(group) },
                                    set: {
                                        if $0 {
                                            store.airportGroups.insert(group)
                                        } else {
                                            store.airportGroups.remove(group)
                                        }
                                    }))
                        }
                    }.navigationTitle("Airports")
                }
            }
            Section {
                Button {
                    close()
                    Task {
                        try? await Task.sleep(for: .milliseconds(400))
                        store.snapshotCommand = UUID()
                    }
                } label: {
                    Label("Share map snapshot", systemImage: "square.and.arrow.up")
                }
                NavigationLink("Settings", destination: NativeSettings(store: store))
            }
        }.navigationTitle("Your map")
            .onAppear {
                opacity = store.opacity
                color = Color(uiColor: UIColor(mapColor: store.accent))
            }
    }
    private func prefBool(_ key: String) -> Binding<Bool> {
        Binding(get: { store.prefs[key].bool }, set: { store.save([key: .bool($0)]) })
    }
}

extension Color {
    var nativeHex: String {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

struct ServerContent<Content: View>: View {
    @ObservedObject var store: NativeStore
    let path: String
    @ViewBuilder var content: (JSON) -> Content
    @State private var value: JSON = .null
    @State private var error: String?
    var body: some View {
        Group {
            if value.exists {
                content(value)
            } else if let error {
                VStack(spacing: 16) {
                    Text(error)
                    Button("Try again") { Task { await load() } }
                }.padding()
            } else {
                ProgressView("Loading…")
            }
        }.task(id: "\(path):\(store.revision)") { await load() }
            .refreshable { await load(fresh: true) }
    }
    private func load(fresh: Bool = false) async {
        do {
            value = try await store.api.get(path, fresh: fresh)
            error = nil
        } catch is CancellationError {} catch {
            if (error as? ServerFailure)?.status == 401 {
                await store.report(error)
            } else {
                self.error = error.localizedDescription
            }
        }
    }
}
