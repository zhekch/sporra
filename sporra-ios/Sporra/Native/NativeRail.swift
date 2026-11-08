import Foundation

/// UIKit requires constant dash arrays and explicit colour branches.
nonisolated enum NativeRail {
    static func layers(_ layer: JSON) -> [JSON] {
        let dash = layer["paint"]["line-dasharray"].array
        if dash.first?.string == "match", dash.count >= 5 {
            var conditions: [JSON] = []
            var result: [JSON] = []
            for i in stride(from: 2, to: dash.count - 1, by: 2) {
                let labels = dash[i].array.isEmpty ? [dash[i]] : dash[i].array
                let condition = JSON.array([
                    .string("in"), dash[1], .array([.string("literal"), .array(labels)]),
                ])
                conditions.append(condition)
                result += colors(
                    with(
                        layer, property: "line-dasharray", value: unwrap(dash[i + 1]), condition: condition,
                        suffix: "dash-\(i)"))
            }
            result += colors(
                with(
                    layer, property: "line-dasharray", value: unwrap(dash.last ?? .null),
                    condition: .array([.string("!"), .array([.string("any")] + conditions)]),
                    suffix: "dash-default"))
            return result
        }
        return colors(layer)
    }
    private static func unwrap(_ v: JSON) -> JSON { v[0].string == "literal" ? v[1] : v }
    private static func with(_ layer: JSON, property: String, value: JSON, condition: JSON, suffix: String)
        -> JSON
    {
        var result = layer
        result["id"] = .string(layer["id"].string + "-" + suffix)
        var paint = result["paint"]
        paint[property] = value
        result["paint"] = paint
        result["filter"] = .array(
            [.string("all")] + (layer["filter"].exists ? [layer["filter"]] : []) + [condition])
        return result
    }
    private static func colors(_ layer: JSON) -> [JSON] {
        for (key, value) in layer["paint"].object.sorted(by: { $0.key < $1.key }) where key.hasSuffix("color")
        {
            let values = value.array
            guard let kind = values.first?.string, ["case", "match"].contains(kind) else { continue }
            var conditions: [JSON] = []
            var result: [JSON] = []
            for i in stride(from: kind == "case" ? 1 : 2, to: values.count - 1, by: 2) {
                let labels = values[i].array.isEmpty ? [values[i]] : values[i].array
                let condition =
                    kind == "case"
                    ? values[i]
                    : .array([.string("in"), values[1], .array([.string("literal"), .array(labels)])])
                let exclusive: JSON = .array(
                    [.string("all")]
                        + (conditions.isEmpty
                            ? [] : [.array([.string("!"), .array([.string("any")] + conditions)])]) + [
                            condition
                        ])
                result += colors(
                    with(
                        layer, property: key, value: values[i + 1], condition: exclusive,
                        suffix: "\(key)-\(i)"))
                conditions.append(condition)
            }
            result += colors(
                with(
                    layer, property: key, value: values.last ?? .null,
                    condition: .array([.string("!"), .array([.string("any")] + conditions)]),
                    suffix: "\(key)-default"))
            return result
        }
        return [layer]
    }
}
