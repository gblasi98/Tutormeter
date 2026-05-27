import Testing
import Foundation
@testable import Velox

// MARK: - VeloxActivityContentState Tests

struct VeloxActivityContentStateTests {

    @Test("Formatted time: zero seconds")
    func formattedTimeZero() {
        let state = VeloxActivityContentState(
            averageSpeedKmh: 0, instantSpeedKmh: 0,
            distanceKm: 0, elapsedSeconds: 0,
            confidence: 0, trackingState: "active",
            isOverLimit: false, isGPSLost: false
        )
        #expect(state.formattedTime == "00:00")
    }

    @Test("Formatted time: minutes and seconds")
    func formattedTimeMinutesSeconds() {
        let state = VeloxActivityContentState(
            averageSpeedKmh: 100, instantSpeedKmh: 110,
            distanceKm: 5.2, elapsedSeconds: 185,
            confidence: 0.9, trackingState: "tracking",
            isOverLimit: false, isGPSLost: false
        )
        #expect(state.formattedTime == "03:05")
    }

    @Test("Formatted time: exactly one hour")
    func formattedTimeOneHour() {
        let state = VeloxActivityContentState(
            averageSpeedKmh: 120, instantSpeedKmh: 120,
            distanceKm: 120, elapsedSeconds: 3600,
            confidence: 1.0, trackingState: "tracking",
            isOverLimit: false, isGPSLost: false
        )
        #expect(state.formattedTime == "60:00")
    }

    @Test("Formatted speed: zero")
    func formattedSpeedZero() {
        let state = VeloxActivityContentState(
            averageSpeedKmh: 0, instantSpeedKmh: 0,
            distanceKm: 0, elapsedSeconds: 0,
            confidence: 0, trackingState: "idle",
            isOverLimit: false, isGPSLost: false
        )
        #expect(state.formattedSpeed == "0 km/h")
    }

    @Test("Formatted speed: highway speed")
    func formattedSpeedHighway() {
        let state = VeloxActivityContentState(
            averageSpeedKmh: 127.3, instantSpeedKmh: 130,
            distanceKm: 10, elapsedSeconds: 283,
            confidence: 0.95, trackingState: "tracking",
            isOverLimit: false, isGPSLost: false
        )
        #expect(state.formattedSpeed == "127 km/h")
    }

    @Test("Over limit flag is set")
    func overLimitFlag() {
        let state = VeloxActivityContentState(
            averageSpeedKmh: 135, instantSpeedKmh: 138,
            distanceKm: 5, elapsedSeconds: 133,
            confidence: 0.9, trackingState: "tracking",
            isOverLimit: true, isGPSLost: false
        )
        #expect(state.isOverLimit)
    }

    @Test("GPS lost flag is set")
    func gpsLostFlag() {
        let state = VeloxActivityContentState(
            averageSpeedKmh: 100, instantSpeedKmh: 0,
            distanceKm: 3, elapsedSeconds: 108,
            confidence: 0.3, trackingState: "gpsLost",
            isOverLimit: false, isGPSLost: true
        )
        #expect(state.isGPSLost)
    }

    @Test("Content state is hashable for diffing")
    func contentStateHashable() {
        let state1 = VeloxActivityContentState(
            averageSpeedKmh: 120, instantSpeedKmh: 120,
            distanceKm: 1, elapsedSeconds: 30,
            confidence: 0.8, trackingState: "tracking",
            isOverLimit: false, isGPSLost: false
        )
        let state2 = VeloxActivityContentState(
            averageSpeedKmh: 120, instantSpeedKmh: 120,
            distanceKm: 1, elapsedSeconds: 30,
            confidence: 0.8, trackingState: "tracking",
            isOverLimit: false, isGPSLost: false
        )
        #expect(state1 == state2)
        #expect(state1.hashValue == state2.hashValue)
    }
}

// MARK: - VeloxActivityAttributes Tests

struct VeloxActivityAttributesTests {

    @Test("Zone type encoding")
    func zoneTypeEncoding() {
        let tutor = VeloxActivityAttributes.ZoneType.tutor
        let autovelox = VeloxActivityAttributes.ZoneType.autovelox
        let unknown = VeloxActivityAttributes.ZoneType.unknown

        #expect(tutor.rawValue == "Tutor")
        #expect(autovelox.rawValue == "Autovelox")
        #expect(unknown.rawValue == "Speed Zone")
    }

    @Test("Attributes with Tutor zone")
    func tutorAttributes() {
        let attrs = VeloxActivityAttributes(
            zoneType: .tutor,
            startLatitude: 45.30,
            startLongitude: 9.50
        )
        #expect(attrs.zoneType == .tutor)
        #expect(attrs.startLatitude == 45.30)
        #expect(attrs.startLongitude == 9.50)
    }
}

// MARK: - Live Activity Manager Unit Tests

struct LiveActivityManagerUnitTests {

    @Test("Initial state has no active activity")
    func initialNoActivity() {
        let mgr = LiveActivityManager()
        #expect(!mgr.isActive)
        #expect(mgr.timeSinceLastUpdate >= 0)
    }

    @Test("Update interval constant is 1 second")
    func updateIntervalConstant() {
        #expect(LiveActivityManager.minUpdateInterval == 1.0)
    }

    @Test("Max activity age is 1 hour")
    func maxActivityAge() {
        #expect(LiveActivityManager.maxActivityAge == 3600.0)
    }
}
