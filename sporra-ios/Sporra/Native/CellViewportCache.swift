import Foundation

/// A prepared snapshot can answer a new viewport without another HTTP read or
/// decoding and scanning the account's entire history during each pan.
nonisolated struct CellSpatialIndex: Sendable {
    let rowCount: Int
    private static let world = 40075016.68557849
    private struct Bucket: Hashable, Sendable {
        let x: Int
        let y: Int
    }
    private let size: Double
    private let radius: Double
    private let header: JSON
    private var buckets: [Bucket: [JSON]] = [:]

    init(_ data: JSON) {
        rowCount = data["rows"].array.count
        radius = data["radius"].double
        size = max(1, radius * 64)
        var header = data
        header["rows"] = .array([])
        self.header = header
        for row in data["rows"].array {
            let x = row[1].double - floor(row[1].double / Self.world) * Self.world
            let bucket = Bucket(x: Int(floor(x / size)), y: Int(floor(row[2].double / size)))
            buckets[bucket, default: []].append(row)
        }
    }

    func viewport(_ bounds: [Double]) -> JSON {
        // Never form integer bucket ranges from invalid or inverted SDK bounds.
        guard bounds.count == 4, bounds.allSatisfy(\.isFinite), bounds[1] <= bounds[3]
        else { return header }
        let world = Self.world
        let margin = radius * 3
        let west = bounds[0] / 360 * world - margin
        let span =
            (bounds[2] >= bounds[0] ? bounds[2] - bounds[0] : bounds[2] + 360 - bounds[0]) / 360
            * world
        let east = bounds[0] / 360 * world + span + margin
        func y(_ lat: Double) -> Double {
            log(tan(.pi / 4 + min(85.051129, max(-85.051129, lat)) * .pi / 360)) * world / (2 * .pi)
        }
        let south = y(bounds[1]) - margin
        let north = y(bounds[3]) + margin
        let lowY = Int(floor(south / size))
        let highY = Int(floor(north / size))
        let ranges: [ClosedRange<Int>]
        if east - west >= world {
            ranges = [0...Int(floor(world / size))]
        } else {
            let start = west - floor(west / world) * world
            let end = start + east - west
            if end < world {
                ranges = [Int(floor(start / size))...Int(floor(end / size))]
            } else {
                ranges = [
                    Int(floor(start / size))...Int(floor(world / size)),
                    0...Int(floor((end - world) / size)),
                ]
            }
        }
        var rows: [JSON] = []
        func append(_ candidates: [JSON]) {
            for row in candidates {
                let x =
                    row[1].double + (((west + east) / 2 - row[1].double) / world).rounded() * world
                if x >= west, x <= east, row[2].double >= south, row[2].double <= north {
                    rows.append(row)
                }
            }
        }
        let count = ranges.reduce(0) { $0 + $1.count } * (highY - lowY + 1)
        if count > buckets.count * 2 {
            for (key, candidates) in buckets where key.y >= lowY && key.y <= highY {
                append(candidates)
            }
        } else {
            for range in ranges {
                for x in range {
                    for y in lowY...highY {
                        if let candidates = buckets[Bucket(x: x, y: y)] { append(candidates) }
                    }
                }
            }
        }
        // Stable ordering also lets an unchanged revalidation skip repainting.
        rows.sort { $0[0].string < $1[0].string }
        var result = header
        result["rows"] = .array(rows)
        return result
    }
}

actor CellViewportCache {
    private struct Entry: Sendable {
        let scope: String
        let query: String
        let bounds: [Double]?
        let index: CellSpatialIndex
    }
    private let api: ServerAPI
    private var entries: [Entry] = []
    private var pending: [String: Task<Entry?, Never>] = [:]
    private var scope = ""
    private var generation = 0
    init(api: ServerAPI) { self.api = api }

    private func prepare(_ scope: String) {
        guard self.scope != scope else { return }
        self.scope = scope
        generation += 1
        entries = []
        for work in pending.values { work.cancel() }
        pending = [:]
    }
    private func key(_ query: [URLQueryItem]) -> String {
        var parts = URLComponents()
        parts.queryItems = query.filter { $0.name != "bbox" }.sorted {
            ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "")
        }
        return parts.percentEncodedQuery ?? ""
    }
    private func covers(_ outer: [Double]?, _ inner: [Double]) -> Bool {
        guard let outer else { return true }
        guard inner[1] >= outer[1], inner[3] <= outer[3] else { return false }
        let width = outer[2] >= outer[0] ? outer[2] - outer[0] : outer[2] + 360 - outer[0]
        let span = inner[2] >= inner[0] ? inner[2] - inner[0] : inner[2] + 360 - inner[0]
        let start = inner[0] - outer[0] - floor((inner[0] - outer[0]) / 360) * 360
        return width >= 360 || start + span <= width
    }
    private func retain(_ entry: Entry) {
        entries.removeAll { $0.query == entry.query && $0.bounds == entry.bounds }
        entries.append(entry)
        // Keep all six cell detail levels and the two most recent viewport patches.
        // Zooming back must not decode and index the same history again.
        while entries.count > 1 && (entries.count > 8 || entries.reduce(0, { $0 + $1.index.rowCount }) > 750_000) {
            entries.remove(at: entries.firstIndex { $0.bounds != nil } ?? 0)
        }
    }

    func cached(query: [URLQueryItem], scope: String, bounds: [Double]) async -> JSON? {
        prepare(scope)
        let key = key(query)
        if let held = entries.reversed().first(where: {
            $0.query == key && covers($0.bounds, bounds)
        }) {
            return held.index.viewport(bounds)
        }
        let epoch = generation
        let token = key + ":world"
        let work: Task<Entry?, Never>
        if let held = pending[token] {
            work = held
        } else {
            work = Task {
                let start = ContinuousClock.now
                guard
                    let data = await api.cachedGet(
                        "/api/render/cells", query: query.filter { $0.name != "bbox" }),
                    !Task.isCancelled
                else { return nil }
                let index = CellSpatialIndex(data)
                MapPerformance.report("cell-index", since: start, count: data["rows"].array.count)
                return Entry(scope: scope, query: key, bounds: nil, index: index)
            }
            pending[token] = work
        }
        let world = await work.value
        guard generation == epoch, !Task.isCancelled else { return nil }
        pending[token] = nil
        if let world {
            retain(world)
            return world.index.viewport(bounds)
        }
        guard let data = await api.cachedGet("/api/render/cells", query: query),
            generation == epoch, !Task.isCancelled
        else { return nil }
        let entry = Entry(scope: scope, query: key, bounds: bounds, index: CellSpatialIndex(data))
        retain(entry)
        return entry.index.viewport(bounds)
    }

    func load(query: [URLQueryItem], scope: String, bounds: [Double]) async throws -> JSON {
        prepare(scope)
        let epoch = generation
        let data = try await api.get("/api/render/cells", query: query)
        try Task.checkCancellation()
        guard generation == epoch else { throw CancellationError() }
        let entry = Entry(
            scope: scope, query: key(query), bounds: bounds, index: CellSpatialIndex(data))
        retain(entry)
        return entry.index.viewport(bounds)
    }
}
