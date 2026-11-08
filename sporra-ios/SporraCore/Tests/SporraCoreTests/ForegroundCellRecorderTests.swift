import Testing

@testable import SporraCore

@Suite("Foreground cell recording")
struct ForegroundCellRecorderTests {
    @Test("records cell crossings without the background cadence delay")
    func crossings() {
        var recorder = ForegroundCellRecorder()
        let first = recorder.visit(
            lat: 47.37, lng: 8.54, accuracy: 10, timestamp: 1000, now: 1000, maximumAccuracy: 80)
        #expect(first?.id == HexGrid.cellId(level: 0, lat: 47.37, lng: 8.54))
        #expect(
            recorder.visit(
                lat: 47.37, lng: 8.54, accuracy: 10, timestamp: 1001, now: 1001, maximumAccuracy: 80
            ) == nil)
        #expect(
            recorder.visit(
                lat: 47.38, lng: 8.55, accuracy: 10, timestamp: 1002, now: 1002, maximumAccuracy: 80
            ) != nil)
        #expect(
            recorder.visit(
                lat: 47.37, lng: 8.54, accuracy: 10, timestamp: 1003, now: 1003, maximumAccuracy: 80
            ) == first)
    }
    @Test("rejects stale, inaccurate and invalid GPS fixes")
    func rejectedFixes() {
        var recorder = ForegroundCellRecorder()
        #expect(
            recorder.visit(
                lat: 47.37, lng: 8.54, accuracy: 81, timestamp: 1000, now: 1000, maximumAccuracy: 80
            ) == nil)
        #expect(
            recorder.visit(
                lat: 47.37, lng: 8.54, accuracy: -1, timestamp: 1000, now: 1000, maximumAccuracy: 80
            ) == nil)
        #expect(
            recorder.visit(
                lat: 47.37, lng: 8.54, accuracy: 10, timestamp: 960, now: 1000, maximumAccuracy: 80)
                == nil)
        #expect(
            recorder.visit(
                lat: 91, lng: 8.54, accuracy: 10, timestamp: 1000, now: 1000, maximumAccuracy: 80)
                == nil)
        #expect(
            recorder.visit(
                lat: 47.37, lng: 8.54, accuracy: 10, timestamp: 1000, now: 1000, maximumAccuracy: 80
            ) != nil)
        #expect(
            recorder.visit(
                lat: 47.38, lng: 8.55, accuracy: 10, timestamp: 999, now: 1000, maximumAccuracy: 80)
                == nil)
    }
}
