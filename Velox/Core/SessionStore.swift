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
        case lastSessionState = "tutormeter.last_session_state"
        case lastSessionStartTime = "tutormeter.last_session_start"
        case lastCalibrationBiasX = "tutormeter.calibration.biasX"
        case lastCalibrationBiasY = "tutormeter.calibration.biasY"
        case lastCalibrationBiasZ = "tutormeter.calibration.biasZ"
        case lastCalibrationNoise = "tutormeter.calibration.noiseVariance"
        case lastCalibrationDate = "tutormeter.calibration.date"
        case totalSessions = "tutormeter.total_sessions"
        case totalDistanceKm = "tutormeter.total_distance_km"
        case totalTrackingSeconds = "tutormeter.total_tracking_seconds"
    }

    private let defaults: UserDefaults
    private let config: TutormeterConfiguration
    private let dateProvider: any DateProvider

    // MARK: - Init

    init(
        defaults: UserDefaults = .standard,
        config: TutormeterConfiguration = .shared,
        dateProvider: any DateProvider = SystemDateProvider()
    ) {
        self.defaults = defaults
        self.config = config
        self.dateProvider = dateProvider
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
        defaults.set(dateProvider.now().timeIntervalSince1970, forKey: Keys.lastCalibrationDate.rawValue)
    }

    /// Recovers the last calibration data, if still valid (< 30 minutes old).
    func recoverCalibration() -> CalibrationResult? {
        let lastDate = defaults.double(forKey: Keys.lastCalibrationDate.rawValue)
        guard lastDate > 0 else { return nil }

        let age = Date().timeIntervalSince(Date(timeIntervalSince1970: lastDate))
        guard age < config.calibrationMaxAgeSeconds else {
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
    /// Negative or non-finite values are ignored.
    func addDistanceKm(_ km: Double) {
        guard km.isFinite, km >= 0 else {
            print("[SessionStore] addDistanceKm ignored invalid value: \(km)")
            return
        }
        let current = defaults.double(forKey: Keys.totalDistanceKm.rawValue)
        defaults.set(current + km, forKey: Keys.totalDistanceKm.rawValue)
    }

    /// Adds to the total tracking time.
    /// Negative or non-finite values are ignored.
    func addTrackingSeconds(_ seconds: TimeInterval) {
        guard seconds.isFinite, seconds >= 0 else {
            print("[SessionStore] addTrackingSeconds ignored invalid value: \(seconds)")
            return
        }
        let current = defaults.double(forKey: Keys.totalTrackingSeconds.rawValue)
        defaults.set(current + seconds, forKey: Keys.totalTrackingSeconds.rawValue)
    }

    /// Persists a completed TutorRecord.
    /// - Note: Wire this up to the app's SwiftData ModelContext when calling
    ///   from `TrackingManager.saveCompletedSession()`. The SwiftData
    ///   `@Model` definition lives in `SpeedCalculator.swift`.
    func saveTutorRecord(_ record: TutorRecord, in context: ModelContext) {
        context.insert(record)
        do {
            try context.save()
        } catch {
            print("[SessionStore] Failed to save TutorRecord: \(error.localizedDescription)")
        }
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

        // Sessions older than the configured max age are considered stale.
        let age = Date().timeIntervalSince(start)
        guard age < config.sessionMaxAgeSeconds else {
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
        let canRecover = age < config.sessionMaxAgeSeconds

        return (true, age, canRecover)
    }
}
