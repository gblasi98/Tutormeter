import Foundation

// MARK: - Speed Calculator

/// Core engine for computing average speed in Tutor zones.
///
/// Uses a Kalman Filter to fuse GPS position measurements with IMU acceleration
/// data, producing a smooth, accurate velocity estimate even during
/// short GPS outages (tunnels, urban canyons).
///
/// Architecture:
/// ```
/// GPS Fix → Haversine distance → KF.update(position) ──┐
/// IMU Accel → Low-pass filter → KF.predict(accel, dt) ─┤
///                                                        ├→ avg speed
///                                                        └→ confidence
/// ```
struct SpeedCalculator {
    // MARK: - Core State
    private var kf: KalmanFilter1D
    private(set) var totalDistanceMeters: Double = 0.0
    private(set) var totalKFDistanceMeters: Double = 0.0
    private(set) var startTime: Date?
    private(set) var lastFix: GPSFix?
    private var fixCount: Int = 0
    private var imuSampleCount: Int = 0

    /// Previous GPS cumulative position (for detecting KF vs GPS divergence).
    private var previousGPSPosition: Double = 0.0
    /// Previous KF position (for tracking KF distance).
    private var previousKFPosition: Double = 0.0

    /// Source of "now" for time-dependent calculations. Injected so tests
    /// can deterministically control the clock.
    private let dateProvider: any DateProvider

    // MARK: - Configuration
    static let maxAccuracy: Double = 20.0
    static let gpsTimeout: TimeInterval = 5.0
    private static let earthRadiusMeters: Double = 6_371_000.0

    // MARK: - Init

    init(
        initialPosition: Double = 0.0,
        initialVelocity: Double = 0.0,
        dateProvider: any DateProvider = SystemDateProvider()
    ) {
        self.kf = KalmanFilter1D(
            initialPosition: initialPosition,
            initialVelocity: initialVelocity
        )
        self.dateProvider = dateProvider
    }

    /// Reconfigures the Kalman filter with calibration-derived noise parameters.
    mutating func configureFilter(
        processNoisePos: Double = 0.1,
        processNoiseVel: Double = 0.5,
        measurementNoise: Double = 25.0
    ) {
        kf = KalmanFilter1D(
            initialPosition: kf.position,
            initialVelocity: kf.velocity,
            positionUncertainty: kf.positionUncertainty,
            velocityUncertainty: kf.velocityUncertainty,
            processNoisePos: processNoisePos,
            processNoiseVel: processNoiseVel,
            measurementNoise: measurementNoise
        )
    }

    // MARK: - GPS Integration

    /// Feeds a new GPS fix into the calculator.
    /// The fix position is converted to a cumulative distance along the road
    /// and used to update the Kalman filter.
    ///
    /// - Returns: The updated average speed in km/h, or nil if the fix was rejected.
    @discardableResult
    mutating func processGPSFix(_ fix: GPSFix) -> Double? {
        // Validate coordinates
        guard fix.latitude.isFinite, fix.longitude.isFinite,
              fix.latitude >= -90, fix.latitude <= 90,
              fix.longitude >= -180, fix.longitude <= 180 else {
            return currentAverageSpeedKmh()
        }

        // Reject low-accuracy fixes
        guard fix.horizontalAccuracy <= Self.maxAccuracy else {
            return currentAverageSpeedKmh()
        }

        // Initialize on first valid fix
        if startTime == nil {
            startTime = fix.timestamp
            lastFix = fix
            fixCount = 1
            previousGPSPosition = 0.0
            previousKFPosition = 0.0
            return 0.0
        }

        // Calculate incremental distance from last fix
        if let previous = lastFix {
            let distance = Self.haversineDistance(
                lat1: previous.latitude,
                lon1: previous.longitude,
                lat2: fix.latitude,
                lon2: fix.longitude
            )

            let timeDelta = fix.timestamp.timeIntervalSince(previous.timestamp)

            // Outlier rejection: skip unrealistic jumps.
            let cfg = TutormeterConfiguration.shared
            if timeDelta > 0 && (distance / timeDelta) < cfg.maxSpeedJumpMetersPerSecond {
                totalDistanceMeters += distance
                fixCount += 1

                // Update cumulative GPS position
                let gpsPosition = previousGPSPosition + distance

                // Kalman filter update with GPS position measurement
                let gain = kf.update(measurement: gpsPosition)

                // Track KF distance separately (for comparison)
                let kfDistanceDelta = kf.position - previousKFPosition
                if kfDistanceDelta > 0 && kfDistanceDelta < cfg.maxKalmanDistanceDeltaMeters {
                    totalKFDistanceMeters += kfDistanceDelta
                }

                previousGPSPosition = gpsPosition
                previousKFPosition = kf.position
            }
        }

        lastFix = fix
        return currentAverageSpeedKmh()
    }

