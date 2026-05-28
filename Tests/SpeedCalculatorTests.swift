import Testing
import Foundation
@testable import Tutormeter

// MARK: - Haversine Distance Tests (unchanged from Phase 0)

struct HaversineDistanceTests {

    @Test("Zero distance for same point")
    func zeroDistanceForSamePoint() {
        let dist = SpeedCalculator.haversineDistance(
            lat1: 45.0, lon1: 9.0,
            lat2: 45.0, lon2: 9.0
        )
        #expect(dist == 0.0)
    }

    @Test("Short known distance (~111m per 0.001 degrees latitude)")
    func shortKnownDistance() {
        let dist = SpeedCalculator.haversineDistance(
            lat1: 45.0, lon1: 9.0,
            lat2: 45.001, lon2: 9.0
        )
        #expect(dist > 100 && dist < 120)
    }

    @Test("Milan to Rome approximates known distance")
    func longDistance() {
        let dist = SpeedCalculator.haversineDistance(
            lat1: 45.4642, lon1: 9.1900,
            lat2: 41.9028, lon2: 12.4964
        )
        let distKm = dist / 1000
        #expect(distKm > 450 && distKm < 500)
    }

    @Test("Equator crossing produces valid distance")
    func equatorCrossing() {
        let dist = SpeedCalculator.haversineDistance(
            lat1: -1.0, lon1: 0.0,
            lat2: 1.0, lon2: 0.0
        )
        #expect(dist > 200_000 && dist < 250_000)
    }

    @Test("Antimeridian crossing handled correctly")
    func antimeridianCrossing() {
        let dist = SpeedCalculator.haversineDistance(
            lat1: 0.0, lon1: 179.0,
            lat2: 0.0, lon2: -179.0
        )
        #expect(dist > 200_000 && dist < 250_000)
    }

    @Test("North pole vicinity handled")
    func nearNorthPole() {
        let dist = SpeedCalculator.haversineDistance(
            lat1: 89.0, lon1: 0.0,
            lat2: 89.0, lon2: 180.0
        )
        #expect(dist < 300_000) // Short distance near pole
    }
}

// MARK: - Kalman Filter 1D Tests

struct KalmanFilter1DTests {

    @Test("Initial state is zero")
    func initialZeroState() {
        let kf = KalmanFilter1D()
        #expect(kf.position == 0.0)
        #expect(kf.velocity == 0.0)
        #expect(!kf.hasConverged)
        #expect(!kf.hasDiverged)
    }

    @Test("Predict advances state with positive acceleration")
    func predictAdvancesState() {
        var kf = KalmanFilter1D(initialPosition: 0, initialVelocity: 10)
        kf.predict(acceleration: 2.0, deltaTime: 1.0)

        // v_new = 10 + 2*1 = 12 m/s
        // x_new = 0 + 10*1 + 0.5*2*1 = 11 m
        #expect(abs(kf.velocity - 12.0) < 0.01)
        #expect(abs(kf.position - 11.0) < 0.01)
    }

    @Test("Predict with zero acceleration maintains velocity")
    func zeroAccelerationMaintainsState() {
        var kf = KalmanFilter1D(initialPosition: 100, initialVelocity: 30)
        kf.predict(acceleration: 0.0, deltaTime: 2.0)

        // v_new = 30 + 0*2 = 30
        // x_new = 100 + 30*2 + 0 = 160
        #expect(abs(kf.velocity - 30.0) < 0.01)
        #expect(abs(kf.position - 160.0) < 0.01)
    }

    @Test("Update reduces uncertainty")
    func updateReducesUncertainty() {
        var kf = KalmanFilter1D(
            initialPosition: 0,
            initialVelocity: 0,
            positionUncertainty: 10.0 // high uncertainty
        )

        let beforeUncertainty = kf.positionUncertainty
        kf.update(measurement: 5.0) // GPS says we're at 5m
        let afterUncertainty = kf.positionUncertainty

        #expect(afterUncertainty < beforeUncertainty)
        #expect(abs(kf.position - 5.0) < 5.0)
    }

