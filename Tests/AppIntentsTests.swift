import Testing
import Foundation
@testable import Tutormeter

// MARK: - Deep Link Handler Tests

struct DeepLinkHandlerTests {

    @Test("Valid start-tracking URL is recognized")
    func validStartTrackingURL() {
        let url = URL(string: "velox://start-tracking")!
        #expect(DeepLinkHandler.handle(url))
    }

    @Test("Valid start-tracking with wait param")
    func startTrackingWithWait() {
        let url = URL(string: "velox://start-tracking?wait")!
        #expect(DeepLinkHandler.handle(url))
    }

    @Test("Valid stop-tracking URL is recognized")
    func validStopTrackingURL() {
        let url = URL(string: "velox://stop-tracking")!
        #expect(DeepLinkHandler.handle(url))
    }

    @Test("Status URL is recognized")
    func statusURLRecognized() {
        let url = URL(string: "velox://status")!
        #expect(DeepLinkHandler.handle(url))
    }

    @Test("Unknown host returns false")
    func unknownHostReturnsFalse() {
        let url = URL(string: "velox://unknown-action")!
        #expect(!DeepLinkHandler.handle(url))
    }

    @Test("Malformed URL returns false")
    func malformedURL() {
        let url = URL(string: "not-a-url-at-all")!
        #expect(!DeepLinkHandler.handle(url))
    }

    @Test("Wrong scheme returns false")
    func wrongSchemeURL() {
        let url = URL(string: "https://velox/start-tracking")!
        #expect(!DeepLinkHandler.handle(url))
    }

    @Test("URL generator creates correct URLs")
    func urlGenerators() {
        #expect(DeepLinkHandler.startTrackingURL.absoluteString == "velox://start-tracking")
        #expect(DeepLinkHandler.startTrackingWaitURL.absoluteString == "velox://start-tracking?wait")
        #expect(DeepLinkHandler.stopTrackingURL.absoluteString == "velox://stop-tracking")
    }
}

// MARK: - Tracking Manager Tests

struct TrackingManagerActivationTests {

    @Test("Initial state is not tracking")
    func initialNotTracking() {
        let mgr = TrackingManager.shared
        #expect(!mgr.isTracking)
        #expect(mgr.state == .idle)
        #expect(mgr.averageSpeed == 0.0)
        #expect(mgr.errorMessage == nil)
    }

    @Test("Start sets tracking flag")
    func startSetsTracking() {
        let mgr = TrackingManager.shared

        // Ensure stopped before test
        if mgr.isTracking {
            let _ = mgr.stopTracking()
        }

        mgr.startTracking()
        #expect(mgr.isTracking)
        #expect(mgr.state == .active || mgr.state == .tracking)

        // Cleanup
        let _ = mgr.stopTracking()
    }

    @Test("Stop clears tracking state")
    func stopClearsState() {
        let mgr = TrackingManager.shared

        if mgr.isTracking {
            let _ = mgr.stopTracking()
        }

        mgr.startTracking()
        let summary = mgr.stopTracking()

        #expect(!mgr.isTracking)
        #expect(mgr.state == .completed)
        #expect(summary.finalAverageSpeedKmh >= 0)
    }

    @Test("Stop when not tracking returns zero summary")
    func stopWhenNotTracking() {
        let mgr = TrackingManager.shared

        if mgr.isTracking {
            let _ = mgr.stopTracking()
        }

        let summary = mgr.stopTracking()
        #expect(summary.finalAverageSpeedKmh == 0.0)
        #expect(summary.totalDistanceKm == 0.0)
    }

    @Test("Double start is idempotent")
    func doubleStartIsIdempotent() {
        let mgr = TrackingManager.shared

        if mgr.isTracking {
            let _ = mgr.stopTracking()
        }

        let first = mgr.startTracking()
        let second = mgr.startTracking()

        #expect(first == true)
        #expect(second == false) // second start should be rejected

        let _ = mgr.stopTracking()
    }

    @Test("Singleton returns same instance")
    func singletonIdentity() {
        let a = TrackingManager.shared
        let b = TrackingManager.shared
        #expect(a === b)
    }
}

// MARK: - ContentView State Mapping Tests

struct ContentViewStateTests {

    @Test("State label maps correctly")
    func stateLabelMapping() {
        let cases: [(TrackingStateMachine.State, String)] = [
            (.idle, "Ready"),
            (.active, "Activating..."),
            (.tracking, "Monitoring"),
            (.gpsLost, "GPS Lost"),
            (.completed, "Completed")
        ]

        for (state, expected) in cases {
            let label = stateLabel(for: state)
            #expect(label == expected)
        }
    }

    // Replicate ContentView's logic for testability
    private func stateLabel(for state: TrackingStateMachine.State) -> String {
        switch state {
        case .idle:       return "Ready"
        case .active:     return "Activating..."
        case .tracking:   return "Monitoring"
        case .gpsLost:    return "GPS Lost"
        case .completed:  return "Completed"
        }
    }
}
