import CryptoKit
import Foundation

/// A typed, sendable boundary for the server's evolving render documents.
nonisolated enum JSON: Codable, Sendable, Equatable {
    case object([String: JSON])
    case array([JSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([JSON].self) {
            self = .array(v)
        } else {
            self = .object(try c.decode([String: JSON].self))
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    subscript(_ key: String) -> JSON {
        get { object[key] ?? .null }
        set {
            var o = object
            o[key] = newValue
            self = .object(o)
        }
    }
    subscript(_ i: Int) -> JSON { array.indices.contains(i) ? array[i] : .null }
    var object: [String: JSON] {
        if case .object(let v) = self { return v }
        return [:]
    }
    var array: [JSON] {
        if case .array(let v) = self { return v }
        return []
    }
    var string: String {
        if case .string(let v) = self { return v }
        if case .number(let v) = self { return v == v.rounded() ? String(format: "%.0f", v) : String(v) }
        return ""
    }
    var double: Double {
        if case .number(let v) = self { return v }
        return Double(string) ?? 0
    }
    var int: Int { Int(double) }
    var bool: Bool { self == .bool(true) }
    var exists: Bool { self != .null }
    func text(_ fallback: String) -> String { string.isEmpty ? fallback : string }
    static func strings(_ v: [String]) -> JSON { .array(v.map(JSON.string)) }
    var data: Data { (try? JSONEncoder().encode(self)) ?? Data() }
}

nonisolated struct OfflineRecord: Codable {
    let file: String
    let bytes: Int
    let savedAt: Date
}

nonisolated struct ServerFailure: LocalizedError, Sendable {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

actor ServerAPI {
    static let shared = ServerAPI()
    private var base: URL?
    private var generation = 0
    private var session: URLSession
    private var cache: URLCache
    private let cookieStorage: HTTPCookieStorage
    private let cacheRoot: URL
    private var account = "signed-out"
    private var offline = false
    private var records: [String: OfflineRecord] = [:]
    private var offlineDirectory: URL?
    private let connectionEvents: AsyncStream<Bool>.Continuation
    nonisolated let connectionChanges: AsyncStream<Bool>
    private static let offlineByteLimit = 256 * 1024 * 1024
    private static let offlineEntryLimit = 1024
    init(cookieStorage: HTTPCookieStorage = .shared, cacheRoot: URL? = nil) {
        let events = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        connectionChanges = events.stream
        connectionEvents = events.continuation
        self.cookieStorage = cookieStorage
        let root =
            cacheRoot
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(
                "SporraNative", isDirectory: true)
        self.cacheRoot = root
        let c = URLSessionConfiguration.default
        c.httpCookieStorage = cookieStorage
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 120
        cache = URLCache(
            memoryCapacity: 32 * 1024 * 1024, diskCapacity: 256 * 1024 * 1024,
            diskPath: root.appendingPathComponent("signed-out").path)
        c.urlCache = cache
        session = URLSession(configuration: c)
    }
    static func address(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: trimmed.contains("://") ? trimmed : "https://" + trimmed),
            ["https", "http"].contains(parts.scheme ?? ""), let host = parts.host, !host.isEmpty,
            parts.user == nil, parts.password == nil
        else {
            throw ServerFailure(status: 0, message: "Enter a valid server address.")
        }
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        guard let url = parts.url else {
            throw ServerFailure(status: 0, message: "Enter a valid server address.")
        }
        return url
    }
    func configure(_ url: URL, account: String = "signed-out") {
        generation += 1
        session.invalidateAndCancel()
        base = url
        self.account = account
        offline = false
        let scope = SHA256.hash(data: Data((url.absoluteString + "\n" + account).utf8)).map {
            String(format: "%02x", $0)
        }.joined()
        let directory = cacheRoot.appendingPathComponent(scope, isDirectory: true)
        offlineDirectory = directory.appendingPathComponent("responses", isDirectory: true)
        records = [:]
        if account != "signed-out", let offlineDirectory {
            try? FileManager.default.createDirectory(at: offlineDirectory, withIntermediateDirectories: true)
            var root = cacheRoot
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? root.setResourceValues(values)
            if let data = try? Data(contentsOf: offlineDirectory.appendingPathComponent("index.json")),
                let saved = try? JSONDecoder().decode([String: OfflineRecord].self, from: data)
            {
                records = saved
            }
        }
        cache = URLCache(
            memoryCapacity: 32 * 1024 * 1024, diskCapacity: 256 * 1024 * 1024,
            diskPath: directory.appendingPathComponent("http").path)
        let c = URLSessionConfiguration.default
        c.httpCookieStorage = cookieStorage
        c.urlCache = cache
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 120
        session = URLSession(configuration: c)
    }
    func invalidateHTTPCache() { cache.removeAllCachedResponses() }
    func clearCache() {
        cache.removeAllCachedResponses()
        if let offlineDirectory { try? FileManager.default.removeItem(at: offlineDirectory) }
        records = [:]
    }
    func setOffline(_ value: Bool) {
        guard offline != value else { return }
        offline = value
        connectionEvents.yield(value)
    }
    func isOffline() -> Bool { offline }
    static func isUnavailable(_ error: Error) -> Bool {
        if let failure = error as? ServerFailure { return failure.status >= 500 || failure.status == -1009 }
        guard let failure = error as? URLError else { return false }
        return [
            .notConnectedToInternet, .timedOut, .cannotFindHost, .cannotConnectToHost,
            .networkConnectionLost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff,
        ].contains(failure.code)
    }
    func get(_ path: String, query: [URLQueryItem] = [], fresh: Bool = false) async throws -> JSON {
        try await request(path, query: query, body: nil, fresh: fresh)
    }
    func post(_ path: String, _ body: [String: JSON] = [:]) async throws -> JSON {
        if offline && !["/api/login", "/api/register"].contains(path) {
            throw ServerFailure(status: -1009, message: "Connect to your server to make this change.")
        }
        let value = try await request(path, query: [], body: .object(body), fresh: true)
        if path == "/api/prefs", let prefs = body["prefs"],
            let request = try? makeRequest(path, query: [], body: nil, fresh: false)
        {
            saveResponse(JSON.object(["prefs": prefs]).data, request: request)
        }
        cache.removeAllCachedResponses()
        return value
    }
    private func makeRequest(_ path: String, query: [URLQueryItem], body: JSON?, fresh: Bool) throws
        -> URLRequest
    {
        guard let base, let resolved = URL(string: path, relativeTo: base),
            var parts = URLComponents(url: resolved.absoluteURL, resolvingAgainstBaseURL: true)
        else {
            throw ServerFailure(status: 0, message: "Connect to your server first.")
        }
        // Absolute URLs from data must never receive account cookies.
        guard parts.host == base.host, parts.scheme == base.scheme, parts.port == base.port else {
            throw ServerFailure(status: 0, message: "Invalid server resource.")
        }
        if !query.isEmpty { parts.queryItems = (parts.queryItems ?? []) + query }
        guard let url = parts.url else { throw ServerFailure(status: 0, message: "Invalid server resource.") }
        var r = URLRequest(url: url)
        r.setValue("ios-native", forHTTPHeaderField: "X-Sporra-Client")
        r.cachePolicy = fresh ? .reloadRevalidatingCacheData : .useProtocolCachePolicy
        if let body {
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = body.data
        }
        return r
    }
    private func request(_ path: String, query: [URLQueryItem], body: JSON?, fresh: Bool) async throws -> JSON
    {
        var request = try makeRequest(path, query: query, body: body, fresh: fresh)
        let cacheable = body == nil && canSave(request)
        if offline && !fresh && cacheable {
            guard let saved = savedResponse(request) else { throw missingOfflineData() }
            return try JSONDecoder().decode(JSON.self, from: saved)
        }
        if body == nil { request.timeoutInterval = 5 }
        let epoch = generation
        do {
            let bytes = try await downloadRequest(request)
            let value = bytes.isEmpty ? JSON.object([:]) : try JSONDecoder().decode(JSON.self, from: bytes)
            if cacheable { saveResponse(bytes, request: request) }
            return value
        } catch {
            guard epoch == generation else { throw CancellationError() }
            if Self.isUnavailable(error) {
                setOffline(true)
                if cacheable, let saved = savedResponse(request) {
                    return try JSONDecoder().decode(JSON.self, from: saved)
                }
                if cacheable { throw missingOfflineData() }
            }
            throw error
        }
    }
    private func missingOfflineData() -> ServerFailure {
        ServerFailure(
            status: -1009, message: "This content isn't saved on this device yet. Reconnect to download it.")
    }
    private func canSave(_ request: URLRequest) -> Bool {
        guard account != "signed-out", let path = request.url?.path else { return false }
        return path.hasPrefix("/api/render/") || path.hasPrefix("/api/day/")
            || [
                "/api/prefs", "/api/routes", "/api/days", "/api/trips", "/api/stats", "/api/sources",
                "/api/search",
            ].contains(path)
    }
    private func responseKey(_ request: URLRequest) -> String {
        guard let url = request.url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return ""
        }
        parts.queryItems = parts.queryItems?.sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
        return parts.url?.absoluteString ?? url.absoluteString
    }
    private func saveResponse(_ data: Data, request: URLRequest, publicResource: Bool = false) {
        guard canSave(request) || (publicResource && account != "signed-out"),
            data.count <= Self.offlineByteLimit, let directory = offlineDirectory
        else { return }
        let key = responseKey(request)
        let name = Self.digest(responseKey(request)) + ".json"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            records[key] = OfflineRecord(file: name, bytes: data.count, savedAt: Date())
            var bytes = records.values.reduce(0) { $0 + $1.bytes }
            for (key, record) in records.sorted(by: { $0.value.savedAt < $1.value.savedAt }) {
                if bytes <= Self.offlineByteLimit && records.count <= Self.offlineEntryLimit { break }
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(record.file))
                bytes -= record.bytes
                records.removeValue(forKey: key)
            }
            try JSONEncoder().encode(records).write(
                to: directory.appendingPathComponent("index.json"), options: .atomic)
        } catch { /* A full disk must not turn a successful online read into a failure. */  }
    }
    private func savedResponse(_ request: URLRequest) -> Data? {
        guard let directory = offlineDirectory else { return nil }
        if let record = records[responseKey(request)],
            let bytes = try? Data(contentsOf: directory.appendingPathComponent(record.file)),
            (try? JSONDecoder().decode(JSON.self, from: bytes)) != nil
        {
            return bytes
        }
        // Geometry is reusable across viewports. An unbounded snapshot downloaded
        // while online covers every later viewport at the same appearance/level.
        guard ["/api/render/cells", "/api/render/regions"].contains(request.url?.path ?? ""),
            var parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: true)
        else { return nil }
        parts.queryItems = parts.queryItems?.filter { $0.name != "bbox" }
        guard let url = parts.url else { return nil }
        var unbounded = request
        unbounded.url = url
        guard let record = records[responseKey(unbounded)],
            let bytes = try? Data(contentsOf: directory.appendingPathComponent(record.file))
        else { return nil }
        return bytes
    }
    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func accountFile(_ url: URL) -> URL {
        cacheRoot.appendingPathComponent("account-" + Self.digest(url.absoluteString) + ".json")
    }
    func savedAccount(for url: URL) -> JSON? {
        guard let bytes = try? Data(contentsOf: accountFile(url)),
            let value = try? JSONDecoder().decode(JSON.self, from: bytes),
            value["server"].string == url.absoluteString, !value["user"]["username"].string.isEmpty
        else { return nil }
        return value
    }
    func saveAccount(user: JSON, prefs: JSON, pending: [String: JSON] = [:]) {
        guard let base, account == user["username"].string, account != "signed-out" else { return }
        let value = JSON.object([
            "server": .string(base.absoluteString), "user": user, "prefs": prefs,
            "pending": .object(pending), "savedAt": .number(Date().timeIntervalSince1970),
        ])
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try? value.data.write(to: accountFile(base), options: .atomic)
    }
    func forgetAccount() {
        generation += 1
        session.invalidateAndCancel()
        clearCache()
        if let base, let saved = savedAccount(for: base), saved["user"]["username"].string == account {
            try? FileManager.default.removeItem(at: accountFile(base))
        }
        account = "signed-out"
    }
    func publicResource(_ url: URL) async throws -> Data {
        let sameOrigin =
            base.map { url.scheme == $0.scheme && url.host == $0.host && url.port == $0.port } ?? false
        guard sameOrigin || url.scheme == "https" else {
            throw ServerFailure(status: 0, message: "Invalid public resource URL.")
        }
        let request =
            sameOrigin
            ? try makeRequest(url.absoluteString, query: [], body: nil, fresh: false) : URLRequest(url: url)
        let saved = records[responseKey(request)].flatMap { record in
            offlineDirectory.flatMap { try? Data(contentsOf: $0.appendingPathComponent(record.file)) }
        }
        if let saved, let record = records[responseKey(request)],
            offline || Date().timeIntervalSince(record.savedAt) < 24 * 60 * 60
        {
            return saved
        }
        if offline { throw missingOfflineData() }
        let epoch = generation
        do {
            let data: Data
            if sameOrigin {
                data = try await downloadRequest(request)
            } else {
                let config = URLSessionConfiguration.ephemeral
                config.httpCookieStorage = nil
                config.urlCredentialStorage = nil
                config.timeoutIntervalForRequest = 5
                let publicSession = URLSession(configuration: config)
                defer { publicSession.finishTasksAndInvalidate() }
                let (bytes, response) = try await publicSession.data(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    throw ServerFailure(status: status, message: "Could not load a map reference resource.")
                }
                data = bytes
            }
            guard epoch == generation else { throw CancellationError() }
            saveResponse(data, request: request, publicResource: true)
            return data
        } catch {
            guard epoch == generation else { throw CancellationError() }
            if Self.isUnavailable(error), let saved { return saved }
            throw error
        }
    }
    func download(_ path: String) async throws -> Data {
        try await downloadRequest(makeRequest(path, query: [], body: nil, fresh: true))
    }
    private func downloadRequest(_ request: URLRequest) async throws -> Data {
        let epoch = generation
        let (data, response) = try await session.data(for: request)
        guard generation == epoch else { throw CancellationError() }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let reply = try? JSONDecoder().decode(JSON.self, from: data)
            throw ServerFailure(
                status: status,
                message: reply?["error"].text("Your server answered \(status).")
                    ?? "Unable to read the server response.")
        }
        return data
    }
}

func query(_ values: [String: String]) -> [URLQueryItem] {
    values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
}