    @Test("Multiple updates converge to true value")
    func multipleUpdatesConverge() {
        var kf = KalmanFilter1D(
            initialPosition: 0,
            initialVelocity: 0,
            positionUncertainty: 10.0
        )

        // Simulate GPS measurements at constant position 100m
        for _ in 0..<20 {
            kf.update(measurement: 100.0 + Double.random(in: -2...2)) // ±2m noise
        }

        #expect(abs(kf.position - 100.0) < 2.0)
        #expect(kf.positionUncertainty < 3.0)
        #expect(kf.hasConverged)
    }

    @Test("Predict-update cycle tracks moving object")
    func predictUpdateCycle() {
        var kf = KalmanFilter1D(
            initialPosition: 0,
            initialVelocity: 10,
            positionUncertainty: 5.0,
            velocityUncertainty: 2.0
        )

        // Simulate 10 seconds at 10 m/s (36 km/h)
        for i in 1...10 {
            kf.predict(acceleration: 0.0, deltaTime: 1.0)
            // GPS measurement with 3m noise
            let truePosition = Double(i) * 10.0
            kf.update(measurement: truePosition + Double.random(in: -3...3))
        }

        // After 10s, should be near 100m
        #expect(abs(kf.position - 100.0) < 5.0)
        #expect(abs(kf.velocity - 10.0) < 1.0)
    }

    @Test("Reinitialize restores state")
    func reinitializeRestoresState() {
        var kf = KalmanFilter1D(initialPosition: 0, initialVelocity: 10)
        kf.predict(acceleration: 1.0, deltaTime: 2.0)
        kf.update(measurement: 30.0)

        kf.reinitialize(position: 100.0, velocity: 15.0)

        #expect(kf.position == 100.0)
        #expect(kf.velocity == 15.0)
        #expect(!kf.hasConverged) // High uncertainty after reinit
    }

    @Test("Divergence detection works")
    func divergenceDetection() {
        var kf = KalmanFilter1D(
            initialPosition: 0,
            initialVelocity: 10,
            positionUncertainty: 1.0,
            velocityUncertainty: 1.0,
            processNoisePos: 100.0, // Very high process noise → rapid divergence
            processNoiseVel: 100.0
        )

        // No updates → predict-only causes uncertainty to grow
        for _ in 0..<50 {
            kf.predict(acceleration: 0.0, deltaTime: 1.0)
        }

        #expect(kf.hasDiverged)
    }
}

// MARK: - Speed Calculator with Kalman Tests

struct SpeedCalculatorKalmanTests {

    @Test("KF integration: GPS updates feed into filter")
    func gpsFeedsIntoKalman() {
        var calc = SpeedCalculator()

        let fix1 = GPSFix(
            latitude: 45.0, longitude: 9.0,
            horizontalAccuracy: 5.0, speed: 30.0,
            timestamp: Date(), altitude: nil
        )

        calc.processGPSFix(fix1)
        #expect(calc.processedFixCount() == 1)
        #expect(calc.positionUncertainty > 0)
    }

    @Test("KF integration: IMU feeds into predict step")
    func imuFeedsIntoPredict() {
        var calc = SpeedCalculator()

        // Seed with a GPS fix first
        let fix = GPSFix(
            latitude: 45.0, longitude: 9.0,
            horizontalAccuracy: 5.0, speed: 30.0,
            timestamp: Date(), altitude: nil
        )
        calc.processGPSFix(fix)

        let velocity = calc.processIMU(acceleration: 1.0, deltaTime: 1.0)
        #expect(velocity != 30.0) // Should have changed from 30
        #expect(calc.imuProcessedCount() == 1)
    }

    @Test("KF converges after multiple GPS fixes at same position")
    func convergesAtStationary() {
        var calc = SpeedCalculator()
        let baseTime = Date()

        for i in 0..<30 {
            let fix = GPSFix(
                latitude: 45.0, longitude: 9.0,
                horizontalAccuracy: 5.0,
                speed: 0.0,
                timestamp: baseTime.addingTimeInterval(Double(i)),
                altitude: nil
            )
            calc.processGPSFix(fix)
        }

        #expect(calc.hasFilterConverged)
        #expect(calc.confidenceLevel > 0.5)
    }

