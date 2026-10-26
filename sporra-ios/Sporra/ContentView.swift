import Combine
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var store = NativeStore()
    var body: some View {
        Group {
            if !store.ready {
                ProgressView("Opening Sporra…")
            } else if store.signedIn {
                NativeMapScreen(store: store)
            } else {
                NativeLogin(store: store)
            }
        }
        .task { await store.initialize() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) {
            _ in
            Task { await SyncClient.shared.flush(force: true) }
        }
        .alert(
            "Sporra",
            isPresented: Binding(
                get: { store.error != nil && !store.signedIn }, set: { if !$0 { store.error = nil } })
        ) {
            Button("OK") { store.error = nil }
        } message: {
            Text(store.error ?? "")
        }
    }
}

private struct NativeLogin: View {
    @ObservedObject var store: NativeStore
    @State private var server = AppSettings.shared.serverURL
    @State private var username = ""
    @State private var password = ""
    @State private var register = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        Image(systemName: "globe.europe.africa.fill").font(.system(size: 52)).foregroundStyle(
                            .tint)
                        Text("Your world, remembered.").font(.largeTitle.bold())
                        Text("Connect to your Sporra server to see the places you have been.")
                            .foregroundStyle(.secondary)
                    }.padding(.vertical, 20)
                }.listRowBackground(Color.clear)
                Section("Your server") {
                    TextField("https://sporra.example.com", text: $server).keyboardType(.URL).textContentType(
                        .URL
                    ).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Username", text: $username).textContentType(.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password).textContentType(
                        register ? .newPassword : .password
                    ).onSubmit(submit)
                }
                Section {
                    Button(action: submit) {
                        HStack {
                            Spacer()
                            if store.busy { ProgressView() }
                            Text(register ? "Create account" : "Sign in")
                            Spacer()
                        }
                    }.disabled(store.busy || server.isEmpty || username.isEmpty || password.isEmpty)
                    Button(register ? "Already have an account? Sign in" : "Create an account") {
                        register.toggle()
                    }.disabled(store.busy)
                }
                Section {
                    Text(
                        "Sporra for iOS · \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")"
                    ).font(.footnote).foregroundStyle(.secondary)
                }.listRowBackground(Color.clear)
            }
        }
    }
    private func submit() {
        Task {
            await store.login(address: server, username: username, password: password, register: register)
            if store.signedIn { password = "" }
        }
    }
}

