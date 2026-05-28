import Foundation

// MARK: - Kalman Filter

/// A 1D Kalman Filter for fusing GPS position measurements
/// with IMU acceleration data to produce a smooth, accurate
/// velocity estimate for average speed calculation.
///
/// State vector: [position (m), velocity (m/s)]
/// Control input: longitudinal acceleration (m/s²)
/// Measurement: GPS-derived position (m)
///
/// This filter mitigates GPS noise (2-5m typical error) and
/// provides dead reckoning during signal loss (tunnels).
struct KalmanFilter1D {
    // MARK: - State

    /// Estimated position in meters along the road.
    private(set) var position: Double

    /// Estimated velocity in m/s.
    private(set) var velocity: Double

    /// State covariance matrix (2x2).
    /// P[0,0] = position variance, P[1,1] = velocity variance,
    /// P[0,1] = P[1,0] = cross-covariance.
    private var P: [[Double]]

    // MARK: - Constants

    /// Process noise covariance for position (m²/s³).
    /// Models uncertainty in the IMU acceleration integration.
    private let processNoisePos: Double

    /// Process noise covariance for velocity (m²/s³).
    private let processNoiseVel: Double

    /// Measurement noise covariance for GPS position (m²).
    /// Typical GPS error: 2-5m → variance: 4-25 m².
    private let measurementNoise: Double

    // MARK: - Initialization

    /// Creates a new Kalman filter.
    /// - Parameters:
    ///   - initialPosition: Starting position in meters (default 0).
    ///   - initialVelocity: Starting velocity in m/s (default 0).
    ///   - positionUncertainty: Initial position uncertainty in meters (default 10).
    ///   - velocityUncertainty: Initial velocity uncertainty in m/s (default 5).
    ///   - processNoisePos: Process noise for position (default 0.1).
    ///   - processNoiseVel: Process noise for velocity (default 0.5).
    ///   - measurementNoise: GPS measurement noise variance (default 25.0 = 5m σ).
    init(
        initialPosition: Double = 0.0,
        initialVelocity: Double = 0.0,
        positionUncertainty: Double = 10.0,
        velocityUncertainty: Double = 5.0,
        processNoisePos: Double = 0.1,
        processNoiseVel: Double = 0.5,
        measurementNoise: Double = 25.0
    ) {
        self.position = initialPosition
        self.velocity = initialVelocity
        self.processNoisePos = processNoisePos
        self.processNoiseVel = processNoiseVel
        self.measurementNoise = measurementNoise

        // Initialize covariance: diagonal matrix with initial uncertainties
        self.P = [
            [positionUncertainty * positionUncertainty, 0.0],
            [0.0, velocityUncertainty * velocityUncertainty]
        ]
    }

    // MARK: - Core Operations

    /// Predict step: advances the state estimate using IMU acceleration.
    ///
    /// State transition (constant acceleration model):
    ///   x_k|k-1 = x_k-1 + v_k-1 * dt + 0.5 * a * dt²
    ///   v_k|k-1 = v_k-1 + a * dt
    ///
    /// - Parameters:
    ///   - acceleration: Longitudinal acceleration in m/s².
    ///   - deltaTime: Time step in seconds.
    mutating func predict(acceleration: Double, deltaTime: TimeInterval) {
        let config = TutormeterConfiguration.shared

        // Sanity checks: skip predict on invalid inputs rather than corrupting state.
        guard deltaTime > 0, deltaTime < config.kalmanMaxDeltaTimeSeconds else {
            return
        }
        guard acceleration.isFinite,
              !acceleration.isNaN,
              abs(acceleration) < config.kalmanMaxAccelerationMetersPerSecondSquared else {
            return
        }

        let dt = deltaTime

        // State transition Jacobian (F matrix)
        // F = [[1, dt], [0, 1]]
        let F00 = 1.0
        let F01 = dt
        let F10 = 0.0
        let F11 = 1.0

        // Control input matrix (B matrix)
        // B = [0.5 * dt², dt]ᵀ
        let B0 = 0.5 * dt * dt
        let B1 = dt

        // Predict state: x_k = F * x_{k-1} + B * u
        let newPosition = F00 * position + F01 * velocity + B0 * acceleration
        let newVelocity = F10 * position + F11 * velocity + B1 * acceleration

        // Predict covariance: P_k = F * P_{k-1} * Fᵀ + Q
        let P00 = P[0][0]
        let P01 = P[0][1]
        let P10 = P[1][0]
        let P11 = P[1][1]

        // F * P
        let FP00 = F00 * P00 + F01 * P10
        let FP01 = F00 * P01 + F01 * P11
        let FP10 = F10 * P00 + F11 * P10
        let FP11 = F10 * P01 + F11 * P11

        // (F * P) * Fᵀ  +  Q
        // Q = process noise covariance, approximated as:
        // Q ≈ B * σ²_accel * Bᵀ for simplicity
        let q00 = processNoisePos * dt * dt * dt / 3.0
        let q01 = processNoisePos * dt * dt / 2.0
        let q10 = q01
        let q11 = processNoiseVel * dt

        let newP00 = FP00 * F00 + FP01 * F01 + q00
        let newP01 = FP00 * F10 + FP01 * F11 + q01
        let newP10 = FP10 * F00 + FP11 * F01 + q10
        let newP11 = FP10 * F10 + FP11 * F11 + q11

        // Update stored values
        position = newPosition
        velocity = newVelocity
        P = [[newP00, newP01], [newP10, newP11]]
    }

