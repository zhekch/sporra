import SwiftUI
import UniformTypeIdentifiers

struct NativeImport: View {
    @ObservedObject var store: NativeStore
    @State private var picker = false
    @State private var files: [URL] = []
    @State private var source = ""
    @State private var includeRoutes = true
    @State private var link = ""
    @State private var preview: JSON = .null
    @State private var requestBody: [String: JSON] = [:]
    @State private var endpoint = "/api/import/file"
    @State private var status = ""
    @State private var importing = false
    var body: some View {
        Form {
            Section("Options") {
                TextField("Source (automatic if empty)", text: $source).textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Toggle("Include activities", isOn: $includeRoutes)
            }.disabled(importing || preview.exists)
            Section {
                Button("Choose files…") { picker = true }.disabled(importing || preview.exists)
                Text("GPX, TCX, KML, FIT, GeoJSON, CSV, JSON, ZIP, and GZip").font(.footnote).foregroundStyle(
                    .secondary)
            }
            Section("Import from a link") {
                TextField("Komoot tour or share links", text: $link).keyboardType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Review link") { Task { await reviewLink() } }.disabled(
                    link.isEmpty || importing || preview.exists)
            }
            if importing { ProgressView("Reading…") }
            if preview.exists {
                Section("Review \(requestBody["name"]?.string ?? "link")") {
                    LabeledContent("Cells", value: preview["imported"].string)
                    LabeledContent("Activities", value: preview["routes"].string)
                    LabeledContent(
                        "Sources", value: preview["sources"].array.map(\.string).joined(separator: ", "))
                    LabeledContent("Files", value: String(preview["files"].array.count))
                    Button("Import") { Task { await commit() } }.disabled(importing)
                    Button("Skip", role: .cancel) {
                        preview = .null
                        requestBody = [:]
                        Task { await nextFile() }
                    }.disabled(importing)
                    Button("Cancel remaining files", role: .cancel) {
                        files = []
                        preview = .null
                        requestBody = [:]
                    }.disabled(importing)
                }
            }
            if !status.isEmpty { Section { Text(status).foregroundStyle(.secondary) } }
        }.navigationTitle("Import")
            .fileImporter(
                isPresented: $picker, allowedContentTypes: [.data, .content, .archive],
                allowsMultipleSelection: true
            ) { result in
                do {
                    files = try result.get()
                    Task { await nextFile() }
                } catch { store.error = error.localizedDescription }
            }
    }
    private func options() -> [String: JSON] {
        var values: [String: JSON] = ["includeRoutes": .bool(includeRoutes)]
        if !source.trimmingCharacters(in: .whitespaces).isEmpty {
            values["source"] = .string(source.trimmingCharacters(in: .whitespaces))
        }
        return values
    }
    private func nextFile() async {
        guard !files.isEmpty else { return }
        let url = files.removeFirst()
        importing = true
        defer { importing = false }
        await store.perform {
            let bytes = try await Task.detached {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 64 * 1024 * 1024 else {
                    throw ServerFailure(status: 0, message: "This file exceeds the 64 MB import limit.")
                }
                return try Data(contentsOf: url)
            }.value
            endpoint = "/api/import/file"
            requestBody = options()
            requestBody["name"] = .string(url.lastPathComponent)
            requestBody["base64"] = .string(bytes.base64EncodedString())
            var request = requestBody
            request["preview"] = .bool(true)
            preview = try await store.api.post(endpoint, request)
        }
    }
    private func reviewLink() async {
        importing = true
        defer { importing = false }
        await store.perform {
            endpoint = "/api/import/link"
            requestBody = options()
            requestBody["links"] = .string(link.trimmingCharacters(in: .whitespacesAndNewlines))
            var request = requestBody
            request["preview"] = .bool(true)
            preview = try await store.api.post(endpoint, request)
        }
    }
    private func commit() async {
        importing = true
        await store.perform {
            let result = try await store.api.post(endpoint, requestBody)
            status = "Imported \(result["imported"].int) cells and \(result["routes"].int) activities."
            preview = .null
            requestBody = [:]
            store.changed()
        }
        importing = false
        if !preview.exists { await nextFile() }
    }
}
