import Foundation
import AppIntents
import CoreLocation

// MARK: - UserDefaults Keys

enum AppIntentsKeys {
    /// Set to `true` by StartTrackingIntent to signal the UI to begin tracking.
    static let shouldStartTracking = "Tutormeter.shouldStartTracking"
}

// MARK: - Start Tracking Intent

/// Siri Shortcut to start Tutormeter speed monitoring.
///
/// Opens the app and signals the ContentView to begin tracking.
/// Does NOT call startTracking() directly — the UI handles it
/// to avoid crashes when launched from the Siri context.
struct StartTrackingIntent: AppIntent {
    static var title: LocalizedStringResource = "Avvia Monitoraggio Tutor"
    static var description = IntentDescription(
        "Starts monitoring your average speed in speed camera zones.",
        categoryName: "Navigation"
    )
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // Just signal the app to start tracking when it opens.
        // The ContentView handles the actual startTracking() call.
        UserDefaults.standard.set(true, forKey: AppIntentsKeys.shouldStartTracking)

        return .result(
            dialog: "Tutormeter si sta avviando. Monitoraggio in corso."
        )
    }
}

// MARK: - Stop Tracking Intent

/// Siri Shortcut to stop Tutormeter speed monitoring.
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
                dialog: "Tutormeter non è in monitoraggio."
            )
        }

        let summary = manager.stopTracking()
        let avgSpeed = Int(summary.finalAverageSpeedKmh)

        return .result(
            dialog: "Monitoraggio fermato. Velocità media: \(avgSpeed) km/h."
        )
    }
}

// MARK: - Get Status Intent

/// Siri Shortcut to query current tracking status.
struct GetTutormeterStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Stato Tutormeter"
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
                dialog: "Tutormeter is tracking. Current average speed: \(speed) kilometers per hour."
            )
        } else {
            return .result(
                dialog: "Tutormeter is idle. Say 'Avvia monitoraggio Tutor' to start."
            )
        }
    }
}

// MARK: - App Shortcuts Provider

/// Registers the available Siri Shortcuts and App Intents for
/// the Shortcuts app and Siri voice commands.
struct TutormeterAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartTrackingIntent(),
            phrases: [
                "Avvia monitoraggio con \(.applicationName)",
                "Avvia \(.applicationName)",
                "Inizia tracciamento con \(.applicationName)",
                "Start tracking with \(.applicationName)"
            ],
            shortTitle: "Avvia Monitoraggio",
            systemImageName: "speedometer"
        )

        AppShortcut(
            intent: StopTrackingIntent(),
            phrases: [
                "Ferma monitoraggio con \(.applicationName)",
                "Ferma \(.applicationName)",
                "Stop tracking with \(.applicationName)"
            ],
            shortTitle: "Ferma Monitoraggio",
            systemImageName: "stop.circle"
        )

        AppShortcut(
            intent: GetTutormeterStatusIntent(),
            phrases: [
                "Qual è la mia velocità con \(.applicationName)",
                "Stato \(.applicationName)",
                "What's my speed with \(.applicationName)"
            ],
            shortTitle: "Stato Tutormeter",
            systemImageName: "info.circle"
        )
    }
}

// MARK: - Tracking Manager (Phase 3 update)

/// Central coordinator for the tracking lifecycle.
/// Manages location services, sensor fusion, and state machine.
///
/// Updated in Phase 3 with Intent support and session summary.
@MainActor
@Observable
final class TrackingManager {
    static let shared = TrackingManager()

    // Phase 2-4 components
    private var locationTracker: LocationTracker?
    private var imuFilter: IMUFilter?
    private var calibrationMgr: CalibrationManager?
    private var stateMachine: TrackingStateMachine
    private var liveActivityManager: LiveActivityManager?

    /// Handle to the async setup Task so we can cancel it on stop.
    private var setupTask: Task<Void, Never>?

    private(set) var isTracking = false
    private(set) var averageSpeed: Double = 0.0
    private(set) var instantSpeed: Double = 0.0
    private(set) var confidence: Double = 0.0
    private(set) var state: TrackingStateMachine.State = .idle
    private(set) var authStatus: LocationAuthStatus = .notDetermined
    private(set) var errorMessage: String?

    private init() {
        self.stateMachine = TrackingStateMachine()
    }

    // MARK: - Public API (called from Intents, UI, URL scheme)

