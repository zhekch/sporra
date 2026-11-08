import Combine
import SwiftUI
import UIKit

private let mapMenuCompactFraction = 0.515

private struct NativeMapControlStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 21, weight: .semibold))
            .frame(width: 50, height: 50)
            .contentShape(Rectangle())
            .background {
                Circle().fill(.primary.opacity(configuration.isPressed ? 0.10 : 0))
                    .padding(4)
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 1.12 : 1)
            .animation(reduceMotion ? .none : .spring(response: 0.24, dampingFraction: 0.65),
                value: configuration.isPressed)
    }
}

private nonisolated enum MapPanel: String, Identifiable {
    case menu, search
    var id: String { rawValue }
}

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
    @State private var panel: MapPanel?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        NavigationStack {
            NativeMap(store: store).ignoresSafeArea()
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 8) {
                        mapControls
                            .background(GeometryReader { proxy in
                                Color.clear
                                    .onAppear { store.mapControlsFrame = proxy.frame(in: .global) }
                                    .onChange(of: proxy.frame(in: .global)) { store.mapControlsFrame = $0 }
                            })
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.horizontal, 16)
                            .overlay(alignment: .bottom) {
                                if store.offline || store.connectionNotice || store.needsSignIn {
                                    offlineNotice
                                }
                            }
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
                                }.font(.subheadline).padding().modifier(NativeMapCardSurface())
                            }
                            if store.editing { editBar }
                            if store.activity.exists {
                                NativeActivityCard(store: store)
                                    .frame(maxWidth: 440)
                                    .id("activity:" + store.activity["route"]["id"].string)
                                    .transition(cardTransition)
                            } else if store.track.exists {
                                NativeTrackCard(store: store)
                                    .id(store.trackDay ?? store.track["id"].string)
                                    .transition(cardTransition)
                            } else if store.place.exists {
                                NativePlaceCard(store: store)
                                    .id(store.placeCardID)
                                    .transition(cardTransition)
                            }
                        }
                        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.88), value: selectionCardID)
                        .background(GeometryReader { proxy in
                            let layout = MapCardLayout(id: selectionCardID, frame: proxy.frame(in: .global))
                            Color.clear
                                .onAppear { store.mapCardLayout = layout }
                                .onChange(of: layout) { store.mapCardLayout = $0 }
                        })
                        .padding(.horizontal, 12).frame(maxWidth: 600)
                    }.padding(.bottom, 12)
                }
                .ignoresSafeArea(.container, edges: .bottom)
                .toolbar(.hidden, for: .navigationBar)
                .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(item: $panel) { destination in
            NavigationStack {
                Group {
                    switch destination {
                    case .search:
                        NativeSearch(store: store, close: { panel = nil }).modifier(NativeSheetTitleStyle())
                    case .menu:
                        NativeMenu(store: store, close: { panel = nil }).modifier(NativeSheetTitleStyle())
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
            }.tint(.primary)
                .presentationDetents(destination == .search ? [.medium, .large] : [.fraction(mapMenuCompactFraction), .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: Binding(
            get: { !store.routeChoices.isEmpty }, set: { if !$0 { store.routeChoices = [] } })
        ) {
            NativeActivityPicker(store: store)
        }
        .onAppear {
            store.restorePendingCells()
            LocationLogger.shared.setForegroundRecording(true)
        }
        .onDisappear { LocationLogger.shared.setForegroundRecording(false) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            LocationLogger.shared.setForegroundRecording(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: LocationLogger.didRecordForegroundFix)) { event in
            if let fix = event.object as? FixQueue.Fix { store.recordForegroundFix(fix) }
        }
        .onReceive(NotificationCenter.default.publisher(for: SyncClient.didUploadFixes)) { _ in
            Task {
                await store.api.invalidateHTTPCache()
                store.changed()
            }
        }
        .onReceive(Timer.publish(every: 15, on: .main, in: .common).autoconnect()) { _ in
            guard UIApplication.shared.applicationState == .active else { return }
            Task { await SyncClient.shared.flush() }
        }
        .task { await store.checkAnnouncements() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) {
            store.lightClock = $0
            Task {
                await store.reconnect()
                await store.checkAnnouncements()
            }
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
            LocationLogger.shared.setForegroundRecording(true)
            Task { await store.reconnect() }
        }
        .sheet(isPresented: Binding(get: { store.shareURL != nil }, set: { if !$0 { store.shareURL = nil } }))
        {
            if let url = store.shareURL { NativeShare(items: [url]) }
        }
    }
    private var selectionCardID: String { store.mapSelectionID }
    private var cardTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }

    @ViewBuilder
    private var mapControls: some View {
        if #available(iOS 26.0, *) {
            mapControlButtons
                // One shared glass surface; each button handles its own press.
                .glassEffect(.regular.interactive(), in: Capsule())
        } else {
            mapControlButtons.background(.regularMaterial, in: Capsule())
        }
    }

    private var mapControlButtons: some View {
        VStack(spacing: 0) {
            mapButton("My location", icon: store.locationFocused ? "location.fill" : "location") {
                store.locationCommand = UUID()
            }
            .accessibilityValue(store.locationFocused ? "Focused on your location" : "Not focused")
            Divider().frame(width: 24).opacity(0.4)
            mapButton("Search and calendar", icon: "magnifyingglass") { panel = .search }
            Divider().frame(width: 24).opacity(0.4)
            mapButton("Your map", icon: "line.3.horizontal") { panel = .menu }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private func mapButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if #available(iOS 17.0, *) {
                Image(systemName: icon).contentTransition(.symbolEffect(.replace))
            } else {
                Image(systemName: icon)
            }
        }
        .buttonStyle(NativeMapControlStyle())
        .accessibilityLabel(title)
    }

    private var offlineNotice: some View {
        Button {
            if store.needsSignIn { store.beginSignIn() }
            else { Task { await store.reconnect(force: true) } }
        } label: {
            HStack(spacing: 5) {
                if store.reconnecting { ProgressView().controlSize(.mini) }
                Label("Offline", systemImage: "wifi.slash")
                if !store.reconnecting { Image(systemName: "arrow.clockwise") }
            }.font(.caption2).padding(.horizontal, 10).padding(.vertical, 6)
        }
        .buttonStyle(.plain).modifier(NativeMapCardSurface())
        .accessibilityLabel(store.needsSignIn ? "Offline. Sign in to sync" : "Offline. Retry connection")
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
        }.padding().modifier(NativeMapCardSurface())
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
        }.padding(12).modifier(NativeMapCardSurface())
    }

}

struct NativeShare: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Keep the larger, leading title inside the toolbar alongside Done.
private struct NativeSheetTitleStyle: ViewModifier {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.toolbarTitleDisplayMode(verticalSizeClass == .compact ? .inline : .inlineLarge)
        } else {
            content.navigationBarTitleDisplayMode(.inline)
        }
    }
}
