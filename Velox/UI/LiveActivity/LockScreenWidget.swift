import SwiftUI
import WidgetKit

// MARK: - Lock Screen Widget

/// Lock Screen and Home Screen widget for quick Velox status at a glance.
///
/// Shows current tracking state and average speed without opening the app.
/// Can be configured as:
/// - Lock Screen circular widget (small speed readout)
/// - Lock Screen rectangular widget (speed + state)
/// - Home Screen small widget (speed + status)
@available(iOS 17.0, *)
struct VeloxLockScreenWidget: Widget {
    let kind: String = "VeloxLockScreenWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: VeloxWidgetIntent.self,
            provider: VeloxWidgetProvider()
        ) { entry in
            VeloxWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Velox Speed")
        .description("Shows your current average speed in the speed camera zone.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .systemSmall
        ])
    }
}

// MARK: - Widget Intent

struct VeloxWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Velox Configuration"
    static var description = IntentDescription("Displays your current Velox tracking status.")
}

// MARK: - Widget Timeline Entry

struct VeloxWidgetEntry: TimelineEntry {
    let date: Date
    let averageSpeedKmh: Double
    let instantSpeedKmh: Double
    let isTracking: Bool
    let isGPSLost: Bool
    let confidence: Double
    let trackingState: String
}

// MARK: - Widget Provider

struct VeloxWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> VeloxWidgetEntry {
        VeloxWidgetEntry(
            date: Date(),
            averageSpeedKmh: 127,
            instantSpeedKmh: 130,
            isTracking: true,
            isGPSLost: false,
            confidence: 0.95,
            trackingState: "tracking"
        )
    }

    func snapshot(
        for configuration: VeloxWidgetIntent,
        in context: Context
    ) async -> VeloxWidgetEntry {
        placeholder(in: context)
    }

    func timeline(
        for configuration: VeloxWidgetIntent,
        in context: Context
    ) async -> Timeline<VeloxWidgetEntry> {
        let manager = TrackingManager.shared

        let entry = VeloxWidgetEntry(
            date: Date(),
            averageSpeedKmh: manager.averageSpeed,
            instantSpeedKmh: manager.instantSpeed,
            isTracking: manager.isTracking,
            isGPSLost: manager.state == .gpsLost,
            confidence: manager.confidence,
            trackingState: manager.state.rawValue
        )

        // Refresh every 5 seconds when tracking, every 15 minutes when idle
        let refreshInterval: TimeInterval = manager.isTracking ? 5 : 900
        let nextRefresh = Date().addingTimeInterval(refreshInterval)

        return Timeline(entries: [entry], policy: .after(nextRefresh))
    }
}

// MARK: - Widget Entry View

struct VeloxWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    var entry: VeloxWidgetProvider.Entry

    var body: some View {
        switch family {
        case .accessoryCircular:
            circularView
        case .accessoryRectangular:
            rectangularView
        case .systemSmall:
            systemSmallView
        @unknown default:
            circularView
        }
    }

    // MARK: - Circular (Lock Screen)

    private var circularView: some View {
        ZStack {
            // Background gauge
            Circle()
                .stroke(.gray.opacity(0.3), lineWidth: 4)

            Circle()
                .trim(from: 0, to: CGFloat(entry.confidence))
                .stroke(speedColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))

            // Speed
            VStack(spacing: 0) {
                Text(entry.isTracking ? String(format: "%.0f", entry.averageSpeedKmh) : "--")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text("km/h")
                    .font(.system(size: 7))
                    .opacity(0.7)
            }
        }
        .padding(4)
    }

    // MARK: - Rectangular (Lock Screen)

    private var rectangularView: some View {
        HStack(spacing: 6) {
            // Speed
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.isTracking ? String(format: "%.0f", entry.averageSpeedKmh) : "--")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(speedColor)
                Text("km/h avg")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Status
            VStack(alignment: .trailing, spacing: 2) {
                Image(systemName: statusIcon)
                    .font(.caption)
                    .foregroundStyle(statusColor)

                Text(statusLabel)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - System Small (Home Screen)

    private var systemSmallView: some View {
        VStack(spacing: 8) {
            Spacer()

            // Speed
            Text(entry.isTracking ? String(format: "%.0f", entry.averageSpeedKmh) : "--")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundColor(speedColor)

            Text("km/h")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            // Status badge
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)

                Text(statusLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())

            Spacer()
        }
    }

    // MARK: - Computed

    private var speedColor: Color {
        guard entry.isTracking else { return .gray }
        if entry.averageSpeedKmh > 130 { return .red }
        if entry.isGPSLost { return .yellow }
        return .green
    }

    private var statusColor: Color {
        guard entry.isTracking else { return .gray }
        if entry.isGPSLost { return .yellow }
        return .green
    }

    private var statusIcon: String {
        guard entry.isTracking else { return "circle" }
        if entry.isGPSLost { return "location.slash" }
        return "location.fill"
    }

    private var statusLabel: String {
        guard entry.isTracking else { return "Ready" }
        if entry.isGPSLost { return "GPS Lost" }
        return "Tracking"
    }
}

// MARK: - Widget Bundle

@available(iOS 17.0, *)
struct VeloxWidgetBundle: WidgetBundle {
    var body: some Widget {
        VeloxLockScreenWidget()
    }
}
