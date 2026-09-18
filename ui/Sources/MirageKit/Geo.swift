import Foundation

/// Spherical geometry and arc-length indexed polylines.
///
/// A direct port of `core/mirage/geo.py`. The Python engine still drives the Mac app;
/// this exists so the iPhone app runs the same maths rather than a second approximation
/// of it. `Tests/MirageKitTests/GoldenTests.swift` asserts both against values generated
/// by the Python, so the two cannot drift silently.
///
/// All distances are metres, all bearings degrees clockwise from true north.

public let earthRadiusMetres = 6_371_008.8  // IUGG mean radius

public struct LatLon: Equatable, Sendable {
    public var lat: Double
    public var lon: Double

    public init(_ lat: Double, _ lon: Double) {
        self.lat = lat
        self.lon = lon
    }
}

/// Python's `%` on floats always returns a value with the divisor's sign; Swift's
/// `truncatingRemainder` keeps the dividend's. Every angle wrap in this file goes
/// through here, because getting it wrong shows up as a heading that is 360 degrees
/// out only for southbound travel.
func floorMod(_ value: Double, _ modulus: Double) -> Double {
    let r = value.truncatingRemainder(dividingBy: modulus)
    return r < 0 ? r + modulus : r
}

/// Great-circle distance in metres.
public func haversine(_ a: LatLon, _ b: LatLon) -> Double {
    let p1 = a.lat * .pi / 180
    let p2 = b.lat * .pi / 180
    let dp = p2 - p1
    let dl = (b.lon - a.lon) * .pi / 180
    let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
    return 2 * earthRadiusMetres * asin(min(1.0, h.squareRoot()))
}

/// Initial bearing from `a` to `b`, in [0, 360).
public func bearing(_ a: LatLon, _ b: LatLon) -> Double {
    let p1 = a.lat * .pi / 180
    let p2 = b.lat * .pi / 180
    let dl = (b.lon - a.lon) * .pi / 180
    let y = sin(dl) * cos(p2)
    let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
    return floorMod(atan2(y, x) * 180 / .pi, 360)
}

/// Point reached travelling `distance` metres from `origin` on `bearingDegrees`.
public func destination(_ origin: LatLon, bearingDegrees: Double, distance: Double) -> LatLon {
    let d = distance / earthRadiusMetres
    let br = bearingDegrees * .pi / 180
    let p1 = origin.lat * .pi / 180
    let l1 = origin.lon * .pi / 180
    let p2 = asin(sin(p1) * cos(d) + cos(p1) * sin(d) * cos(br))
    let l2 = l1 + atan2(sin(br) * sin(d) * cos(p1), cos(d) - sin(p1) * sin(p2))
    return LatLon(p2 * 180 / .pi, floorMod(l2 * 180 / .pi + 540, 360) - 180)
}

/// Radius of the circle through three points — the local turn radius at `p1`.
///
/// Returns `.infinity` for collinear points. Uses Kahan's numerically stable triangle
/// area formula; naive Heron loses all precision on the sliver triangles that dense
/// road polylines are made of.
public func circumradius(_ p0: LatLon, _ p1: LatLon, _ p2: LatLon) -> Double {
    let a = haversine(p1, p2)
    let b = haversine(p0, p2)
    let c = haversine(p0, p1)
    let sorted = [a, b, c].sorted(by: >)   // x >= y >= z
    let x = sorted[0], y = sorted[1], z = sorted[2]
    let t = (x + (y + z)) * (z - (x - y)) * (z + (x - y)) * (x + (y - z))
    if t <= 0 { return .infinity }
    let area = 0.25 * t.squareRoot()
    if area < 1e-9 { return .infinity }
    return (a * b * c) / (4.0 * area)
}

/// Absolute heading change at `p1`, in degrees [0, 180].
public func turnAngle(_ p0: LatLon, _ p1: LatLon, _ p2: LatLon) -> Double {
    let delta = floorMod(bearing(p1, p2) - bearing(p0, p1) + 180.0, 360.0) - 180.0
    return abs(delta)
}

/// Index of the first element strictly greater than `x` — Python's `bisect_right`.
func bisectRight(_ values: [Double], _ x: Double) -> Int {
    var lo = 0
    var hi = values.count
    while lo < hi {
        let mid = (lo + hi) / 2
        if x < values[mid] { hi = mid } else { lo = mid + 1 }
    }
    return lo
}

/// A path with cumulative arc-length indexing, so any distance along it maps to a
/// coordinate in O(log n).
public struct Polyline: Sendable {
    public let points: [LatLon]
    public let cumulative: [Double]

    public enum Failure: Error, Equatable {
        case tooFewPoints
        case collapsedToSinglePoint
    }

    public init(_ input: [LatLon]) throws {
        guard input.count >= 2 else { throw Failure.tooFewPoints }

        // Drop consecutive duplicates; zero-length segments break the speed solver.
        var cleaned = [input[0]]
        for p in input.dropFirst() where haversine(cleaned[cleaned.count - 1], p) > 1e-3 {
            cleaned.append(p)
        }
        guard cleaned.count >= 2 else { throw Failure.collapsedToSinglePoint }

        var cum = [0.0]
        cum.reserveCapacity(cleaned.count)
        for i in 1..<cleaned.count {
            cum.append(cum[i - 1] + haversine(cleaned[i - 1], cleaned[i]))
        }

        self.points = cleaned
        self.cumulative = cum
    }

    public var count: Int { points.count }

    public var length: Double { cumulative[cumulative.count - 1] }

    public func segmentLengths() -> [Double] {
        guard points.count > 1 else { return [] }
        return (1..<cumulative.count).map { cumulative[$0] - cumulative[$0 - 1] }
    }

    /// Coordinate and heading at arc length `s` metres from the start.
    public func point(at s: Double) -> (point: LatLon, heading: Double) {
        let clamped = max(0.0, min(s, length))
        let i = max(0, min(bisectRight(cumulative, clamped) - 1, points.count - 2))
        let segLen = cumulative[i + 1] - cumulative[i]
        let a = points[i], b = points[i + 1]
        let hdg = bearing(a, b)
        if segLen <= 0 { return (a, hdg) }
        return (destination(a, bearingDegrees: hdg, distance: clamped - cumulative[i]), hdg)
    }

    /// Turn radius at each vertex; endpoints are unconstrained.
    public func curvatureRadii() -> [Double] {
        var radii = [Double](repeating: .infinity, count: points.count)
        guard points.count > 2 else { return radii }
        for i in 1..<(points.count - 1) {
            radii[i] = circumradius(points[i - 1], points[i], points[i + 1])
        }
        return radii
    }
}
