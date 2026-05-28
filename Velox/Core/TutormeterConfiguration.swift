import Foundation

// MARK: - Tutormeter Configuration

/// Centralized configuration for all magic numbers used throughout the app.
///
/// All tunable parameters (thresholds, intervals, limits) live here so they can
/// be reviewed, changed and (in the future) overridden remotely or per-build.
///
/// Access via `TutormeterConfiguration.shared` or inject `TutormeterConfiguration`
/// instances for testing.
struct TutormeterConfiguration {

    // MARK: - Singleton

    /// Shared default configuration. Replace at app launch for non-default tuning.
    static let shared = TutormeterConfiguration()

    // MARK: - Speed Limits

    /// Italian motorway average-speed limit (km/h). Used for over-limit detection.
    let speedLimitKmh: Double = 130.0

    // MARK: - GPS

    /// Maximum acceptable horizontal accuracy for a GPS fix (meters).
    let gpsMaxAccuracyMeters: Double = 20.0

    /// Time after which an unreceived GPS fix is considered "lost" (seconds).
    let gpsTimeoutSeconds: TimeInterval = 5.0

    /// Maximum age of a cached location that can still be accepted (seconds).
    let maxLocationAgeSeconds: TimeInterval = 5.0

    /// Maximum plausible speed used to reject GPS outliers (m/s, ~360 km/h).
    let maxSpeedJumpMetersPerSecond: Double = 100.0

    /// Maximum plausible delta between consecutive KF position samples (meters).
    let maxKalmanDistanceDeltaMeters: Double = 200.0

    /// Minimum valid altitude — below sea level cap, anything lower is rejected.
    let minAltitudeMeters: Double = -500.0

    // MARK: - Kalman Filter

    /// Position uncertainty above which the filter is considered diverged (meters).
    let kalmanMaxDivergencePositionMeters: Double = 100.0

    /// Velocity uncertainty above which the filter is considered diverged (m/s).
    let kalmanMaxDivergenceVelocityMetersPerSecond: Double = 20.0

    /// Position uncertainty below which the filter is considered converged (meters).
    let kalmanConvergenceThresholdMeters: Double = 3.0

    /// Maximum sane deltaTime between two predict calls (seconds).
    let kalmanMaxDeltaTimeSeconds: TimeInterval = 10.0

    /// Maximum sane acceleration magnitude (m/s²).
    let kalmanMaxAccelerationMetersPerSecondSquared: Double = 100.0

    // MARK: - IMU

    /// Low-pass filter cutoff frequency for IMU (Hz).
    let imuLowPassCutoffHz: Double = 5.0

    /// IMU sampling interval (seconds) → 100 Hz.
    let imuUpdateIntervalSeconds: TimeInterval = 1.0 / 100.0

    /// Lower clamp for IMU dt (seconds).
    let imuMinDeltaTimeSeconds: TimeInterval = 0.001

    /// Upper clamp for IMU dt (seconds).
    let imuMaxDeltaTimeSeconds: TimeInterval = 1.0

    // MARK: - Calibration

    /// Minimum stationary duration required for valid calibration (seconds).
    let calibrationMinStationaryDurationSeconds: TimeInterval = 2.0

    /// Maximum acceleration magnitude considered "stationary" (m/s²).
    let calibrationStationaryThreshold: Double = 1.0

    /// Maximum acceptable per-axis bias from calibration (g).
    let calibrationMaxBiasG: Double = 0.2

    /// Noise variance above which the device is considered "noisy".
    let calibrationNoiseThreshold: Double = 0.1

    /// Maximum age of a calibration before it must be redone (seconds).
    let calibrationMaxAgeSeconds: TimeInterval = 1800.0

    // MARK: - Live Activity

    /// Minimum interval between Live Activity updates (seconds).
    let liveActivityMinUpdateIntervalSeconds: TimeInterval = 1.0

    /// Maximum age of a Live Activity before auto-end (seconds).
    let liveActivityMaxAgeSeconds: TimeInterval = 3600.0

    /// Content relevance score for the Dynamic Island.
    let liveActivityRelevanceScore: Double = 80.0

    // MARK: - Widget

    /// Widget refresh interval while tracking (seconds).
    let widgetRefreshIntervalTrackingSeconds: TimeInterval = 5.0

    /// Widget refresh interval while idle (seconds).
    let widgetRefreshIntervalIdleSeconds: TimeInterval = 900.0

    // MARK: - Session

    /// Maximum age of a recoverable terminated session (seconds).
    let sessionMaxAgeSeconds: TimeInterval = 1800.0

    /// Background-stale threshold: when GPS has been lost for this long, the
    /// background refresh task flags the session as stale (seconds).
    let backgroundStaleGPSThresholdSeconds: TimeInterval = 5.0 * 60.0

    /// Age cutoff for purging old TutorRecord entries during background cleanup (seconds).
    let backgroundOldRecordAgeSeconds: TimeInterval = 30.0 * 24.0 * 3600.0

    // MARK: - Background Tasks

    /// Earliest schedule for the periodic refresh task (seconds).
    let backgroundRefreshIntervalSeconds: TimeInterval = 900.0

    /// Earliest schedule for the heavier cleanup task (seconds).
    let backgroundCleanupIntervalSeconds: TimeInterval = 7200.0

    // MARK: - State Machine

    /// Time without a GPS fix that triggers a GPS_LOST transition (seconds).
    let stateMachineGPSLostThresholdSeconds: TimeInterval = 5.0

    /// Maximum age of the latest fix to consider GPS "recovered" (seconds).
    let stateMachineGPSRecoveryThresholdSeconds: TimeInterval = 2.0
}
