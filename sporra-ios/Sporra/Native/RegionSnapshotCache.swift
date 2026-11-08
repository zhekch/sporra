import Foundation

/// Coarse area geometry is global. A moving camera must not cancel and restart
/// the same server aggregation, or discard its result before it can be cached.
actor RegionSnapshotCache {
    private let api: ServerAPI
    private var scope = ""
    private var generation = 0
    private var snapshots: [String: JSON] = [:]
    private var validated: Set<String> = []
    private var pending: [String: Task<JSON, Error>] = [:]

    init(api: ServerAPI) { self.api = api }

    private func prepare(_ scope: String) {
        guard self.scope != scope else { return }
        self.scope = scope
        generation += 1
        snapshots = [:]
        validated = []
        pending.values.forEach { $0.cancel() }
        pending = [:]
    }

    private func parameters(_ query: [URLQueryItem]) -> [URLQueryItem] {
        query.filter { !["bbox", "fine", "info"].contains($0.name) }
            + [URLQueryItem(name: "fine", value: "0"), URLQueryItem(name: "info", value: "0")]
    }

    private func key(_ query: [URLQueryItem]) -> String {
        var parts = URLComponents()
        parts.queryItems = parameters(query).sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
        return parts.percentEncodedQuery ?? ""
    }

    func cached(query: [URLQueryItem], scope: String) async -> JSON? {
        prepare(scope)
        let key = key(query)
        if let saved = snapshots[key] { return saved }
        let epoch = generation
        guard let saved = await api.cachedGet("/api/render/regions", query: parameters(query)),
            epoch == generation else { return nil }
        retain(saved, key: key)
        return saved
    }

    func load(query: [URLQueryItem], scope: String) async throws -> JSON {
        prepare(scope)
        let key = key(query)
        if validated.contains(key), let saved = snapshots[key] { return saved }
        if let work = pending[key] { return try await work.value }
        let epoch = generation
        let parameters = parameters(query)
        let work = Task {
            defer { if epoch == generation { pending[key] = nil } }
            let start = ContinuousClock.now
            let data = try await api.get("/api/render/regions", query: parameters)
            guard epoch == generation else { throw CancellationError() }
            retain(data, key: key)
            validated.insert(key)
            MapPerformance.report("regions-snapshot", since: start, count: data["features"].array.count)
            return data
        }
        pending[key] = work
        return try await work.value
    }

    private func retain(_ data: JSON, key: String) {
        if snapshots[key] == nil, snapshots.count >= 9, let oldest = snapshots.keys.first {
            snapshots[oldest] = nil
            validated.remove(oldest)
        }
        snapshots[key] = data
    }
}