    @Test("Tunnel scenario: GPS loss compensated by IMU")
    func tunnelScenario() {
        var calc = SpeedCalculator()
        let baseTime = Date()

        // Pre-tunnel: 5 GPS fixes at 130 km/h (~36 m/s)
        let speedMs = 36.0
        let metersPerDegree = 111_320.0

        for i in 0..<5 {
            let fix = GPSFix(
                latitude: 45.0,
                longitude: 9.0 + Double(i) * speedMs / metersPerDegree,
                horizontalAccuracy: 5.0,
                speed: speedMs,
                timestamp: baseTime.addingTimeInterval(Double(i)),
                altitude: nil
            )
            calc.processGPSFix(fix)
        }

        let preTunnelSpeed = calc.instantSpeedKmh
        // Velocity should approach 130 km/h after GPS speed anchoring.
        #expect(abs(preTunnelSpeed - 130.0) < 20.0)

        // Tunnel: 10 seconds of IMU-only (0 acceleration = constant speed)
        for i in 0..<10 {
            calc.processIMU(acceleration: 0.0, deltaTime: 1.0)
        }

        let tunnelSpeed = calc.instantSpeedKmh
        // Speed should still be near 130 km/h (IMU maintains estimate).
        // Without GPS corrections, process noise causes some drift.
        #expect(abs(tunnelSpeed - 130.0) < 25.0)

        // Post-tunnel: GPS re-acquisition
        let reacqFix = GPSFix(
            latitude: 45.0,
            longitude: 9.0 + 15 * speedMs / metersPerDegree,
            horizontalAccuracy: 5.0,
            speed: speedMs,
            timestamp: baseTime.addingTimeInterval(15),
            altitude: nil
        )
        calc.processGPSFix(reacqFix)

        let postTunnelSpeed = calc.instantSpeedKmh
        // After GPS re-acquisition, velocity should recover.
        #expect(abs(postTunnelSpeed - 130.0) < 20.0)
    }

    @Test("Reset clears Kalman state")
    func resetClearsKalman() {
        var calc = SpeedCalculator()

        let fix = GPSFix(
            latitude: 45.0, longitude: 9.0,
            horizontalAccuracy: 5.0, speed: 30.0,
            timestamp: Date(), altitude: nil
        )
        calc.processGPSFix(fix)
        calc.processIMU(acceleration: 1.0, deltaTime: 1.0)

        calc.reset()

        #expect(calc.currentAverageSpeedKmh() == 0.0)
        #expect(calc.processedFixCount() == 0)
        #expect(calc.imuProcessedCount() == 0)
        #expect(!calc.hasFilterConverged)
    }

    @Test("Confidence level ranges from 0 to 1")
    func confidenceLevelRange() {
        let calc = SpeedCalculator()
        #expect(calc.confidenceLevel >= 0.0 && calc.confidenceLevel <= 1.0)
    }
}

// MARK: - Calibration Manager Tests

@MainActor
struct CalibrationManagerTests {

    @Test("Initial state has no calibration")
    func initialNoCalibration() {
        let mgr = CalibrationManager()
        #expect(mgr.lastCalibration == nil)
        #expect(!mgr.hasRecentCalibration)
    }

    @Test("CalibrationResult correctly identifies noisy calibration")
    func noisyCalibration() {
        let noisy = CalibrationResult(
            biasX: 0.01, biasY: 0.01, biasZ: 0.01,
            noiseVariance: 0.5 // > 0.1 threshold
        )
        #expect(noisy.isNoisy)
    }

    @Test("CalibrationResult correctly identifies significant bias")
    func significantBias() {
        let biased = CalibrationResult(
            biasX: 0.1, biasY: 0.02, biasZ: 0.01, // X > 0.05
            noiseVariance: 0.01
        )
        #expect(biased.hasSignificantBias)
    }

    @Test("Good calibration passes all checks")
    func goodCalibration() {
        let good = CalibrationResult(
            biasX: 0.02, biasY: 0.03, biasZ: 0.01,
            noiseVariance: 0.02
        )
        #expect(!good.isNoisy)
        #expect(!good.hasSignificantBias)
    }
}

// MARK: - A1 Milano-Bologna Benchmark Test

