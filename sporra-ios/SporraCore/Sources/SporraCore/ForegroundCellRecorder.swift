import Foundation

/// Record cell crossings from fresh foreground fixes, independently of the
/// slower background cadence. Repeated readings in the same cell do not grow
/// the durable upload queue.
public struct ForegroundCellRecorder: Sendable {
    private var lastCell: Cell?
    private var lastTimestamp = 0
    public init() {}

    public mutating func visit(
        lat: Double, lng: Double, accuracy: Double, timestamp: TimeInterval,
        now: TimeInterval, maximumAccuracy: Double
    ) -> Cell? {
        guard lat.isFinite, lng.isFinite, accuracy.isFinite, timestamp.isFinite,
            abs(lat) <= 90, abs(lng) <= 180, accuracy >= 0,
            maximumAccuracy <= 0 || accuracy <= maximumAccuracy,
            now - timestamp <= 30, timestamp - now <= 5,
            Int(timestamp) > lastTimestamp
        else { return nil }
        let id = HexGrid.cellId(level: 0, lat: lat, lng: lng)
        guard let cell = HexGrid.parse(cellId: id), cell != lastCell else { return nil }
        lastCell = cell
        lastTimestamp = Int(timestamp)
        return cell
    }
}
