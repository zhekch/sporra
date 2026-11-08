import Foundation

@main
struct MapRenderCheck {
    struct Failure: Error { let message: String }
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
        print("  ok  " + message)
    }
    static func main() throws {
        var state = MapRenderState()
        let first = state.begin("cells")!
        try check(state.begin("cells") == nil, "deduplicates an in-flight viewport")
        state.finish(first, displayed: false)
        let retry = state.begin("cells")
        try check(retry != nil, "failed or cancelled draws can retry the same viewport")
        state.finish(retry!, displayed: true)
        try check(state.begin("cells") == nil, "completed draws are not repeated on routine updates")
        let countries = state.begin("countries")!
        let backToCells = state.begin("cells")
        try check(backToCells != nil, "returning to the previous viewport supersedes pending work")
        state.finish(countries, displayed: true)
        try check(state.isCurrent(backToCells!), "late completion cannot overwrite a newer request")
        state.finish(backToCells!, displayed: true)
        state.invalidate()
        let foreground = state.begin("cells")
        try check(foreground != nil, "foreground entry redraws an unchanged viewport")
        state.invalidate()
        let nextForeground = state.begin("cells")!
        state.finish(foreground!, displayed: true)
        try check(state.isCurrent(nextForeground), "suspended work cannot complete a foreground request")
        state.finish(nextForeground, displayed: false)
        try check(state.begin("cells") != nil, "a failed foreground draw remains retryable")
        try check(MapViewport.contains([170,-10,-170,10], [175,-5,-175,5]), "padded viewport containment handles the date line")
        try check(!MapViewport.contains([170,-10,-170,10], [-20,-5,20,5]), "a distant viewport cannot reuse the displayed sheet")
        var images = MapImageSwapState()
        let firstImage = images.begin("visited-blob", opacity: 0.3).image
        try check(images.rendered().isEmpty, "an unloaded image cannot replace the visible sheet")
        images.prepared(firstImage.id)
        try check(images.rendered(after: .distantPast).isEmpty, "a frame queued before the image cannot retire old shading")
        try check(images.rendered().first?.previous == nil, "local pixels become visible after preparation and rendering without a source event")
        let secondImage = images.begin("visited-blob", opacity: 0.3).image
        try check(secondImage.previous == firstImage.id && images.rendered().isEmpty, "old shading survives while its replacement loads")
        let thirdImage = images.begin("visited-blob", opacity: 0.3)
        try check(thirdImage.discard == secondImage.id && thirdImage.image.previous == firstImage.id, "superseding a pending image preserves the displayed source")
        images.prepared(secondImage.id)
        try check(images.rendered().isEmpty, "a late source event cannot display an obsolete sheet")
        images.prepared(thirdImage.image.id)
        try check(images.rendered().first?.previous == firstImage.id, "ready replacement retires only the previous visible sheet")
        let failedImage = images.begin("visited-blob", opacity: 0.3).image
        _ = images.remove(failedImage.id)
        images.prepared(failedImage.id)
        try check(images.rendered().isEmpty, "a failed replacement cannot remove the visible sheet")
        try check(images.remove("visited-blob") == [thirdImage.image.id], "hiding ground also removes its buffered source")
        let shown = images.begin("visited-blob", opacity: 0.5).image
        images.prepared(shown.id)
        _ = images.rendered()
        try check(images.updateOpacity("visited-blob", opacity: 0.2) == shown.id,
            "an opacity change targets the existing image without repainting")
        try check(images.updateOpacity("visited-blob", opacity: 0.8) == shown.id,
            "subsequent opacity changes still target the visible image")
        let incoming = images.begin("visited-blob", opacity: 0.8).image
        _ = images.updateOpacity("visited-blob", opacity: 0.35)
        images.prepared(incoming.id)
        try check(images.rendered().first?.opacity == 0.35,
            "an uploading image inherits the latest slider value")
        let viewport = CGRect(x: 0, y: 0, width: 393, height: 852)
        let card = CGRect(x: 12, y: 480, width: 369, height: 360)
        let controls = CGRect(x: 327, y: 300, width: 50, height: 156)
        let fitted = MapFocusLayout.insets(bounds: viewport, safeTop: 59, safeBottom: 34, card: card, controls: controls)
        try check(viewport.height - fitted.bottom < card.minY,
            "Focus reserves space above the measured card")
        try check(viewport.width - fitted.right < controls.minX,
            "Focus also avoids the floating map buttons")
        try check(fitted.top > 59 && fitted.left >= 24,
            "Focus keeps route geometry clear of the status bar and screen edges")
        let tallCard = CGRect(x: 12, y: 380, width: 369, height: 460)
        let resized = MapFocusLayout.insets(bounds: viewport, safeTop: 59, safeBottom: 34, card: tallCard, controls: controls)
        try check(resized.bottom > fitted.bottom,
            "Focus responds to a taller card rather than a fixed menu estimate")
        var focus = MapFocusReadiness()
        let loadingLayout = MapFocusSnapshot(bounds: viewport,
            card: MapCardLayout(id: "activity:1", frame: card), controls: controls)
        try check(!focus.ready(loadingLayout, contentReady: false, now: 0),
            "automatic focus waits for activity details instead of fitting the loading card")
        try check(!focus.ready(loadingLayout, contentReady: true, now: 1),
            "loaded content starts a fresh layout-settling interval")
        try check(!focus.ready(loadingLayout, contentReady: true, now: 1.08),
            "the old 80 ms delay cannot fit during the card's entrance animation")
        let loadedLayout = MapFocusSnapshot(bounds: viewport,
            card: MapCardLayout(id: "activity:1", frame: tallCard), controls: controls)
        try check(!focus.ready(loadedLayout, contentReady: true, now: 1.3),
            "the graph changing card height restarts focus settling")
        try check(!focus.ready(loadedLayout, contentReady: true, now: 1.5),
            "focus cannot consume the command before the final card layout settles")
        try check(focus.ready(loadedLayout, contentReady: true, now: 1.8),
            "automatic focus uses the final loaded card layout")
        focus.reset()
        try check(!focus.ready(loadedLayout, contentReady: true, now: 2),
            "a new focus request never inherits an earlier selection's readiness")
        print("Map render lifecycle checks passed")
    }
}