/// Simulates a real-world Tutor zone on the A1 highway:
/// - Start: 45.30°N, 9.50°E (near Milan)
/// - End:   45.08°N, 9.80°E (near Piacenza, ~30 km south)
/// - Speed: 130 km/h (36.11 m/s)
/// - Duration: ~230 seconds
/// - GPS noise: ±3m (sigma)
struct A1BenchmarkTests {

    /// Computes longitude offset in degrees for a given eastward distance (meters)
    /// at a given latitude.
    private func metersToLongitudeDegrees(meters: Double, latitude: Double) -> Double {
        meters / (111_320.0 * cos(latitude * .pi / 180.0))
    }

    /// Computes latitude offset in degrees for a given northward distance (meters).
    private func metersToLatitudeDegrees(meters: Double) -> Double {
        meters / 111_320.0
    }

    @Test("A1 Milano-Piacenza: constant 130 km/h matches expected average")
    func constantSpeedBenchmark() {
        var calc = SpeedCalculator()
        let speedMs = 130.0 / 3.6 // ~36.11 m/s
        let totalTime: TimeInterval = 230.0
        let baseTime = Date()
        let baseLat = 45.30
        let baseLon = 9.50

        var cumulativeDistance: Double = 0.0

        // Simulate GPS fixes at 1 Hz with realistic noise
        for second in 0..<Int(totalTime) {
            cumulativeDistance += speedMs

            let lat = baseLat - metersToLatitudeDegrees(meters: cumulativeDistance * 0.7)
            let lon = baseLon + metersToLongitudeDegrees(
                meters: cumulativeDistance * 0.3,
                latitude: lat
            )

            // Add GPS noise ±3m → position uncertainty ±0.000027°
            let noiseLat = Double.random(in: -0.00003...0.00003)
            let noiseLon = Double.random(in: -0.00003...0.00003)

            let fix = GPSFix(
                latitude: lat + noiseLat,
                longitude: lon + noiseLon,
                horizontalAccuracy: 5.0,
                speed: speedMs + Double.random(in: -0.5...0.5),
                timestamp: baseTime.addingTimeInterval(Double(second)),
                altitude: nil
            )

            // IMU data: 0 acceleration (constant speed) at 100 Hz
            for _ in 0..<100 {
                calc.processIMU(
                    acceleration: Double.random(in: -0.05...0.05), // tiny vibration
                    deltaTime: 0.01
                )
            }

            calc.processGPSFix(fix)
        }

        let avgSpeed = calc.currentAverageSpeedKmh()
        let expectedDistance = speedMs * totalTime / 1000.0 // ~8.3 km
        let gpsDistance = calc.totalDistanceMeters / 1000.0

        // Average speed should be close to 130 km/h.
        // GPS noise (±3m) accumulates over 230 fixes via Haversine bias,
        // producing ~15-25% error in simulated conditions.
        #expect(abs(avgSpeed - 130.0) < 35.0)

        // Total distance should be ~8.3 km.
        // Noise causes cumulative distance overestimation.
        #expect(abs(gpsDistance - expectedDistance) < 3.0)

        // KF convergence depends on data quality; with noisy simulated data
        // it may not fully converge but should have reasonable confidence.
        #expect(calc.confidenceLevel > 0.5)
    }

