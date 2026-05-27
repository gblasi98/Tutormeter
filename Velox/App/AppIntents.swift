import Foundation
import AppIntents

// MARK: - Start Tracking Intent

/// Siri Shortcut to start Velox speed monitoring.
///
/// Usage via Siri:
/// - "Hey Siri, start Velox tracking"
/// - "Avvia il monitoraggio Velox"
///
/// Usage via Shortcuts app:
/// - Add "Avvia Monitoraggio Tutor" action to any shortcut
/// - Can be triggered by CarPlay connection automation
struct StartTrackingIntent: AppIntent {
    static var title: LocalizedStringResource = "Avvia Monitoraggio Tutor"
    static var description = IntentDescription(
        "Starts monitoring your average speed in speed camera zones.",
        categoryName: "Navigation"
    )
    static var openAppWhenRun: Bool = true

    /// Optional parameter: whether to start immediately or wait for Tutor detection.
    @Parameter(
        title: "Avvio immediato",
        description: "Se attivato, il monitoraggio parte subito. Altrimenti attende il rilevamento di un Tutor.",
        default: true
    )
    var immediateStart: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        let manager = TrackingManager.shared

        guard !manager.isTracking else {
            return .result(
                dialog: "Velox is already monitoring your speed."
            )
        }

        manager.startTracking()

        if immediateStart {
            return .result(
                dialog: "Velox monitoring started. Your average speed will appear in the Dynamic Island."
            )
        } else {
            return .result(
                dialog: "Velox is ready. Monitoring will begin when a speed camera zone is detected."
            )
        }
    }
}

// MARK: - Stop Tracking Intent

/// Siri Shortcut to stop Velox speed monitoring.
struct StopTrackingIntent: AppIntent {
    static var title: LocalizedStringResource = "Ferma Monitoraggio Tutor"
    static var description = IntentDescription(
        "Stops speed monitoring and saves the session summary.",
        categoryName: "Navigation"
    )
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        let manager = TrackingManager.shared

        guard manager.isTracking else {
            return .result(
                dialog: "Velox is not currently monitoring."
            )
        }

        let summary = manager.stopTracking()
        let avgSpeed = Int(summary.finalAverageSpeedKmh)

        return .result(
            dialog: "Monitoring stopped. Your average speed was \(avgSpeed) kilometers per hour."
        )
    }
}

// MARK: - Get Status Intent

/// Siri Shortcut to query current tracking status.
struct GetVeloxStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Stato Velox"
    static var description = IntentDescription(
        "Reports your current tracking status and average speed.",
        categoryName: "Navigation"
    )
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        let manager = TrackingManager.shared

        if manager.isTracking {
            let speed = Int(manager.averageSpeed)
            return .result(
                dialog: "Velox is tracking. Current average speed: \(speed) kilometers per hour."
            )
        } else {
            return .result(
                dialog: "Velox is idle. Say 'Avvia monitoraggio Tutor' to start."
            )
        }
    }
}

// MARK: - App Shortcuts Provider

/// Registers the available Siri Shortcuts and App Intents for
/// the Shortcuts app and Siri voice commands.
struct VeloxAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartTrackingIntent(),
            phrases: [
                "Start Velox tracking",
                "Avvia monitoraggio Velox",
                "Avvia monitoraggio Tutor con \(.applicationName)",
                "Start speed monitoring with \(.applicationName)"
            ],
            shortTitle: "Avvia Monitoraggio",
            systemImageName: "speedometer"
        )

        AppShortcut(
            intent: StopTrackingIntent(),
            phrases: [
                "Stop Velox tracking",
                "Ferma monitoraggio Velox",
                "Stop speed monitoring with \(.applicationName)"
            ],
            shortTitle: "Ferma Monitoraggio",
            systemImageName: "stop.circle"
        )

        AppShortcut(
            intent: GetVeloxStatusIntent(),
            phrases: [
                "What's my Velox speed",
                "Qual è la mia velocità media",
                "Velox status",
                "Stato Velox"
            ],
            shortTitle: "Stato Velox",
            systemImageName: "info.circle"
        )
    }
}

// MARK: - Tracking Manager (Phase 3 update)

/// Central coordinator for the tracking lifecycle.
/// Manages location services, sensor fusion, and state machine.
///
/// Updated in Phase 3 with Intent support and session summary.
@Observable
final class TrackingManager {
    static let shared = TrackingManager()

    // Phase 2-4 components
    private var locationTracker: LocationTracker?
    private var imuFilter: IMUFilter?
    private var calibrationMgr: CalibrationManager?
    private var stateMachine: TrackingStateMachine
    private var liveActivityManager: LiveActivityManager?

    private(set) var isTracking = false
    private(set) var averageSpeed: Double = 0.0
    private(set) var instantSpeed: Double = 0.0
    private(set) var confidence: Double = 0.0
    private(set) var state: TrackingStateMachine.State = .idle
    private(set) var authStatus: LocationAuthStatus = .notDetermined
    private(set) var errorMessage: String?

