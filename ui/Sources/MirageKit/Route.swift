import Foundation

/// Trajectory planning: turn a route polyline plus a traffic-aware ETA into a physically
/// plausible sequence of timed positions. A port of `core/mirage/route.py`.
///
/// The naive approach — constant speed = distance / ETA — is what makes simulated drives
/// look fake. It sends you through hairpins and motorways at the same 47 km/h and never
/// stops at a junction.
///
/// Instead this runs the standard three-stage time-parameterisation used by motion
/// planners:
///
///   1. Cap speed at each vertex by the local turn radius (lateral acceleration limit),
///      so the vehicle slows for corners.
///   2. Forward pass bounding longitudinal acceleration, backward pass bounding braking,
///      so speed changes are reachable.
///   3. Insert dwell time at junctions, then scale the whole profile so total elapsed
///      time equals the ETA.
///
/// Step 3 is where traffic enters, and it is why this stays honest without a separate
/// traffic feed: `MKDirections` already returns a *traffic-aware* `expectedTravelTime`.

public struct VehicleLimits: Equatable, Sendable {
    public var vMax: Double = 33.3          // m/s, ~120 km/h
    public var aAccel: Double = 1.8         // m/s^2, comfortable
    public var aBrake: Double = 3.0         // m/s^2
    public var aLateral: Double = 2.5       // m/s^2 cornering comfort
    public var vMinCorner: Double = 2.0

    // Junction dwell modelling
    public var stopTurnThreshold: Double = 55.0   // degrees of heading change implying a junction
    public var stopProbability: Double = 0.45     // fraction of such junctions where we stop
    public var stopDuration: Double = 9.0         // seconds, averaged over lights and give-ways

    /// How far above a posted limit a driver actually travels when traffic allows. Driving
    /// a route at exactly the limit the whole way is its own kind of tell; nobody does it.
    /// Scaled down as congestion rises — you cannot speed in a queue.
    public var speedingAllowance: Double = 8.0 / 3.6   // m/s, about 8 km/h

    public init() {}
}

/// Uniform draws for junction dwell modelling.
///
/// This does **not** reproduce Python's `random.Random`, so a plan built with
/// `includeStops: true` will differ between the two engines. That is deliberate: the
/// junction model is stochastic by design and seeded only for reproducibility within one
/// engine. Everything deterministic — corner speeds, acceleration limits, segment times,
/// ETA scaling, interpolation — is identical, and the golden tests pin it down with
/// `includeStops: false`.
public protocol JunctionRandom: AnyObject {
    func random() -> Double
}

extension JunctionRandom {
    public func uniform(_ a: Double, _ b: Double) -> Double { a + (b - a) * random() }
}

/// SplitMix64. Small, seedable and stable across platforms and OS versions, which
/// `SystemRandomNumberGenerator` is not.
public final class SeededJunctionRandom: JunctionRandom {
    private var state: UInt64

    public init(seed: UInt64 = 0) { self.state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    public func random() -> Double {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z >> 31)
        return Double(z >> 11) * (1.0 / 9_007_199_254_740_992.0)  // 2^-53
    }
}

/// A fully timed trajectory. `state(at:)` is the only thing playback needs.
public struct DrivePlan: Sendable {
    public let polyline: Polyline
    public let speeds: [Double]       // m/s at each vertex
    public let arrive: [Double]       // seconds, arrival time at each vertex
    public let depart: [Double]       // seconds, departure (arrive + any dwell)
    public let limits: VehicleLimits
    public let requestedETA: Double?

    /// `false` when the requested ETA was faster than the route can physically be driven;
    /// `totalTime` is then the achievable time, not the requested one.
    public let etaAchievable: Bool

    public var totalTime: Double { depart[depart.count - 1] }
    public var distance: Double { polyline.length }

    /// Position, heading (degrees) and speed (m/s) at `t` seconds into the drive.
    public func state(at t: Double) -> (point: LatLon, heading: Double, speed: Double) {
        if t <= 0 || t >= totalTime {
            let s = t <= 0 ? 0.0 : polyline.length
            let (p, h) = polyline.point(at: s)
            return (p, h, 0.0)
        }

        // depart is monotonic, so this is the vertex we most recently left.
        let i = bisectRight(depart, t) - 1
        if i < 0 {                                  // still dwelling at the start vertex
            let (p, h) = polyline.point(at: 0.0)
            return (p, h, 0.0)
        }
        if i >= speeds.count - 1 {
            let (p, h) = polyline.point(at: polyline.length)
            return (p, h, 0.0)
        }
        // t in [depart[i], depart[i+1]) splits into travelling, then dwelling at i+1.
        if t >= arrive[i + 1] {
            let (p, h) = polyline.point(at: polyline.cumulative[i + 1])
            return (p, h, 0.0)
        }

        let span = arrive[i + 1] - depart[i]
        let v0 = speeds[i], v1 = speeds[i + 1]
        if span <= 0 {
            let (p, h) = polyline.point(at: polyline.cumulative[i])
            return (p, h, v0)
        }
        let tau = min(t - depart[i], span)
        let accel = (v1 - v0) / span
        let s = polyline.cumulative[i] + v0 * tau + 0.5 * accel * tau * tau
        let (p, h) = polyline.point(at: s)
        return (p, h, max(0.0, v0 + accel * tau))
    }
}

