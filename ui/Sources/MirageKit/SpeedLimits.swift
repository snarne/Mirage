import Foundation

/// Per-vertex road speed limits, from OpenStreetMap.
///
/// The realism problem this solves: without it, the only speed constraints are corner
/// radius, acceleration and a single global `vMax` of 120 km/h. A residential street gets
/// driven at 120, which is a louder tell than any amount of traffic modelling fixes.
///
/// OSM is the right source for a project that must stay free: no API key, no billing, and
/// an ODbL licence with none of the "display only on our map" restrictions that make the
/// commercial traffic APIs awkward to build on.
///
/// Everything here is pure. The network lives in `OverpassClient`.

/// A drivable way, as Overpass returns it.
public struct OSMWay: Sendable, Equatable {
    public let geometry: [LatLon]
    /// The raw `maxspeed` tag, if the way carries one. Most do not.
    public let maxspeed: String?
    /// The `highway` tag: motorway, residential, and so on.
    public let highway: String?

    public init(geometry: [LatLon], maxspeed: String?, highway: String?) {
        self.geometry = geometry
        self.maxspeed = maxspeed
        self.highway = highway
    }

    /// Speed ceiling in m/s: the tag when it parses, the road class otherwise, and nil when
    /// neither says anything useful.
    public var speedLimit: Double? {
        if let maxspeed, let parsed = SpeedLimits.parse(maxspeed) { return parsed }
        if let highway, let fallback = SpeedLimits.defaultLimit(forHighway: highway) { return fallback }
        return nil
    }
}

public enum SpeedLimits {

    /// Beyond this, a vertex is not considered to be on the way at all. Routes and OSM
    /// geometry disagree by a few metres routinely; 40 m tolerates that without snapping
    /// to a parallel service road.
    public static let maxSnapDistance: Double = 40

    // MARK: - Parsing

    /// Parse an OSM `maxspeed` value into m/s.
    ///
    /// The tag is free-form and messy in practice. Handled: plain km/h (`50`), mph
    /// (`30 mph`), `walk`. Deliberately *not* guessed at: `none` (German autobahn),
    /// `signals`, `variable`, and country codes like `DE:urban` — those return nil so the
    /// road class decides instead of inventing a number.
    public static func parse(_ raw: String) -> Double? {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if value.isEmpty { return nil }

        // "50;30" — conditional or multi-value. Take the first, which is the general case.
        if let semicolon = value.firstIndex(of: ";") {
            return parse(String(value[value.startIndex..<semicolon]))
        }

        switch value {
        case "walk": return 5.0 / 3.6
        case "none", "signals", "variable", "unposted": return nil
        default: break
        }

        let isMPH = value.contains("mph")
        let isKnots = value.contains("knots")
        let number = value
            .replacingOccurrences(of: "mph", with: "")
            .replacingOccurrences(of: "km/h", with: "")
            .replacingOccurrences(of: "kmh", with: "")
            .replacingOccurrences(of: "knots", with: "")
            .trimmingCharacters(in: .whitespaces)

        guard let magnitude = Double(number), magnitude > 0 else { return nil }
        if isMPH { return magnitude * 1609.344 / 3600 }
        if isKnots { return magnitude * 1852 / 3600 }
        return magnitude / 3.6
    }

    /// Fallback by road class, in m/s, for the many ways with no `maxspeed` tag.
    ///
    /// These are rough and vary by country. That is acceptable: the purpose is to stop a
    /// side street being driven at motorway speed, not to be legally accurate.
    public static func defaultLimit(forHighway highway: String) -> Double? {
        let kph: Double
        switch highway {
        case "motorway": kph = 110
        case "motorway_link": kph = 80
        case "trunk": kph = 90
        case "trunk_link": kph = 60
        case "primary": kph = 80
        case "primary_link": kph = 50
        case "secondary": kph = 60
        case "secondary_link": kph = 50
        case "tertiary": kph = 50
        case "tertiary_link": kph = 40
        case "unclassified", "road": kph = 40
        case "residential": kph = 30
        case "living_street": kph = 10
        case "service": kph = 20
        case "track": kph = 20
        default: return nil
        }
        return kph / 3.6
    }

