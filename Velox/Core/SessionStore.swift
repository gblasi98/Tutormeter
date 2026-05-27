import Foundation
import SwiftData

// MARK: - Session Store

/// Persists tracking session state for recovery after app termination.
///
/// iOS may terminate background apps at any time. This store ensures
/// that when the app relaunches:
/// 1. Incomplete sessions can be resumed or properly closed
/// 2. Completed Tutor records are saved
/// 3. Calibration data persists across launches
///
/// Uses SwiftData for persistence and UserDefaults for lightweight state.
@MainActor
final class SessionStore {
    // MARK: - Keys
    private enum Keys: String {
        case lastSessionState = "velox.last_session_state"
        case lastSessionStartTime = "velox.last_session_start"
        case lastCalibrationBiasX = "velox.calibration.biasX"
        case lastCalibrationBiasY = "velox.calibration.biasY"
        case lastCalibrationBiasZ = "velox.calibration.biasZ"
        case lastCalibrationNoise = "velox.calibration.noiseVariance"
        case lastCalibrationDate = "velox.calibration.date"
        case totalSessions = "velox.total_sessions"
        case totalDistanceKm = "velox.total_distance_km"
        case totalTrackingSeconds = "velox.total_tracking_seconds"
    }

    private let defaults: UserDefaults

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Session State Persistence

    /// Saves the current tracking state for recovery.
    func saveSessionState(isTracking: Bool, startTime: Date?) {
        defaults.set(isTracking, forKey: Keys.lastSessionState.rawValue)
        if let startTime = startTime {
            defaults.set(startTime.timeIntervalSince1970, forKey: Keys.lastSessionStartTime.rawValue)
        } else {
            defaults.removeObject(forKey: Keys.lastSessionStartTime.rawValue)
        }
    }

    /// Recovers the last known session state.
    /// - Returns: Whether the app was tracking when it was terminated, and the start time.
    func recoverSessionState() -> (wasTracking: Bool, startTime: Date?) {
        let wasTracking = defaults.bool(forKey: Keys.lastSessionState.rawValue)

        let startTime: Date?
        let timestamp = defaults.double(forKey: Keys.lastSessionStartTime.rawValue)
        if timestamp > 0 {
            startTime = Date(timeIntervalSince1970: timestamp)
        } else {
            startTime = nil
        }

        return (wasTracking, startTime)
    }

    /// Clears the persisted session state (called after successful stop).
    func clearSessionState() {
        defaults.removeObject(forKey: Keys.lastSessionState.rawValue)
        defaults.removeObject(forKey: Keys.lastSessionStartTime.rawValue)
    }

    // MARK: - Calibration Persistence

    /// Saves calibration data for reuse across launches.
    /// Calibration is valid for ~30 minutes (device temperature changes slowly).
    func saveCalibration(_ result: CalibrationResult) {
        defaults.set(result.biasX, forKey: Keys.lastCalibrationBiasX.rawValue)
        defaults.set(result.biasY, forKey: Keys.lastCalibrationBiasY.rawValue)
        defaults.set(result.biasZ, forKey: Keys.lastCalibrationBiasZ.rawValue)
        defaults.set(result.noiseVariance, forKey: Keys.lastCalibrationNoise.rawValue)
        defaults.set(Date().timeIntervalSince1970, forKey: Keys.lastCalibrationDate.rawValue)
    }

    /// Recovers the last calibration data, if still valid (< 30 minutes old).
    func recoverCalibration() -> CalibrationResult? {
        let lastDate = defaults.double(forKey: Keys.lastCalibrationDate.rawValue)
        guard lastDate > 0 else { return nil }

        let age = Date().timeIntervalSince(Date(timeIntervalSince1970: lastDate))
        guard age < 1800 else { // 30 minutes
            clearCalibration()
            return nil
        }

        let biasX = defaults.double(forKey: Keys.lastCalibrationBiasX.rawValue)
        let biasY = defaults.double(forKey: Keys.lastCalibrationBiasY.rawValue)
        let biasZ = defaults.double(forKey: Keys.lastCalibrationBiasZ.rawValue)
        let noise = defaults.double(forKey: Keys.lastCalibrationNoise.rawValue)

        // If all zeros, no calibration was saved — return nil
        guard biasX != 0 || biasY != 0 || biasZ != 0 || noise > 0 else {
            return nil
        }

        return CalibrationResult(
            biasX: biasX,
            biasY: biasY,
            biasZ: biasZ,
            noiseVariance: max(noise, 0.001)
        )
    }

