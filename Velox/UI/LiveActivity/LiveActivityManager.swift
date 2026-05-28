import Foundation
import ActivityKit

// MARK: - Live Activity Manager

/// Manages the lifecycle of the Tutormeter Live Activity in the Dynamic Island
/// and Lock Screen.
///
/// Responsible for:
/// - Starting a Live Activity with initial attributes and state
/// - Periodically updating the content state (speed, time, distance)
/// - Ending the activity with a final summary
/// - Handling stale data and activity staleness
///
/// Usage:
/// ```swift
/// let manager = LiveActivityManager()
/// manager.start(zoneType: .tutor, lat: 45.0, lon: 9.0)
///
/// // Every second:
/// manager.update(speed: 127, distance: 2.3, time: 65, confidence: 0.9)
///
/// // On stop:
/// manager.end(finalSpeed: 125, distance: 15.2, duration: 420)
/// ```
@MainActor
final class LiveActivityManager {
    // MARK: - State
    private var currentActivity: Activity<TutormeterActivityAttributes>?
    private var updateCount: Int = 0
    private var lastUpdateTime: Date

    /// Source of "now" for rate-limiting and stale-activity detection.
    private let dateProvider: any DateProvider

    // MARK: - Init

    init(dateProvider: any DateProvider = SystemDateProvider()) {
        self.dateProvider = dateProvider
        self.lastUpdateTime = dateProvider.now()
    }

    /// Whether a Live Activity is currently active.
    var isActive: Bool {
        currentActivity != nil
    }

    /// The time since the last content update was pushed.
    var timeSinceLastUpdate: TimeInterval {
        dateProvider.now().timeIntervalSince(lastUpdateTime)
    }

    // MARK: - Configuration
    /// Minimum interval between update pushes (seconds).
    nonisolated static var minUpdateInterval: TimeInterval {
        TutormeterConfiguration.shared.liveActivityMinUpdateIntervalSeconds
    }

    /// Maximum age of the activity before it's considered stale.
    nonisolated static var maxActivityAge: TimeInterval {
        TutormeterConfiguration.shared.liveActivityMaxAgeSeconds
    }

    /// Content relevance score (higher = more prominent in Dynamic Island).
    nonisolated static var relevanceScore: Double {
        TutormeterConfiguration.shared.liveActivityRelevanceScore
    }

    // MARK: - Lifecycle

    /// Starts a new Live Activity for a speed camera zone.
    /// - Parameters:
    ///   - zoneType: The type of zone (Tutor, Autovelox, etc.).
    ///   - latitude: Starting latitude of the zone.
    ///   - longitude: Starting longitude of the zone.
    /// - Returns: Whether the activity was started successfully.
    @discardableResult
    func start(
        zoneType: TutormeterActivityAttributes.ZoneType,
        latitude: Double,
        longitude: Double
    ) -> Bool {
        // Validate coordinates before requesting an activity.
        guard latitude.isFinite, longitude.isFinite,
              latitude >= -90, latitude <= 90,
              longitude >= -180, longitude <= 180 else {
            print("[LiveActivityManager] Invalid coordinates: (\(latitude), \(longitude))")
            return false
        }

        // Cancel any existing activity
        if let existing = currentActivity {
            endExisting(existing, reason: "New zone started")
        }

        // Check authorization
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            print("[LiveActivityManager] Activities not authorized")
            return false
        }

        let attributes = TutormeterActivityAttributes(
            zoneType: zoneType,
            startLatitude: latitude,
            startLongitude: longitude
        )