    // MARK: - IMU Integration (Kalman Filter Predict)

    /// Feeds IMU acceleration data into the Kalman filter's predict step.
    /// This advances the state estimate between GPS updates, providing
    /// dead reckoning during signal loss.
    ///
    /// - Parameters:
    ///   - acceleration: Longitudinal acceleration in m/s² (gravity-compensated, bias-corrected).
    ///   - deltaTime: Time since last IMU sample in seconds.
    @discardableResult
    mutating func processIMU(acceleration: Double, deltaTime: TimeInterval) -> Double {
        // Skip invalid samples to avoid corrupting the KF state.
        guard deltaTime > 0, acceleration.isFinite, !acceleration.isNaN else {
            return kf.velocity
        }

        imuSampleCount += 1

        // Kalman filter predict step
        kf.predict(acceleration: acceleration, deltaTime: deltaTime)

        // If GPS has been lost, the KF predicts without corrections.
        // We accumulate KF distance even during GPS loss for dead reckoning.
        if let lastGps = lastFix {
            let gpsAge = dateProvider.now().timeIntervalSince(lastGps.timestamp)
            if gpsAge > Self.gpsTimeout {
                let kfDistanceDelta = kf.position - previousKFPosition
                let maxDelta = TutormeterConfiguration.shared.maxKalmanDistanceDeltaMeters
                if kfDistanceDelta > 0 && kfDistanceDelta < maxDelta {
                    totalKFDistanceMeters += kfDistanceDelta
                }
                previousKFPosition = kf.position
            }
        }

        return kf.velocity
    }

    // MARK: - Average Speed

    /// Returns the average speed in km/h using the KF-smoothed distance.
    /// Falls back to raw GPS distance if KF has not converged.
    func currentAverageSpeedKmh() -> Double {
        guard let start = startTime else { return 0.0 }

        let elapsed = dateProvider.now().timeIntervalSince(start)
        guard elapsed > 0 else { return 0.0 }

        // Use KF distance if filter has converged, else raw GPS
        let distance = kf.hasConverged ? totalKFDistanceMeters : totalDistanceMeters

        return (max(distance, 0) / 1000.0) / (elapsed / 3600.0)
    }

    /// Returns the instantaneous speed from the Kalman filter (m/s).
    var instantSpeedMs: Double {
        kf.velocity
    }

    /// Returns the instantaneous speed in km/h.
    var instantSpeedKmh: Double {
        kf.velocity * 3.6
    }

    /// Returns the elapsed tracking time in seconds.
    func elapsedTime() -> TimeInterval {
        guard let start = startTime else { return 0 }
        return dateProvider.now().timeIntervalSince(start)
    }

    /// Returns the total number of valid GPS fixes processed.
    func processedFixCount() -> Int { fixCount }

    /// Returns the total number of IMU samples processed.
    func imuProcessedCount() -> Int { imuSampleCount }

    // MARK: - Quality Metrics

