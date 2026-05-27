import Foundation
import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - Velox Live Activity Attributes

/// Static attributes for the Velox Live Activity.
/// These are set once when the activity starts and never change.
struct VeloxActivityAttributes: ActivityAttributes, Sendable {
    typealias ContentState = VeloxActivityContentState

    /// The type of speed zone being monitored.
    enum ZoneType: String, Codable, Sendable {
        case tutor = "Tutor"
        case autovelox = "Autovelox"
        case unknown = "Speed Zone"
    }

    let zoneType: ZoneType
    let startLatitude: Double
    let startLongitude: Double
}

// MARK: - Velox Live Activity Content State

/// Dynamic content state updated periodically during tracking.
struct VeloxActivityContentState: Codable, Hashable, Sendable {
    /// Current average speed in km/h.
    var averageSpeedKmh: Double

    /// Instantaneous speed in km/h.
    var instantSpeedKmh: Double

    /// Distance traveled in the zone (km).
    var distanceKm: Double

    /// Time elapsed since entering the zone (seconds).
    var elapsedSeconds: TimeInterval

    /// Kalman filter confidence (0.0 - 1.0).
    var confidence: Double

    /// Current tracking state.
    var trackingState: String // "active", "tracking", "gpsLost"

    /// Whether the driver is exceeding the limit.
    var isOverLimit: Bool

    /// Whether GPS is currently lost.
    var isGPSLost: Bool

    /// Formatted time string (e.g. "04:32").
    var formattedTime: String {
        let minutes = Int(elapsedSeconds) / 60
        let seconds = Int(elapsedSeconds) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// Formatted average speed (e.g. "127 km/h").
    var formattedSpeed: String {
        String(format: "%.0f km/h", averageSpeedKmh)
    }
}

// MARK: - Live Activity Widget

/// Defines the Dynamic Island and Lock Screen presentation for Velox.
@available(iOS 16.1, *)
struct VeloxLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VeloxActivityAttributes.self) { context in
            // MARK: Lock Screen Banner
            lockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.3))

        } dynamicIsland: { context in
            // MARK: Dynamic Island
            DynamicIsland {
                // --- Expanded (long press) ---
                DynamicIslandExpandedRegion(.leading) {
                    expandedLeadingView(context: context)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    expandedTrailingView(context: context)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    expandedBottomView(context: context)
                }
                DynamicIslandExpandedRegion(.center) {
                    expandedCenterView(context: context)
                }

            } compactLeading: {
                // --- Compact Leading (when another app is also in DI) ---
                compactLeadingView(context: context)

            } compactTrailing: {
                // --- Compact Trailing ---
                compactTrailingView(context: context)

            } minimal: {
                // --- Minimal (when both apps are using DI) ---
                minimalView(context: context)
            }
        }
    }

    // MARK: - Lock Screen View

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<VeloxActivityAttributes>) -> some View {
        HStack(spacing: 0) {
            // Left: Speed
            VStack(alignment: .leading, spacing: 2) {
                Text(context.state.formattedSpeed)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundColor(speedColor(context.state))

                Text("avg speed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Center: Zone type
            VStack(spacing: 2) {
                Image(systemName: "speedometer")
                    .font(.title3)
                    .foregroundStyle(context.state.isGPSLost ? .yellow : .green.opacity(0.8))

                Text(context.attributes.zoneType.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Right: Time + Distance
            VStack(alignment: .trailing, spacing: 2) {
                Text(context.state.formattedTime)
                    .font(.title3.weight(.medium).monospacedDigit())
                    .foregroundColor(.primary)

                Text(String(format: "%.1f km", context.state.distanceKm))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Dynamic Island Views

    // Expanded Leading: Speed with large text
    @ViewBuilder
    private func expandedLeadingView(context: ActivityViewContext<VeloxActivityAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(context.state.formattedSpeed)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(speedColor(context.state))
            Text("avg")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 4)
    }

    // Expanded Trailing: Time
    @ViewBuilder
    private func expandedTrailingView(context: ActivityViewContext<VeloxActivityAttributes>) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(context.state.formattedTime)
                .font(.title3.weight(.medium).monospacedDigit())
            Text(String(format: "%.1f km", context.state.distanceKm))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.trailing, 4)
    }

    // Expanded Center: Zone + Confidence bar
    @ViewBuilder
    private func expandedCenterView(context: ActivityViewContext<VeloxActivityAttributes>) -> some View {
        HStack(spacing: 6) {
            Image(systemName: context.state.isGPSLost ? "location.slash" : "location.fill")
                .font(.caption)
                .foregroundStyle(context.state.isGPSLost ? .yellow : .green)

            Text(context.attributes.zoneType.rawValue)
                .font(.caption.weight(.medium))
        }
    }

    // Expanded Bottom: Confidence bar + GPS status
    @ViewBuilder
    private func expandedBottomView(context: ActivityViewContext<VeloxActivityAttributes>) -> some View {
        VStack(spacing: 4) {
            // Confidence bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.gray.opacity(0.3))
                        .frame(height: 4)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(confidenceColor(context.state.confidence))
                        .frame(
                            width: geo.size.width * CGFloat(context.state.confidence),
                            height: 4
                        )
                }
            }
            .frame(height: 4)

            // GPS status text
            if context.state.isGPSLost {
                HStack(spacing: 4) {
                    Circle()
                        .fill(.yellow)
                        .frame(width: 6, height: 6)
                    Text("GPS Lost — using sensors")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    // Compact Leading: Small speed icon + value
    @ViewBuilder
    private func compactLeadingView(context: ActivityViewContext<VeloxActivityAttributes>) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "speedometer")
                .font(.caption2)
            Text(String(format: "%.0f", context.state.averageSpeedKmh))
                .font(.caption.weight(.bold).monospacedDigit())
        }
        .foregroundColor(speedColor(context.state))
    }

    // Compact Trailing: Time
    @ViewBuilder
    private func compactTrailingView(context: ActivityViewContext<VeloxActivityAttributes>) -> some View {
        Text(context.state.formattedTime)
            .font(.caption.monospacedDigit())
    }

    // Minimal: Just the speed number
    @ViewBuilder
    private func minimalView(context: ActivityViewContext<VeloxActivityAttributes>) -> some View {
        Text(String(format: "%.0f", context.state.averageSpeedKmh))
            .font(.caption.bold().monospacedDigit())
            .foregroundColor(speedColor(context.state))
    }

    // MARK: - Colors

    private func speedColor(_ state: VeloxActivityContentState) -> Color {
        if state.isOverLimit { return .red }
        if state.isGPSLost { return .yellow }
        if state.confidence > 0.7 { return .green }
        return .orange
    }

    private func confidenceColor(_ confidence: Double) -> Color {
        if confidence > 0.66 { return .green }
        if confidence > 0.33 { return .yellow }
        return .red
    }
}
