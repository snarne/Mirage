import Foundation

/// How speeds and distances are shown.
///
/// The engine is metric throughout — metres, metres per second — and nothing here changes
/// that. This is presentation only, at the edge, so no conversion ever touches the
/// trajectory solver.
///
/// The default follows the device's region rather than asking, but stays overridable:
/// people travelling, or using a phone bought elsewhere, routinely want the other one.
public enum UnitSystem: String, Codable, Sendable, CaseIterable, Identifiable {
    case metric
    case imperial

    public var id: String { rawValue }

    /// What this region puts on its road signs.
    ///
    /// The UK is the case that catches people out: it is a metric country that posts speed
    /// limits in mph and distances in miles. `Locale.MeasurementSystem` distinguishes `.uk`
    /// from `.metric` precisely for this, where the older `usesMetricSystem` flag does not.
    public static var deviceDefault: UnitSystem {
        switch Locale.current.measurementSystem {
        case .us, .uk: return .imperial
        default: return .metric
        }
    }

    public var speedAbbreviation: String {
        switch self {
        case .metric: return "km/h"
        case .imperial: return "mph"
        }
    }

    public var distanceAbbreviation: String {
        switch self {
        case .metric: return "km"
        case .imperial: return "mi"
        }
    }

    /// For a settings picker.
    public var displayName: String {
        switch self {
        case .metric: return "Kilometres (km/h)"
        case .imperial: return "Miles (mph)"
        }
    }

    // MARK: - Conversion

    private static let metresPerMile = 1609.344

    /// Metres per second in this system's speed unit.
    public func speedValue(metresPerSecond: Double) -> Double {
        switch self {
        case .metric: return metresPerSecond * 3.6
        case .imperial: return metresPerSecond * 3600 / Self.metresPerMile
        }
    }

    /// Metres in this system's distance unit.
    public func distanceValue(metres: Double) -> Double {
        switch self {
        case .metric: return metres / 1000
        case .imperial: return metres / Self.metresPerMile
        }
    }

    // MARK: - Formatting

    /// A speed with its unit, e.g. `48 km/h` or `30 mph`.
    public func speed(_ metresPerSecond: Double, decimals: Int = 0) -> String {
        let value = speedValue(metresPerSecond: metresPerSecond)
        return "\(format(value, decimals: decimals)) \(speedAbbreviation)"
    }

    /// A distance with its unit. Short distances gain a decimal place, because "0 km" is
    /// not a useful thing to tell someone.
    public func distance(_ metres: Double) -> String {
        let value = distanceValue(metres: metres)
        let decimals = value < 10 ? 1 : 0
        return "\(format(value, decimals: decimals)) \(distanceAbbreviation)"
    }

    private func format(_ value: Double, decimals: Int) -> String {
        let rounded = (value.isFinite ? value : 0)
        return String(format: "%.\(max(0, decimals))f", rounded)
    }
}

/// The user's choice, or the region's default until they make one.
///
/// Stored rather than derived on every read so that a deliberate choice survives the app
/// being used abroad, where the region default would otherwise flip underneath them.
public struct UnitPreference: Codable, Equatable, Sendable {
    /// nil means "follow the device", which is the state before anyone chooses.
    public var explicit: UnitSystem?

    public init(explicit: UnitSystem? = nil) {
        self.explicit = explicit
    }

    public var resolved: UnitSystem { explicit ?? .deviceDefault }

    public var isFollowingDevice: Bool { explicit == nil }
}
