import Foundation

nonisolated enum MapPerformance {
    static let enabled = ProcessInfo.processInfo.environment["SPORRA_PERFORMANCE_TRACE"] == "1"
    static func report(_ event: String, since start: ContinuousClock.Instant, count: Int = 0) {
        guard enabled else { return }
        let elapsed = start.duration(to: .now).components
        let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        // Timings and sizes only: queries, coordinates, account data and tokens
        // never belong in a performance log.
        let line = String(format: "[sporra-map] %@ %.1f ms count=%d\n", event, milliseconds, count)
        FileHandle.standardError.write(Data(line.utf8))
    }
}
