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
    init(cookieStorage: HTTPCookieStorage = .shared, cacheRoot: URL? = nil) {
        self.cookieStorage = cookieStorage
        let root =
            cacheRoot
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(
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
        let scope = SHA256.hash(data: Data((url.absoluteString + "\n" + account).utf8)).map {
            String(format: "%02x", $0)
        }.joined()
        cache = URLCache(
            memoryCapacity: 32 * 1024 * 1024, diskCapacity: 256 * 1024 * 1024,
            diskPath: cacheRoot.appendingPathComponent(scope).path)
        let c = URLSessionConfiguration.default
        c.httpCookieStorage = cookieStorage
        c.urlCache = cache
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 120
        session = URLSession(configuration: c)
    }
    func clearCache() { cache.removeAllCachedResponses() }
    func get(_ path: String, query: [URLQueryItem] = [], fresh: Bool = false) async throws -> JSON {
        try await request(path, query: query, body: nil, fresh: fresh)
    }
    func post(_ path: String, _ body: [String: JSON] = [:]) async throws -> JSON {
        let value = try await request(path, query: [], body: .object(body), fresh: true)
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
        let bytes = try await downloadRequest(makeRequest(path, query: query, body: body, fresh: fresh))
        return bytes.isEmpty ? .object([:]) : try JSONDecoder().decode(JSON.self, from: bytes)
    }
    func publicResource(_ url: URL) async throws -> Data {
        if let base, url.scheme == base.scheme, url.host == base.host, url.port == base.port {
            return try await downloadRequest(
                makeRequest(url.absoluteString, query: [], body: nil, fresh: false))
        }
        guard url.scheme == "https" else {
            throw ServerFailure(status: 0, message: "Invalid public resource URL.")
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 20
        let publicSession = URLSession(configuration: config)
        defer { publicSession.finishTasksAndInvalidate() }
        let (data, response) = try await publicSession.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ServerFailure(status: 0, message: "Could not load a map reference resource.")
        }
        return data
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