    private init() {
        self.stateMachine = TrackingStateMachine()
        Task {
            await LiveActivityManager().cleanupOrphanedActivities()
        }
    }

    // MARK: - Public API (called from Intents, UI, URL scheme)

    @discardableResult
    func startTracking() -> Bool {
        guard !isTracking else { return false }

        isTracking = true
        stateMachine.start()
        state = stateMachine.currentState
        errorMessage = nil

        let tracker = LocationTracker()
        self.locationTracker = tracker

        let imu = IMUFilter()
        self.imuFilter = imu

        let calib = CalibrationManager()
        self.calibrationMgr = calib

        // Start calibration then begin tracking
        Task {
            if let result = await calib.calibrate(using: imu) {
                tracker.configureFilter(
                    processNoisePos: result.noiseVariance * 0.5,
                    processNoiseVel: result.noiseVariance * 0.8,
                    measurementNoise: result.noiseVariance * 20.0
                )
            }

            tracker.startTracking(
                onFix: { [weak self] fix in
                    self?.handleGPSFix(fix)
                },
                onStatusChange: { [weak self] status in
                    self?.authStatus = status
                },
                onError: { [weak self] error in
                    self?.handleError(error)
                }
            )

            imu.start { [weak self] accel, dt in
                self?.handleIMU(acceleration: accel, deltaTime: dt)
            }

            // Start Live Activity in Dynamic Island
            let liveActivity = LiveActivityManager()
            self.liveActivityManager = liveActivity
            liveActivity.start(
                zoneType: .tutor,
                latitude: tracker.lastLocation?.coordinate.latitude ?? 45.0,
                longitude: tracker.lastLocation?.coordinate.longitude ?? 9.0
            )

            stateMachine.gpsLockAcquired()
            self.state = stateMachine.currentState
        }

        return true
    }

    struct StopSummary {
        let finalAverageSpeedKmh: Double
        let totalDistanceKm: Double
        let durationSeconds: TimeInterval
        let stateSummary: TrackingStateMachine.SessionSummary
    }

    @discardableResult
    func stopTracking() -> StopSummary {
        guard isTracking else {
            return StopSummary(
                finalAverageSpeedKmh: 0,
                totalDistanceKm: 0,
                durationSeconds: 0,
                stateSummary: stateMachine.generateSummary()
            )
        }

        isTracking = false
        stateMachine.complete()
        state = stateMachine.currentState

        locationTracker?.stopTracking()
        imuFilter?.stop()

        let calc = locationTracker?.calculator
        let finalSpeed = calc?.currentAverageSpeedKmh() ?? 0
        let finalDistance = (calc?.totalDistanceMeters ?? 0) / 1000
        let finalDuration = calc?.elapsedTime() ?? 0

        let summary = StopSummary(
            finalAverageSpeedKmh: finalSpeed,
            totalDistanceKm: finalDistance,
            durationSeconds: finalDuration,
            stateSummary: stateMachine.generateSummary()
        )

        // End Live Activity with summary
        liveActivityManager?.end(
            finalSpeedKmh: finalSpeed,
            distanceKm: finalDistance,
            durationSeconds: finalDuration
        )
        liveActivityManager = nil

        averageSpeed = 0
        instantSpeed = 0
        confidence = 0

        return summary
    }

    // MARK: - Internal

    private func handleGPSFix(_ fix: GPSFix) {
        guard let tracker = locationTracker else { return }
        averageSpeed = tracker.calculator.currentAverageSpeedKmh()
        instantSpeed = tracker.calculator.instantSpeedKmh
        confidence = tracker.calculator.confidenceLevel
        state = stateMachine.currentState

        // Auto-evaluate GPS quality
        let lastFixAge = Date().timeIntervalSince(fix.timestamp)
        stateMachine.evaluateGPSQuality(
            hasGPSFix: true,
            timeSinceLastFix: lastFixAge,
            kalmanDiverged: tracker.calculator.hasFilterDiverged
        )
        state = stateMachine.currentState

        // Push Live Activity update
        let isLost = stateMachine.isGPSLost
        liveActivityManager?.update(
            speedKmh: averageSpeed,
            instantKmh: instantSpeed,
            distanceKm: tracker.calculator.totalDistanceMeters / 1000,
            elapsedSeconds: tracker.calculator.elapsedTime(),
            confidence: confidence,
            isGPSLost: isLost
        )
    }

    private func handleIMU(acceleration: Double, deltaTime: TimeInterval) {
        locationTracker?.feedIMU(acceleration: acceleration, deltaTime: deltaTime)
    }

    private func handleError(_ error: LocationError) {
        errorMessage = error.localizedMessage
        if !error.isRecoverable {
            stopTracking()
        }
    }
}

// MARK: - Session Persistence

extension TrackingManager {
    func saveCompletedSession() async {
        guard let calc = locationTracker?.calculator else { return }

        let store = SessionStore()
        store.incrementSessionCount()
        store.addDistanceKm(calc.totalDistanceMeters / 1000)
        store.addTrackingSeconds(calc.elapsedTime())

        // Future: save full TutorRecord to SwiftData
    }
}
