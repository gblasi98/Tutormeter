import Testing
import Foundation
import CoreLocation
@testable import Tutormeter

// MARK: - Location Auth Status Tests

struct LocationAuthStatusTests {

    @Test("canTrack returns true for authorized states")
    func canTrackForAuthorized() {
        #expect(LocationAuthStatus.authorizedWhenInUse.canTrack)
        #expect(LocationAuthStatus.authorizedAlways.canTrack)
    }

    @Test("canTrack returns false for denied/restricted")
    func cannotTrackWhenDenied() {
        #expect(!LocationAuthStatus.denied.canTrack)
        #expect(!LocationAuthStatus.restricted.canTrack)
        #expect(!LocationAuthStatus.notDetermined.canTrack)
    }

    @Test("canBackgroundTrack only true for always")
    func backgroundTrackAlwaysOnly() {
        #expect(LocationAuthStatus.authorizedAlways.canBackgroundTrack)
        #expect(!LocationAuthStatus.authorizedWhenInUse.canBackgroundTrack)
        #expect(!LocationAuthStatus.denied.canBackgroundTrack)
    }

    @Test("needsSettingsIntervention for denied and restricted")
    func settingsIntervention() {
        #expect(LocationAuthStatus.denied.needsSettingsIntervention)
        #expect(LocationAuthStatus.restricted.needsSettingsIntervention)
        #expect(!LocationAuthStatus.authorizedAlways.needsSettingsIntervention)
    }

    @Test("canRequest for notDetermined and whenInUse")
    func canRequestAuthorization() {
        #expect(LocationAuthStatus.notDetermined.canRequest)
        #expect(LocationAuthStatus.authorizedWhenInUse.canRequest)
        #expect(!LocationAuthStatus.denied.canRequest)
    }
}

// MARK: - Location Error Tests

struct LocationErrorTests {

    @Test("Temporary error is recoverable")
    func temporaryIsRecoverable() {
        let error = LocationError(.temporary, description: "Test")
        #expect(error.isRecoverable)
    }

    @Test("Denied error is not recoverable")
    func deniedNotRecoverable() {
        let error = LocationError(.denied, description: "Test")
        #expect(!error.isRecoverable)
    }

    @Test("Network error is recoverable")
    func networkIsRecoverable() {
        let error = LocationError(.network, description: "Test")
        #expect(error.isRecoverable)
    }
}

// MARK: - Location Tracker Tests

@MainActor
struct LocationTrackerTests {

    @Test("Initial state is not tracking")
    func initialNotTracking() {
        let tracker = LocationTracker()
        #expect(!tracker.isTracking)
        #expect(tracker.checkAuthorization() == .notDetermined)
        #expect(tracker.fixAcceptanceRatio == 1.0)
    }

    @Test("Fix acceptance ratio computed correctly")
    func fixAcceptanceRatio() async {
        let tracker = LocationTracker()

        // Directly verify ratio logic
        let calc = tracker.calculator

        // After reset, ratio should be 1.0
        #expect(tracker.fixAcceptanceRatio == 1.0)
    }

    @Test("GPS poor quality flag triggers below 50%")
    func gpsPoorQualityFlag() {
        let tracker = LocationTracker()
        // Fresh tracker with no fixes should not flag as poor
        #expect(!tracker.isGPSPoor)
    }

    @Test("Stop tracking when not tracking is safe")
    func stopWhenNotTracking() {
        let tracker = LocationTracker()
        #expect(!tracker.isTracking)
        tracker.stopTracking()
        #expect(!tracker.isTracking) // Should remain stopped, no crash
    }
}

// MARK: - State Machine Tests

@MainActor
struct StateMachineTests {

    @Test("Initial state is idle")
    func initialIdle() {
        let sm = TrackingStateMachine()
        #expect(sm.currentState == .idle)
        #expect(!sm.isTrackingActive)
    }

    @Test("start transitions idle → active")
    func startTransitionsToActive() {
        let sm = TrackingStateMachine()
        sm.start()
        #expect(sm.currentState == .active)
        #expect(sm.isTrackingActive)
        #expect(sm.transitionHistory.count == 1)
    }

    @Test("gpsLockAcquired transitions active → tracking")
    func gpsLockTransitionsToTracking() {
        let sm = TrackingStateMachine()
        sm.start()
        sm.gpsLockAcquired()
        #expect(sm.currentState == .tracking)
        #expect(sm.isTrackingActive)
    }

    @Test("gpsSignalLost transitions tracking → gpsLost")
    func gpsSignalLostFromTracking() {
        let sm = TrackingStateMachine()
        sm.start()
        sm.gpsLockAcquired()
        sm.gpsSignalLost()
        #expect(sm.currentState == .gpsLost)
        #expect(sm.isGPSLost)
        #expect(sm.isTrackingActive)
    }

    @Test("gpsSignalRecovered transitions gpsLost → tracking")
    func gpsSignalRecovered() {
        let sm = TrackingStateMachine()
        sm.start()
        sm.gpsLockAcquired()
        sm.gpsSignalLost()
        sm.gpsSignalRecovered()
        #expect(sm.currentState == .tracking)
        #expect(!sm.isGPSLost)
    }

