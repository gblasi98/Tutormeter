import Foundation
import CarPlay

// MARK: - CarPlay Manager

/// Bridges tracking data to the CarPlay interface.
///
/// Provides formatted data optimized for in-vehicle display:
/// - Large, glanceable speed readouts
/// - Simplified status text (driver shouldn't read paragraphs)
/// - Color-coded alerts (red = over limit, yellow = GPS lost, green = OK)
///
/// Design principles for CarPlay:
/// 1. **Glanceability**: Information must be readable in < 1 second
/// 2. **Minimal text**: Icons and colors over text where possible
/// 3. **No interaction required**: Auto-updating, minimal driver input
/// 4. **Safety first**: Never distract the driver
@MainActor
final class VeloxCarPlayManager {
    // MARK: - Data Access

    /// The shared tracking manager instance.
    private var tracking: TrackingManager { TrackingManager.shared }

    // MARK: - Formatted Data for CarPlay

    /// Speed formatted for large CarPlay display.
    var formattedSpeed: String {
        guard tracking.isTracking else { return "--" }
        return String(format: "%.0f km/h", tracking.averageSpeed)
    }

    /// Whether the speed should be displayed in red (over limit).
    var isOverLimit: Bool {
        tracking.averageSpeed > 130.0
    }

    /// Current tracking state as a CarPlay-friendly string.
    var statusText: String {
        switch tracking.state {
        case .idle:       return "Pronto"
        case .active:     return "Attivazione..."
        case .tracking:   return "Monitoraggio"
        case .gpsLost:    return "GPS Perso"
        case .completed:  return "Completato"
        }
    }

    /// Confidence level as a simplified string.
    var confidenceText: String {
        let c = tracking.confidence
        if c > 0.8 { return "Alta" }
        if c > 0.5 { return "Media" }
        return "Bassa"
    }

    /// Whether the driver can start tracking (authorization OK).
    var canStartTracking: Bool {
        !tracking.isTracking && tracking.authStatus.canTrack
    }

    /// Whether the driver can stop tracking.
    var canStopTracking: Bool {
        tracking.isTracking
    }

    // MARK: - CarPlay-Specific Data Structures

    /// Represents a section of the CarPlay dashboard.
    struct DashboardSection {
        let title: String
        let value: String
        let alertLevel: AlertLevel

        enum AlertLevel {
            case normal    // Green / default
            case warning   // Yellow (GPS lost)
            case critical  // Red (over speed limit)
        }
    }

    /// Builds all dashboard sections for the current tracking state.
    var dashboardSections: [DashboardSection] {
        var sections: [DashboardSection] = []

        // Speed (always shown)
        sections.append(DashboardSection(
            title: "Velocità Media",
            value: formattedSpeed,
            alertLevel: isOverLimit ? .critical : .normal
        ))

        // Status
        sections.append(DashboardSection(
            title: "Stato",
            value: statusText,
            alertLevel: tracking.state == .gpsLost ? .warning : .normal
        ))

        // Confidence (when tracking)
        if tracking.isTracking {
            sections.append(DashboardSection(
                title: "Precisione",
                value: confidenceText,
                alertLevel: tracking.confidence < 0.5 ? .warning : .normal
            ))
        }

        return sections
    }
}
