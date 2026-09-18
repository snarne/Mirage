import Foundation

/// Positional noise. A port of `core/mirage/motion.py`.
///
/// IMPORTANT: the DVT selector is `simulateLocationWithLatitude:longitude:` — latitude
/// and longitude and nothing else. Speed, course, altitude and horizontal accuracy
/// cannot be injected; iOS derives all of those itself from successive fixes. The *only*
/// realism lever is the sequence of coordinates and the timing between them, which is
/// why this file and `Route.swift` carry most of the weight.
///
/// A perfectly static coordinate is the single loudest tell that a location is
/// simulated: real GNSS never stops moving. But real drift is not white noise either —
/// it is strongly autocorrelated, wandering over tens of seconds as satellite geometry
/// and multipath change. An Ornstein-Uhlenbeck process reproduces that: mean-reverting,
/// so it stays near the true position, but temporally smooth rather than jumping every
/// fix.

/// Source of standard-normal draws.
///
/// Deliberately injectable. The Python engine seeds `random.Random`, whose Mersenne
/// Twister this port does **not** reproduce — matching it bit for bit would mean
/// reimplementing MT19937 and Python's exact 53-bit `random()` construction, for no gain
/// beyond making one class of test easier. Instead the golden tests feed both sides the
/// same fixed sequence, so the decay arithmetic is compared rather than the generator.
public protocol NoiseSource: AnyObject {
    func gauss(_ mu: Double, _ sigma: Double) -> Double
}

/// Box-Muller over `SystemRandomNumberGenerator`. Used in production.
public final class SystemNoise: NoiseSource {
    private var spare: Double?

    public init() {}

    public func gauss(_ mu: Double, _ sigma: Double) -> Double {
        if let s = spare {
            spare = nil
            return mu + sigma * s
        }
        var u1 = 0.0
        var u2 = 0.0
        repeat { u1 = Double.random(in: 0..<1) } while u1 <= .leastNormalMagnitude
        u2 = Double.random(in: 0..<1)
        let mag = (-2.0 * log(u1)).squareRoot()
        spare = mag * sin(2 * .pi * u2)
        return mu + sigma * (mag * cos(2 * .pi * u2))
    }
}

/// Replays a fixed list of standard normals, cycling. For tests only.
public final class FixedNoise: NoiseSource {
    private let values: [Double]
    private var index = 0

    public init(_ values: [Double]) {
        precondition(!values.isEmpty, "FixedNoise needs at least one value")
        self.values = values
    }

    public func gauss(_ mu: Double, _ sigma: Double) -> Double {
        let v = values[index % values.count]
        index += 1
        return mu + sigma * v
    }
}

/// `sigma` is the stationary standard deviation in metres; `tau` the correlation time in
/// seconds (how long the wander takes to forget where it was).
public struct JitterProfile: Equatable, Sendable {
    public var sigma: Double
    public var tau: Double

    public init(sigma: Double, tau: Double) {
        self.sigma = sigma
        self.tau = tau
    }

    public var theta: Double { 1.0 / tau }

    // Tuned to what a phone actually reports: worse when stationary indoors (multipath,
    // no Doppler aiding), better at speed with clear sky.
    public static let stationary = JitterProfile(sigma: 4.5, tau: 30.0)
    public static let walking = JitterProfile(sigma: 5.0, tau: 15.0)
    public static let driving = JitterProfile(sigma: 3.0, tau: 10.0)
    public static let parkedIndoors = JitterProfile(sigma: 12.0, tau: 45.0)

    public static func named(_ name: String) -> JitterProfile? {
        switch name {
        case "stationary": return .stationary
        case "walking": return .walking
        case "driving": return .driving
        case "indoors": return .parkedIndoors
        default: return nil
        }
    }
}

/// Mean-reverting 2D random walk: dX = -theta*X*dt + sigma_w*dW.
///
/// Parameterised by the *stationary* standard deviation the caller wants, rather than
/// the raw volatility, because that is the number with a physical meaning here.
public final class OrnsteinUhlenbeck2D {
    public let profile: JitterProfile
    private let noise: any NoiseSource
    private var x = 0.0
    private var y = 0.0

    public init(profile: JitterProfile, noise: any NoiseSource = SystemNoise()) {
        self.profile = profile
        self.noise = noise
    }

    /// Advance by `dt` seconds; returns an (east, north) offset in metres.
    ///
    /// Uses the exact discrete-time solution of the OU SDE rather than an Euler step, so
    /// the statistics stay correct for any `dt` — including the long `dt` of a resumed
    /// session, which on iPhone is the normal case rather than an edge case.
    @discardableResult
    public func step(_ dt: Double) -> (east: Double, north: Double) {
        let decay = exp(-profile.theta * dt)
        // Stationary std of the increment given the decay.
        let noiseStd = profile.sigma * max(0.0, 1.0 - decay * decay).squareRoot()
        x = x * decay + noise.gauss(0.0, noiseStd)
        y = y * decay + noise.gauss(0.0, noiseStd)
        return (x, y)
    }

    public func apply(to point: LatLon, dt: Double) -> LatLon {
        let (east, north) = step(dt)
        let dist = (east * east + north * north).squareRoot()
        if dist < 1e-6 { return point }
        let brg = floorMod(atan2(east, north) * 180 / .pi, 360)
        return destination(point, bearingDegrees: brg, distance: dist)
    }
}
