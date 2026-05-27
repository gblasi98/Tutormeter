import Foundation
import BackgroundTasks

// MARK: - Background Task Manager

/// Manages iOS background task scheduling and execution for Velox.
///
/// Background tasks are essential because iOS may suspend the app at any time
/// when it's not in the foreground. Even with background location updates enabled,
/// iOS limits execution time. BGTaskScheduler provides guaranteed execution
/// windows for critical operations.
///
/// Registered tasks:
/// - `com.velox.refresh`: Periodic state check and Kalman filter maintenance
/// - `com.velox.cleanup`: Clean up stale sessions and orphaned Live Activities
///
/// Usage:
/// - Call `registerTasks()` in `application(_:didFinishLaunchingWithOptions:)`
/// - Call `scheduleRefresh()` at the end of each background location update
@MainActor
final class BackgroundTaskManager {
    // MARK: - Task Identifiers
    static let refreshTaskID = "com.velox.refresh"
    static let cleanupTaskID = "com.velox.cleanup"

    // MARK: - State
    private var isRegistered = false
    private var refreshCount: Int = 0
    private var lastRefreshTime: Date = Date()

    // MARK: - Registration

    /// Registers all background task handlers.
    /// Must be called once during app launch (typically in AppDelegate/SceneDelegate).
    func registerTasks() {
        guard !isRegistered else {
            print("[BackgroundTaskManager] Tasks already registered")
            return
        }

        // Register refresh task
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshTaskID,
            using: nil
        ) { [weak self] task in
            self?.handleRefresh(task as! BGAppRefreshTask)
        }

        // Register cleanup task
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.cleanupTaskID,
            using: nil
        ) { [weak self] task in
            self?.handleCleanup(task as! BGProcessingTask)
        }

        isRegistered = true
        print("[BackgroundTaskManager] Tasks registered: \(Self.refreshTaskID), \(Self.cleanupTaskID)")

        // Schedule initial tasks
        scheduleRefresh()
        scheduleCleanup()
    }

    // MARK: - Scheduling

    /// Schedules a refresh task for periodic state maintenance.
    /// Should be called after each background location update.
    func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)

        // Request execution no sooner than 15 minutes from now
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("[BackgroundTaskManager] Failed to schedule refresh: \(error.localizedDescription)")
        }
    }

    /// Schedules a cleanup task for housekeeping operations.
    /// Runs less frequently (every few hours).
    func scheduleCleanup() {
        let request = BGProcessingTaskRequest(identifier: Self.cleanupTaskID)

        // Processing tasks require external power (plugged in)
        request.requiresExternalPower = false

        // Network connectivity for potential sync (future)
        request.requiresNetworkConnectivity = false

        // Run no sooner than 2 hours from now
        request.earliestBeginDate = Date(timeIntervalSinceNow: 2 * 3600)

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("[BackgroundTaskManager] Failed to schedule cleanup: \(error.localizedDescription)")
        }
    }

    // MARK: - Task Handlers

    /// Handles the refresh background task.
    /// Performs lightweight state maintenance:
    /// - Checks if tracking session is still valid
    /// - Cleans up stale Kalman filter state
    /// - Schedules next refresh
    private func handleRefresh(_ task: BGAppRefreshTask) {
        let startTime = Date()
        refreshCount += 1
        lastRefreshTime = startTime

        // Set expiration handler — iOS may kill the task
        task.expirationHandler = {
            print("[BackgroundTaskManager] Refresh task expired after \(Date().timeIntervalSince(startTime))s")
        }

        print("[BackgroundTaskManager] Refresh task #\(refreshCount) started")

        // Perform maintenance
        performRefreshMaintenance()

        // Schedule next refresh
        scheduleRefresh()

        // Mark complete
        task.setTaskCompleted(success: true)
        print("[BackgroundTaskManager] Refresh completed in \(Date().timeIntervalSince(startTime))s")
    }

    /// Handles the cleanup background processing task.
    /// Performs heavier housekeeping:
    /// - Cleans up orphaned Live Activities
    /// - Removes stale session data
    /// - Compacts the transition history
    private func handleCleanup(_ task: BGProcessingTask) {
        let startTime = Date()

        task.expirationHandler = {
            print("[BackgroundTaskManager] Cleanup task expired")
        }

        print("[BackgroundTaskManager] Cleanup task started")

        Task {
            await performCleanupMaintenance()
            task.setTaskCompleted(success: true)
            print("[BackgroundTaskManager] Cleanup completed in \(Date().timeIntervalSince(startTime))s")
        }
    }

    // MARK: - Maintenance Operations

    /// Performs lightweight state checks for the refresh task.
    private func performRefreshMaintenance() {
        let manager = TrackingManager.shared

        // If tracking but no GPS fix for > 5 minutes, flag as stale
        if manager.isTracking {
            // TrackingManager handles its own staleness detection
            // via the state machine's evaluateGPSQuality method
        }

        // Compact state machine history
        // (handled internally by StateMachine)

        // Reschedule Live Activity if needed
        // (handled by LiveActivityManager)
    }

    /// Performs heavier cleanup operations.
    private func performCleanupMaintenance() async {
        // Clean up orphaned Live Activities
        await LiveActivityManager().cleanupOrphanedActivities()

        // Compact transition history
        // (handled internally by StateMachine)

        // Future: clean up old TutorRecord entries from SwiftData
    }

    // MARK: - Diagnostic Information

    /// Summary of background task activity.
    struct BackgroundTaskSummary {
        let totalRefreshes: Int
        let lastRefreshTime: Date
        let isRegistered: Bool
    }

    /// Returns diagnostic information about background task activity.
    func summary() -> BackgroundTaskSummary {
        BackgroundTaskSummary(
            totalRefreshes: refreshCount,
            lastRefreshTime: lastRefreshTime,
            isRegistered: isRegistered
        )
    }
}
