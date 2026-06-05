import Foundation
import CoreLocation

// MARK: - Location Tracker

/// Manages GPS location tracking for the Tutormeter speed monitoring system.
///
/// Configures CLLocationManager for high-accuracy automotive navigation:
/// - `kCLLocationAccuracyBestForNavigation` for maximum precision
/// - `.automotiveNavigation` activity type for road-optimized filtering
/// - `distanceFilter = kCLDistanceFilterNone` for 1 Hz continuous updates
/// - `allowsBackgroundLocationUpdates = true` for background tracking
///
/// Delegates processed GPS fixes to the SpeedCalculator via a callback closure.
@MainActor
final class LocationTracker: NSObject {
    // MARK: - Dependencies
    private let locationManager: CLLocationManager
    private var speedCalculator: SpeedCalculator

    // MARK: - Callbacks
    typealias FixCallback = (GPSFix) -> Void
    typealias StatusCallback = (LocationAuthStatus) -> Void
    typealias ErrorCallback = (LocationError) -> Void

    private var onFix: FixCallback?
    private var onStatusChange: StatusCallback?
    private var onError: ErrorCallback?

    // MARK: - State
    private(set) var isTracking = false
    private(set) var authStatus: LocationAuthStatus = .notDetermined
    private(set) var lastLocation: CLLocation?
    private(set) var fixCount: Int = 0
    private var rejectedFixCount: Int = 0

    // MARK: - Configuration
    /// Minimum horizontal accuracy to accept a GPS fix (meters).
    private nonisolated static var minAccuracy: Double { TutormeterConfiguration.shared.gpsMaxAccuracyMeters }

    /// Maximum age of a cached location to accept (seconds).
    private nonisolated static var maxLocationAge: TimeInterval { TutormeterConfiguration.shared.maxLocationAgeSeconds }

    /// Delay between location updates. nil = continuous.
    private nonisolated static let updateInterval: TimeInterval? = nil

    // MARK: - Init

    init(
        locationManager: CLLocationManager = CLLocationManager(),
        speedCalculator: SpeedCalculator = SpeedCalculator()
    ) {
        self.locationManager = locationManager
        self.speedCalculator = speedCalculator
        super.init()
        self.locationManager.delegate = self
        configureLocationManager()
    }