        let initialState = TutormeterActivityContentState(
            averageSpeedKmh: 0.0,
            instantSpeedKmh: 0.0,
            distanceKm: 0.0,
            elapsedSeconds: 0.0,
            confidence: 0.0,
            trackingState: "active",
            isOverLimit: false,
            isGPSLost: false
        )

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialState, staleDate: nil),
                pushType: nil // Local updates only (no push notifications)
            )

            currentActivity = activity
            updateCount = 0
            lastUpdateTime = dateProvider.now()

            print("[LiveActivityManager] Started: \(activity.id)")
            return true
        } catch {
            print("[LiveActivityManager] Failed to start: \(error.localizedDescription)")
            return false
        }
    }

    /// Updates the Live Activity with new tracking data.
    /// Should be called at ~1 Hz from the tracking loop.
    ///
    /// - Parameters:
    ///   - speedKmh: Average speed in km/h.
    ///   - instantKmh: Instantaneous speed in km/h.
    ///   - distanceKm: Distance traveled in the current zone.
    ///   - elapsedSeconds: Time since entering the zone.
    ///   - confidence: Kalman filter confidence (0-1).
    ///   - isGPSLost: Whether GPS signal is currently lost.
    func update(
        speedKmh: Double,
        instantKmh: Double,
        distanceKm: Double,
        elapsedSeconds: TimeInterval,
        confidence: Double,
        isGPSLost: Bool
    ) {
        // Silently no-op when there's no activity. Logging here would spam
        // the console on every tick when no zone is active.
        guard let activity = currentActivity else { return }

        // Reject obviously invalid inputs (negative speed/distance).
        guard speedKmh >= 0, distanceKm >= 0,
              speedKmh.isFinite, distanceKm.isFinite else {
            return
        }

        // Rate limit
        let now = dateProvider.now()
        guard now.timeIntervalSince(lastUpdateTime) >= Self.minUpdateInterval else {
            return
        }

        let limit = TutormeterConfiguration.shared.speedLimitKmh

        let newState = TutormeterActivityContentState(
            averageSpeedKmh: speedKmh,
            instantSpeedKmh: instantKmh,
            distanceKm: distanceKm,
            elapsedSeconds: elapsedSeconds,
            confidence: confidence,
            trackingState: isGPSLost ? "gpsLost" : "tracking",
            isOverLimit: speedKmh > limit,
            isGPSLost: isGPSLost
        )

        Task {
            let alertConfig = AlertConfiguration(
                title: isGPSLost ? "GPS Signal Lost" : "Speed Alert",
                body: LocalizedStringResource(
                    stringLiteral: isGPSLost
                        ? "Using sensors to estimate speed."
                        : speedKmh > limit
                            ? "Above limit: \(Int(speedKmh)) km/h"
                            : "Average: \(Int(speedKmh)) km/h"
                ),
                sound: isGPSLost ? .default : .default
            )

            await activity.update(
                .init(state: newState, staleDate: nil),
                alertConfiguration: speedKmh > limit || isGPSLost ? alertConfig : nil
            )

            updateCount += 1
            lastUpdateTime = now
        }

        // Check for stale activity
        if elapsedSeconds > Self.maxActivityAge {
            endExisting(activity, reason: "Activity timeout")
        }
    }

    /// Ends the Live Activity with a final summary.
    /// - Parameters:
    ///   - finalSpeedKmh: Final average speed.
    ///   - distanceKm: Total distance in the zone.
    ///   - durationSeconds: Total time in the zone.
    func end(finalSpeedKmh: Double, distanceKm: Double, durationSeconds: TimeInterval) {
        // Already ended (or never started) — no-op, this is idempotent.
        guard let activity = currentActivity else { return }

        let limit = TutormeterConfiguration.shared.speedLimitKmh

        let finalState = TutormeterActivityContentState(
            averageSpeedKmh: finalSpeedKmh,
            instantSpeedKmh: 0.0,
            distanceKm: distanceKm,
            elapsedSeconds: durationSeconds,
            confidence: 1.0,
            trackingState: "completed",
            isOverLimit: finalSpeedKmh > limit,
            isGPSLost: false
        )

        // Detach so this can be called from a sync context safely.
        Task {
            await activity.end(
                .init(state: finalState, staleDate: nil),
                dismissalPolicy: .default
            )
            print("[LiveActivityManager] Ended: \(activity.id) after \(updateCount) updates")
        }

        currentActivity = nil
        updateCount = 0
    }

    /// Cancels the Live Activity without a summary (e.g., error state).
    func cancel(reason: String = "Cancelled") {
        guard let activity = currentActivity else { return }
        endExisting(activity, reason: reason)
    }

    // MARK: - Activity Monitoring

    /// Checks for stale or orphaned activities (e.g., from a previous launch).
    func cleanupOrphanedActivities() async {
        for activity in Activity<TutormeterActivityAttributes>.activities {
            let now = dateProvider.now()
            let age = now.timeIntervalSince(activity.contentState.elapsedSeconds > 0
                ? now.addingTimeInterval(-activity.contentState.elapsedSeconds)
                : now)

            if age > Self.maxActivityAge {
                await activity.end(nil, dismissalPolicy: .immediate)
                print("[LiveActivityManager] Cleaned up orphaned activity: \(activity.id)")
            }
        }
    }

    // MARK: - Helpers

    private func endExisting(_ activity: Activity<TutormeterActivityAttributes>, reason: String) {
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        if activity.id == currentActivity?.id {
            currentActivity = nil
        }
        print("[LiveActivityManager] Ended existing: \(activity.id) — \(reason)")
    }
}
