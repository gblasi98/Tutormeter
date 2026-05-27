import Testing
import Foundation
@testable import Tutormeter

// MARK: - Background Task Manager Tests

struct BackgroundTaskManagerTests {

    @Test("Task identifiers are correct")
    func taskIdentifiers() {
        #expect(BackgroundTaskManager.refreshTaskID == "com.velox.refresh")
        #expect(BackgroundTaskManager.cleanupTaskID == "com.velox.cleanup")
    }

    @Test("Initial state: not registered, zero refreshes")
    func initialNotRegistered() {
        let mgr = BackgroundTaskManager()
        let summary = mgr.summary()
        #expect(!summary.isRegistered)
        #expect(summary.totalRefreshes == 0)
    }
}

// MARK: - Session Store Tests

struct SessionStoreTests {
    private let store: SessionStore

    init() {
        // Use a dedicated suite to avoid polluting real UserDefaults
        let defaults = UserDefaults(suiteName: "com.velox.tests")!
        defaults.removePersistentDomain(forName: "com.velox.tests")
        self.store = SessionStore(defaults: defaults)
    }

    @Test("Initial state: no saved session")
    func initialNoSavedSession() {
        let (wasTracking, startTime) = store.recoverSessionState()
        #expect(!wasTracking)
        #expect(startTime == nil)
    }

    @Test("Save and recover session state")
    func saveAndRecoverSessionState() {
        let startTime = Date()
        store.saveSessionState(isTracking: true, startTime: startTime)

        let (wasTracking, recoveredStart) = store.recoverSessionState()
        #expect(wasTracking)
        #expect(recoveredStart != nil)
        #expect(abs(recoveredStart!.timeIntervalSince(startTime)) < 1.0)
    }

    @Test("Clear session state removes all data")
    func clearSessionState() {
        store.saveSessionState(isTracking: true, startTime: Date())
        store.clearSessionState()

        let (wasTracking, startTime) = store.recoverSessionState()
        #expect(!wasTracking)
        #expect(startTime == nil)
    }

    @Test("Save and recover calibration")
    func saveAndRecoverCalibration() {
        let cal = CalibrationResult(
            biasX: 0.02, biasY: 0.03, biasZ: 0.01,
            noiseVariance: 0.04
        )
        store.saveCalibration(cal)

        let recovered = store.recoverCalibration()
        #expect(recovered != nil)
        #expect(abs(recovered!.biasX - 0.02) < 0.001)
        #expect(abs(recovered!.biasY - 0.03) < 0.001)
        #expect(abs(recovered!.noiseVariance - 0.04) < 0.001)
    }

    @Test("Recover calibration with no saved data returns nil")
    func recoverCalibrationWithNoData() {
        let recovered = store.recoverCalibration()
        #expect(recovered == nil)
    }

    @Test("Lifetime statistics increment correctly")
    func lifetimeStatistics() {
        store.incrementSessionCount()
        store.incrementSessionCount()
        store.incrementSessionCount()

        store.addDistanceKm(150.5)
        store.addDistanceKm(200.0)

        store.addTrackingSeconds(3600) // 1 hour
        store.addTrackingSeconds(1800) // 30 min

        let stats = store.lifetimeStats()
        #expect(stats.totalSessions == 3)
        #expect(stats.totalDistanceKm == 350.5)
        #expect(abs(stats.totalTrackingHours - 1.5) < 0.01)
    }

    @Test("Lifetime stats formatting")
    func lifetimeStatsFormatting() {
        store.addDistanceKm(1234.5)
        let stats = store.lifetimeStats()
        #expect(stats.formattedDistance == "1235 km")
        // Time formatting: 0h 0m
        #expect(stats.formattedTime.contains("h"))
        #expect(stats.formattedTime.contains("m"))
    }

    @Test("Should recover session: no saved data returns false")
    func shouldRecoverNoSavedData() {
        #expect(!store.shouldRecoverSession())
    }

    @Test("Should recover session: saved active session returns true")
    func shouldRecoverSavedSession() {
        store.saveSessionState(isTracking: true, startTime: Date())
        #expect(store.shouldRecoverSession())
    }

    @Test("Should recover session: saved inactive session returns false")
    func shouldRecoverInactiveSession() {
        store.saveSessionState(isTracking: false, startTime: nil)
        #expect(!store.shouldRecoverSession())
    }

    @Test("Attempt recovery returns correct age")
    func attemptRecoveryAge() {
        let pastTime = Date().addingTimeInterval(-300) // 5 minutes ago
        store.saveSessionState(isTracking: true, startTime: pastTime)

        let (wasTracking, age, canRecover) = store.attemptSessionRecovery()
        #expect(wasTracking)
        #expect(age >= 300) // at least 5 minutes
        #expect(canRecover)
    }
}
