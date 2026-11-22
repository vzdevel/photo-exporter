//
//  Photo_ExporterApp.swift
//  Photo Exporter
//
//  Created by Vincent on 10/30/26.
//

import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .allButUpsideDown

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.orientationLock
    }

    @MainActor
    static func setOrientationLock(
        _ mask: UIInterfaceOrientationMask,
        preferredGeometry: UIInterfaceOrientationMask? = nil
    ) {
        orientationLock = mask
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                var controller = window.rootViewController
                controller?.setNeedsUpdateOfSupportedInterfaceOrientations()
                while let presented = controller?.presentedViewController {
                    presented.setNeedsUpdateOfSupportedInterfaceOrientations()
                    controller = presented
                }
            }
            let currentMask = interfaceMask(for: windowScene.effectiveGeometry.interfaceOrientation)
            let needsGeometryUpdate = preferredGeometry != nil || (currentMask.rawValue & mask.rawValue) == 0
            if needsGeometryUpdate {
                let targetGeometry = preferredGeometry ?? mask
                windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: targetGeometry)) { _ in }
            }
        }
    }

    private static func interfaceMask(for orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
        switch orientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return .allButUpsideDown
        }
    }

    func applicationWillTerminate(_ application: UIApplication) {
        MainActor.assumeIsolated {
            BackgroundExportManager.shared.endExportTask(success: true)
        }
    }
}

@main
struct Photo_ExporterApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        let launchDate = Date()
        BackgroundExportManager.shared.register()
        MetadataCacheService.shared.performStartupStorageSweep(launchedAt: launchDate)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