    @discardableResult
    func startTracking() -> Bool {
        guard !isTracking, locationTracker == nil else { return false }

        // Eagerly construct dependencies so we can surface init failures
        // before kicking off the async setup.
        let tracker = LocationTracker()
        guard CLLocationManager.locationServicesEnabled() else {
            errorMessage = "Location services are disabled. Enable them in Settings."
            return false
        }

        errorMessage = nil

        // Reset state machine if coming from a previous completed session.
        if stateMachine.currentState == .completed {
            stateMachine.reset()
        }

        // Set public state immediately so UI and tests see the transition.
        // The state machine moves to .active (awaiting GPS lock), while the
        // actual service wiring happens asynchronously in the Task below.
        isTracking = true
        stateMachine.start()
        state = stateMachine.currentState

        self.locationTracker = tracker
        let imu = IMUFilter()
        self.imuFilter = imu
        let calib = CalibrationManager()
        self.calibrationMgr = calib

        // Wire up services asynchronously. Calibration and GPS lock happen
        // inside this Task; until then the state remains .active.
        setupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.isTracking else { return }

            do {
                if let result = await calib.calibrate(using: imu) {
                    tracker.configureFilter(
                        processNoisePos: result.noiseVariance * 0.5,
                        processNoiseVel: result.noiseVariance * 0.8,
                        measurementNoise: result.noiseVariance * 20.0
                    )
                }

                tracker.startTracking(
                    onFix: { [weak self] fix in
                        guard fix.latitude.isFinite, fix.longitude.isFinite,
                              fix.horizontalAccuracy.isFinite, fix.speed.isFinite else { return }
                        Task { @MainActor [weak self] in
                            self?.handleGPSFix(fix)
                        }
                    },
                    onStatusChange: { [weak self] status in
                        Task { @MainActor [weak self] in
                            self?.authStatus = status
                        }
                    },
                    onError: { [weak self] error in
                        Task { @MainActor [weak self] in
                            self?.handleError(error)
                        }
                    }
                )

                imu.start { [weak self] accel, dt in
                    guard accel.isFinite, dt.isFinite, dt > 0 else { return }
                    Task { @MainActor [weak self] in
                        self?.handleIMU(acceleration: accel, deltaTime: dt)
                    }
                }

                // Start Live Activity in Dynamic Island
                let liveActivity = LiveActivityManager()
                self.liveActivityManager = liveActivity
                liveActivity.start(
                    zoneType: .tutor,
                    latitude: tracker.lastLocation?.coordinate.latitude ?? 45.0,
                    longitude: tracker.lastLocation?.coordinate.longitude ?? 9.0
                )

                // GPS lock acquired — advance to full tracking state.
                self.stateMachine.gpsLockAcquired()
                self.state = self.stateMachine.currentState
            } catch {
                print("[TrackingManager] SetupTask failed: \(error)")
                self.errorMessage = "Errore durante l'avvio del monitoraggio."
                self.stopTracking()
            }
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
        // Idempotent: double-stop is a no-op with a zero summary.
        guard isTracking else {
            print("[TrackingManager] stopTracking ignored: not currently tracking")
            return StopSummary(
                finalAverageSpeedKmh: 0,
                totalDistanceKm: 0,
                durationSeconds: 0,
                stateSummary: stateMachine.generateSummary()
            )
        }

        // Cancel any pending async setup to prevent stale Task
        // from mutating state after stop.
        setupTask?.cancel()
        setupTask = nil

        isTracking = false
        stateMachine.complete()
        state = stateMachine.currentState

        locationTracker?.stopTracking()
        imuFilter?.stop()
        locationTracker = nil
        imuFilter = nil
        calibrationMgr = nil

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

        let avgSpeed = tracker.calculator.currentAverageSpeedKmh()
        let instSpeed = tracker.calculator.instantSpeedKmh
        let conf = tracker.calculator.confidenceLevel

        // Defend against NaN/Inf from Kalman filter divergence
        guard avgSpeed.isFinite, instSpeed.isFinite, conf.isFinite else {
            print("[TrackingManager] NaN detected in GPS fix — resetting calculator")
            tracker.calculator.reset()
            return
        }

        averageSpeed = avgSpeed
        instantSpeed = instSpeed
        confidence = conf
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
        let distance = tracker.calculator.totalDistanceMeters / 1000
        let elapsed = tracker.calculator.elapsedTime()
        guard distance.isFinite, elapsed.isFinite else { return }

        liveActivityManager?.update(
            speedKmh: averageSpeed,
            instantKmh: instantSpeed,
            distanceKm: distance,
            elapsedSeconds: elapsed,
            confidence: confidence,
            isGPSLost: isLost
        )
    }

    private func handleIMU(acceleration: Double, deltaTime: TimeInterval) {
        guard acceleration.isFinite, deltaTime.isFinite, deltaTime > 0 else { return }
        locationTracker?.feedIMU(acceleration: acceleration, deltaTime: deltaTime)
    }

    private func handleError(_ error: LocationError) {
        errorMessage = error.localizedMessage
        if !error.isRecoverable {
            stopTracking()
        }
    }

    // MARK: - Background Task Hooks

    /// Time elapsed in the current state-machine state (seconds).
    /// Used by `BackgroundTaskManager` to decide if a session has gone stale.
    var stateAge: TimeInterval { stateMachine.timeInCurrentState }

    /// Re-push the latest state to the Live Activity (e.g. from a BG refresh).
    func refreshLiveActivity() {
        guard let liveActivity = liveActivityManager,
              let calc = locationTracker?.calculator else { return }
        liveActivity.update(
            speedKmh: averageSpeed,
            instantKmh: instantSpeed,
            distanceKm: calc.totalDistanceMeters / 1000,
            elapsedSeconds: calc.elapsedTime(),
            confidence: confidence,
            isGPSLost: state == .gpsLost
        )
    }

    /// Trims state-machine transition history.
    /// `TrackingStateMachine` already self-trims to 100, this is here as an
    /// explicit hook for `BackgroundTaskManager.performCleanupMaintenance`.
    func compactStateHistory() {
        // The state machine self-compacts on every transition, so this is a
        // no-op today. Kept as a stable API surface for the BG task to call.
        _ = stateMachine.transitionHistory.count
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

        // TODO: SwiftData integration — build a `TutorRecord` from the current
        // session and pass it to `store.saveTutorRecord(_:in:)` together with
        // the app's `ModelContext` (created in `VeloxApp.modelContainer`).
    }
}
