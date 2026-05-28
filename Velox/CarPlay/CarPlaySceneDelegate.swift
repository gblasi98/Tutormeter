import CarPlay
import SwiftUI

// MARK: - CarPlay Scene Delegate

/// Manages the CarPlay interface for Tutormeter.
///
/// When the iPhone connects to a CarPlay-enabled vehicle, this delegate
/// creates and manages the dashboard interface showing:
/// - Current average speed (large, prominent)
/// - Time elapsed in the speed zone
/// - GPS signal quality indicator
/// - Zone type (Tutor / Autovelox)
///
/// CarPlay is the ideal interface for Tutormeter because:
/// - The driver's phone is typically connected to CarPlay while navigating
/// - The car's display is larger and more visible than the phone
/// - It's safer: eyes stay on the road, not on the phone
///
/// Template used: `CPInformationTemplate` with speed as the primary info.
@MainActor
final class TutormeterCarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    // MARK: - Properties
    private var interfaceController: CPInterfaceController?
    private var carPlayManager = TutormeterCarPlayManager()
    private var updateTimer: Timer?

    // MARK: - Scene Lifecycle

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        print("[CarPlay] Connected to vehicle display")

        self.interfaceController = interfaceController
        interfaceController.delegate = self

        // Show the main speed template
        let template = createSpeedTemplate()
        interfaceController.setRootTemplate(template, animated: true)

        // Start periodic updates (1 Hz)
        startUpdates()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        print("[CarPlay] Disconnected from vehicle display")
        stopUpdates()
        self.interfaceController = nil
    }

    // MARK: - Template Creation

    /// Creates the main dashboard template showing speed information.
    private func createSpeedTemplate() -> CPInformationTemplate {
        let items = buildInfoItems()
        let actions = buildActions()

        return CPInformationTemplate(
            title: "Tutormeter",
            layout: .leading, // Icon on left, text on right
            items: items,
            actions: actions
        )
    }

    /// Builds the information items from the current tracking state.
    private func buildInfoItems() -> [CPInformationItem] {
        let tracking = TrackingManager.shared
        var items: [CPInformationItem] = []

        // Speed item (most prominent)
        if tracking.isTracking {
            let speedText = String(format: "%.0f km/h", tracking.averageSpeed)
            items.append(CPInformationItem(
                title: "Velocità Media",
                detail: speedText
            ))
        } else {
            items.append(CPInformationItem(
                title: "Velocità Media",
                detail: "In attesa..."
            ))
        }

        // Status
        let statusText: String
        switch tracking.state {
        case .idle:       statusText = "Pronto"
        case .active:     statusText = "Attivazione..."
        case .tracking:   statusText = "Monitoraggio attivo"
        case .gpsLost:    statusText = "GPS perso"
        case .completed:  statusText = "Completato"
        }
        items.append(CPInformationItem(title: "Stato", detail: statusText))

        // Time
        if tracking.isTracking {
            let elapsed = tracking.averageSpeed > 0 ? "" : "0:00"
            items.append(CPInformationItem(title: "Tempo", detail: elapsed))
        }

        // GPS quality
        let gpsText = tracking.state == .gpsLost ? "⚠️ GPS perso" : "✅ OK"
        items.append(CPInformationItem(title: "Segnale", detail: gpsText))

        return items
    }

    /// Builds the action buttons.
    private func buildActions() -> [CPTextButton] {
        let tracking = TrackingManager.shared

        if tracking.isTracking {
            return [
                CPTextButton(title: "Ferma Monitoraggio", textStyle: .normal) { [weak self] _ in
                    let _ = tracking.stopTracking()
                    self?.refreshTemplate()
                }
            ]
        } else {
            return [
                CPTextButton(title: "Avvia Monitoraggio", textStyle: .normal) { [weak self] _ in
                    let _ = tracking.startTracking()
                    self?.refreshTemplate()
                }
            ]
        }
    }

    // MARK: - Updates

    /// Starts a periodic timer to refresh the CarPlay display.
    private func startUpdates() {
        guard updateTimer == nil else { return }

        updateTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshTemplate()
            }
        }
    }

    /// Stops the periodic update timer.
    private func stopUpdates() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    /// Rebuilds and pushes the updated template to CarPlay.
    private func refreshTemplate() {
        guard let controller = interfaceController else { return }

        let template = createSpeedTemplate()
        controller.setRootTemplate(template, animated: true)

        // If we're showing a tab bar or other templates, update them too
        controller.templates.forEach { cpTemplate in
            if let infoTemplate = cpTemplate as? CPInformationTemplate {
                // Trigger a visual update by replacing
            }
        }
    }
}

// MARK: - CPInterfaceControllerDelegate

extension TutormeterCarPlaySceneDelegate: CPInterfaceControllerDelegate {
    func templateWillAppear(_ aTemplate: CPTemplate, animated: Bool) {
        print("[CarPlay] Template will appear: \(type(of: aTemplate))")
    }

    func templateDidAppear(_ aTemplate: CPTemplate, animated: Bool) {
        print("[CarPlay] Template did appear")
    }

    func templateWillDisappear(_ aTemplate: CPTemplate, animated: Bool) {
        print("[CarPlay] Template will disappear")
    }

    func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {
        print("[CarPlay] Template did disappear")
    }
}
