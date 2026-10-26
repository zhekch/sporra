import CoreLocation
import SwiftUI

struct NativeSettings: View {
    @ObservedObject var store: NativeStore
    @State private var token = ""
    @State private var password = ""
    @State private var deleting = false
    @State private var signedOut = false
    @State private var serverVersion = ""
    var body: some View {
        Form {
            Section("Account") {
                LabeledContent("Username", value: store.user["username"].string)
                LabeledContent("Server", value: AppSettings.shared.serverURL)
                NavigationLink("Home") { NativeHome(store: store) }
                Picker(
                    "Clock",
                    selection: Binding(
                        get: { store.prefs["clock"].text("auto") },
                        set: { store.save(["clock": .string($0)]) })
                ) {
                    Text("System").tag("auto")
                    Text("24 hour").tag("24")
                    Text("12 hour").tag("12")
                }
                Toggle(
                    "What's new",
                    isOn: Binding(
                        get: { store.prefs["whatsNew"].string != "never" },
                        set: { store.save(["whatsNew": .string($0 ? "substantial" : "never")]) }))
            }
            Section("Import & sync") {
                NavigationLink("Import files or a link", destination: NativeImport(store: store))
                NavigationLink("This iPhone", destination: NativeDeviceSettings(store: store))
                NavigationLink("Sources", destination: NativeSources(store: store))
                NavigationLink("Strava", destination: NativeConnector(store: store, kind: "strava"))
                NavigationLink("Home Assistant", destination: NativeConnector(store: store, kind: "ha"))
                Button("Sync now") { Task { await store.sync() } }.disabled(store.busy)
            }
            Section {
                SecureField("Mapbox public token (pk.)", text: $token).textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save Mapbox token") {
                    Task {
                        await store.perform {
                            let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !clean.isEmpty {
                                guard clean.hasPrefix("pk.") else {
                                    throw ServerFailure(
                                        status: 0, message: "Use a public Mapbox token beginning with pk.")
                                }
                                var parts = URLComponents(
                                    string: "https://api.mapbox.com/styles/v1/mapbox/standard")!
                                parts.queryItems = query(["access_token": clean])
                                let (_, response) = try await URLSession.shared.data(from: parts.url!)
                                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                                    throw ServerFailure(
                                        status: 0,
                                        message:
                                            "Mapbox rejected this token. Check its permissions and URL restrictions."
                                    )
                                }
                            }
                            try await store.patchPrefs(["mapboxToken": .string(clean)])
                            if !clean.isEmpty {
                                store.style = "mapbox"
                            } else if store.style == "mapbox" {
                                store.style = "dark"
                            }
                        }
                    }
                }.disabled(store.busy)
                Picker(
                    "3D lighting",
                    selection: Binding(
                        get: { store.prefs["mapboxLight"].text("auto") },
                        set: { store.save(["mapboxLight": .string($0)]) })
                ) {
                    Text("Automatic").tag("auto")
                    Text("Day").tag("day")
                    Text("Night").tag("night")
                }
            } header: {
                Text("Map layers")
            } footer: {
                Text("3D and Mapbox satellite use your public token. Free 2D maps work without one.")
            }
            if store.user["admin"].bool {
                Section("Server") {
                    NavigationLink("Backups", destination: NativeBackups(store: store))
                    NavigationLink("Users", destination: NativeUsers(store: store))
                }
            }
            Section("On this device") {
                Button("Reload map") { store.changed() }
                Button("Clear map cache") {
                    Task {
                        await store.api.clearCache()
                        store.changed()
                    }
                }
                LabeledContent(
                    "App version",
                    value:
                        "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""))"
                )
                LabeledContent(
                    "Server version",
                    value: serverVersion.isEmpty ? store.user["version"].string : serverVersion)
            }
            Section {
                Button("Sign out", role: .destructive) { signedOut = true }
                Button("Delete account…", role: .destructive) { deleting = true }
            }
        }.navigationTitle("Settings").onAppear { token = store.token }
            .task {
                serverVersion = (try? await store.api.get("/api/health", fresh: true)["version"].string) ?? ""
            }
            .confirmationDialog("Sign out of Sporra?", isPresented: $signedOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { Task { await store.signOut() } }
            }
            .alert("Delete your account?", isPresented: $deleting) {
                SecureField("Confirm your password", text: $password)
                Button("Delete account", role: .destructive) {
                    Task {
                        await store.perform {
                            _ = try await store.api.post(
                                "/api/account/delete", ["password": .string(password)])
                            password = ""
                            await store.signOut()
                        }
                    }
                }
                Button("Cancel", role: .cancel) { password = "" }
            } message: {
                Text(
                    "This permanently removes your map, routes, and account. Server backups are kept. Enter your password to continue."
                )
            }
    }
}
struct NativeHome: View {
    @ObservedObject var store: NativeStore
    var body: some View {
        Form {
            if store.prefs["home"].exists {
                LabeledContent("Home", value: store.prefs["home"]["name"].text("Your home"))
                Button("Remove home", role: .destructive) { store.save(["home": .null]) }
            }
            Text("Search for your home, then hold the result and choose Set as home.").foregroundStyle(
                .secondary)
            NavigationLink("Find home") { NativeSearch(store: store, close: {}) }
        }.navigationTitle("Home")
    }
}
struct NativeDeviceSettings: View {
    @ObservedObject var store: NativeStore
    @ObservedObject private var tracking = TrackingSettings.shared
    @ObservedObject private var logger = LocationLogger.shared
    @ObservedObject private var photos = PhotoSync.shared
    @State private var resetHealth = false
    var body: some View {
        Form {
            Section("Recording") {
                TextField("Device name", text: $tracking.deviceName)
                Picker("Record location", selection: $tracking.cadence) {
                    ForEach(TrackingSettings.Cadence.allCases) { Text($0.title).tag($0) }
                }
                Picker("Accuracy", selection: $tracking.precision) {
                    ForEach(TrackingSettings.Precision.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Queued fixes", value: String(FixQueue.shared.count))
                if let error = tracking.status.lastError { Text(error).foregroundStyle(.orange) }
                Button("Open iOS permissions") {
                    UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                }
            }
            Section("Apple Health") {
                Toggle("Sync workouts", isOn: $tracking.syncWorkouts).disabled(!HealthSync.shared.isAvailable)
                LabeledContent("Workouts sent", value: String(tracking.status.workoutsSent))
                Button("Re-import Apple Health", role: .destructive) { resetHealth = true }
            }
            Section {
                Toggle("Sync photo locations", isOn: $tracking.syncPhotos)
                LabeledContent("Photos located", value: String(tracking.status.photosSent))
                if photos.isLimited {
                    Text(
                        "Only selected photos are available. Allow full access in iOS Settings to include the whole library."
                    ).foregroundStyle(.secondary)
                }
            } header: {
                Text("Photographs")
            } footer: {
                Text("Only photo locations are sent to your server. Images and videos remain on this device.")
            }
            Section { Button("Sync now") { Task { await store.sync() } }.disabled(store.busy) }
        }.navigationTitle("This iPhone")
            .confirmationDialog(
                "Re-import all Apple Health workouts?", isPresented: $resetHealth, titleVisibility: .visible
            ) {
                Button("Re-import", role: .destructive) {
                    Task {
                        await store.perform {
                            try await SyncClient.shared.resetHealth()
                            await HealthSync.shared.sync()
                            store.changed()
                        }
                    }
                }
            }
    }
}
struct NativeSources: View {
    @ObservedObject var store: NativeStore
    @State private var rename: JSON = .null
    @State private var deleting: JSON = .null
    @State private var name = ""
    var body: some View {
        ServerContent(store: store, path: "/api/sources") { data in
            List {
                ForEach(Array(data["sources"].array.enumerated()), id: \.offset) { _, source in
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(
                            source["label"].text(source["key"].string),
                            isOn: Binding(
                                get: { !store.hidden.contains(source["key"].string) },
                                set: {
                                    if $0 {
                                        store.hidden.remove(source["key"].string)
                                    } else {
                                        store.hidden.insert(source["key"].string)
                                    }
                                    store.changed()
                                }))
                        Text("\(source["cells"].int) cells · \(source["routes"].int) activities").font(
                            .caption
                        ).foregroundStyle(.secondary)
                        Text("\(nativeDate(source["firstAt"])) – \(nativeDate(source["lastAt"]))").font(
                            .caption
                        ).foregroundStyle(.secondary)
                    }.swipeActions {
                        Button("Delete", role: .destructive) { deleting = source }
                        Button("Rename") {
                            rename = source
                            name = source["key"].string
                        }.tint(.blue)
                    }
                }
                if data["sources"].array.isEmpty { Text("No sources yet").foregroundStyle(.secondary) }
            }
        }.navigationTitle("Sources")
            .alert(
                "Rename source",
                isPresented: Binding(get: { rename.exists }, set: { if !$0 { rename = .null } })
            ) {
                TextField("Source name", text: $name).textInputAutocapitalization(.never)
                Button("Save") {
                    let source = rename
                    rename = .null
                    Task {
                        await store.perform {
                            _ = try await store.api.post(
                                "/api/sources/rename", ["from": source["key"], "to": .string(name)])
                            store.changed()
                        }
                    }
                }
                Button("Cancel", role: .cancel) { rename = .null }
            } message: {
                Text("Use lower-case letters, numbers, and hyphens.")
            }
            .confirmationDialog(
                "Remove this source and all its locations and activities?",
                isPresented: Binding(get: { deleting.exists }, set: { if !$0 { deleting = .null } }),
                titleVisibility: .visible
            ) {
                Button("Remove source", role: .destructive) {
                    let source = deleting
                    deleting = .null
                    Task {
                        await store.perform {
                            _ = try await store.api.post("/api/sources/delete", ["source": source["key"]])
                            store.changed()
                        }
                    }
                }
            }
    }
}
