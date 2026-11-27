// Geometry of the signature element: two tapering curved strokes (stylised bull horns) that rise from a
// wide base and meet at one point at the top. Used by the connect control (SwiftUI/HornShape.swift) and,
// through the same numbers, by the app icon generator (Tools/make-app-icon.py writes
// Apps/Branding/horn.svg; HornGeometryTests checks that the SVG matches this file).
//
// Coordinates are in a unit square, x to the right, y downwards, in thousandths (integers), so that the
// Swift shape, the SVG and the Python rasteriser agree exactly.

public struct HornPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    /// Mirror across the vertical centre line.
    public var mirrored: HornPoint { HornPoint(1 - x, y) }
}

/// A cubic Bézier segment from the current point.
public struct HornCubic: Equatable, Sendable {
    public var control1: HornPoint
    public var control2: HornPoint
    public var end: HornPoint

    public var mirrored: HornCubic { HornCubic(control1: control1.mirrored, control2: control2.mirrored, end: end.mirrored) }
}

/// One closed horn outline: base outer corner → (outer curve) → tip → (inner curve) → base inner corner → close.
public struct HornOutline: Equatable, Sendable {
    public var start: HornPoint
    public var outer: HornCubic
    public var inner: HornCubic

    public var mirrored: HornOutline { HornOutline(start: start.mirrored, outer: outer.mirrored, inner: inner.mirrored) }

    /// The outline as a polygon of `2 * steps + 1` points (curves sampled uniformly in the parameter).
    public func polygon(steps: Int) -> [HornPoint] {
        var points = [start]
        points += HornOutline.sample(from: start, outer, steps: steps)
        points += HornOutline.sample(from: outer.end, inner, steps: steps)
        return points
    }

    static func sample(from p0: HornPoint, _ c: HornCubic, steps: Int) -> [HornPoint] {
        (1...steps).map { i in
            let t = Double(i) / Double(steps), u = 1 - t
            let a = u * u * u, b = 3 * u * u * t, d = 3 * u * t * t, e = t * t * t
            return HornPoint(
                a * p0.x + b * c.control1.x + d * c.control2.x + e * c.end.x,
                a * p0.y + b * c.control1.y + d * c.control2.y + e * c.end.y
            )
        }
    }
}

public enum HornGeometry {
    /// The left horn. The right one is its mirror image; both tips are the same point.
    public static let left = HornOutline(
        start: HornPoint(0.270, 0.940),
        outer: HornCubic(control1: HornPoint(0.000, 0.800), control2: HornPoint(0.030, 0.220), end: HornPoint(0.500, 0.050)),
        inner: HornCubic(control1: HornPoint(0.250, 0.210), control2: HornPoint(0.220, 0.700), end: HornPoint(0.450, 0.940))
    )

    public static var right: HornOutline { left.mirrored }

    /// Both outlines, left first.
    public static var outlines: [HornOutline] { [left, right] }

    /// Top of the shape (the tips) and bottom (the bases), for the fill that rises from the base.
    public static let top: Double = 0.050
    public static let bottom: Double = 0.940

    /// Height of the bottom-anchored mask, as a fraction of the square, that shows `fill` (0 … 1) of the horns'
    /// height: 0 shows nothing (the mask ends at the bases), 1 reaches the tips.
    public static func maskFraction(fill: Double) -> Double {
        let clamped = min(1, max(0, fill))
        return (1 - bottom) + clamped * (bottom - top)
    }

    /// SVG path data of both horns in a `0 0 1000 1000` view box, integer coordinates.
    /// Format: `M x y C x y x y x y C x y x y x y Z` per horn, separated by one space.
    public static func svgPathData() -> String {
        func p(_ point: HornPoint) -> String {
            "\(Int((point.x * 1000).rounded())) \(Int((point.y * 1000).rounded()))"
        }
        func c(_ cubic: HornCubic) -> String {
            "C \(p(cubic.control1)) \(p(cubic.control2)) \(p(cubic.end))"
        }
        return outlines.map { "M \(p($0.start)) \(c($0.outer)) \(c($0.inner)) Z" }.joined(separator: " ")
    }
}