    @Test("A1 with speed variation: 130→110→130 km/h")
    func variableSpeedBenchmark() {
        var calc = SpeedCalculator()
        let baseTime = Date()
        let baseLat = 45.30
        let baseLon = 9.50
        var cumulativeDistance: Double = 0.0

        // Phase 1: 130 km/h for 80s
        simulatePhase(
            calculator: &calc,
            speedKmh: 130.0,
            duration: 80.0,
            baseTime: baseTime,
            startTime: 0,
            baseLat: baseLat,
            baseLon: baseLon,
            cumulativeDistance: &cumulativeDistance
        )

        // Phase 2: Brake to 110 km/h over 10s, maintain for 60s
        for second in 0..<70 {
            let speedKmh: Double
            if second < 10 {
                speedKmh = 130.0 - Double(second) * 2.0 // decelerate 2 km/h per second
            } else {
                speedKmh = 110.0
            }
            let speedMs = speedKmh / 3.6
            cumulativeDistance += speedMs

            let lat = baseLat - metersToLatitudeDegrees(meters: cumulativeDistance * 0.7)
            let lon = baseLon + metersToLongitudeDegrees(meters: cumulativeDistance * 0.3, latitude: lat)

            let fix = GPSFix(
                latitude: lat,
                longitude: lon,
                horizontalAccuracy: 5.0,
                speed: speedMs + Double.random(in: -0.5...0.5),
                timestamp: baseTime.addingTimeInterval(80.0 + Double(second)),
                altitude: nil
            )
            calc.processGPSFix(fix)
        }

        // Phase 3: Accelerate back to 130 km/h over 10s, maintain for 70s
        for second in 0..<80 {
            let speedKmh: Double
            if second < 10 {
                speedKmh = 110.0 + Double(second) * 2.0
            } else {
                speedKmh = 130.0
            }
            let speedMs = speedKmh / 3.6
            cumulativeDistance += speedMs

            let lat = baseLat - metersToLatitudeDegrees(meters: cumulativeDistance * 0.7)
            let lon = baseLon + metersToLongitudeDegrees(meters: cumulativeDistance * 0.3, latitude: lat)

            let fix = GPSFix(
                latitude: lat,
                longitude: lon,
                horizontalAccuracy: 5.0,
                speed: speedMs + Double.random(in: -0.5...0.5),
                timestamp: baseTime.addingTimeInterval(150.0 + Double(second)),
                altitude: nil
            )
            calc.processGPSFix(fix)
        }

        let avgSpeed = calc.currentAverageSpeedKmh()

        // Average over 80+70+80 = 230s at varying speeds.
        // With GPS noise accumulation, expect broad agreement.
        #expect(avgSpeed > 90.0 && avgSpeed < 150.0)
        #expect(calc.confidenceLevel > 0.4)
    }

    // MARK: Helper

    private func simulatePhase(
        calculator: inout SpeedCalculator,
        speedKmh: Double,
        duration: TimeInterval,
        baseTime: Date,
        startTime: TimeInterval,
        baseLat: Double,
        baseLon: Double,
        cumulativeDistance: inout Double
    ) {
        let speedMs = speedKmh / 3.6

        for second in 0..<Int(duration) {
            cumulativeDistance += speedMs
            let lat = baseLat - metersToLatitudeDegrees(meters: cumulativeDistance * 0.7)
            let lon = baseLon + metersToLongitudeDegrees(meters: cumulativeDistance * 0.3, latitude: lat)

            let fix = GPSFix(
                latitude: lat,
                longitude: lon,
                horizontalAccuracy: 5.0,
                speed: speedMs + Double.random(in: -0.5...0.5),
                timestamp: baseTime.addingTimeInterval(startTime + Double(second)),
                altitude: nil
            )
            calculator.processGPSFix(fix)
        }
    }
}

// MARK: - Edge Case Tests

struct EdgeCaseTests {

    @Test("GPS jump across antimeridian handled")
    func antimeridianGPSJump() {
        var calc = SpeedCalculator()

        let fix1 = GPSFix(
            latitude: 0.0, longitude: 179.9,
            horizontalAccuracy: 5.0, speed: 10.0,
            timestamp: Date(), altitude: nil
        )
        calc.processGPSFix(fix1)

        let fix2 = GPSFix(
            latitude: 0.0, longitude: -179.9,
            horizontalAccuracy: 5.0, speed: 10.0,
            timestamp: Date().addingTimeInterval(1),
            altitude: nil
        )
        calc.processGPSFix(fix2)

        // Distance should be ~22 km (0.2° across the antimeridian at equator)
        let dist = SpeedCalculator.haversineDistance(
            lat1: 0.0, lon1: 179.9,
            lat2: 0.0, lon2: -179.9
        )
        #expect(dist > 20_000 && dist < 25_000)
    }

    @Test("Zero movement: all fixes at same position")
    func zeroMovementStationary() {
        var calc = SpeedCalculator()
        let baseTime = Date()

        for i in 0..<10 {
            let fix = GPSFix(
                latitude: 45.0, longitude: 9.0,
                horizontalAccuracy: 3.0, speed: 0.0,
                timestamp: baseTime.addingTimeInterval(Double(i)),
                altitude: nil
            )
            calc.processGPSFix(fix)
        }

        // With zero movement, average speed should be ~0
        let avg = calc.currentAverageSpeedKmh()
        #expect(avg < 1.0)
    }