/// The hard speed ceiling at each vertex: the vehicle's, capped by the road's.
///
/// Without `roadLimits` every vertex caps at `vMax`, which on a residential street means the
/// solver will happily do 120 km/h because nothing tells it not to. That is a far louder
/// tell than any amount of traffic modelling fixes.
func ceilings(_ poly: Polyline, _ limits: VehicleLimits, _ roadLimits: [Double]?,
              _ allowance: Double = 0) -> [Double] {
    (0..<poly.count).map { i in
        // The allowance applies only where a limit is actually known. With no limit there
        // is nothing to be over, and vMax already caps things.
        guard let roadLimits, i < roadLimits.count, roadLimits[i] > 0 else { return limits.vMax }
        return min(limits.vMax, roadLimits[i] + allowance)
    }
}

/// v = sqrt(a_lat * R) — the speed at which cornering hits the comfort limit, then capped by
/// whatever the road allows.
func cornerSpeeds(_ poly: Polyline, _ limits: VehicleLimits,
                  _ caps: [Double]? = nil) -> [Double] {
    let ceiling = caps ?? [Double](repeating: limits.vMax, count: poly.count)
    var speeds = poly.curvatureRadii().enumerated().map { i, r -> Double in
        r.isInfinite ? ceiling[i]
                     : min(ceiling[i], max(limits.vMinCorner, (limits.aLateral * r).squareRoot()))
    }
    speeds[0] = 0.0
    speeds[speeds.count - 1] = 0.0
    return speeds
}

/// Seconds spent stationary at each vertex. Sharp heading changes imply a junction; we
/// stop at a fraction of them.
func junctionDwells(_ poly: Polyline, _ limits: VehicleLimits, _ rng: any JunctionRandom) -> [Double] {
    var dwell = [Double](repeating: 0.0, count: poly.count)
    guard poly.count > 2 else { return dwell }
    for i in 1..<(poly.count - 1) {
        let angle = turnAngle(poly.points[i - 1], poly.points[i], poly.points[i + 1])
        if angle >= limits.stopTurnThreshold, rng.random() < limits.stopProbability {
            dwell[i] = limits.stopDuration * rng.uniform(0.5, 1.8)
        }
    }
    return dwell
}

/// Forward pass for acceleration, backward for braking. In place.
func applyAccelLimits(_ speeds: inout [Double], _ seg: [Double], _ limits: VehicleLimits) {
    for i in 0..<seg.count {
        let reachable = (speeds[i] * speeds[i] + 2 * limits.aAccel * seg[i]).squareRoot()
        speeds[i + 1] = min(speeds[i + 1], reachable)
    }
    for i in stride(from: seg.count - 1, through: 0, by: -1) {
        let stoppable = (speeds[i + 1] * speeds[i + 1] + 2 * limits.aBrake * seg[i]).squareRoot()
        speeds[i] = min(speeds[i], stoppable)
    }
}

/// Trapezoidal: dt = 2*ds/(v0+v1), exact for constant acceleration.
func segmentTimes(_ speeds: [Double], _ seg: [Double]) -> [Double] {
    seg.enumerated().map { i, ds in
        let vsum = speeds[i] + speeds[i + 1]
        return vsum > 1e-6 ? (2.0 * ds / vsum) : 0.0
    }
}

