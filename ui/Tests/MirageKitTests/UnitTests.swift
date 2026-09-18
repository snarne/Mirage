import Foundation
import Testing
@testable import MirageKit

@Suite("Speed and distance units")
struct UnitSystemTests {

    @Test("Speeds convert to what the road sign would say")
    func speedConversion() {
        // 13.4 m/s is about 48 km/h, which is about 30 mph - the classic urban limit in
        // both systems, and a good check that the two do not get swapped.
        let mps = 30 * 1609.344 / 3600
        #expect(abs(UnitSystem.imperial.speedValue(metresPerSecond: mps) - 30) < 0.001)
        #expect(abs(UnitSystem.metric.speedValue(metresPerSecond: mps) - 48.28) < 0.01)
    }

    @Test("Distances convert")
    func distanceConversion() {
        #expect(abs(UnitSystem.metric.distanceValue(metres: 5000) - 5) < 1e-9)
        #expect(abs(UnitSystem.imperial.distanceValue(metres: 1609.344) - 1) < 1e-9)
    }

    @Test("Formatted output carries the unit")
    func formatting() {
        let mps = 30 * 1609.344 / 3600
        #expect(UnitSystem.imperial.speed(mps) == "30 mph")
        #expect(UnitSystem.metric.speed(mps) == "48 km/h")
        #expect(UnitSystem.metric.distance(4200) == "4.2 km")
        #expect(UnitSystem.metric.distance(42000) == "42 km")
        #expect(UnitSystem.imperial.distance(1609.344) == "1.0 mi")
    }

    @Test("A short distance keeps a decimal rather than rounding to zero")
    func shortDistances() {
        // "0 km" tells a driver nothing; "0.4 km" does.
        #expect(UnitSystem.metric.distance(400) == "0.4 km")
        #expect(UnitSystem.imperial.distance(400) == "0.2 mi")
    }

    @Test("Non-finite values format rather than crash")
    func degenerateInput() {
        #expect(UnitSystem.metric.speed(.nan) == "0 km/h")
        #expect(UnitSystem.metric.speed(.infinity) == "0 km/h")
    }

    @Test("A deliberate choice survives travelling; no choice follows the device")
    func preference() {
        var preference = UnitPreference()
        #expect(preference.isFollowingDevice)
        #expect(preference.resolved == UnitSystem.deviceDefault)

        // Someone who picks mph keeps mph after landing somewhere metric.
        preference.explicit = .imperial
        #expect(preference.isFollowingDevice == false)
        #expect(preference.resolved == .imperial)
    }

    @Test("The preference round-trips through storage")
    func codable() throws {
        let original = UnitPreference(explicit: .imperial)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(UnitPreference.self, from: data) == original)

        let following = UnitPreference()
        let data2 = try JSONEncoder().encode(following)
        #expect(try JSONDecoder().decode(UnitPreference.self, from: data2).isFollowingDevice)
    }

    @Test("Every system is offerable in a picker")
    func pickerReady() {
        #expect(UnitSystem.allCases.count == 2)
        for system in UnitSystem.allCases {
            #expect(!system.displayName.isEmpty)
            #expect(!system.speedAbbreviation.isEmpty)
        }
    }
}
