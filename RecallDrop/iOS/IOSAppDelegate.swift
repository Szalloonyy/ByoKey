//
//  IOSAppDelegate.swift
//  RecallDrop (iOS)
//
//  Installs the notification delegate before launch completes, so tapping a
//  reminder while the app is not running still opens the capture, and
//  offers home screen quick actions.
//

import SwiftUI
import UIKit

final class IOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        NotificationCoordinator.shared.installDelegate()
        AppEnvironment.shared.start()
        application.shortcutItems = [
            UIApplicationShortcutItem(type: QuickAction.capture.rawValue, localizedTitle: "New Capture",
                                      localizedSubtitle: nil, icon: UIApplicationShortcutIcon(systemImageName: "plus.circle"),
                                      userInfo: nil),
            UIApplicationShortcutItem(type: QuickAction.note.rawValue, localizedTitle: "Quick Note",
                                      localizedSubtitle: nil, icon: UIApplicationShortcutIcon(systemImageName: "note.text"),
                                      userInfo: nil),
            UIApplicationShortcutItem(type: QuickAction.search.rawValue, localizedTitle: "Search",
                                      localizedSubtitle: nil, icon: UIApplicationShortcutIcon(systemImageName: "magnifyingglass"),
                                      userInfo: nil)
        ]
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if let shortcut = options.shortcutItem {
            QuickAction(rawValue: shortcut.type)?.perform()
        }
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = QuickActionSceneDelegate.self
        return configuration
    }
}

/// Receives quick actions while the app is already running.
final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let action = QuickAction(rawValue: shortcutItem.type)
        action?.perform()
        completionHandler(action != nil)
    }
}

enum QuickAction: String {
    case capture = "com.recalldrop.capture"
    case note = "com.recalldrop.note"
    case search = "com.recalldrop.search"

    @MainActor
    func perform() {
        let router = AppEnvironment.shared.router
        switch self {
        case .capture:
            router.selectedTab = .library
            router.isCapturePresented = true
        case .note:
            router.selectedTab = .library
            router.isNewNotePresented = true
        case .search:
            router.selectedTab = .search
        }
    }
}
