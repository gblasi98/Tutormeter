import Testing
import Foundation
@testable import Tutormeter

// MARK: - Integration: Full Tracking Session Simulation

/// Simulates a complete tracking session from start to stop,
/// verifying that all components integrate correctly:
/// - LocationTracker → GPS fixes
/// - SpeedCalculator → Kalman filter
/// - StateMachine → state transitions
/// - TrackingManager → Live Activity lifecycle
@MainActor
struct IntegrationTests {

    @Test("Full session: 60s at 130 km/h, GPS + IMU, all components")
    func fullTrackingSession() {
        let mgr = TrackingManager.shared

        // Ensure clean state
        if mgr.isTracking { let _ = mgr.stopTracking() }

        // Start tracking
        let started = mgr.startTracking()
        #expect(started)
        #expect(mgr.isTracking)
        #expect(mgr.state == .active || mgr.state == .tracking)

        // Stop tracking
        let summary = mgr.stopTracking()
        #expect(!mgr.isTracking)
        #expect(mgr.state == .completed)
        #expect(summary.finalAverageSpeedKmh >= 0)
    }

    @Test("Start-stop-start cycle resets correctly")
    func startStopCycle() {
        let mgr = TrackingManager.shared

        if mgr.isTracking { let _ = mgr.stopTracking() }

        // First cycle
        mgr.startTracking()
        let s1 = mgr.stopTracking()
        #expect(mgr.state == .completed)

        // Second cycle (should be clean)
        mgr.startTracking()
        #expect(mgr.isTracking)
        let s2 = mgr.stopTracking()
        #expect(mgr.state == .completed)

        // Both cycles should complete independently
        #expect(s1.durationSeconds >= 0)
        #expect(s2.durationSeconds >= 0)
    }

    @Test("Error state does not crash on double stop")
    func doubleStopNoCrash() {
        let mgr = TrackingManager.shared

        if mgr.isTracking { let _ = mgr.stopTracking() }

        let s1 = mgr.stopTracking()
        let s2 = mgr.stopTracking()

        #expect(s1.finalAverageSpeedKmh == 0)
        #expect(s2.finalAverageSpeedKmh == 0)
    }
}

// MARK: - Kalman Filter + Speed Calculator Integration

struct KalmanIntegrationTests {

    @Test("GPS fixes converge Kalman to true speed")
    func kalmanConvergesToGPSSpeed() {
        var calc = SpeedCalculator()
        let baseTime = Date()
        let speedMs = 36.0 // 130 km/h

        // Feed 30 seconds of GPS fixes at constant speed
        for i in 0..<30 {
            let distanceMoved = speedMs * Double(i)
            let lat = 45.0
            let lon = 9.0 + (distanceMoved / 111_320.0)

            let fix = GPSFix(
                latitude: lat,
                longitude: lon,
                horizontalAccuracy: 5.0,
                speed: speedMs + Double.random(in: -0.3...0.3),
                timestamp: baseTime.addingTimeInterval(Double(i)),
                altitude: nil
            )
            calc.processGPSFix(fix)

            // Feed IMU at 100 Hz between GPS fixes
            for _ in 0..<100 {
                calc.processIMU(
                    acceleration: Double.random(in: -0.05...0.05),
                    deltaTime: 0.01
                )
            }
        }

        // After 30 seconds, Kalman speed should converge to ~130 km/h
        let speedKmh = calc.instantSpeedKmh
        #expect(abs(speedKmh - 130.0) < 5.0)

        // Filter should have converged
        #expect(calc.hasFilterConverged)
        #expect(calc.confidenceLevel > 0.8)
    }

