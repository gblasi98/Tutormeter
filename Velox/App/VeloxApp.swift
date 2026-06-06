import SwiftUI

/// Main entry point for the Tutormeter application.
///
/// Tutormeter monitors your average speed in speed camera (Tutor) zones
/// and displays it as an overlay while you use Waze or other navigation apps.
///
/// Activation methods:
/// - Siri Shortcut: "Hey Siri, avvia monitoraggio Tutormeter"
/// - URL Scheme: `tutormeter://start-tracking`
/// - CarPlay: Automatic on connection
/// - Manual: Tap "Start" in the app
@main
struct TutormeterApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - Content View (Phase 3: full implementation)

struct ContentView: View {
    var body: some View {
        Text("Tutormeter")
            .font(.largeTitle)
            .padding()
    }
}