    private func configureLocationManager() {
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.activityType = .automotiveNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.showsBackgroundLocationIndicator = true

        // allowsBackgroundLocationUpdates throws an ObjC exception unless
        // the user has already granted Always authorization.
        if locationManager.authorizationStatus == .authorizedAlways {
            locationManager.allowsBackgroundLocationUpdates = true
        }

        // If available, request live updates for even better accuracy
        if #available(iOS 18.0, *) {
            // iOS 18+ supports live updates natively
        }
    }

    // MARK: - Lifecycle

    /// Starts GPS tracking. Requests authorization if needed.
    /// - Parameters:
    ///   - onFix: Called with each processed GPS fix.
    ///   - onStatusChange: Called when authorization status changes.
    ///   - onError: Called on location errors.
    func startTracking(
        onFix: @escaping FixCallback,
        onStatusChange: @escaping StatusCallback = { _ in },
        onError: @escaping ErrorCallback = { _ in }
    ) {
        guard !isTracking else {
            print("[LocationTracker] Already tracking")
            return
        }

        self.onFix = onFix
        self.onStatusChange = onStatusChange
        self.onError = onError

        isTracking = true
        fixCount = 0
        rejectedFixCount = 0
        speedCalculator.reset()

        let status = mapAuthStatus(locationManager.authorizationStatus)
        authStatus = status

        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            locationManager.startUpdatingLocation()
            print("[LocationTracker] GPS tracking started")

        case .notDetermined:
            print("[LocationTracker] Requesting WhenInUse authorization...")
            locationManager.requestWhenInUseAuthorization()

        case .denied, .restricted:
            let error = LocationError(.denied, description: "Location access denied. Enable in Settings.")
            onError(error)
            stopTracking()
            print("[LocationTracker] Cannot start: authorization \(status)")
        }
    }

    /// Stops GPS tracking and resets state.
    func stopTracking() {
        guard isTracking else { return }
        isTracking = false
        locationManager.stopUpdatingLocation()
        print("[LocationTracker] GPS tracking stopped. Fixes: \(fixCount), Rejected: \(rejectedFixCount)")
    }

    // MARK: - Authorization

    /// Requests Always authorization (needed for background tracking).
    /// Should be called after user has seen the context explanation.
    func requestAlwaysAuthorization() {
        guard locationManager.authorizationStatus == .authorizedWhenInUse else {
            print("[LocationTracker] Cannot upgrade: current status is \(locationManager.authorizationStatus.rawValue)")
            return
        }
        locationManager.requestAlwaysAuthorization()
    }

    /// Returns the current authorization status.
    func checkAuthorization() -> LocationAuthStatus {
        mapAuthStatus(locationManager.authorizationStatus)
    }

    /// Whether location services are enabled system-wide.
    var locationServicesEnabled: Bool {
        CLLocationManager.locationServicesEnabled()
    }

    // MARK: - GPS Quality

    /// Ratio of accepted to total fixes (quality indicator).
    var fixAcceptanceRatio: Double {
        let total = fixCount + rejectedFixCount
        guard total > 0 else { return 1.0 }
        return Double(fixCount) / Double(total)
    }

    /// Whether GPS signal quality is currently poor.
    var isGPSPoor: Bool {
        guard fixCount > 10 else { return false }
        return fixAcceptanceRatio < 0.5
    }

    // MARK: - Speed Calculator Access

    /// Direct access to the speed calculator for UI binding.
    var calculator: SpeedCalculator { speedCalculator }

    /// Feed IMU data into the speed calculator (called from IMUFilter callback).
    func feedIMU(acceleration: Double, deltaTime: TimeInterval) {
        speedCalculator.processIMU(acceleration: acceleration, deltaTime: deltaTime)
    }

    /// Configures the Kalman filter with calibration-derived parameters.
    func configureFilter(processNoisePos: Double, processNoiseVel: Double, measurementNoise: Double) {
        speedCalculator.configureFilter(
            processNoisePos: processNoisePos,
            processNoiseVel: processNoiseVel,
            measurementNoise: measurementNoise
        )
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationTracker: CLLocationManagerDelegate {

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard isTracking else { return }

        for location in locations {
            processLocation(location)
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        Task { @MainActor in
        let nsError = error as NSError
        let locError: LocationError

        switch CLError.Code(rawValue: nsError.code) {
        case .denied:
            locError = LocationError(.denied, description: error.localizedDescription)
            stopTracking()
        case .locationUnknown:
            locError = LocationError(.temporary, description: error.localizedDescription)
        case .network:
            locError = LocationError(.network, description: "Network unavailable for assisted GPS.")
        default:
            locError = LocationError(.unknown, description: error.localizedDescription)
        }

        onError?(locError)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let newStatus = mapAuthStatus(manager.authorizationStatus)

        guard newStatus != authStatus else { return }
        authStatus = newStatus
        onStatusChange?(newStatus)

        // Enable background updates when Always access is granted.
        if manager.authorizationStatus == .authorizedAlways {
            locationManager.allowsBackgroundLocationUpdates = true
        }

        print("[LocationTracker] Authorization changed: \(newStatus)")

        switch newStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            if isTracking {
                locationManager.startUpdatingLocation()
            }
        case .denied, .restricted:
            if isTracking {
                onError?(LocationError(.denied, description: "Location access revoked."))
                stopTracking()
            }
        case .notDetermined:
            break
        }
    }

    // MARK: - Location Processing

    private func processLocation(_ location: CLLocation) {
        // Reject stale cached locations
        let age = abs(location.timestamp.timeIntervalSinceNow)
        guard age < Self.maxLocationAge else {
            rejectedFixCount += 1
            return
        }

        // Reject low-accuracy fixes (handled in SpeedCalculator too, but filter early)
        guard location.horizontalAccuracy > 0,
              location.horizontalAccuracy <= Self.minAccuracy else {
            rejectedFixCount += 1
            return
        }

        // Reject negative or NaN coordinates
        guard location.coordinate.latitude.isFinite,
              location.coordinate.longitude.isFinite else {
            rejectedFixCount += 1
            return
        }

        // Reject impossible altitudes (sensor glitches occasionally return -10⁹).
        guard location.altitude > TutormeterConfiguration.shared.minAltitudeMeters else {
            rejectedFixCount += 1
            return
        }

        lastLocation = location

        // Convert to GPSFix and feed to calculator
        let fix = GPSFix(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            horizontalAccuracy: location.horizontalAccuracy,
            speed: location.speed >= 0 ? location.speed : 0,
            timestamp: location.timestamp,
            altitude: location.altitude
        )

        speedCalculator.processGPSFix(fix)
        fixCount += 1
        onFix?(fix)
    }

    private func mapAuthStatus(_ status: CLAuthorizationStatus) -> LocationAuthStatus {
        switch status {
        case .notDetermined:    return .notDetermined
        case .restricted:       return .restricted
        case .denied:           return .denied
        case .authorizedWhenInUse: return .authorizedWhenInUse
        case .authorizedAlways: return .authorizedAlways
        @unknown default:       return .notDetermined
        }
    }
}

// MARK: - Location Auth Status

/// User-facing authorization status for location services.
enum LocationAuthStatus: String, CustomStringConvertible {
    case notDetermined
    case restricted
    case denied
    case authorizedWhenInUse
    case authorizedAlways

    var description: String {
        switch self {
        case .notDetermined:        return "Not Determined"
        case .restricted:           return "Restricted (Parental Controls)"
        case .denied:               return "Denied"
        case .authorizedWhenInUse:  return "While Using App"
        case .authorizedAlways:     return "Always"
        }
    }

    /// Whether location tracking can start (any authorization level).
    var canTrack: Bool {
        self == .authorizedWhenInUse || self == .authorizedAlways
    }

    /// Whether background tracking is available.
    var canBackgroundTrack: Bool {
        self == .authorizedAlways
    }

    /// Whether the user needs to go to Settings to change this.
    var needsSettingsIntervention: Bool {
        self == .denied || self == .restricted
    }

    /// Whether we can request authorization (not permanently denied).
    var canRequest: Bool {
        self == .notDetermined || self == .authorizedWhenInUse
    }
}

// MARK: - Location Error

/// Structured location error for UI consumption.
struct LocationError: Error, CustomStringConvertible {
    enum Code {
        case denied
        case temporary
        case network
        case unknown
    }

    let code: Code
    let description: String

    init(_ code: Code, description: String) {
        self.code = code
        self.description = description
    }

    var isRecoverable: Bool {
        code == .temporary || code == .network
    }

    var localizedMessage: String {
        switch code {
        case .denied:    return "Location access denied. Enable in Settings > Privacy > Location Services."
        case .temporary: return "Temporarily unable to determine location. Retrying..."
        case .network:   return "Network unavailable. GPS may be less accurate."
        case .unknown:   return "Location error: \(description)"
        }
    }
}
