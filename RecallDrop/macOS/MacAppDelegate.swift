//
//  MacAppDelegate.swift
//  RecallDrop (macOS)
//
//  Launch-time setup: notifications, global shortcuts, Dock icon policy and
//  the Drop Shelf. RecallDrop keeps running in the menu bar when its last
//  window closes.
//

import AppKit
import SwiftUI

final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCoordinator.shared.installDelegate()
        let environment = AppEnvironment.shared
        environment.start()

        Self.applyActivationPolicy(hideDockIcon: environment.settings.hideDockIcon)

        HotKeyCenter.shared.onAction = { action in
            MacCaptureCoordinator.shared.perform(action)
        }
        HotKeyCenter.shared.apply(HotKeyBindings.load(from: environment.settings))

        if environment.settings.showDropShelfAtLaunch {
            DropShelfController.shared.show()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MacCaptureCoordinator.shared.openMainWindow()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyCenter.shared.unregisterAll()
        try? AppEnvironment.shared.container.mainContext.save()
    }

    static func applyActivationPolicy(hideDockIcon: Bool) {
        NSApp.setActivationPolicy(hideDockIcon ? .accessory : .regular)
        if !hideDockIcon {
            NSApp.activate()
        }
    }
}
