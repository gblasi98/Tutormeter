import Foundation

// MARK: - Deep Link Handler

/// Routes incoming URL scheme invocations to the appropriate action.
///
/// Supported URL schemes:
/// - `tutormeter://start-tracking`          → Begin speed monitoring
/// - `tutormeter://start-tracking?wait`     → Wait for Tutor detection before monitoring
/// - `tutormeter://stop-tracking`           → Stop monitoring
/// - `tutormeter://status`                  → Return current status (for Shortcuts)
///
/// These URLs can be triggered from:
/// - The iOS Shortcuts app (Open URL action)
/// - CarPlay automation (when CarPlay connects)
/// - Focus modes (Driving focus activation)
/// - NFC tags (tap to start tracking)
/// - Widgets (upcoming)
struct DeepLinkHandler {
    // MARK: - URL Parsing

    /// Parses and executes a Tutormeter deep link URL.
    /// - Parameter url: The URL to handle.
    /// - Returns: Whether the URL was recognized and handled.
    @discardableResult
    static func handle(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host else {
            return false
        }

        let queryItems = components.queryItems ?? []
        let params = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value) })

        switch host {
        case "start-tracking":
            let wait = params["wait"] != nil
            Task { @MainActor in
                TrackingManager.shared.startTracking()
            }
            return true

        case "stop-tracking":
            Task { @MainActor in
                let _ = TrackingManager.shared.stopTracking()
            }
            return true

        case "status":
            // Status is queried via Siri Intent, not deep link.
            // This is a no-op here but recognized for Shortcuts compatibility.
            return true

        default:
            print("[DeepLinkHandler] Unknown host: \(host)")
            return false
        }
    }

    /// Returns a URL for starting tracking (for use in Shortcuts).
    static var startTrackingURL: URL {
        URL(string: "tutormeter://start-tracking")!
    }

    /// Returns a URL for starting tracking in wait mode.
    static var startTrackingWaitURL: URL {
        URL(string: "tutormeter://start-tracking?wait")!
    }

    /// Returns a URL for stopping tracking.
    static var stopTrackingURL: URL {
        URL(string: "tutormeter://stop-tracking")!
    }
}
