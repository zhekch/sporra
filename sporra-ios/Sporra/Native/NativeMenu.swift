import CoreLocation
import SwiftUI

struct NativeMenu: View {
    @ObservedObject var store: NativeStore
    var close: () -> Void = {}
    @State private var opacity = 0.3
    @State private var color = Color.blue
    @State private var last2DStyle = "dark"
    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Map type", selection: mapType) {
                    Text("2D").tag("2d")
                    Text("3D").tag("3d").disabled(store.token.isEmpty)
                    Text("Satellite").tag("satellite")
                }.pickerStyle(.segmented)
                if mapType.wrappedValue == "2d" {
                    Picker("2D appearance", selection: $store.style) {
                        Text("Dark").tag("dark")
                        Text("Terrain").tag("terrain")
                        Text("Light").tag("voyager")
                    }.pickerStyle(.segmented)
                } else if mapType.wrappedValue == "3d" {
                    Picker("3D appearance", selection: Binding(
                        get: { store.prefs["mapboxLight"].text("auto") },
                        set: { store.save(["mapboxLight": .string($0)]) }
                    )) {
                        Text("Dark").tag("night")
                        Text("Light").tag("day")
                        Text("Auto").tag("auto")
                    }.pickerStyle(.segmented)
                }
                if store.token.isEmpty {
                    Text("Add a Mapbox public token in Settings → Map layers to enable 3D.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Picker("Detail", selection: $store.detail) {
                    Text("Automatic").tag("auto")
                    Text("Finest").tag("finest")
                    Text("Regions").tag("regions")
                    Text("Country").tag("country")
                }.pickerStyle(.menu)
                Picker(
                    "Colour by",
                    selection: Binding(get: { store.mode }, set: { store.save(["heatMode": .string($0)]) })
                ) {
                    Text("Single colour").tag("flat")
                    Text("Visits").tag("visits")
                    Text("First visit").tag("oldest")
                    Text("Source").tag("type")
                }.pickerStyle(.menu)
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
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Opacity")
                        Spacer()
                        Text(opacity, format: .percent.precision(.fractionLength(0))).foregroundStyle(
                            .secondary)
                    }
                    NativeOpacitySlider(value: $opacity) {
                        var values = store.prefs["mapOpacities"]
                        values[store.mode] = .number(opacity)
                        store.save(["mapOpacities": values])
                    }
                    .frame(height: 32)
                    .onChange(of: store.mode) { _ in opacity = store.opacity }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
            }
            Section("Your map") {
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
        }
            .navigationTitle("Your map")
            .onAppear {
                if !["mapbox", "satellite"].contains(store.style) { last2DStyle = store.style }
                opacity = store.opacity
                color = Color(uiColor: UIColor(mapColor: store.accent))
            }
    }
    private var mapType: Binding<String> {
        Binding(
            get: {
                store.style == "mapbox" ? "3d" : (store.style == "satellite" ? "satellite" : "2d")
            },
            set: { value in
                guard value != "3d" || !store.token.isEmpty else { return }
                if !["mapbox", "satellite"].contains(store.style) { last2DStyle = store.style }
                switch value {
                case "3d": store.style = "mapbox"
                case "satellite": store.style = "satellite"
                default: store.style = last2DStyle
                }
            })
    }

    private func prefBool(_ key: String) -> Binding<Bool> {
        Binding(get: { store.prefs[key].bool }, set: { store.save([key: .bool($0)]) })
    }
}

/// UIKit owns the thumb, relative tracking, press animation and accessibility.
private struct NativeOpacitySlider: UIViewRepresentable {
    @Binding var value: Double
    var commit: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UISlider {
        let slider = UISlider()
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.minimumTrackTintColor = .label
        if #available(iOS 26.0, *) {
            slider.sliderStyle = .thumbless
        } else {
            let thumb = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
            slider.setThumbImage(thumb, for: .normal)
            slider.setThumbImage(thumb, for: .highlighted)
        }
        slider.accessibilityLabel = "Map opacity"
        slider.addTarget(context.coordinator, action: #selector(Coordinator.began(_:)), for: .touchDown)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.ended(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return slider
    }
    func updateUIView(_ slider: UISlider, context: Context) {
        context.coordinator.parent = self
        if !slider.isTracking { slider.setValue(Float(value), animated: false) }
        slider.accessibilityValue = value.formatted(.percent.precision(.fractionLength(0)))
    }
    final class Coordinator: NSObject {
        var parent: NativeOpacitySlider
        private let feedback = UISelectionFeedbackGenerator()
        private var step: Int?
        init(_ parent: NativeOpacitySlider) { self.parent = parent }
        @objc func began(_ slider: UISlider) { step = Int((slider.value * 20).rounded()); feedback.prepare() }
        @objc func changed(_ slider: UISlider) {
            parent.value = Double(slider.value)
            let next = Int((slider.value * 20).rounded())
            if step != next { feedback.selectionChanged(); feedback.prepare(); step = next }
            slider.accessibilityValue = parent.value.formatted(.percent.precision(.fractionLength(0)))
            parent.commit()
        }
        @objc func ended(_ slider: UISlider) { parent.value = Double(slider.value); parent.commit(); step = nil }
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
