import Foundation

/// Network work belongs to the activity, rather than the gesture that selected
/// it. Cancelling a tap must not restart a slow detail response on the next tap.
actor ActivityDetailCache {
    private let api: ServerAPI
    private var scope = ""
    private var generation = 0
    private var details: [String: JSON] = [:]
    private var pending: [String: Task<JSON, Error>] = [:]
    private var versions: [String: Int] = [:]

    init(api: ServerAPI) { self.api = api }

    private func prepare(_ scope: String) {
        guard self.scope != scope else { return }
        self.scope = scope
        generation += 1
        details = [:]
        versions = [:]
        pending.values.forEach { $0.cancel() }
        pending = [:]
    }

    func cached(_ id: String, scope: String) async -> JSON? {
        prepare(scope)
        if let data = details[id] { return data }
        let epoch = generation
        guard let data = await api.cachedGet("/api/render/activity", query: query(["id": id])),
            epoch == generation else { return nil }
        retain(data, id: id)
        return data
    }

    func load(_ id: String, scope: String, refresh: Bool = false) async throws -> JSON {
        prepare(scope)
        if refresh {
            pending.removeValue(forKey: id)?.cancel()
            versions[id, default: 0] += 1
        }
        if let work = pending[id] { return try await work.value }
        let epoch = generation, version = versions[id, default: 0]
        let work = Task {
            defer { if epoch == generation && version == versions[id, default: 0] { pending[id] = nil } }
            let clock = ContinuousClock.now
            let data = try await api.get("/api/render/activity", query: query(["id": id]), fresh: true)
            guard epoch == generation, version == versions[id, default: 0] else { throw CancellationError() }
            retain(data, id: id)
            MapPerformance.report("activity-details", since: clock, count: data["samples"].array.count)
            return data
        }
        pending[id] = work
        return try await work.value
    }

    private func retain(_ data: JSON, id: String) {
        if details[id] == nil, details.count >= 8, let oldest = details.keys.first { details[oldest] = nil }
        details[id] = data
    }
}

nonisolated enum ActivityPresentation {
    static func preview(id: JSON, route: JSON) -> JSON {
        var route = route.exists ? route : .object([:])
        route["id"] = id
        var summary: JSON = .object([:])
        if route["lengthM"].double > 0 {
            summary["distance"] = .string(String(format: "%.1f km", route["lengthM"].double / 1000))
        }
        return .object(["route": route, "summary": summary, "loading": .bool(true)])
    }
}