    /// Clears stale calibration data.
    func clearCalibration() {
        defaults.removeObject(forKey: Keys.lastCalibrationBiasX.rawValue)
        defaults.removeObject(forKey: Keys.lastCalibrationBiasY.rawValue)
        defaults.removeObject(forKey: Keys.lastCalibrationBiasZ.rawValue)
        defaults.removeObject(forKey: Keys.lastCalibrationNoise.rawValue)
        defaults.removeObject(forKey: Keys.lastCalibrationDate.rawValue)
    }

    // MARK: - Lifetime Statistics

    /// Increments the total session counter.
    func incrementSessionCount() {
        let current = defaults.integer(forKey: Keys.totalSessions.rawValue)
        defaults.set(current + 1, forKey: Keys.totalSessions.rawValue)
    }

    /// Adds to the total distance tracked across all sessions.
    func addDistanceKm(_ km: Double) {
        let current = defaults.double(forKey: Keys.totalDistanceKm.rawValue)
        defaults.set(current + km, forKey: Keys.totalDistanceKm.rawValue)
    }

    /// Adds to the total tracking time.
    func addTrackingSeconds(_ seconds: TimeInterval) {
        let current = defaults.double(forKey: Keys.totalTrackingSeconds.rawValue)
        defaults.set(current + seconds, forKey: Keys.totalTrackingSeconds.rawValue)
    }

    /// Returns lifetime statistics.
    struct LifetimeStats {
        let totalSessions: Int
        let totalDistanceKm: Double
        let totalTrackingHours: Double

        var formattedDistance: String {
            String(format: "%.0f km", totalDistanceKm)
        }

        var formattedTime: String {
            let hours = Int(totalTrackingHours)
            let minutes = Int((totalTrackingHours - Double(hours)) * 60)
            return "\(hours)h \(minutes)m"
        }
    }

    /// Returns lifetime usage statistics.
    func lifetimeStats() -> LifetimeStats {
        LifetimeStats(
            totalSessions: defaults.integer(forKey: Keys.totalSessions.rawValue),
            totalDistanceKm: defaults.double(forKey: Keys.totalDistanceKm.rawValue),
            totalTrackingHours: defaults.double(forKey: Keys.totalTrackingSeconds.rawValue) / 3600
        )
    }

    // MARK: - Session Recovery Logic

    /// Determines if the app was terminated mid-tracking and should attempt recovery.
    func shouldRecoverSession() -> Bool {
        let (wasTracking, startTime) = recoverSessionState()

        guard wasTracking, let start = startTime else { return false }

        // If the app was terminated < 10 minutes ago, the session might still be valid
        let age = Date().timeIntervalSince(start)
        let terminatedAge = Date().timeIntervalSince(start) // simplified

        // Session older than 30 minutes is definitely stale
        guard age < 1800 else {
            clearSessionState()
            return false
        }

        return true
    }

    /// Attempts to recover a terminated tracking session.
    /// Returns nil if recovery is not possible (session too old, etc.).
    func attemptSessionRecovery() -> (
        wasTracking: Bool,
        sessionAge: TimeInterval,
        canRecover: Bool
    ) {
        let (wasTracking, startTime) = recoverSessionState()

        guard wasTracking, let start = startTime else {
            return (false, 0, false)
        }

        let age = Date().timeIntervalSince(start)

        // Can recover if < 30 minutes old
        let canRecover = age < 1800

        return (true, age, canRecover)
    }
}
