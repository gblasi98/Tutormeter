import Foundation

// MARK: - Calibration Manager

/// Orchestrates the IMU calibration process at the start of each tracking session.
///
/// Calibration is critical because every accelerometer has a unique bias
/// (typically 20-50 mg) that would cause ~0.7-1.8 km/h velocity error per second
/// if uncorrected.
///
/// The calibration flow:
/// 1. Detect that the device is stationary (no significant motion for 2s)
/// 2. Collect IMU samples while stationary
/// 3. Compute bias, noise, and quality metrics
/// 4. Apply calibration to the IMU filter
@MainActor
final class CalibrationManager {
    // MARK: - Configuration

    /// Minimum stationary duration required for valid calibration.
    static let minimumStationarySeconds: TimeInterval = 2.0

    /// Maximum acceleration magnitude to consider the device "stationary" (m/s²).
    /// Gravity ≈ 9.81, so we allow ±0.1 g variation.
    static let stationaryThreshold: Double = 1.0

    // MARK: - State

    private(set) var lastCalibration: CalibrationResult?
    private(set) var calibrationDate: Date?
    private var isCalibrating = false

    /// Whether the device currently appears to be stationary.
    private(set) var isStationary = false

    // MARK: - Calibration

    /// Performs a full calibration sequence using the provided IMU filter.
    /// Blocks until calibration is complete (~2-3 seconds).
    ///
    /// - Parameter imuFilter: The IMU filter to calibrate.
    /// - Returns: The calibration result, or nil if calibration failed.
    func calibrate(using imuFilter: IMUFilter) async -> CalibrationResult? {
        guard !isCalibrating else {
            print("[CalibrationManager] Already calibrating")
            return lastCalibration
        }

        isCalibrating = true
        defer { isCalibrating = false }

        print("[CalibrationManager] Starting IMU calibration...")

        // Wait for device to be stationary
        let becameStationary = await waitForStationary()
        guard becameStationary else {
            print("[CalibrationManager] Device never became stationary — using previous calibration")
            return lastCalibration
        }

        // Collect samples
        let result = await imuFilter.calibrate(duration: Self.minimumStationarySeconds)

        // Validate calibration quality
        guard validateCalibration(result) else {
            print("[CalibrationManager] Calibration failed quality check — using previous calibration")
            return lastCalibration
        }

        // Apply
        imuFilter.applyCalibration(result)
        lastCalibration = result
        calibrationDate = Date()

        print("[CalibrationManager] Calibration complete: \(result.summary)")
        return result
    }

    // MARK: - Stationary Detection

    /// Waits for the device to become stationary by monitoring accelerometer data.
    /// Returns true if stationary was achieved within the timeout.
    private func waitForStationary(timeout: TimeInterval = 10.0) async -> Bool {
        // In production, this would use a CMMotionManager instance.
        // For the current implementation, we assume the device is stationary
        // after a short delay — the actual detection will be integrated
        // when we connect to real hardware.

        // Simulated wait: in the real implementation, we'd subscribe to
        // accelerometer updates and check if magnitude ≈ 9.81 ± threshold
        // for at least minimumStationarySeconds.

        try? await Task.sleep(nanoseconds: UInt64(1.0 * 1_000_000_000))

        isStationary = true
        return true
    }

    // MARK: - Validation

    /// Validates calibration quality by checking for excessive bias or noise.
    private func validateCalibration(_ result: CalibrationResult) -> Bool {
        // Reject if excessive noise (possible hardware issue or movement during calibration)
        if result.isNoisy {
            print("[CalibrationManager] Rejected: noise variance \(result.noiseVariance) exceeds threshold")
            return false
        }

        // Reject if bias is > 0.2g (device may have been moving)
        if abs(result.biasX) > 0.2 || abs(result.biasY) > 0.2 || abs(result.biasZ) > 0.2 {
            print("[CalibrationManager] Rejected: bias magnitude exceeds 0.2g")
            return false
        }

        return true
    }

    // MARK: - State Queries

    /// Time since last successful calibration.
    var timeSinceLastCalibration: TimeInterval? {
        guard let date = calibrationDate else { return nil }
        return Date().timeIntervalSince(date)
    }

    /// Whether a recent calibration (< 30 minutes old) is available.
    var hasRecentCalibration: Bool {
        guard let elapsed = timeSinceLastCalibration else { return false }
        return elapsed < 1800 // 30 minutes
    }

    /// Resets calibration state (called at session end).
    func reset() {
        lastCalibration = nil
        calibrationDate = nil
        isStationary = false
    }
}
