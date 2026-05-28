import Foundation
import BackgroundTasks
import SwiftData

// MARK: - Background Task Manager

/// Manages iOS background task scheduling and execution for Tutormeter.
///
/// Background tasks are essential because iOS may suspend the app at any time
/// when it's not in the foreground. Even with background location updates enabled,
/// iOS limits execution time. BGTaskScheduler provides guaranteed execution
/// windows for critical operations.
///
/// Registered tasks:
/// - `com.tutormeter.refresh`: Periodic state check and Kalman filter maintenance
/// - `com.tutormeter.cleanup`: Clean up stale sessions and orphaned Live Activities
///
/// Usage:
/// - Call `registerTasks()` in `application(_:didFinishLaunchingWithOptions:)`
/// - Call `scheduleRefresh()` at the end of each background location update
@MainActor
final class BackgroundTaskManager {
    // MARK: - Task Identifiers
    nonisolated static let refreshTaskID = "com.tutormeter.refresh"
    nonisolated static let cleanupTaskID = "com.tutormeter.cleanup"

    // MARK: - Dependencies
    private let config: TutormeterConfiguration

    // MARK: - State
    private var isRegistered = false
    private var refreshCount: Int = 0
    private var lastRefreshTime: Date = Date()

    // MARK: - Init
    init(config: TutormeterConfiguration = .shared) {
        self.config = config
    }

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
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self?.handleRefresh(refreshTask)
        }

        // Register cleanup task
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.cleanupTaskID,
            using: nil
        ) { [weak self] task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self?.handleCleanup(processingTask)
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
        request.earliestBeginDate = Date(timeIntervalSinceNow: config.backgroundRefreshIntervalSeconds)
        submit(request, kind: "refresh", retryAllowed: true)
    }

    /// Schedules a cleanup task for housekeeping operations.
    /// Runs less frequently (every few hours).
    func scheduleCleanup() {
        let request = BGProcessingTaskRequest(identifier: Self.cleanupTaskID)
        request.requiresExternalPower = false
        request.requiresNetworkConnectivity = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: config.backgroundCleanupIntervalSeconds)
        submit(request, kind: "cleanup", retryAllowed: true)
    }

    /// Submits a BG task request with do-catch + a single 1s-delayed retry.
    private func submit(_ request: BGTaskRequest, kind: String, retryAllowed: Bool) {
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("[BackgroundTaskManager] Failed to schedule \(kind): \(error.localizedDescription)")
            guard retryAllowed else { return }

            // Single fallback retry after 1 second.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard self != nil else { return }
                do {
                    try BGTaskScheduler.shared.submit(request)
                    print("[BackgroundTaskManager] Retry succeeded for \(kind)")
                } catch {
                    print("[BackgroundTaskManager] Retry failed for \(kind): \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Task Handlers

    /// Handles the refresh background task.
    private func handleRefresh(_ task: BGAppRefreshTask) {
        let startTime = Date()
        refreshCount += 1
        lastRefreshTime = startTime

        task.expirationHandler = {
            print("[BackgroundTaskManager] Refresh task expired after \(Date().timeIntervalSince(startTime))s")
        }

        print("[BackgroundTaskManager] Refresh task #\(refreshCount) started")

        performRefreshMaintenance()

        scheduleRefresh()

        task.setTaskCompleted(success: true)
        print("[BackgroundTaskManager] Refresh completed in \(Date().timeIntervalSince(startTime))s")
    }

    /// Handles the cleanup background processing task.
    private func handleCleanup(_ task: BGProcessingTask) {
        let startTime = Date()

        task.expirationHandler = {
            print("[BackgroundTaskManager] Cleanup task expired")
        }

        print("[BackgroundTaskManager] Cleanup task started")

        Task { @MainActor in
            await performCleanupMaintenance()
            task.setTaskCompleted(success: true)
            print("[BackgroundTaskManager] Cleanup completed in \(Date().timeIntervalSince(startTime))s")
        }
    }

    // MARK: - Maintenance Operations

    /// Performs lightweight state checks for the refresh task.
    ///
    /// Responsibilities:
    /// - If tracking and GPS has been lost > threshold, flag the session as stale.
    /// - Refresh the Live Activity (if any) so it doesn't go stale on the lock screen.
    private func performRefreshMaintenance() {
        let manager = TrackingManager.shared

        guard manager.isTracking else { return }

        // If GPS has been lost for too long, flag the persisted session as stale.
        if manager.state == .gpsLost,
           manager.stateAge > config.backgroundStaleGPSThresholdSeconds {
            print("[BackgroundTaskManager] GPS lost > \(Int(config.backgroundStaleGPSThresholdSeconds))s — clearing stale session state")
            SessionStore().clearSessionState()
        }

        // Re-publish current state to the Live Activity so it doesn't dim.
        manager.refreshLiveActivity()
    }

    /// Performs heavier cleanup operations.
    ///
    /// Responsibilities:
    /// - End orphaned Live Activities.
    /// - Compact the state-machine transition history (handled by StateMachine itself).
    /// - Purge TutorRecord entries older than `backgroundOldRecordAgeSeconds`.
    private func performCleanupMaintenance() async {
        // 1. Clean up orphaned Live Activities
        await LiveActivityManager().cleanupOrphanedActivities()

        // 2. Compact state-machine history
        TrackingManager.shared.compactStateHistory()

        // 3. Purge old TutorRecord rows from SwiftData
        await purgeOldTutorRecords()
    }

    /// Deletes TutorRecord entries older than the configured retention window.
    private func purgeOldTutorRecords() async {
        let cutoff = Date().addingTimeInterval(-config.backgroundOldRecordAgeSeconds)
        do {
            let container = try ModelContainer(for: TutorRecord.self)
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<TutorRecord>(
                predicate: #Predicate { $0.endDate < cutoff }
            )
            let stale = try context.fetch(descriptor)
            for record in stale {
                context.delete(record)
            }
            if !stale.isEmpty {
                try context.save()
                print("[BackgroundTaskManager] Purged \(stale.count) old TutorRecord(s)")
            }
        } catch {
            print("[BackgroundTaskManager] purgeOldTutorRecords failed: \(error.localizedDescription)")
        }
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
