import CoreGraphics
import Foundation

nonisolated struct MapCardLayout: Equatable {
    let id: String
    let frame: CGRect
    static let empty = MapCardLayout(id: "none", frame: .null)
}

/// SDK camera fitting uses the real unoccluded map rectangle, rather than an
/// estimated zoom or a fixed card height that breaks with different content.
nonisolated enum MapFocusLayout {
    struct Insets: Equatable {
        let top: CGFloat
        let left: CGFloat
        let bottom: CGFloat
        let right: CGFloat
    }
    static func insets(bounds: CGRect, safeTop: CGFloat, safeBottom: CGFloat, card: CGRect, controls: CGRect) -> Insets {
        let top = min(safeTop + 24, max(24, bounds.height * 0.3))
        let coveredBottom = !card.isNull && card.intersects(bounds) ? bounds.maxY - max(bounds.minY, card.minY) + 20 : safeBottom + 24
        let bottom = min(coveredBottom, max(0, bounds.height - top - 80))
        let coveredRight = !controls.isNull && controls.intersects(bounds) && controls.minX > bounds.midX
            ? bounds.maxX - controls.minX + 16 : 24
        let right = min(coveredRight, max(24, bounds.width - 104))
        return Insets(top: top, left: 24, bottom: bottom, right: right)
    }
}

nonisolated struct MapFocusSnapshot: Equatable {
    let bounds: CGRect
    let card: MapCardLayout
    let controls: CGRect
}

/// Card insertion animates for 320 ms, and loading a graph can resize it again.
/// Only fit after the loaded content and its occluding frames have settled.
nonisolated struct MapFocusReadiness {
    private var snapshot: MapFocusSnapshot?
    private var stableSince = 0.0
    mutating func reset() { snapshot = nil }

    mutating func ready(_ layout: MapFocusSnapshot, contentReady: Bool, now: TimeInterval) -> Bool {
        guard contentReady else { reset(); return false }
        guard snapshot == layout else {
            snapshot = layout
            stableSince = now
            return false
        }
        return now - stableSince >= 0.4
    }
}
