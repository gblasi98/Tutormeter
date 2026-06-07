import Foundation
import CoreLocation

// MARK: - Tutor Zone Manager

/// Manages the Tutor zone database and provides geofencing capabilities.
///
/// Responsibilities:
/// - Load zones from bundled JSON
/// - Check if a GPS coordinate is near a zone entry point
/// - Track which zone the user is currently in
/// - Detect zone exit
@MainActor
final class TutorZoneManager {
    static let shared = TutorZoneManager()

    private var database: TutorZoneDatabase?
    private var isLoading = false

    /// The zone the user is currently traversing, if any.
    private(set) var activeZone: TutorZone?

    /// Whether auto-start on Tutor detection is enabled.
    var isAutoStartEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "Tutormeter.autoStartEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "Tutormeter.autoStartEnabled") }
    }

    private init() {
        // Enable auto-start by default.
        if UserDefaults.standard.object(forKey: "Tutormeter.autoStartEnabled") == nil {
            UserDefaults.standard.set(true, forKey: "Tutormeter.autoStartEnabled")
        }
    }

    // MARK: - Loading

    /// Loads the Tutor zone database from the bundled JSON file.
    func loadDatabase() {
        guard !isLoading, database == nil else { return }
        isLoading = true

        guard let url = Bundle.main.url(forResource: "tutor_zones", withExtension: "json") else {
            print("[TutorZoneManager] tutor_zones.json not found in bundle")
            isLoading = false
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            database = try decoder.decode(TutorZoneDatabase.self, from: data)
            print("[TutorZoneManager] Loaded \(database?.zones.count ?? 0) Tutor zones (v\(database?.version ?? "?"))")
        } catch {
            print("[TutorZoneManager] Failed to load zones: \(error)")
        }

        isLoading = false
    }

    /// All loaded zones, or empty if not yet loaded.
    var zones: [TutorZone] {
        database?.zones ?? []
    }

    // MARK: - Geofencing

    /// Maximum distance (meters) from a zone start to consider it a "hit".
    private static let entryThreshold: CLLocationDistance = 150

    /// Minimum distance (meters) past the end to trigger exit.
    private static let exitThreshold: CLLocationDistance = 200

    /// Checks if the given coordinate is entering a Tutor zone.
    ///
    /// - Parameter coordinate: Current GPS position.
    /// - Returns: The `TutorZone` being entered, or `nil`.
    func checkEntry(at coordinate: CLLocationCoordinate2D) -> TutorZone? {
        guard let db = database, !db.zones.isEmpty else { return nil }

        for zone in db.zones {
            if zone.isNearStart(coordinate, threshold: Self.entryThreshold) {
                print("[TutorZoneManager] Entering zone: \(zone.name)")
                activeZone = zone
                return zone
            }
        }

        return nil
    }

    /// Checks if the user has exited the active zone.
    ///
    /// - Parameter coordinate: Current GPS position.
    /// - Returns: `true` if the zone was exited.
    func checkExit(at coordinate: CLLocationCoordinate2D) -> Bool {
        guard let zone = activeZone else { return false }

        if zone.isPastEnd(coordinate, threshold: Self.exitThreshold) {
            print("[TutorZoneManager] Exited zone: \(zone.name)")
            activeZone = nil
            return true
        }

        return false
    }

    /// Reset the active zone (e.g., when tracking is stopped manually).
    func reset() {
        activeZone = nil
    }

    // MARK: - Idle Zone Monitoring

    /// Low-power location manager for idle zone detection.
    private var monitor: CLLocationManager?
    private var monitorDelegate: ZoneMonitorDelegate?

    /// Whether idle zone monitoring is active (GPS on, low power).
    private(set) var isMonitoring = false

    /// Starts low-power GPS monitoring for Tutor zone detection.
    /// Call when tracking is NOT active.
    func startMonitoring() {
        guard !isMonitoring, database != nil else { return }
        guard CLLocationManager.locationServicesEnabled() else { return }

        let lm = CLLocationManager()
        let delegate = ZoneMonitorDelegate(manager: self)
        self.monitorDelegate = delegate
        lm.delegate = delegate
        lm.desiredAccuracy = kCLLocationAccuracyHundredMeters
        lm.distanceFilter = 500
        lm.allowsBackgroundLocationUpdates = false
        lm.requestAlwaysAuthorization()
        lm.startUpdatingLocation()

        self.monitor = lm
        isMonitoring = true
        print("[TutorZoneManager] Zone monitoring started")
    }

    /// Stops idle zone monitoring.
    func stopMonitoring() {
        guard isMonitoring else { return }
        monitor?.stopUpdatingLocation()
        monitor = nil
        monitorDelegate = nil
        isMonitoring = false
        activeZone = nil
        print("[TutorZoneManager] Zone monitoring stopped")
    }

    /// Called by delegate on each GPS fix during idle monitoring.
    fileprivate func handleLocationUpdate(_ coordinate: CLLocationCoordinate2D) {
        guard isAutoStartEnabled else { return }

        if activeZone == nil {
            if let zone = checkEntry(at: coordinate) {
                activeZone = zone
                if !TrackingManager.shared.isTracking {
                    _ = TrackingManager.shared.startTracking()
                }
            }
        } else {
            if checkExit(at: coordinate) {
                let zoneName = activeZone?.name ?? "?"
                activeZone = nil
                if TrackingManager.shared.isTracking {
                    let summary = TrackingManager.shared.stopTracking()
                    print("[TutorZoneManager] Auto-stop \(zoneName). Avg: \(Int(summary.finalAverageSpeedKmh)) km/h")
                }
            }
        }
    }
}

// MARK: - Zone Monitor Delegate

private final class ZoneMonitorDelegate: NSObject, CLLocationManagerDelegate {
    private weak var manager: TutorZoneManager?

    init(manager: TutorZoneManager) {
        self.manager = manager
    }

    func locationManager(_ lm: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coord = locations.last?.coordinate else { return }
        Task { @MainActor [weak self] in
            self?.manager?.handleLocationUpdate(coord)
        }
    }

    func locationManagerDidChangeAuthorization(_ lm: CLLocationManager) {
        // Handled by main tracking flow.
    }
}
