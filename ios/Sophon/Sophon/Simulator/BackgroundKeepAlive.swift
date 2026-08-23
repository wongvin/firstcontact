import CoreLocation
import Foundation
import os

/// Keeps the process scheduled while the app is backgrounded or the screen is
/// locked, so the simulator keeps sampling and notifying.
///
/// **Why this exists at all.** `UIBackgroundModes: bluetooth-peripheral` keeps a
/// peripheral *wakeable* — iOS resumes the app to service BLE events aimed at it.
/// That is enough for a peripheral which answers reads and writes. It is not
/// enough for this one, which is *push-driven*: nothing external asks it for a
/// frame, it produces frames from CoreMotion at 52 Hz. Once suspended, no event
/// arrives to wake it, so nothing is pushed, so nothing wakes it. The stream
/// simply stops. (The viewer's 2 s stats poll does wake us intermittently, which
/// buys a stutter, not a stream.)
///
/// A location session is the mechanism used to hold the process running. The
/// location itself is never read, stored or transmitted — only the existence of
/// an active session matters. Chosen over the silent-audio alternative, which
/// needs no permission but seizes the audio session and is more readily reclaimed.
///
/// Costs a When-In-Use prompt and the blue status indicator while simulating. The
/// indicator is arguably a feature: it is a standing reminder that the phone is
/// pretending to be a sensor.
@MainActor
final class BackgroundKeepAlive: NSObject {
    private let manager = CLLocationManager()
    private let log = Logger(subsystem: "com.vwong.Sophon", category: "keepalive")

    private(set) var isRunning = false

    var authorization: CLAuthorizationStatus { manager.authorizationStatus }

    /// True once the OS has granted enough for the session to actually hold us
    /// up. Denied authorization is not fatal — the simulator still works with the
    /// screen on — so the UI reports it rather than the code refusing to start.
    var isAuthorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: true
        default: false
        }
    }

    override init() {
        super.init()
        manager.delegate = self
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        if manager.authorizationStatus == .notDetermined {
            // When-In-Use is sufficient: combined with allowsBackgroundLocationUpdates
            // it survives backgrounding, and it is a far lighter ask than Always.
            manager.requestWhenInUseAuthorization()
        }

        // The cheapest configuration that still counts as an active session. We
        // want the session, not the fixes.
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = 1000
        manager.activityType = .other

        // THE line that decides whether any of this works.
        //
        // Left at its default, iOS pauses location updates once it decides the
        // device has been stationary for a while — and a phone simulating a
        // sensor on a desk is the most stationary object in the building. The
        // keep-alive would expire precisely when it is needed, minutes in, and
        // the symptom would look like CoreMotion mysteriously stopping.
        manager.pausesLocationUpdatesAutomatically = false

        // Throws unless `location` is present in UIBackgroundModes, so the
        // Info.plist entry and this line are a single change, not two.
        manager.allowsBackgroundLocationUpdates = true

        manager.startUpdatingLocation()
        log.info("keep-alive started")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        manager.stopUpdatingLocation()
        // Cleared so the app holds no background-location privilege while in
        // viewer mode, where it has no business running one.
        manager.allowsBackgroundLocationUpdates = false
        log.info("keep-alive stopped")
    }
}

extension BackgroundKeepAlive: CLLocationManagerDelegate {
    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        // Deliberately empty. The fixes are not wanted and are not looked at;
        // only the running session is.
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            // Not fatal. A failing location session weakens the keep-alive but
            // does not stop the simulator, which still runs with the screen on.
            log.error("keep-alive: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            log.info("keep-alive authorization now \(manager.authorizationStatus.rawValue)")
        }
    }
}
