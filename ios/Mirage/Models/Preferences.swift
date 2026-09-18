import Foundation
import MirageKit

/// Everything the person has chosen. Small enough to live in `UserDefaults`, which is
/// inside the app container like the rest of it.
///
/// Nothing here is a credential — those are `SetupStore`'s, with their own protection.
@MainActor
@Observable
final class Preferences {

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.unitPreference = Preferences.readUnits(defaults)
        self.sessionCapMinutes = defaults.object(forKey: Keys.sessionCap) as? Int ?? 60
        self.vpnAddress = defaults.string(forKey: Keys.vpnAddress) ?? Preferences.defaultVPNAddress
        self.acknowledged = defaults.bool(forKey: Keys.acknowledged)
    }

    private enum Keys {
        static let units = "units"
        static let sessionCap = "sessionCapMinutes"
        static let vpnAddress = "vpnAddress"
        static let acknowledged = "acknowledged"
    }

    /// LocalDevVPN and the other loopback VPNs all hand out this peer address. Kept
    /// editable because it is the single most likely thing to differ between setups, and
    /// a wrong value here looks identical to a broken pairing file.
    static let defaultVPNAddress = "10.7.0.1"

    // MARK: - Units

    /// nil inside means "follow the region", which is the state before anyone chooses.
    ///
    /// Written through a method rather than a `didSet`: `@Observable` turns stored
    /// properties into computed ones, and a property observer has nowhere to go.
    private(set) var unitPreference: UnitPreference

    func setUnits(_ explicit: UnitSystem?) {
        unitPreference = UnitPreference(explicit: explicit)
        if let explicit {
            defaults.set(explicit.rawValue, forKey: Keys.units)
        } else {
            defaults.removeObject(forKey: Keys.units)
        }
    }

    var units: UnitSystem { unitPreference.resolved }

    private static func readUnits(_ defaults: UserDefaults) -> UnitPreference {
        guard let raw = defaults.string(forKey: Keys.units),
              let system = UnitSystem(rawValue: raw)
        else { return UnitPreference() }
        return UnitPreference(explicit: system)
    }

    // MARK: - Session

    /// How long a session runs before Mirage stops advancing it and says so. It never
    /// restores on its own: undoing a location someone chose is their decision, and they
    /// may not be holding the phone when the timer runs out.
    private(set) var sessionCapMinutes: Int

    func setSessionCap(minutes: Int) {
        sessionCapMinutes = minutes
        defaults.set(minutes, forKey: Keys.sessionCap)
    }

    var sessionCap: TimeInterval? {
        sessionCapMinutes > 0 ? TimeInterval(sessionCapMinutes) * 60 : nil
    }

    private(set) var vpnAddress: String

    func setVPNAddress(_ address: String) {
        vpnAddress = address
        defaults.set(address, forKey: Keys.vpnAddress)
    }

    /// The one-time acknowledgement. Not a licence agreement — a short, plain statement of
    /// what this does to the phone and who can tell.
    private(set) var acknowledged: Bool

    func setAcknowledged(_ value: Bool) {
        acknowledged = value
        defaults.set(value, forKey: Keys.acknowledged)
    }

    func forgetEverything() {
        for key in [Keys.units, Keys.sessionCap, Keys.vpnAddress, Keys.acknowledged] {
            defaults.removeObject(forKey: key)
        }
        unitPreference = UnitPreference()
        sessionCapMinutes = 60
        vpnAddress = Preferences.defaultVPNAddress
        acknowledged = false
        // The defaults are already gone; these assignments only bring the observable copy
        // back into line so the screens redraw.
    }
}