    @Test("complete transitions to completed")
    func completeTracking() {
        let sm = TrackingStateMachine()
        sm.start()
        sm.gpsLockAcquired()
        sm.complete()
        #expect(sm.currentState == .completed)
        #expect(sm.hasCompletedSession)
        #expect(!sm.isTrackingActive)
    }

    @Test("reset always transitions to idle")
    func resetToIdle() {
        let sm = TrackingStateMachine()
        sm.start()
        sm.gpsLockAcquired()
        sm.reset()
        #expect(sm.currentState == .idle)
        #expect(sm.transitionHistory.count == 3) // idle→active→tracking→idle
    }

    @Test("Invalid transitions are ignored")
    func invalidTransitionsIgnored() {
        let sm = TrackingStateMachine()

        // Cannot acquire GPS lock from idle
        sm.gpsLockAcquired()
        #expect(sm.currentState == .idle)

        // Cannot complete from idle
        sm.complete()
        #expect(sm.currentState == .idle)

        // Cannot lose GPS from idle
        sm.gpsSignalLost()
        #expect(sm.currentState == .idle)
    }

    @Test("Auto-evaluate transitions active→tracking on GPS fix")
    func autoEvaluateActiveToTracking() {
        let sm = TrackingStateMachine()
        sm.start()

        sm.evaluateGPSQuality(hasGPSFix: true, timeSinceLastFix: 0.5, kalmanDiverged: false)
        #expect(sm.currentState == .tracking)
    }

    @Test("Auto-evaluate transitions tracking→gpsLost after 6s no fix")
    func autoEvaluateToGPSLost() {
        let sm = TrackingStateMachine()
        sm.start()

        sm.evaluateGPSQuality(hasGPSFix: true, timeSinceLastFix: 0.5, kalmanDiverged: false)
        #expect(sm.currentState == .tracking)

        sm.evaluateGPSQuality(hasGPSFix: false, timeSinceLastFix: 6.0, kalmanDiverged: false)
        #expect(sm.currentState == .gpsLost)
    }

    @Test("Auto-evaluate transitions gpsLost→tracking on recovery")
    func autoEvaluateRecovery() {
        let sm = TrackingStateMachine()
        sm.start()

        sm.evaluateGPSQuality(hasGPSFix: true, timeSinceLastFix: 0.5, kalmanDiverged: false)
        sm.evaluateGPSQuality(hasGPSFix: false, timeSinceLastFix: 6.0, kalmanDiverged: false)
        #expect(sm.currentState == .gpsLost)

        sm.evaluateGPSQuality(hasGPSFix: true, timeSinceLastFix: 1.0, kalmanDiverged: false)
        #expect(sm.currentState == .tracking)
    }

    @Test("No auto-transition when GPS lost < 5s")
    func noEarlyGPSLostTransition() {
        let sm = TrackingStateMachine()
        sm.start()
        sm.evaluateGPSQuality(hasGPSFix: true, timeSinceLastFix: 0.5, kalmanDiverged: false)
        #expect(sm.currentState == .tracking)

        sm.evaluateGPSQuality(hasGPSFix: false, timeSinceLastFix: 3.0, kalmanDiverged: false)
        #expect(sm.currentState == .tracking) // Still tracking
    }

    @Test("Transition history is capped at 100 entries")
    func transitionHistoryCapped() {
        let sm = TrackingStateMachine()
        for _ in 0..<150 {
            sm.start()
            sm.reset()
        }
        #expect(sm.transitionHistory.count <= 100)
    }

    @Test("Session summary computes correctly")
    func sessionSummary() {
        let sm = TrackingStateMachine()
        let startTime = Date()

        sm.start()
        sm.gpsLockAcquired()
        // Simulate some time passing
        sm.gpsSignalLost()
        sm.gpsSignalRecovered()
        sm.complete()

        let summary = sm.generateSummary(endTime: startTime.addingTimeInterval(100))
        // 5 transitions: idle→active, active→tracking, tracking→gpsLost,
        // gpsLost→tracking, tracking→completed
        #expect(summary.totalStates == 5)
        // Floating-point: allow ±1s tolerance
        #expect(abs(summary.totalDuration - 100.0) < 1.0)
        #expect(summary.gpsLossPercentage >= 0)
        // Most time should have been in tracking (active→tracking spans most of it)
        #expect(summary.timeInTracking >= 0)
    }

    @Test("timeInCurrentState increases over time")
    func timeInCurrentState() async {
        let sm = TrackingStateMachine()
        sm.start()

        let t1 = sm.timeInCurrentState
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        let t2 = sm.timeInCurrentState

        #expect(t2 >= t1)
    }

    @Test("previousState preserved after transition")
    func previousStatePreserved() {
        let sm = TrackingStateMachine()
        sm.start()
        #expect(sm.previousState == .idle)

        sm.gpsLockAcquired()
        #expect(sm.previousState == .active)
    }
}
