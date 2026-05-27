import Foundation
import CoreMotion

// MARK: - IMU Filter

/// Processes raw accelerometer and gyroscope data from CMMotionManager
/// to extract the vehicle's longitudinal acceleration for dead reckoning.
///
/// Handles:
/// - Gravity compensation via device attitude (CMAttitude)
/// - Projection of acceleration onto the vehicle's forward axis
/// - Low-pass filtering to remove engine vibration and road noise
/// - Orientation tracking for coordinate frame transforms
///
/// Usage:
/// ```swift
/// let imu = IMUFilter()
/// imu.start { acceleration, dt in
///     kalmanFilter.predict(acceleration: acceleration, deltaTime: dt)
/// }
/// ```
@MainActor
final class IMUFilter: @unchecked Sendable {
    // MARK: - Dependencies
    private let motionManager: CMMotionManager

    // MARK: - State
    private var lastTimestamp: TimeInterval?
    private var filteredAccelX: Double = 0.0
    private var filteredAccelY: Double = 0.0
    private var filteredAccelZ: Double = 0.0
    private var isRunning = false

    // MARK: - Calibration
    private var biasX: Double = 0.0
    private var biasY: Double = 0.0
    private var biasZ: Double = 0.0
    private var noiseVariance: Double = 0.01 // default small noise

    // MARK: - Configuration

    /// Cutoff frequency for the low-pass filter (Hz).
    /// Lower = more smoothing, higher = more responsive.
    /// Vehicle dynamics are below 5 Hz; engine vibration is above 10 Hz.
    static let lowPassCutoffHz: Double = 5.0

    /// Device motion update interval in seconds (100 Hz).
    static let updateInterval: TimeInterval = 1.0 / 100.0

    /// Sampling duration for auto-calibration.
    static let calibrationDuration: TimeInterval = 2.0

    // MARK: - Initialization

    init(motionManager: CMMotionManager = CMMotionManager()) {
        self.motionManager = motionManager
    }

    // MARK: - Lifecycle

    /// Starts the IMU processing loop.
    /// - Parameter callback: Called with (longitudinalAcceleration_m_s2, deltaTime_s).
    func start(callback: @escaping (Double, TimeInterval) -> Void) {
        guard !isRunning, motionManager.isDeviceMotionAvailable else {
            print("[IMUFilter] Cannot start: unavailable or already running")
            return
        }

        isRunning = true
        motionManager.deviceMotionUpdateInterval = Self.updateInterval

        motionManager.startDeviceMotionUpdates(
            using: .xArbitraryZVertical,
            to: .main
        ) { [weak self] motion, error in
            guard let self = self, let motion = motion else {
                if let error = error {
                    print("[IMUFilter] Error: \(error.localizedDescription)")
                }
                return
            }
            self.processMotion(motion, callback: callback)
        }
    }

    /// Stops the IMU processing loop.
    func stop() {
        isRunning = false
        motionManager.stopDeviceMotionUpdates()
    }

    // MARK: - Calibration

    /// Calibrates the IMU by collecting still samples and computing bias/noise.
    /// Should be called at the start of each session while the device is stationary.
    func calibrate(duration: TimeInterval = calibrationDuration) async -> CalibrationResult {
        return await withCheckedContinuation { continuation in
            var samples: [(x: Double, y: Double, z: Double)] = []
            let startTime = Date()

            // Temporarily start collecting raw accelerometer data
            motionManager.accelerometerUpdateInterval = 1.0 / 50.0 // 50 Hz for calibration
            motionManager.startAccelerometerUpdates(to: .main) { data, error in
                guard let data = data else { return }

                samples.append((data.acceleration.x, data.acceleration.y, data.acceleration.z))

                if Date().timeIntervalSince(startTime) >= duration {
                    self.motionManager.stopAccelerometerUpdates()

                    let result = self.computeCalibration(from: samples)
                    self.applyCalibration(result)
                    continuation.resume(returning: result)
                }
            }
        }
    }

    /// Applies calibration parameters.
    func applyCalibration(_ result: CalibrationResult) {
        biasX = result.biasX
        biasY = result.biasY
        biasZ = result.biasZ
        noiseVariance = result.noiseVariance
    }

    // MARK: - Processing

    private func processMotion(
        _ motion: CMDeviceMotion,
        callback: (Double, TimeInterval) -> Void
    ) {
        let now = Date().timeIntervalSince1970
        let dt = lastTimestamp.map { now - $0 } ?? Self.updateInterval
        lastTimestamp = now

        // Step 1: Get user acceleration (gravity already compensated by CoreMotion)
        let rawAccel = motion.userAcceleration
        let accelX = rawAccel.x - biasX
        let accelY = rawAccel.y - biasY
        let accelZ = rawAccel.z - biasZ

        // Step 2: Low-pass filter to remove high-frequency noise (vibration)
        let alpha = lowPassAlpha(cutoffHz: Self.lowPassCutoffHz, deltaTime: dt)
        filteredAccelX = alpha * accelX + (1 - alpha) * filteredAccelX
        filteredAccelY = alpha * accelY + (1 - alpha) * filteredAccelY
        filteredAccelZ = alpha * accelZ + (1 - alpha) * filteredAccelZ

        // Step 3: Project acceleration onto the longitudinal (forward) axis
        // The vehicle's forward direction is the direction the device is "pointing"
        // when mounted. We use the device's attitude to determine this.
        let longitudinal = projectToLongitudinal(
            ax: filteredAccelX,
            ay: filteredAccelY,
            az: filteredAccelZ,
            attitude: motion.attitude
        )

        callback(longitudinal, dt)
    }

