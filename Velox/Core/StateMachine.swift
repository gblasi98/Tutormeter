import Foundation

// MARK: - Tracking State Machine

/// Finite state machine for the Tutormeter tracking lifecycle.
///
/// States:
/// ```
/// IDLE ──start()──▶ ACTIVE ──gpsLock──▶ TRACKING ──stop()──▶ COMPLETED
///                     │                    │
///                     │ gpsLost            │ gpsLost
///                     ▼                    ▼
///                  GPS_LOST ◀────────── GPS_LOST
///                     │                    │
///                     │ gpsRecovered       │ gpsRecovered
///                     ▼                    ▼
///                  TRACKING ◀────────── TRACKING
/// ```
///
/// State transitions are atomic and publish notifications for UI binding.
@MainActor
@Observable
final class TrackingStateMachine {
    // MARK: - State

    enum State: String, Equatable, CaseIterable {
        /// Not tracking. Initial state.
        case idle

        /// Tracking requested but awaiting GPS lock or Tutor detection.
        case active

        /// GPS locked and actively computing average speed.
        case tracking

        /// GPS signal lost (tunnel, urban canyon). IMU dead reckoning active.
        case gpsLost

        /// Tracking ended. Summary available.
        case completed
    }

    private(set) var currentState: State = .idle
    private(set) var previousState: State?
    private(set) var stateEnteredAt: Date = Date()

    /// History of state transitions for debugging.
    private(set) var transitionHistory: [Transition] = []

    // MARK: - Transition Record

    struct Transition: CustomStringConvertible {
        let from: State
        let to: State
        let reason: String
        let timestamp: Date

        var description: String {
            "[\(timestamp.formatted(.iso8601))] \(from) → \(to): \(reason)"
        }
    }

    // MARK: - State Queries

    /// Whether the system is in a tracking-capable state.
    var isTrackingActive: Bool {
        currentState == .active || currentState == .tracking || currentState == .gpsLost
    }

    /// Whether GPS is currently lost.
    var isGPSLost: Bool {
        currentState == .gpsLost
    }

    /// Whether a completed session summary is available.
    var hasCompletedSession: Bool {
        currentState == .completed
    }

    /// Time spent in the current state.
    var timeInCurrentState: TimeInterval {
        Date().timeIntervalSince(stateEnteredAt)
    }

    // MARK: - Transitions

    /// Transition to ACTIVE: user initiated tracking.
    func start() {
        transition(to: .active, reason: "User initiated tracking")
    }

    /// Transition to TRACKING: GPS lock acquired, first valid fix received.
    func gpsLockAcquired() {
        guard currentState == .active || currentState == .gpsLost else {
            print("[StateMachine] Ignored gpsLockAcquired in state \(currentState)")
            return
        }
        transition(to: .tracking, reason: "GPS lock acquired")
    }

    /// Transition to GPS_LOST: GPS signal temporarily unavailable.
    func gpsSignalLost() {
        guard currentState == .active || currentState == .tracking else {
            print("[StateMachine] Ignored gpsSignalLost in state \(currentState)")
            return
        }
        transition(to: .gpsLost, reason: "GPS signal lost (tunnel or obstruction)")
    }

    /// Transition back to TRACKING: GPS signal recovered after loss.
    func gpsSignalRecovered() {
        guard currentState == .gpsLost else {
            print("[StateMachine] Ignored gpsSignalRecovered in state \(currentState)")
            return
        }
        transition(to: .tracking, reason: "GPS signal recovered")
    }

    /// Transition to COMPLETED: user stopped tracking or Tutor zone exited.
    func complete() {
        guard isTrackingActive else {
            print("[StateMachine] Ignored complete in state \(currentState)")
            return
        }
        transition(to: .completed, reason: "Tracking completed")
    }

    /// Transition to IDLE: reset after completion or error.
    func reset() {
        transition(to: .idle, reason: "Reset")
    }

    // MARK: - Auto-Transitions (GPS quality-based)

    /// Evaluates whether to change state based on GPS quality metrics.
    /// Called periodically (e.g., every second) by the tracking loop.
    ///
    /// - Parameters:
    ///   - hasGPSFix: Whether recent GPS fixes are arriving.
    ///   - timeSinceLastFix: Seconds since the last valid fix.
    ///   - kalmanDiverged: Whether the Kalman filter has diverged.
    func evaluateGPSQuality(
        hasGPSFix: Bool,
        timeSinceLastFix: TimeInterval,
        kalmanDiverged: Bool
    ) {
        let cfg = TutormeterConfiguration.shared
        switch currentState {
        case .tracking:
            if !hasGPSFix && timeSinceLastFix > cfg.stateMachineGPSLostThresholdSeconds {
                gpsSignalLost()
            }

        case .gpsLost:
            if hasGPSFix && timeSinceLastFix < cfg.stateMachineGPSRecoveryThresholdSeconds {
                gpsSignalRecovered()
            } else if kalmanDiverged {
                // Kalman filter has diverged — GPS must be gone for too long.
                // Stay in gpsLost but the system should alert the user.
            }

        case .active:
            if hasGPSFix {
                gpsLockAcquired()
            }

        case .idle, .completed:
            break // No auto-transitions from these states
        }
    }

    // MARK: - Core Transition Logic

    private func transition(to newState: State, reason: String) {
        guard newState != currentState else { return }

        let record = Transition(
            from: currentState,
            to: newState,
            reason: reason,
            timestamp: Date()
        )

        previousState = currentState
        currentState = newState
        stateEnteredAt = Date()
        transitionHistory.append(record)

        // Trim history to last 100 entries
        if transitionHistory.count > 100 {
            transitionHistory.removeFirst(transitionHistory.count - 100)
        }

        print("[StateMachine] \(record)")
    }

    // MARK: - Session Summary

    /// Generates a summary of the tracking session for the UI.
    struct SessionSummary {
        let startTime: Date
        let endTime: Date
        let totalStates: Int
        let timeInTracking: TimeInterval
        let timeInGPSLost: TimeInterval
        let transitions: [Transition]

        var totalDuration: TimeInterval {
            endTime.timeIntervalSince(startTime)
        }

        var gpsLossPercentage: Double {
            guard totalDuration > 0 else { return 0 }
            return timeInGPSLost / totalDuration * 100
        }
    }

    /// Computes a session summary from the transition history.
    func generateSummary(endTime: Date = Date()) -> SessionSummary {
        var trackingTime: TimeInterval = 0
        var lostTime: TimeInterval = 0

        // Calculate time spent in each state
        for i in 0..<transitionHistory.count {
            let t = transitionHistory[i]
            let nextTime = i + 1 < transitionHistory.count
                ? transitionHistory[i + 1].timestamp
                : endTime
            let duration = nextTime.timeIntervalSince(t.timestamp)

            if t.to == .tracking { trackingTime += duration }
            if t.to == .gpsLost { lostTime += duration }
        }

        return SessionSummary(
            startTime: transitionHistory.first?.timestamp ?? Date(),
            endTime: endTime,
            totalStates: transitionHistory.count,
            timeInTracking: trackingTime,
            timeInGPSLost: lostTime,
            transitions: transitionHistory
        )
    }
}
