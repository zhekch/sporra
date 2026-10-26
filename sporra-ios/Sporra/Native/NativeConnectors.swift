import AuthenticationServices
import SwiftUI
import UIKit

@MainActor
final class NativeAuthorization: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = NativeAuthorization()
    private var session: ASWebAuthenticationSession?
    func authorize(_ url: URL) async throws -> URL {
        guard session == nil else {
            throw ServerFailure(status: 0, message: "An authorization is already open.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            let auth = ASWebAuthenticationSession(url: url, callbackURLScheme: "sporra-flutter") {
                [weak self] result, error in
                self?.session = nil
                if let result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(
                        throwing: error ?? ServerFailure(status: 0, message: "Authorization was cancelled."))
                }
            }
            auth.presentationContextProvider = self
            session = auth
            if !auth.start() {
                session = nil
                continuation.resume(
                    throwing: ServerFailure(status: 0, message: "Authorization could not be opened."))
            }
        }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(
            where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

struct NativeConnector: View {
    @ObservedObject var store: NativeStore
    var kind: String
    @State private var link: JSON = .null
    @State private var clientID = ""
    @State private var secret = ""
    @State private var baseURL = ""
    @State private var token = ""
    @State private var entities: [JSON] = []
    @State private var chosen: Set<String> = []
    @State private var enabled = true
    @State private var saveRoutes = true
    @State private var interval = 60
    @State private var accuracy = 250
    @State private var loaded = false
    @State private var disconnect = false
    @State private var callbackDomain = ""
    var body: some View {
        Form {
            if !loaded { ProgressView("Loading…") }
            Section(kind == "strava" ? "Strava application" : "Home Assistant server") {
                if kind == "strava" {
                    TextField("Client ID", text: $clientID).keyboardType(.numberPad)
                    SecureField(
                        link.exists ? "Client secret (unchanged if empty)" : "Client secret", text: $secret)
                    LabeledContent("Callback domain", value: callbackDomain)
                    Link(
                        "Create a Strava API application",
                        destination: URL(string: "https://www.strava.com/settings/api")!)
                } else {
                    TextField("Server address", text: $baseURL).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(
                        link.exists ? "Token (unchanged if empty)" : "Long-lived access token", text: $token)
                    Button("Find devices") { Task { await probe() } }.disabled(store.busy)
                    ForEach(Array(entities.enumerated()), id: \.offset) { _, entity in
                        let id = entity["id"].text(entity["entity_id"].string)
                        Toggle(
                            entity["name"].text(id),
                            isOn: Binding(
                                get: { chosen.contains(id) },
                                set: { if $0 { chosen.insert(id) } else { chosen.remove(id) } }))
                    }
                }
            }
            Section("Sync schedule") {
                Toggle("Sync automatically", isOn: $enabled)
                Picker("Interval", selection: $interval) {
                    ForEach(kind == "strava" ? [15, 30, 60, 180, 720] : [5, 15, 30, 60, 180], id: \.self) {
                        Text("Every \($0) minutes").tag($0)
                    }
                }
                if kind == "strava" {
                    Toggle("Save activities", isOn: $saveRoutes)
                } else {
                    Picker("Accuracy", selection: $accuracy) {
                        ForEach([0, 100, 250, 500, 1000], id: \.self) {
                            Text($0 == 0 ? "Any fix" : "Within \($0) m").tag($0)
                        }
                    }
                }
                Button("Save settings") { Task { await save() } }.disabled(store.busy)
            }
            if link.exists {
                Section("Status") {
                    if kind == "strava" {
                        LabeledContent("Account", value: link["athlete"].string)
                        Button(link["connected"].bool ? "Reconnect Strava" : "Authorize Strava") {
                            Task { await authorize() }
                        }.disabled(store.busy)
                    }
                    LabeledContent("Last checked", value: nativeDate(link["lastRun"]))
                    LabeledContent("Last successful sync", value: nativeDate(link["lastOk"]))
                    LabeledContent("Imported", value: link["totalCount"].string)
                    if !link["lastError"].string.isEmpty {
                        Text(link["lastError"].string).foregroundStyle(.orange)
                    }
                    Button("Sync now") {
                        Task {
                            await store.perform {
                                _ = try await store.api.post("/api/\(kind)/sync")
                                await load()
                                store.changed()
                            }
                        }
                    }.disabled(store.busy)
                    Button("Disconnect", role: .destructive) { disconnect = true }
                }
            }
        }.navigationTitle(kind == "strava" ? "Strava" : "Home Assistant")
            .task { await load() }
            .confirmationDialog(
                "Disconnect this service? Imported locations stay on your map.", isPresented: $disconnect,
                titleVisibility: .visible
            ) {
                Button("Disconnect", role: .destructive) {
                    Task {
                        await store.perform {
                            _ = try await store.api.post("/api/\(kind)/delete")
                            link = .null
                            secret = ""
                            token = ""
                            store.changed()
                        }
                    }
                }
            }
    }
    private func load() async {
        await store.perform {
            let data = try await store.api.get("/api/\(kind)", fresh: true)
            link = data["link"]
            callbackDomain = data["callbackDomain"].string
            clientID = link["clientId"].string
            baseURL = link["baseUrl"].string
            enabled = !link.exists || link["enabled"].bool
            saveRoutes = !link.exists || link["saveRoutes"].bool
            interval = link["intervalMin"].exists ? link["intervalMin"].int : kind == "ha" ? 15 : 60
            accuracy = link["maxAccuracy"].exists ? link["maxAccuracy"].int : 250
            chosen = Set(link["entities"].array.map(\.string))
            loaded = true
        }
    }
    private func probe() async {
        await store.perform {
            let data = try await store.api.post(
                "/api/ha/probe", ["baseUrl": .string(baseURL), "token": .string(token)])
            entities = data["entities"].array
        }
    }
    private func save() async {
        await store.perform {
            var body: [String: JSON] = ["enabled": .bool(enabled), "intervalMin": .number(Double(interval))]
            if kind == "strava" {
                body["clientId"] = .string(clientID)
                body["clientSecret"] = .string(secret)
                body["saveRoutes"] = .bool(saveRoutes)
            } else {
                body["baseUrl"] = .string(baseURL)
                body["token"] = .string(token)
                body["entities"] = .strings(chosen.sorted())
                body["maxAccuracy"] = .number(Double(accuracy))
            }
            let result = try await store.api.post("/api/\(kind)", body)
            link = result["link"]
            secret = ""
            token = ""
            store.changed()
        }
    }
    private func authorize() async {
        await store.perform {
            let result = try await store.api.post("/api/strava/authorize", ["native": .bool(true)])
            guard let url = URL(string: result["url"].string), ["https", "http"].contains(url.scheme ?? "")
            else { throw ServerFailure(status: 0, message: "Invalid authorization URL.") }
            let callback = try await NativeAuthorization.shared.authorize(url)
            let status = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first {
                $0.name == "strava"
            }?.value
            guard status == "ok" else {
                throw ServerFailure(status: 0, message: "Strava authorization failed. Please try again.")
            }
            await load()
        }
    }
}

struct NativeBackups: View {
    @ObservedObject var store: NativeStore
    @State private var backup: JSON = .null
    @State private var enabled = true
    @State private var cron = "0 4 * * *"
    @State private var keep = 14
    @State private var note = ""
    @State private var share: URL?
    var body: some View {
        Form {
            if !backup.exists { ProgressView("Loading…") }
            Section("Schedule") {
                Toggle("Automatic backups", isOn: $enabled)
                TextField("Cron schedule", text: $cron).textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Stepper("Keep \(keep) backups", value: $keep, in: 1...365)
                Button("Save schedule") { Task { await run(false) } }.disabled(store.busy)
                Text(
                    "Minute, hour, day of month, month, weekday. For example, 0 4 * * * runs daily at 04:00 in the server's time zone."
                ).font(.footnote).foregroundStyle(.secondary)
            }
            Section("Status") {
                LabeledContent("Last run", value: nativeDate(backup["lastRun"]))
                LabeledContent("Last successful backup", value: nativeDate(backup["lastOk"]))
                if !backup["lastError"].string.isEmpty {
                    Text(backup["lastError"].string).foregroundStyle(.orange)
                }
                Button("Back up now") { Task { await run(true) } }.disabled(store.busy)
                if !note.isEmpty { Text(note).foregroundStyle(.secondary) }
            }
            Section("Backup files") {
                ForEach(Array(backup["files"].array.enumerated()), id: \.offset) { _, file in
                    Button {
                        Task {
                            await store.perform {
                                let bytes = try await store.api.download(
                                    "/api/backup/download?"
                                        + (URLComponents(
                                            string:
                                                "?name=\(file["name"].string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
                                        )?.percentEncodedQuery ?? ""))
                                let name = URL(fileURLWithPath: file["name"].string).lastPathComponent
                                let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                                try bytes.write(to: url, options: .atomic)
                                share = url
                            }
                        }
                    } label: {
                        HStack {
                            Text(file["name"].string)
                            Spacer()
                            Text(
                                ByteCountFormatter.string(
                                    fromByteCount: Int64(file["size"].double), countStyle: .file)
                            ).font(.caption).foregroundStyle(.secondary)
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
        }.navigationTitle("Backups").task { await load() }
            .sheet(isPresented: Binding(get: { share != nil }, set: { if !$0 { share = nil } })) {
                if let share { NativeShare(items: [share]) }
            }
    }
    private func fill(_ value: JSON) {
        backup = value
        enabled = value["enabled"].bool
        cron = value["cron"].text("0 4 * * *")
        keep = value["keep"].exists ? value["keep"].int : 14
    }
    private func load() async {
        await store.perform { fill(try await store.api.get("/api/backup")["backup"]) }
    }
    private func run(_ now: Bool) async {
        await store.perform {
            let result = try await store.api.post(
                now ? "/api/backup/run" : "/api/backup",
                now ? [:] : ["enabled": .bool(enabled), "cron": .string(cron), "keep": .number(Double(keep))])
            fill(result["backup"])
            if result["status"].string == "error" {
                throw ServerFailure(status: 0, message: result["error"].text("Backup failed."))
            }
            note = now ? result["status"].text("Backup finished.") : "Schedule saved."
        }
    }
}
struct NativeUsers: View {
    @ObservedObject var store: NativeStore
    var body: some View {
        ServerContent(store: store, path: "/api/admin/users") { data in
            List {
                ForEach(Array(data["users"].array.enumerated()), id: \.offset) { _, user in
                    VStack(alignment: .leading) {
                        Text(user["username"].string).font(.headline)
                        Text(user["admin"].bool ? "Administrator" : "Member").foregroundStyle(.secondary)
                        Text("Last active: \(nativeDate(user["lastSeen"]))").font(.caption).foregroundStyle(
                            .secondary)
                    }
                }
            }
        }.navigationTitle("Users")
    }
}