    // MARK: - Snapping

    /// A speed ceiling for every vertex of `polyline`, in m/s.
    ///
    /// Zero means "nothing known here", which `buildPlan` reads as "use the vehicle
    /// ceiling" — so a route through an area with no OSM coverage degrades to exactly the
    /// behaviour that existed before this file.
    public static func limits(for polyline: Polyline, ways: [OSMWay]) -> [Double] {
        let candidates: [(way: OSMWay, limit: Double, box: BoundingBox)] = ways.compactMap {
            guard $0.geometry.count >= 2, let limit = $0.speedLimit else { return nil }
            return ($0, limit, BoundingBox($0.geometry))
        }

        return polyline.points.map { point in
            var best = Double.greatestFiniteMagnitude
            var bestLimit = 0.0
            for candidate in candidates {
                // Cheap rejection first: the exact test is far more expensive than this.
                guard candidate.box.isWithin(maxSnapDistance, of: point) else { continue }
                let d = distance(from: point, toWay: candidate.way.geometry, betterThan: best)
                if d < best {
                    best = d
                    bestLimit = candidate.limit
                }
            }
            return best <= maxSnapDistance ? bestLimit : 0
        }
    }

    /// Shortest distance in metres from `point` to any segment of `way`, giving up early
    /// once it cannot beat `betterThan`.
    static func distance(from point: LatLon, toWay way: [LatLon], betterThan: Double) -> Double {
        var best = Double.greatestFiniteMagnitude
        guard way.count >= 2 else { return best }
        for i in 0..<(way.count - 1) {
            let d = distanceToSegment(point, way[i], way[i + 1])
            if d < best { best = d }
            if best == 0 { break }
        }
        return best
    }

    /// Point-to-segment distance using a local equirectangular projection.
    ///
    /// Exact great-circle geometry is unnecessary here — over the tens of metres that
    /// matter for snapping, the flat approximation is wrong by far less than the
    /// disagreement between a route polyline and OSM's own geometry.
    static func distanceToSegment(_ p: LatLon, _ a: LatLon, _ b: LatLon) -> Double {
        let latRadians = p.lat * .pi / 180
        let mPerDegLat = 111_132.0
        let mPerDegLon = 111_320.0 * cos(latRadians)

        let px = (p.lon - a.lon) * mPerDegLon
        let py = (p.lat - a.lat) * mPerDegLat
        let bx = (b.lon - a.lon) * mPerDegLon
        let by = (b.lat - a.lat) * mPerDegLat

        let lengthSquared = bx * bx + by * by
        if lengthSquared <= 0 { return (px * px + py * py).squareRoot() }

        // Projection of p onto ab, clamped to the segment.
        let t = max(0, min(1, (px * bx + py * by) / lengthSquared))
        let dx = px - t * bx
        let dy = py - t * by
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// Degree-space bounding box with a metre-ish margin test. Only used to reject candidates
/// cheaply, so approximation is fine.
struct BoundingBox {
    let minLat, maxLat, minLon, maxLon: Double

    init(_ points: [LatLon]) {
        minLat = points.map(\.lat).min() ?? 0
        maxLat = points.map(\.lat).max() ?? 0
        minLon = points.map(\.lon).min() ?? 0
        maxLon = points.map(\.lon).max() ?? 0
    }

    func isWithin(_ metres: Double, of point: LatLon) -> Bool {
        let latMargin = metres / 111_132.0
        let lonMargin = metres / max(1, 111_320.0 * cos(point.lat * .pi / 180))
        return point.lat >= minLat - latMargin && point.lat <= maxLat + latMargin
            && point.lon >= minLon - lonMargin && point.lon <= maxLon + lonMargin
    }
}
