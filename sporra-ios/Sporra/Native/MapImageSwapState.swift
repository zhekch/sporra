import Foundation

/// Keep the visible source intact until local replacement pixels have been
/// supplied to the SDK and a frame started after staging them has rendered.
nonisolated struct MapImageSwapState {
    struct Pending {
        let logical: String
        let id: String
        let previous: String?
        var opacity: Double
        let queuedAt = Date()
        var ready = false
    }
    private var generation = 0
    private var active: [String: String] = [:]
    private var pending: [String: Pending] = [:]

    mutating func begin(_ logical: String, opacity: Double) -> (image: Pending, discard: String?) {
        generation += 1
        let image = Pending(
            logical: logical, id: "\(logical)-buffer-\(generation)", previous: active[logical],
            opacity: opacity)
        let discard = pending.updateValue(image, forKey: logical)?.id
        return (image, discard)
    }
    mutating func prepared(_ id: String) {
        guard let logical = pending.first(where: { $0.value.id == id })?.key else { return }
        pending[logical]?.ready = true
    }
    mutating func rendered(after frameStart: Date = .distantFuture) -> [Pending] {
        let ready = pending.values.filter { $0.ready && $0.queuedAt <= frameStart }
        for image in ready {
            pending[image.logical] = nil
            active[image.logical] = image.id
        }
        return ready
    }
    mutating func updateOpacity(_ logical: String, opacity: Double) -> String? {
        pending[logical]?.opacity = opacity
        return active[logical]
    }
    mutating func remove(_ logical: String) -> [String] {
        if let key = pending.first(where: { $0.value.id == logical })?.key { pending[key] = nil }
        if let key = active.first(where: { $0.value == logical })?.key { active[key] = nil }
        return [active.removeValue(forKey: logical), pending.removeValue(forKey: logical)?.id].compactMap {
            $0
        }
    }
}
