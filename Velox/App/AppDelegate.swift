import UIKit
import BackgroundTasks

// MARK: - App Delegate

/// Application delegate for Tutormeter — handles app lifecycle events:
/// - Background task registration (BGTaskScheduler)
/// - Session recovery on relaunch after termination
/// - State cleanup on termination
///
/// Note: In SwiftUI apps, this is bridged via `UIApplicationDelegateAdaptor`.
final class TutormeterAppDelegate: NSObject, UIApplicationDelegate {
    private let backgroundTaskManager = BackgroundTaskManager()
    private let sessionStore = SessionStore()

    // MARK: - Launch

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        print("[TutormeterAppDelegate] didFinishLaunching")

        // Register background tasks
        backgroundTaskManager.registerTasks()

        // Load Tutor zone database
        TutorZoneManager.shared.loadDatabase()

        // Start idle zone monitoring if auto-start is enabled
        if TutorZoneManager.shared.isAutoStartEnabled {
            TutorZoneManager.shared.startMonitoring()
        }

        // Attempt session recovery
        attemptSessionRecovery()

        return true
    }

    // MARK: - Background / Termination

    func applicationDidEnterBackground(_ application: UIApplication) {
        print("[TutormeterAppDelegate] didEnterBackground")
        saveStateBeforeBackground()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        print("[TutormeterAppDelegate] willTerminate")
        saveStateBeforeBackground()
        TrackingManager.shared.stopTracking()
    }

    // MARK: - Scene Lifecycle

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
    }

    // MARK: - State Persistence

    /// Saves critical state before the app goes to background or terminates.
    private func saveStateBeforeBackground() {
        let manager = TrackingManager.shared

        sessionStore.saveSessionState(
            isTracking: manager.isTracking,
            startTime: manager.isTracking ? Date() : nil
        )

        print("[TutormeterAppDelegate] State saved: tracking=\(manager.isTracking)")
    }

    // MARK: - Recovery

    /// Attempts to recover a session that was interrupted by app termination.
    private func attemptSessionRecovery() {
        let (wasTracking, age, canRecover) = sessionStore.attemptSessionRecovery()

        guard wasTracking else {
            print("[TutormeterAppDelegate] No session to recover")
            return
        }

        print("[TutormeterAppDelegate] Found interrupted session (\(Int(age))s old)")

        if canRecover {
            print("[TutormeterAppDelegate] Session is recent — attempting auto-resume")
            // In Phase 5, we simply log this. Full auto-resume would require
            // re-initializing the LocationTracker, which is a Phase 7 feature.
            // For now, the user can manually restart tracking.
            sessionStore.clearSessionState()
        } else {
            print("[TutormeterAppDelegate] Session too old (\(Int(age))s) — discarding")
            sessionStore.clearSessionState()
        }
    }
}