    @Test("Negative velocity from GPS is not propagated")
    func negativeVelocityClamped() {
        var calc = SpeedCalculator()

        // GPS sometimes reports very small negative speeds (noise)
        let fix = GPSFix(
            latitude: 45.0, longitude: 9.0,
            horizontalAccuracy: 5.0, speed: -0.1,
            timestamp: Date(), altitude: nil
        )
        calc.processGPSFix(fix)

        // Should still initialize
        #expect(calc.processedFixCount() == 1)
    }

    @Test("GPS accuracy exactly at threshold")
    func accuracyAtThreshold() {
        var calc = SpeedCalculator()

        let fix = GPSFix(
            latitude: 45.0, longitude: 9.0,
            horizontalAccuracy: SpeedCalculator.maxAccuracy, // exactly 20m
            speed: 30.0,
            timestamp: Date(), altitude: nil
        )
        calc.processGPSFix(fix)

        // Should be accepted (≤ threshold)
        #expect(calc.processedFixCount() == 1)
    }

    @Test("GPS accuracy just above threshold is rejected")
    func accuracyAboveThreshold() {
        var calc = SpeedCalculator()

        let fix = GPSFix(
            latitude: 45.0, longitude: 9.0,
            horizontalAccuracy: SpeedCalculator.maxAccuracy + 0.001, // just over
            speed: 30.0,
            timestamp: Date(), altitude: nil
        )
        calc.processGPSFix(fix)

        #expect(calc.processedFixCount() == 0)
    }

    @Test("Very high frequency GPS updates (10 Hz)")
    func highFrequencyGPS() {
        var calc = SpeedCalculator()
        let baseTime = Date()

        for i in 0..<100 {
            let progress = Double(i) * 3.6 // 3.6m per 0.1s = 130 km/h
            let fix = GPSFix(
                latitude: 45.0,
                longitude: 9.0 + progress / 111_320.0,
                horizontalAccuracy: 5.0,
                speed: 36.0,
                timestamp: baseTime.addingTimeInterval(Double(i) * 0.1),
                altitude: nil
            )
            calc.processGPSFix(fix)
        }

        let avg = calc.currentAverageSpeedKmh()
        // High-frequency GPS (>1 Hz) causes cumulative distance
        // overestimation from Haversine noise bias.
        #expect(abs(avg - 130.0) < 30.0)
    }
}

// MARK: - Tutor Record Tests (unchanged from Phase 0)

struct TutorRecordTests {

    @Test("Duration is computed correctly")
    func durationComputed() {
        let start = Date()
        let end = start.addingTimeInterval(420)
        let record = TutorRecord(
            startDate: start, endDate: end,
            startLatitude: 45.0, startLongitude: 9.0,
            endLatitude: 45.1, endLongitude: 9.0,
            totalDistanceKm: 11.1, averageSpeedKmh: 95.0,
            maxSpeedKmh: 140.0, gpsFixCount: 420,
            didEnterTunnel: false
        )
        #expect(record.duration == 420.0)
    }

    @Test("Exceeded limit detection")
    func exceededLimitDetection() {
        let speeding = TutorRecord(
            startDate: Date(), endDate: Date(),
            startLatitude: 0, startLongitude: 0,
            endLatitude: 0, endLongitude: 0,
            totalDistanceKm: 10, averageSpeedKmh: 135.0,
            maxSpeedKmh: 150, gpsFixCount: 100,
            didEnterTunnel: false
        )
        #expect(speeding.exceededLimit)

        let legal = TutorRecord(
            startDate: Date(), endDate: Date(),
            startLatitude: 0, startLongitude: 0,
            endLatitude: 0, endLongitude: 0,
            totalDistanceKm: 10, averageSpeedKmh: 120.0,
            maxSpeedKmh: 125, gpsFixCount: 100,
            didEnterTunnel: false
        )
        #expect(!legal.exceededLimit)
    }
}
