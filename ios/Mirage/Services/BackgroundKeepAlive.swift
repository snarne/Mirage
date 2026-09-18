import CoreLocation
import Foundation

/// Keeps Mirage scheduled while a session runs and the phone is locked.
///
/// A drive is not a foreground task — the normal case is starting one and putting the
/// phone away. Without this the app is suspended within seconds and the journey stops
/// mid-street, which on the Mac never happens because the Mac stays awake.
///
/// The mechanism is a genuine background location session: `UIBackgroundModes: location`
/// in the Info.plist plus a location manager with `allowsBackgroundLocationUpdates`. That
/// is a plist key rather than an entitlement, so it costs a free Apple ID nothing, and it
/// is honest — iOS shows the blue indicator the whole time something holds a location
/// session, and this app genuinely is one.
///
/// Note the ordering iOS enforces: `allowsBackgroundLocationUpdates` may only be set once
/// authorization has actually been granted. Setting it earlier throws.
@MainActor
final class BackgroundKeepAlive: NSObject, CLLocationManagerDelegate {

    private let manager = CLLocationManager()
    private var wanted = false

    private(set) var authorization: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        // Nothing here needs fine positions; a coarse filter means far fewer wakeups for
        // the same amount of staying alive.
        manager.distanceFilter = 50
        manager.pausesLocationUpdatesAutomatically = false
        authorization = manager.authorizationStatus
    }

    var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    func begin() {
        wanted = true
        guard isAuthorized else {
            requestAuthorization()
            return
        }
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
    }

    func end() {
        wanted = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            // Someone who granted access mid-drive should get the background session they
            // were asking for, without having to stop and start again.
            if self.wanted, self.isAuthorized { self.begin() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // The fixes are not used. Holding the session is the entire point, and once a
        // location is being simulated these would only report it back.
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Nothing to do: the session stays requested, and a drive never depends on real
        // positions arriving.
    }
}
