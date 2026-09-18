import Foundation
import Testing
@testable import MirageKit

@Suite("Reading OpenStreetMap speed limits")
struct SpeedLimitParsingTests {

    @Test("Plain values are km/h")
    func kilometresPerHour() {
        #expect(abs(SpeedLimits.parse("50")! - 50 / 3.6) < 1e-9)
        #expect(abs(SpeedLimits.parse(" 30 ")! - 30 / 3.6) < 1e-9)
        #expect(abs(SpeedLimits.parse("100 km/h")! - 100 / 3.6) < 1e-9)
    }

    @Test("mph is converted, not read as km/h")
    func milesPerHour() {
        // 30 mph is 48.3 km/h. Reading it as 30 km/h would be a third too slow, and as
        // 30 mph-as-kph a third too fast.
        let got = SpeedLimits.parse("30 mph")!
        #expect(abs(got - 30 * 1609.344 / 3600) < 1e-6)
        #expect(abs(got * 3.6 - 48.28) < 0.01)
    }

    @Test("Values that state nothing useful return nil rather than a guess")
    func unknowns() {
        // German autobahn: genuinely no limit. Guessing a number here would be worse than
        // deferring to the road class.
        #expect(SpeedLimits.parse("none") == nil)
        #expect(SpeedLimits.parse("signals") == nil)
        #expect(SpeedLimits.parse("variable") == nil)
        #expect(SpeedLimits.parse("DE:urban") == nil)
        #expect(SpeedLimits.parse("") == nil)
        #expect(SpeedLimits.parse("nonsense") == nil)
    }

    @Test("Walking pace and multi-valued tags")
    func specialCases() {
        #expect(abs(SpeedLimits.parse("walk")! - 5 / 3.6) < 1e-9)
        #expect(abs(SpeedLimits.parse("50;30")! - 50 / 3.6) < 1e-9)
    }

    @Test("Road class fills in for the many ways with no maxspeed tag")
    func defaultsByClass() {
        #expect(abs(SpeedLimits.defaultLimit(forHighway: "residential")! - 30 / 3.6) < 1e-9)
        #expect(abs(SpeedLimits.defaultLimit(forHighway: "motorway")! - 110 / 3.6) < 1e-9)
        #expect(abs(SpeedLimits.defaultLimit(forHighway: "living_street")! - 10 / 3.6) < 1e-9)
        #expect(SpeedLimits.defaultLimit(forHighway: "footway") == nil)
    }

    @Test("A tagged limit beats the road class; the class fills the gap")
    func wayResolution() {
        let tagged = OSMWay(geometry: [LatLon(0, 0), LatLon(0, 1)],
                            maxspeed: "20 mph", highway: "motorway")
        #expect(abs(tagged.speedLimit! - 20 * 1609.344 / 3600) < 1e-6)

        let untagged = OSMWay(geometry: [LatLon(0, 0), LatLon(0, 1)],
                              maxspeed: nil, highway: "residential")
        #expect(abs(untagged.speedLimit! - 30 / 3.6) < 1e-9)

        // "none" is not a number, so the road class decides.
        let autobahn = OSMWay(geometry: [LatLon(0, 0), LatLon(0, 1)],
                              maxspeed: "none", highway: "motorway")
        #expect(abs(autobahn.speedLimit! - 110 / 3.6) < 1e-9)

        let useless = OSMWay(geometry: [LatLon(0, 0), LatLon(0, 1)],
                             maxspeed: nil, highway: nil)
        #expect(useless.speedLimit == nil)
    }
}

@Suite("Snapping a route onto roads")
struct SpeedLimitSnapTests {

    /// Two parallel east-west roads about 200 m apart: a 30 km/h residential and a 100 km/h
    /// primary. A route along the southern one must not pick up the northern one's limit.
    private let residential = OSMWay(
        geometry: [LatLon(51.5000, -2.6000), LatLon(51.5000, -2.5900)],
        maxspeed: "30", highway: "residential")
    private let primary = OSMWay(
        geometry: [LatLon(51.5018, -2.6000), LatLon(51.5018, -2.5900)],
        maxspeed: "100", highway: "primary")

    @Test("A vertex takes the limit of the road it is actually on")
    func snapsToNearest() throws {
        let poly = try Polyline([LatLon(51.5000, -2.5980), LatLon(51.5000, -2.5920)])
        let limits = SpeedLimits.limits(for: poly, ways: [residential, primary])
        #expect(limits.count == poly.count)
        for limit in limits {
            #expect(abs(limit - 30 / 3.6) < 1e-9, "snapped to the wrong road")
        }
    }

    @Test("A vertex far from every road reports nothing known")
    func nothingNearby() throws {
        // Zero is the engine's "no limit known here", which falls back to the vehicle
        // ceiling rather than inventing a slow drive across open country.
        let poly = try Polyline([LatLon(52.0000, -2.5980), LatLon(52.0000, -2.5920)])
        let limits = SpeedLimits.limits(for: poly, ways: [residential, primary])
        #expect(limits.allSatisfy { $0 == 0 })
    }

    @Test("Point-to-segment distance measures perpendicular, not to endpoints")
    func segmentDistance() {
        let a = LatLon(51.5000, -2.6000)
        let b = LatLon(51.5000, -2.5900)
        // Directly north of the middle of the segment.
        let p = LatLon(51.5009, -2.5950)
        let d = SpeedLimits.distanceToSegment(p, a, b)
        #expect(abs(d - 100) < 5, "expected about 100 m, got \(d)")

        // Past the end: distance is to the endpoint, not to the infinite line.
        let beyond = LatLon(51.5000, -2.5800)
        #expect(SpeedLimits.distanceToSegment(beyond, a, b) > 600)
    }
}

@Suite("Decoding an Overpass response")
struct OverpassDecodeTests {

    @Test("Ways become usable limits; unusable elements are dropped")
    func decoding() throws {
        let json = """
        {"elements":[
          {"type":"way","geometry":[{"lat":51.5,"lon":-2.6},{"lat":51.5,"lon":-2.59}],
           "tags":{"highway":"residential","maxspeed":"20 mph"}},
          {"type":"way","geometry":[{"lat":51.6,"lon":-2.6},{"lat":51.6,"lon":-2.59}],
           "tags":{"highway":"motorway"}},
          {"type":"way","geometry":[{"lat":51.7,"lon":-2.6}],
           "tags":{"highway":"residential"}},
          {"type":"node","tags":{"highway":"crossing"}}
        ]}
        """
        let ways = try OverpassClient.decode(Data(json.utf8))

        // The single-point way and the node are not usable geometry.
        #expect(ways.count == 2)
        #expect(abs(ways[0].speedLimit! - 20 * 1609.344 / 3600) < 1e-6)
        #expect(abs(ways[1].speedLimit! - 110 / 3.6) < 1e-9, "no tag, so the class decides")
    }
}