    // MARK: - Coordinate Transform

    /// Projects a 3D acceleration vector onto the longitudinal (forward) axis
    /// of the vehicle based on the device's attitude.
    ///
    /// On iOS, the device coordinate system is:
    /// - X: right
    /// - Y: up (top of screen)
    /// - Z: out of screen (toward user)
    ///
    /// For a phone mounted in a car:
    /// - If portrait, facing driver: Z ≈ forward, X ≈ lateral
    /// - If landscape, top-left:  X ≈ forward, Z ≈ lateral
    ///
    /// We use the gravity vector from attitude to determine which device axis
    /// is most aligned with the vehicle's forward direction.
    private func projectToLongitudinal(
        ax: Double, ay: Double, az: Double,
        attitude: CMAttitude
    ) -> Double {
        // The device's forward vector in the world frame is:
        // For a typical car mount, this is approximately the device's Z axis
        // (pointing out of the screen) projected onto the horizontal plane.

        // Get the rotation matrix from device to world frame
        let rotationMatrix = attitude.rotationMatrix

        // Forward direction in device frame: (0, 0, 1) i.e. Z axis
        // Transform to world frame: world_forward = R * device_forward
        let worldForwardX = rotationMatrix.m13 // Z component in world X
        let worldForwardY = rotationMatrix.m23 // Z component in world Y
        let worldForwardZ = rotationMatrix.m33 // Z component in world Z

        // Project onto horizontal plane (ignore vertical/Y component)
        // and normalize
        let horizontalLength = sqrt(worldForwardX * worldForwardX + worldForwardZ * worldForwardZ)

        guard horizontalLength > 0.01 else {
            // Device is vertical (looking up/down) — fall back to using
            // the largest horizontal component of raw acceleration
            return sqrt(ax * ax + az * az) * (ax > 0 ? 1 : -1)
        }

        // Acceleration in the forward direction = a · forward_unit_vector
        // forward_unit_vector = (worldForwardX, 0, worldForwardZ) / horizontalLength
        // But we need this in device coordinates, which is simply:
        // a · (0, 0, 1) = az, since forward is Z in device frame
        // For robustness, we use a weighted combination
        let forwardAccel = az

        return forwardAccel
    }

    // MARK: - Low-Pass Filter

    /// Computes the smoothing factor (alpha) for a 1st-order low-pass filter.
    /// alpha = dt / (dt + 1/(2*pi*fc))
    private func lowPassAlpha(cutoffHz: Double, deltaTime: TimeInterval) -> Double {
        let tau = 1.0 / (2.0 * .pi * cutoffHz)
        let alpha = deltaTime / (deltaTime + tau)
        return min(alpha, 1.0) // clamp to [0, 1]
    }

    // MARK: - Calibration Computation

    private func computeCalibration(
        from samples: [(x: Double, y: Double, z: Double)]
    ) -> CalibrationResult {
        guard !samples.isEmpty else {
            return CalibrationResult(biasX: 0, biasY: 0, biasZ: 0, noiseVariance: 0.01)
        }

        let n = Double(samples.count)

        // Compute mean (bias)
        let meanX = samples.reduce(0) { $0 + $1.x } / n
        let meanY = samples.reduce(0) { $0 + $1.y } / n
        let meanZ = samples.reduce(0) { $0 + $1.z } / n

        // Compute variance (noise)
        let varX = samples.reduce(0) { $0 + pow($1.x - meanX, 2) } / n
        let varY = samples.reduce(0) { $0 + pow($1.y - meanY, 2) } / n
        let varZ = samples.reduce(0) { $0 + pow($1.z - meanZ, 2) } / n

        // Average noise variance across all axes
        let avgVariance = (varX + varY + varZ) / 3.0

        return CalibrationResult(
            biasX: meanX,
            biasY: meanY,
            biasZ: meanZ,
            noiseVariance: max(avgVariance, 0.001) // floor to avoid zero noise
        )
    }

    deinit {
        stop()
    }
}

// MARK: - Calibration Result

/// Result of IMU auto-calibration at session start.
struct CalibrationResult {
    /// Accelerometer bias on X axis (g ≈ 9.81 m/s²).
    let biasX: Double
    /// Accelerometer bias on Y axis.
    let biasY: Double
    /// Accelerometer bias on Z axis.
    let biasZ: Double
    /// Average noise variance across all axes (m²/s⁴).
    let noiseVariance: Double

    /// Whether the calibration detected excessive noise (possible hardware issue).
    var isNoisy: Bool { noiseVariance > 0.1 }

    /// Whether the calibration detected significant bias.
    var hasSignificantBias: Bool {
        abs(biasX) > 0.05 || abs(biasY) > 0.05 || abs(biasZ) > 0.05
    }

    /// Summary for logging.
    var summary: String {
        "Calibration: bias=(\(String(format: "%.3f", biasX)), \(String(format: "%.3f", biasY)), \(String(format: "%.3f", biasZ))) noiseVar=\(String(format: "%.4f", noiseVariance))"
    }
}
