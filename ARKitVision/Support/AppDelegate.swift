/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
App Delegate for the ARKitVision sample.
*/

import UIKit
import SwiftUI
import ARKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        guard ARWorldTrackingConfiguration.isSupported else {
            fatalError("""
                ARKit is not available on this device. For apps that require ARKit
                for core functionality, use the `arkit` key in the key in the
                `UIRequiredDeviceCapabilities` section of the Info.plist to prevent
                the app from installing. (If the app can't be installed, this error
                can't be triggered in a production scenario.)
                In apps where AR is an additive feature, use `isSupported` to
                determine whether to show UI for launching AR experiences.
                """) // For details, see https://developer.apple.com/documentation/arkit
        }

        // Standalone Call-Animal scaffold: bypass Main.storyboard (the old
        // SceneKit ViewController) and launch straight into the RealityKit
        // scene instead. ViewController.swift is left in the project, just
        // unused, so reverting to it later just means reverting this method.
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIHostingController(rootView: AnimalCallScene())
        window.makeKeyAndVisible()
        self.window = window

        return true
    }
}