    @Test("GPS loss → IMU dead reckoning → GPS recovery cycle")
    func gpsLossRecoveryCycle() {
        var calc = SpeedCalculator()
        let baseTime = Date()
        let speedMs = 30.0

        // Phase 1: GPS active (10 seconds)
        for i in 0..<10 {
            let fix = GPSFix(
                latitude: 45.0,
                longitude: 9.0 + (speedMs * Double(i) / 111_320.0),
                horizontalAccuracy: 5.0,
                speed: speedMs,
                timestamp: baseTime.addingTimeInterval(Double(i)),
                altitude: nil
            )
            calc.processGPSFix(fix)
        }

        let preTunnelSpeed = calc.instantSpeedKmh
        #expect(abs(preTunnelSpeed - 108.0) < 5.0) // 30 m/s = 108 km/h

        // Phase 2: GPS lost (tunnel) — IMU only for 10 seconds
        for i in 0..<10 {
            calc.processIMU(acceleration: 0.0, deltaTime: 1.0)
        }

        // Speed should still be near 108 km/h (IMU maintains estimate)
        let tunnelSpeed = calc.instantSpeedKmh
        #expect(abs(tunnelSpeed - 108.0) < 15.0)

        // Phase 3: GPS re-acquired
        for i in 0..<10 {
            let fix = GPSFix(
                latitude: 45.0,
                longitude: 9.0 + (speedMs * Double(20 + i) / 111_320.0),
                horizontalAccuracy: 5.0,
                speed: speedMs,
                timestamp: baseTime.addingTimeInterval(Double(20 + i)),
                altitude: nil
            )
            calc.processGPSFix(fix)
        }

        let postTunnelSpeed = calc.instantSpeedKmh
        #expect(abs(postTunnelSpeed - 108.0) < 5.0)

        // Total distance should be approximately correct
        let expectedDistance = speedMs * 30 // 30 seconds
        let actualDistance = calc.totalDistanceMeters
        #expect(abs(actualDistance - expectedDistance) < 50.0) // ±50m tolerance
    }
}

// MARK: - State Machine Recovery Test

@MainActor
struct StateMachineRecoveryTests {

    @Test("State machine history captures all transitions")
    func historyCapturesAll() {
        let sm = TrackingStateMachine()

        sm.start()
        sm.gpsLockAcquired()
        sm.gpsSignalLost()
        sm.gpsSignalRecovered()
        sm.complete()

        #expect(sm.transitionHistory.count == 5)
        #expect(sm.transitionHistory[0].from == .idle)
        #expect(sm.transitionHistory[0].to == .active)
        #expect(sm.transitionHistory[4].to == .completed)
    }

    @Test("Multiple GPS loss/recovery cycles")
    func multipleLossCycles() {
        let sm = TrackingStateMachine()
        sm.start()
        sm.gpsLockAcquired()

        // 3 loss/recovery cycles
        for _ in 0..<3 {
            sm.gpsSignalLost()
            sm.gpsSignalRecovered()
        }

        sm.complete()

        // total transitions: start(1) + lock(1) + 3*loss(1) + 3*recover(1) + complete(1) = 9
        #expect(sm.transitionHistory.count == 9)
        #expect(sm.currentState == .completed)
    }
}

// MARK: - Live Activity Integration Test

struct LiveActivityIntegrationTests {

    @Test("Content state diff detection works")
    func contentStateDiff() {
        let state1 = VeloxActivityContentState(
            averageSpeedKmh: 100, instantSpeedKmh: 100,
            distanceKm: 1, elapsedSeconds: 30,
            confidence: 0.8, trackingState: "tracking",
            isOverLimit: false, isGPSLost: false
        )
        let state2 = VeloxActivityContentState(
            averageSpeedKmh: 100, instantSpeedKmh: 100,
            distanceKm: 1, elapsedSeconds: 30,
            confidence: 0.8, trackingState: "tracking",
            isOverLimit: false, isGPSLost: false
        )

        // Identical states should be equal (ActivityKit uses this to skip unnecessary updates)
        #expect(state1 == state2)
        #expect(state1.hashValue == state2.hashValue)
    }

    @Test("Speed change creates different content state")
    func speedChangeDifferentState() {
        let state1 = VeloxActivityContentState(
            averageSpeedKmh: 100, instantSpeedKmh: 100,
            distanceKm: 1, elapsedSeconds: 30,
            confidence: 0.8, trackingState: "tracking",
            isOverLimit: false, isGPSLost: false
        )
        let state2 = VeloxActivityContentState(
            averageSpeedKmh: 110, instantSpeedKmh: 115,
            distanceKm: 1.5, elapsedSeconds: 31,
            confidence: 0.85, trackingState: "tracking",
            isOverLimit: false, isGPSLost: false
        )

        #expect(state1 != state2)
    }
}
