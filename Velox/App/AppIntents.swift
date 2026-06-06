import Foundation
import AppIntents
import UIKit

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
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        // Open the app via URL scheme instead of openAppWhenRun
        // to avoid the system-level crash on Siri launch.
        if let url = URL(string: "tutormeter://start-tracking") {
            await UIApplication.shared.open(url)
        }
        return .result(dialog: "OK")
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
    private var stateMachine: TrackingStateMachine

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

        let tracker = LocationTracker()
        guard CLLocationManager.locationServicesEnabled() else {
            errorMessage = "Location services are disabled. Enable them in Settings."
            return false
        }

        errorMessage = nil

        if stateMachine.currentState == .completed {
            stateMachine.reset()
        }

        isTracking = true
        stateMachine.start()
        state = stateMachine.currentState

        self.locationTracker = tracker

        // SAFE MODE: start GPS only. IMU, calibration, and LiveActivity
        // are disabled until we confirm the crash source.
        tracker.startTracking(
            onFix: { [weak self] fix in
                guard fix.latitude.isFinite, fix.longitude.isFinite,
                      fix.horizontalAccuracy.isFinite, fix.speed.isFinite else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let avgSpeed = self.locationTracker?.calculator.currentAverageSpeedKmh() ?? 0
                    let instSpeed = self.locationTracker?.calculator.instantSpeedKmh ?? 0
                    let conf = self.locationTracker?.calculator.confidenceLevel ?? 0
                    guard avgSpeed.isFinite, instSpeed.isFinite, conf.isFinite else { return }
                    self.averageSpeed = avgSpeed
                    self.instantSpeed = instSpeed
                    self.confidence = conf
                    self.state = self.stateMachine.currentState
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

        stateMachine.gpsLockAcquired()
        state = stateMachine.currentState

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
        // (setupTask removed in safe mode — no async work to cancel)

        isTracking = false
        stateMachine.complete()
        state = stateMachine.currentState

        let calc = locationTracker?.calculator
        locationTracker?.stopTracking()
        locationTracker = nil

        let finalSpeed = calc?.currentAverageSpeedKmh() ?? 0
        let finalDistance = (calc?.totalDistanceMeters ?? 0) / 1000
        let finalDuration = calc?.elapsedTime() ?? 0

        let summary = StopSummary(
            finalAverageSpeedKmh: finalSpeed,
            totalDistanceKm: finalDistance,
            durationSeconds: finalDuration,
            stateSummary: stateMachine.generateSummary()
        )

        averageSpeed = 0
        instantSpeed = 0
        confidence = 0

        return summary
    }

    private func handleError(_ error: LocationError) {
        errorMessage = error.localizedMessage
        if !error.isRecoverable {
            stopTracking()
        }
    }

    // MARK: - Background Task Hooks (safe mode stubs)

    /// Time elapsed in the current state-machine state (seconds).
    var stateAge: TimeInterval { stateMachine.timeInCurrentState }
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