    /// Update step: corrects the state estimate using a GPS position measurement.
    ///
    /// Measurement model: z = H * x + v, where H = [1, 0] (we measure position only).
    ///
    /// - Parameter measurement: GPS-derived position in meters.
    /// - Returns: Kalman gain magnitude (for diagnostic purposes).
    @discardableResult
    mutating func update(measurement: Double) -> Double {
        // Skip update on invalid measurements rather than corrupting state.
        guard measurement.isFinite, !measurement.isNaN else {
            return 0.0
        }

        // H = [1, 0], R = measurementNoise
        let H0 = 1.0
        let H1 = 0.0
        let R = measurementNoise

        // Innovation (measurement residual): y = z - H * x
        let y = measurement - (H0 * position + H1 * velocity)

        // Innovation covariance: S = H * P * Hᵀ + R
        // Since H = [1, 0], S = P[0,0] + R
        let S = P[0][0] + R

        // Kalman gain: K = P * Hᵀ / S
        // Since Hᵀ = [1, 0]ᵀ, K = [P[0,0], P[1,0]]ᵀ / S
        let K0 = P[0][0] / S
        let K1 = P[1][0] / S
        let gainMagnitude = abs(K0)

        // Update state: x = x + K * y
        position += K0 * y
        velocity += K1 * y

        // Update covariance: P = (I - K * H) * P
        // I - K*H = [[1-K0, 0], [-K1, 1]]
        let IKH00 = 1.0 - K0
        let IKH01 = 0.0
        let IKH10 = -K1
        let IKH11 = 1.0

        let P00 = P[0][0]
        let P01 = P[0][1]
        let P10 = P[1][0]
        let P11 = P[1][1]

        let newP00 = IKH00 * P00 + IKH01 * P10
        let newP01 = IKH00 * P01 + IKH01 * P11
        let newP10 = IKH10 * P00 + IKH11 * P10
        let newP11 = IKH10 * P01 + IKH11 * P11

        P = [[newP00, newP01], [newP10, newP11]]

        return gainMagnitude
    }

    // MARK: - Uncertainty Accessors

    /// Standard deviation of the position estimate in meters.
    var positionUncertainty: Double {
        sqrt(max(0, P[0][0]))
    }

    /// Standard deviation of the velocity estimate in m/s.
    var velocityUncertainty: Double {
        sqrt(max(0, P[1][1]))
    }

    /// Whether the filter has converged to a stable estimate.
    var hasConverged: Bool {
        positionUncertainty < TutormeterConfiguration.shared.kalmanConvergenceThresholdMeters
    }

    /// Whether the filter has diverged (uncertainty exploded).
    /// This happens during extended GPS loss without reliable IMU data.
    var hasDiverged: Bool {
        let cfg = TutormeterConfiguration.shared
        return positionUncertainty > cfg.kalmanMaxDivergencePositionMeters
            || velocityUncertainty > cfg.kalmanMaxDivergenceVelocityMetersPerSecond
    }

    // MARK: - Reset

    /// Resets the filter to a known state (e.g., on re-acquiring GPS after a tunnel).
    mutating func reinitialize(
        position: Double,
        velocity: Double,
        positionUncertainty: Double = 10.0,
        velocityUncertainty: Double = 5.0
    ) {
        self.position = position
        self.velocity = velocity
        P = [
            [positionUncertainty * positionUncertainty, 0.0],
            [0.0, velocityUncertainty * velocityUncertainty]
        ]
    }
}