struct NativeMapScreen: View {
    @ObservedObject var store: NativeStore
    @State private var panel: String?
    var body: some View {
        NavigationStack {
            NativeMap(store: store).ignoresSafeArea()
                .overlay(alignment: .top) {
                    if store.busy {
                        ProgressView().padding(12).background(.regularMaterial, in: Capsule()).padding()
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 8) {
                    VStack(spacing: 8) {
                        if store.notice.exists { announcement }
                        if store.undo["route"].exists || store.undo["routeUpdate"].exists {
                            HStack {
                                Text(store.undo["route"].exists ? "Activity deleted" : "Activity updated")
                                Spacer()
                                Button("Undo") { Task { await store.undoEdit() } }
                                Button {
                                    store.undo = .null
                                } label: {
                                    Image(systemName: "xmark")
                                }.accessibilityLabel("Dismiss undo")
                            }.font(.subheadline).padding().background(
                                .regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                        }
                        if store.editing { editBar }
                        if store.activity.exists {
                            NativeActivityCard(store: store)
                        } else if store.track.exists {
                            trackBar
                        } else if store.place.exists {
                            NativePlaceCard(store: store)
                        }
                    }.padding(.horizontal).padding(.bottom, 8).frame(maxWidth: 600)
                }
                .toolbar {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        Button {
                            panel = "menu"
                        } label: {
                            Label("Your map", systemImage: "line.3.horizontal")
                        }
                        Button {
                            panel = "search"
                        } label: {
                            Label("Search", systemImage: "magnifyingglass")
                        }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            panel = "calendar"
                        } label: {
                            Label("Calendar", systemImage: "calendar")
                        }
                        Button {
                            store.locationCommand = UUID()
                        } label: {
                            Label("My location", systemImage: "location")
                        }
                    }
                }
                .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
                .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: Binding(get: { panel != nil }, set: { if !$0 { panel = nil } })) {
            NavigationStack {
                Group {
                    switch panel {
                    case "search": NativeSearch(store: store, close: { panel = nil })
                    case "calendar": NativeCalendarScreen(store: store, close: { panel = nil })
                    default: NativeMenu(store: store, close: { panel = nil })
                    }
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { panel = nil } } }
                .alert(
                    "Sporra",
                    isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })
                ) {
                    Button("OK") { store.error = nil }
                } message: {
                    Text(store.error ?? "")
                }
            }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            "Choose an activity",
            isPresented: Binding(
                get: { !store.routeChoices.isEmpty }, set: { if !$0 { store.routeChoices = [] } }),
            titleVisibility: .visible
        ) {
            ForEach(Array(store.routeChoices.enumerated()), id: \.offset) { _, route in
                Button(route["name"].text("Activity")) {
                    store.routeChoices = []
                    Task { await store.openActivity(route["id"]) }
                }
            }
        }
        .task { await store.checkAnnouncements() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) {
            store.lightClock = $0
            Task { await store.checkAnnouncements() }
        }
        .alert(
            "Sporra",
            isPresented: Binding(
                get: { store.error != nil && panel == nil }, set: { if !$0 { store.error = nil } })
        ) {
            Button("OK") { store.error = nil }
        } message: {
            Text(store.error ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) {
            _ in
            store.lightClock = Date()
            store.changed()
        }
        .sheet(isPresented: Binding(get: { store.shareURL != nil }, set: { if !$0 { store.shareURL = nil } }))
        {
            if let url = store.shareURL { NativeShare(items: [url]) }
        }
    }
    private var announcement: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.notice["title"].string).font(.headline)
                Text(store.notice["detail"].string).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let id = store.notice["activityIds"].array.first {
                Button("View") {
                    store.notice = .null
                    Task { await store.openActivity(id) }
                }
            }
            Button {
                store.notice = .null
            } label: {
                Image(systemName: "xmark")
            }.accessibilityLabel("Dismiss news")
        }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
    private var editBar: some View {
        HStack {
            Picker("Brush", selection: $store.brushAction) {
                Text("Paint").tag("paint")
                Text("Erase").tag("erase")
            }.pickerStyle(.segmented)
            Picker("Size", selection: $store.brushSize) {
                ForEach([1, 3, 8, 15, 30], id: \.self) { Text("\($0)").tag($0) }
            }.frame(width: 70)
            Button {
                store.clearingRegion.toggle()
            } label: {
                Image(systemName: store.clearingRegion ? "map.fill" : "map")
            }.accessibilityLabel("Clear a region")
            Button {
                Task { await store.undoEdit() }
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }.disabled(!store.undo.exists).accessibilityLabel("Undo edit")
            Button {
                store.editing = false
            } label: {
                Image(systemName: "checkmark")
            }.accessibilityLabel("Finish editing")
        }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
    private var trackBar: some View {
        HStack {
            Button {
                Task { await store.step(-1) }
            } label: {
                Image(systemName: "chevron.left")
            }.accessibilityLabel("Previous")
            VStack(alignment: .leading) {
                Text(store.track["label"].text("Your track")).font(.headline)
                Text(String(format: "%.1f km", store.track["km"].double)).font(.caption).foregroundStyle(
                    .secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Task { await store.step(1) }
            } label: {
                Image(systemName: "chevron.right")
            }.accessibilityLabel("Next")
            Button {
                store.closeSelection()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }.accessibilityLabel("Close track")
        }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

struct NativeShare: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

func nativeDate(_ value: JSON) -> String {
    if !value.exists || value == .number(0) { return "Unknown" }
    let date =
        value.double > 0
        ? Date(timeIntervalSince1970: value.double) : ISO8601DateFormatter().date(from: value.string)
    return date?.formatted(date: .abbreviated, time: .omitted) ?? value.string
}

func nativeDateTime(_ value: JSON, clock: String) -> String {
    guard value.double > 0 else { return "Unknown" }
    let date = Date(timeIntervalSince1970: value.double)
    let formatter = DateFormatter()
    if clock == "24" {
        formatter.dateFormat = "d MMM yyyy HH:mm"
    } else if clock == "12" {
        formatter.dateFormat = "d MMM yyyy h:mm a"
    } else {
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
    }
    return formatter.string(from: date)
}
