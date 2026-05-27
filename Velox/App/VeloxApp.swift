import SwiftUI

/// Main entry point for the Velox application.
///
/// Velox monitors your average speed in speed camera (Tutor) zones
/// and displays it as an overlay while you use Waze or other navigation apps.
///
/// Activation methods:
/// - Siri Shortcut: "Hey Siri, avvia monitoraggio Velox"
/// - URL Scheme: `velox://start-tracking`
/// - CarPlay: Automatic on connection
/// - Manual: Tap "Start" in the app
@main
struct VeloxApp: App {
    @UIApplicationDelegateAdaptor(VeloxAppDelegate.self) var appDelegate
    @State private var trackingManager = TrackingManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(trackingManager)
                .onOpenURL { url in
                    DeepLinkHandler.handle(url)
                }
        }
    }
}

// MARK: - Content View (Phase 3: full implementation)

struct ContentView: View {
    @Environment(TrackingManager.self) private var manager
    @State private var showAuthAlert = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    // MARK: Speed Display
                    speedCard

                    // MARK: Status & Quality
                    statusSection

                    // MARK: Error Banner
                    if let error = manager.errorMessage {
                        errorBanner(error)
                    }

                    // MARK: Permissions
                    if manager.authStatus.needsSettingsIntervention {
                        permissionWarning
                    }

                    Spacer(minLength: 16)

                    // MARK: Control Button
                    controlButton

                    // MARK: Siri Shortcuts Info
                    shortcutsInfo
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .navigationTitle("Tutormeter")
            .alert("Location Access Required", isPresented: $showAuthAlert) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Velox needs location access to calculate average speed. Enable it in Settings.")
            }
        }
    }

    // MARK: - Subviews

    private var speedCard: some View {
        VStack(spacing: 4) {
            ZStack {
                // Background ring
                Circle()
                    .stroke(
                        manager.isTracking ? Color.green.opacity(0.2) : Color.gray.opacity(0.1),
                        lineWidth: 12
                    )
                    .frame(width: 200, height: 200)

                // Confidence arc
                Circle()
                    .trim(from: 0, to: CGFloat(manager.confidence))
                    .stroke(
                        confidenceColor,
                        style: StrokeStyle(lineWidth: 12, lineCap: .round)
                    )
                    .frame(width: 200, height: 200)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.5), value: manager.confidence)

                // Speed text
                VStack(spacing: 0) {
                    Text(manager.isTracking ? "\(Int(manager.averageSpeed))" : "--")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())

                    Text("km/h")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    if manager.isTracking {
                        Text("\(Int(manager.instantSpeed)) instant")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    private var statusSection: some View {
        VStack(spacing: 12) {
            // State indicator
            HStack(spacing: 8) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 10, height: 10)

                Text(stateLabel)
                    .font(.subheadline.weight(.medium))

                Spacer()

                // GPS quality dots
                HStack(spacing: 4) {
                    ForEach(0..<5) { i in
                        Circle()
                            .fill(i < gpsQualityDots ? Color.green : Color.gray.opacity(0.3))
                            .frame(width: 6, height: 6)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var permissionWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Location Access Required", systemImage: "location.slash.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.orange)

            Text("Enable location access in Settings to start monitoring.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.orange)
        }
        .padding()
        .background(.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundColor(.red)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var controlButton: some View {
        Button {
            if manager.isTracking {
                let _ = manager.stopTracking()
            } else if manager.authStatus.canTrack {
                let _ = manager.startTracking()
            } else if manager.authStatus.canRequest {
                // Authorization will be requested inside startTracking
                let _ = manager.startTracking()
            } else {
                showAuthAlert = true
            }
        } label: {
            Label(
                buttonLabel,
                systemImage: manager.isTracking ? "stop.fill" : "play.fill"
            )
            .font(.title3.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(manager.isTracking ? .red : .green)
    }

    private var shortcutsInfo: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Siri Shortcuts")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                ForEach(shortcutItems, id: \.phrase) { item in
                    VStack(spacing: 4) {
                        Image(systemName: item.icon)
                            .font(.title3)
                            .foregroundStyle(.blue)
                        Text(item.phrase)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Computed Properties

    private var stateLabel: String {
        switch manager.state {
        case .idle:       return "Ready"
        case .active:     return "Activating..."
        case .tracking:   return "Monitoring"
        case .gpsLost:    return "GPS Lost"
        case .completed:  return "Completed"
        }
    }

    private var stateColor: Color {
        switch manager.state {
        case .idle:       return .gray
        case .active:     return .orange
        case .tracking:   return .green
        case .gpsLost:    return .yellow
        case .completed:  return .blue
        }
    }

    private var confidenceColor: Color {
        if manager.confidence > 0.66 { return .green }
        if manager.confidence > 0.33 { return .yellow }
        return .red
    }

    private var buttonLabel: String {
        if manager.isTracking { return "Stop Tracking" }
        if manager.authStatus.needsSettingsIntervention { return "Location Required" }
        return "Start Tracking"
    }

    private var gpsQualityDots: Int {
        // Map confidence to 1-5 dots
        Int(ceil(manager.confidence * 5))
    }

    private var shortcutItems: [(phrase: String, icon: String)] {
        [
            ("Hey Siri,\nAvvia Velox", "mic.fill"),
            ("Avvia\nMonitoraggio", "speedometer"),
            ("Qual è la\nmia velocità?", "info.circle")
        ]
    }
}
