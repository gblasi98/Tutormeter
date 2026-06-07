import SwiftUI

@main
struct TutormeterApp: App {
    @UIApplicationDelegateAdaptor(TutormeterAppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(TrackingManager.shared)
                .onOpenURL { url in
                    DeepLinkHandler.handle(url)
                }
        }
    }
}

// MARK: - Content View

struct ContentView: View {
    @Environment(TrackingManager.self) private var manager
    @State private var showAuthAlert = false
    @State private var hasCheckedIntentLaunch = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    speedCard
                    statusSection

                    if let error = manager.errorMessage {
                        errorBanner(error)
                    }

                    if manager.authStatus.needsSettingsIntervention {
                        permissionWarning
                    }

                    Spacer(minLength: 16)
                    tutorZoneSection
                    controlButton
                    shortcutsInfo
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .navigationTitle("Tutormeter")
            .alert("Accesso alla posizione richiesto", isPresented: $showAuthAlert) {
                Button("Apri Impostazioni") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Annulla", role: .cancel) {}
            } message: {
                Text("Tutormeter ha bisogno di accedere alla posizione per calcolare la velocità media. Abilita l'accesso nelle Impostazioni.")
            }
        }
        .onAppear {
            handleIntentLaunch()
        }
    }

    /// If the app was launched by the Siri StartTrackingIntent,
    /// a UserDefaults flag is set. Clear it and start tracking.
    private func handleIntentLaunch() {
        guard !hasCheckedIntentLaunch else { return }
        hasCheckedIntentLaunch = true

        let key = "Tutormeter.shouldStartTracking"
        guard UserDefaults.standard.bool(forKey: key) else { return }

        UserDefaults.standard.removeObject(forKey: key)

        guard !manager.isTracking else { return }
        guard manager.authStatus.canTrack || manager.authStatus.canRequest else { return }

        _ = manager.startTracking()
    }

    // MARK: - Subviews

    private var speedCard: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(manager.isTracking ? Color.green.opacity(0.2) : Color.gray.opacity(0.1), lineWidth: 12)
                    .frame(width: 200, height: 200)

                Circle()
                    .trim(from: 0, to: CGFloat(manager.confidence))
                    .stroke(confidenceColor, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .frame(width: 200, height: 200)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.5), value: manager.confidence)

                VStack(spacing: 0) {
                    Text(manager.isTracking ? "\(Int(manager.averageSpeed))" : "--")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                    Text("km/h")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    if manager.isTracking {
                        Text("\(Int(manager.instantSpeed)) km/h")
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
            HStack(spacing: 8) {
                Circle().fill(stateColor).frame(width: 10, height: 10)
                Text(stateLabel).font(.subheadline.weight(.medium))
                Spacer()
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
            Label("Accesso alla posizione richiesto", systemImage: "location.slash.fill")
                .font(.subheadline.weight(.semibold)).foregroundColor(.orange)
            Text("Abilita l'accesso alla posizione nelle Impostazioni per avviare il monitoraggio.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Apri Impostazioni") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.bordered).controlSize(.small).tint(.orange)
        }
        .padding().background(.orange.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption).foregroundColor(.red).padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var controlButton: some View {
        Button {
            if manager.isTracking {
                _ = manager.stopTracking()
            } else if manager.authStatus.canTrack {
                _ = manager.startTracking()
            } else if manager.authStatus.canRequest {
                _ = manager.startTracking()
            } else {
                showAuthAlert = true
            }
        } label: {
            Label(buttonLabel, systemImage: manager.isTracking ? "stop.fill" : "play.fill")
                .font(.title3.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 16)
        }
        .buttonStyle(.borderedProminent).controlSize(.large)
        .tint(manager.isTracking ? .red : .green)
    }

    private var shortcutsInfo: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Comandi Siri").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                ForEach(shortcutItems, id: \.phrase) { item in
                    VStack(spacing: 4) {
                        Image(systemName: item.icon).font(.title3).foregroundStyle(.blue)
                        Text(item.phrase).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Tutor Zone Section

    @State private var autoStartEnabled = TutorZoneManager.shared.isAutoStartEnabled

    private var tutorZoneSection: some View {
        VStack(spacing: 8) {
            // Toggle
            HStack {
                Image(systemName: "speedometer")
                    .foregroundStyle(.blue)
                Toggle("Avvio automatico nei Tutor", isOn: $autoStartEnabled)
                    .font(.subheadline)
                    .onChange(of: autoStartEnabled) { _, newValue in
                        let zoneMgr = TutorZoneManager.shared
                        zoneMgr.isAutoStartEnabled = newValue
                        if newValue {
                            zoneMgr.startMonitoring()
                        } else {
                            zoneMgr.stopMonitoring()
                        }
                    }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // Active zone indicator
            if let zone = TutorZoneManager.shared.activeZone {
                HStack(spacing: 6) {
                    Image(systemName: "location.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text(zone.highway)
                        .font(.caption.weight(.semibold))
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text("\(zone.speedLimitKmh) km/h")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(.green.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .transition(.opacity)
                .animation(.easeInOut, value: TutorZoneManager.shared.activeZone?.id)
            }

            // Monitoring status indicator
            if TutorZoneManager.shared.isMonitoring && !manager.isTracking {
                HStack(spacing: 4) {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                    Text("In ascolto Tutor")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Computed

    private var stateLabel: String {
        switch manager.state {
        case .idle: "Pronto"
        case .active: "Avvio..."
        case .tracking: "In monitoraggio"
        case .gpsLost: "GPS perso"
        case .completed: "Completato"
        }
    }

    private var stateColor: Color {
        switch manager.state {
        case .idle: .gray
        case .active: .orange
        case .tracking: .green
        case .gpsLost: .yellow
        case .completed: .blue
        }
    }

    private var confidenceColor: Color {
        if manager.confidence > 0.66 { .green }
        else if manager.confidence > 0.33 { .yellow }
        else { .red }
    }

    private var buttonLabel: String {
        if manager.isTracking { "Ferma monitoraggio" }
        else if manager.authStatus.needsSettingsIntervention { "Posizione richiesta" }
        else { "Avvia monitoraggio" }
    }

    private var gpsQualityDots: Int {
        Int(ceil(manager.confidence * 5))
    }

    private var shortcutItems: [(phrase: String, icon: String)] {
        [
            ("Ehi Siri,\nAvvia Tutormeter", "mic.fill"),
            ("Avvia\nMonitoraggio", "speedometer"),
            ("Velocità\nattuale", "info.circle")
        ]
    }
}
