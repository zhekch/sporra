/// Routes stay above basemap geometry and visit shading, including when either
/// is recreated asynchronously. Keep the final basemap label stack legible.
nonisolated enum NativeLayerOrder {
    static let shading: Set<String> = ["visited-blob", "visited-regions", "foreground-cells"]
    static func isShading(_ id: String) -> Bool { shading.contains(id) || id.hasPrefix("visited-blob-buffer-") }
    static func labelsAboveGeometry(orderedIDs: [String], symbolIDs: Set<String>) -> Set<String> {
        // Some styles interleave early labels with roads, tunnels and bridges.
        // Inserting below the first symbol would put routes beneath those roads.
        Set(orderedIDs.reversed().prefix { symbolIDs.contains($0) })
    }
    private static func rank(_ id: String) -> Int? {
        if isShading(id) { return 0 }
        if id == "activities" { return 10 }
        if id == "activity-metric-outline" { return 19 }
        if ["activity-metric", "track", "track-points"].contains(id) { return 20 }
        if ["place-outline-halo", "place-outline"].contains(id) { return 30 }
        if ["search-pin", "sample", "photos", "photos-cluster"].contains(id) { return 40 }
        if id == "photos-count" { return 41 }
        return nil
    }
    static func anchor(for id: String, orderedIDs: [String], basemapLabels: Set<String> = []) -> String? {
        orderedIDs.first { other in
            if basemapLabels.contains(other) { return true }
            guard let incoming = rank(id), let existing = rank(other) else { return false }
            return incoming < existing
        }
    }
    static func mapboxSlot(for id: String) -> String {
        (rank(id) ?? 0) >= 10 ? "top" : "middle"
    }

    static func mapboxLayer(_ definition: JSON) -> JSON {
        var result = definition
        let id = definition["id"].string
        // Keep shading/reference layers in the middle. Routes and their
        // selection markers share the upper slot, preserving their own order.
        result["slot"] = .string(mapboxSlot(for: id))
        if isShading(id) {
            let property = definition["type"].string == "raster" ? "raster-emissive-strength" : "fill-emissive-strength"
            result["paint"][property] = .number(1)
        }
        if ["activities", "activity-metric-outline", "activity-metric", "track"].contains(id) {
            result["paint"]["line-emissive-strength"] = .number(1)
            // Avoid terrain draping that can reorder lines below roads.
            result["layout"]["line-elevation-reference"] = .string("ground")
            result["layout"]["line-z-offset"] = .number(1)
        }
        if ["track-points", "sample", "photos", "photos-cluster"].contains(id) {
            result["paint"]["circle-emissive-strength"] = .number(1)
        }
        if id == "photos-count" { result["paint"]["text-emissive-strength"] = .number(1) }
        if ["place-outline", "place-outline-halo"].contains(id) {
            // Elevated lines leave the draped raster batch and stay above it.
            result["layout"]["line-elevation-reference"] = .string("ground")
            result["layout"]["line-z-offset"] = .number(1)
            result["paint"]["line-emissive-strength"] = .number(1)
        }
        return result
    }
}