    /// Position uncertainty from the Kalman filter (meters).
    /// Low values (< 3m) indicate high confidence.
    var positionUncertainty: Double { kf.positionUncertainty }

    /// Velocity uncertainty from the Kalman filter (m/s).
    var velocityUncertainty: Double { kf.velocityUncertainty }

    /// Whether the Kalman filter has converged to a stable estimate.
    var hasFilterConverged: Bool { kf.hasConverged }

    /// Whether the filter has diverged (excessive uncertainty).
    var hasFilterDiverged: Bool { kf.hasDiverged }

    /// Confidence level: 0 (no confidence) to 1 (perfect).
    var confidenceLevel: Double {
        if kf.hasDiverged { return 0.0 }
        let posConf = max(0, 1.0 - kf.positionUncertainty / 10.0)
        let velConf = max(0, 1.0 - kf.velocityUncertainty / 5.0)
        return (posConf + velConf) / 2.0
    }

    /// Difference between raw GPS distance and KF distance (diagnostic).
    /// Large values suggest the filter needs tuning.
    var gpsKFDistanceDelta: Double {
        abs(totalDistanceMeters - totalKFDistanceMeters)
    }

    // MARK: - Reset

    mutating func reset() {
        kf = KalmanFilter1D()
        totalDistanceMeters = 0.0
        totalKFDistanceMeters = 0.0
        startTime = nil
        lastFix = nil
        fixCount = 0
        imuSampleCount = 0
        previousGPSPosition = 0.0
        previousKFPosition = 0.0
    }

    // MARK: - Haversine Formula

    static func haversineDistance(
        lat1: Double, lon1: Double,
        lat2: Double, lon2: Double
    ) -> Double {
        let dLat = (lat2 - lat1).degreesToRadians
        let dLon = (lon2 - lon1).degreesToRadians
        let lat1Rad = lat1.degreesToRadians
        let lat2Rad = lat2.degreesToRadians

        let a = sin(dLat / 2) * sin(dLat / 2) +
                cos(lat1Rad) * cos(lat2Rad) *
                sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))

        return earthRadiusMeters * c
    }
}

// MARK: - GPS Fix

struct GPSFix {
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double // meters
    let speed: Double              // m/s (instantaneous GPS speed)
    let timestamp: Date
    let altitude: Double?
}

// MARK: - Tutor Record

import SwiftData

@Model
final class TutorRecord {
    var startDate: Date
    var endDate: Date
    var startLatitude: Double
    var startLongitude: Double
    var endLatitude: Double
    var endLongitude: Double
    var totalDistanceKm: Double
    var averageSpeedKmh: Double
    var maxSpeedKmh: Double
    var gpsFixCount: Int
    var didEnterTunnel: Bool

    init(
        startDate: Date,
        endDate: Date,
        startLatitude: Double,
        startLongitude: Double,
        endLatitude: Double,
        endLongitude: Double,
        totalDistanceKm: Double,
        averageSpeedKmh: Double,
        maxSpeedKmh: Double,
        gpsFixCount: Int,
        didEnterTunnel: Bool
    ) {
        self.startDate = startDate
        self.endDate = endDate
        self.startLatitude = startLatitude
        self.startLongitude = startLongitude
        self.endLatitude = endLatitude
        self.endLongitude = endLongitude
        self.totalDistanceKm = totalDistanceKm
        self.averageSpeedKmh = averageSpeedKmh
        self.maxSpeedKmh = maxSpeedKmh
        self.gpsFixCount = gpsFixCount
        self.didEnterTunnel = didEnterTunnel
    }

    var duration: TimeInterval {
        endDate.timeIntervalSince(startDate)
    }

    var exceededLimit: Bool {
        averageSpeedKmh > TutormeterConfiguration.shared.speedLimitKmh
    }
}

// MARK: - Double Extension

extension Double {
    var degreesToRadians: Double {
        self * .pi / 180.0
    }
}
