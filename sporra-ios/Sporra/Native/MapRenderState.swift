/// Separates an in-flight request from a successfully displayed viewport.
/// Invalidating on foreground entry also prevents a suspended task from
/// marking the new foreground render as complete.
nonisolated struct MapRenderState {
    struct Request: Equatable {
        let key: String
        fileprivate let generation: Int
    }
    private var generation = 0
    private var pending: Request?
    private var displayedKey: String?

    mutating func begin(_ key: String) -> Request? {
        if let pending {
            guard pending.key != key else { return nil }
        } else {
            guard displayedKey != key else { return nil }
        }
        generation += 1
        let request = Request(key: key, generation: generation)
        pending = request
        return request
    }

    func isCurrent(_ request: Request) -> Bool { pending == request }

    mutating func finish(_ request: Request, displayed: Bool) {
        guard isCurrent(request) else { return }
        pending = nil
        // A partial render may have changed the shading before failing.
        displayedKey = displayed ? request.key : nil
    }

    mutating func invalidate() {
        generation += 1
        pending = nil
        displayedKey = nil
    }
}

nonisolated enum MapViewport {
    static func contains(_ outer: [Double], _ inner: [Double]) -> Bool {
        guard outer.count == 4, inner.count == 4, inner[1] >= outer[1], inner[3] <= outer[3] else { return false }
        let width = outer[2] >= outer[0] ? outer[2] - outer[0] : outer[2] + 360 - outer[0]
        let span = inner[2] >= inner[0] ? inner[2] - inner[0] : inner[2] + 360 - inner[0]
        let delta = inner[0] - outer[0]
        let start = delta - (delta / 360).rounded(.down) * 360
        return width >= 360 || start + span <= width
    }
}
