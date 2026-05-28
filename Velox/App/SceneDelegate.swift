import UIKit
import SwiftUI

/// UIKit scene delegate that bridges the SwiftUI app into the standard
/// `UIScene` lifecycle.
///
/// Required because `Info.plist` declares
/// `$(PRODUCT_MODULE_NAME).SceneDelegate` as the delegate class for the
/// default window scene configuration. Without this type the app would
/// crash on launch with "Unable to instantiate the UIScene delegate".
///
/// CarPlay uses a separate scene configuration handled by
/// `CarPlaySceneDelegate`; this delegate intentionally only services the
/// phone's primary `UIWindowScene`.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        let contentView = ContentView()
            .environment(TrackingManager.shared)
        window.rootViewController = UIHostingController(rootView: contentView)
        self.window = window
        window.makeKeyAndVisible()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // Scene was released by the system; release any scene-specific
        // resources here. The session may be reconnected later.
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // Resume any tasks that were paused (or not yet started) while
        // the scene was inactive.
    }

    func sceneWillResignActive(_ scene: UIScene) {
        // Called when the scene is about to move from active to inactive
        // state (e.g., incoming phone call).
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // Counterpart to `sceneDidEnterBackground`; undo background
        // adjustments here.
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Persist any state that should survive termination. Tracking
        // continues via background location updates managed by
        // `LocationTracker` / `BackgroundTaskManager`.
    }
}