/// Build a timed trajectory along `poly`.
///
/// - Parameters:
///   - expectedTravelTime: traffic-aware driving time in seconds, from `MKDirections`.
///     The free-flow profile is scaled so the *driving* portion takes exactly this long.
///   - roadLimits: per-vertex speed ceiling in m/s, from OpenStreetMap's `maxspeed` tags.
///     Anything non-positive means "no limit known here" and falls back to the vehicle
///     ceiling.
///   - waypointStops: vertex index → seconds to wait there. These are the user's own
///     chosen stops on a multi-leg trip, so they are **added on top** of the estimate
///     rather than scaled into it: Apple's number is how long the driving takes, and it
///     cannot know you intend to spend ten minutes at the second pin.
public func buildPlan(
    _ poly: Polyline,
    expectedTravelTime: Double? = nil,
    limits: VehicleLimits = VehicleLimits(),
    rng: (any JunctionRandom)? = nil,
    includeStops: Bool = true,
    waypointStops: [Int: Double] = [:],
    roadLimits: [Double]? = nil
) -> DrivePlan {
    let seg = poly.segmentLengths()
    func solve(_ allowance: Double) -> (caps: [Double], speeds: [Double]) {
        let caps = ceilings(poly, limits, roadLimits, allowance)
        var v = cornerSpeeds(poly, limits, caps)
        applyAccelLimits(&v, seg, limits)
        return (caps, v)
    }

    // First pass assumes traffic allows the full allowance.
    var (ceiling, speeds) = solve(limits.speedingAllowance)

    // Then let the traffic-aware estimate say otherwise. A requested time close to the
    // free-flow time means the road is clear and drivers sit above the limit; one much
    // longer means a queue, where nobody is. Apple gives one number for the whole route, so
    // this is necessarily a route-wide judgement — it is the only traffic signal available
    // without a paid per-segment feed.
    if roadLimits != nil, let eta = expectedTravelTime, eta > 0 {
        let freeFlow = segmentTimes(speeds, seg).reduce(0, +)
        if freeFlow > 0 {
            let congestion = eta / freeFlow
            let factor = max(0, min(1, 2 - congestion))
            if factor < 1 { (ceiling, speeds) = solve(limits.speedingAllowance * factor) }
        }
    }

    var dwell = includeStops
        ? junctionDwells(poly, limits, rng ?? SeededJunctionRandom(seed: 0))
        : [Double](repeating: 0.0, count: poly.count)
    let junctionTotal = dwell.reduce(0, +)

    // The user's own stops, kept separate from the modelled junction dwells because they
    // are accounted for differently against the estimate below.
    var explicit = [Double](repeating: 0.0, count: poly.count)
    for (index, seconds) in waypointStops where index >= 0 && index < poly.count && seconds > 0 {
        explicit[index] += seconds
    }
    let explicitTotal = explicit.reduce(0, +)

    // A stop means zero speed at that vertex; re-run the limits so we actually brake into
    // it and accelerate out rather than teleporting to a halt.
    if dwell.contains(where: { $0 > 0 }) || explicitTotal > 0 {
        for i in 0..<poly.count where dwell[i] > 0 || explicit[i] > 0 {
            speeds[i] = 0.0
        }
        speeds[0] = 0.0
        speeds[speeds.count - 1] = 0.0
        applyAccelLimits(&speeds, seg, limits)
    }

    var times = segmentTimes(speeds, seg)
    let moving = times.reduce(0, +)
    var stopped = junctionTotal

    if let eta = expectedTravelTime, eta > 0, moving > 0 {
        var targetMoving = eta - stopped
        if targetMoving < moving * 0.25 {
            // The estimate is shorter than the modelled junction dwells allow. Drop those
            // and keep the estimate, which is the number the user cares about. Explicit
            // waypoint stops are never dropped: the user asked for them.
            dwell = [Double](repeating: 0.0, count: poly.count)
            stopped = 0.0
            targetMoving = eta
        }
        let scale = moving / targetMoving
        speeds = speeds.map { $0 * scale }
        if scale > 1.0 {
            // The ETA is faster than free flow. Honour physics over the ETA: clamp to the
            // speed ceiling and re-solve the acceleration limits, then report that the
            // requested time was not achievable. Silently emitting 1200 km/h would be a
            // far louder tell than arriving late.
            // Clamp to the road's ceiling, not just the vehicle's: an optimistic estimate
            // must not turn into 120 km/h down a residential street.
            speeds = speeds.enumerated().map { i, v in min(v, ceiling[i]) }
            speeds[0] = 0.0
            speeds[speeds.count - 1] = 0.0
            applyAccelLimits(&speeds, seg, limits)
        }
        times = segmentTimes(speeds, seg)
    }

    // Achievability is judged on the driving portion only; a long deliberate stop does not
    // make an estimate "unachievable".
    let achieved = times.reduce(0, +) + dwell.reduce(0, +)
    let totalDwell = (0..<poly.count).map { dwell[$0] + explicit[$0] }

    var arrive = [0.0]
    var depart = [totalDwell[0]]
    for (i, dt) in times.enumerated() {
        let a = depart[i] + dt
        arrive.append(a)
        depart.append(a + totalDwell[i + 1])
    }

    return DrivePlan(
        polyline: poly,
        speeds: speeds,
        arrive: arrive,
        depart: depart,
        limits: limits,
        requestedETA: expectedTravelTime,
        etaAchievable: expectedTravelTime.map { achieved <= $0 * 1.05 } ?? true
    )
}
