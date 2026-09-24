//
//  RecallDropApp.swift
//  RecallDrop
//
//  App entry point for iOS and macOS.
//
//  macOS: a single main window with sidebar navigation, detail windows per capture,
//  the menu bar extra (quick capture, recent items, one-click agents) and
//  the Settings window. iOS: a tab-based single window scene.
//

import SwiftUI
import SwiftData

@main
struct RecallDropApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(IOSAppDelegate.self) private var appDelegate
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    #endif

    @State private var environment = AppEnvironment.shared

    var body: some Scene {
        #if os(macOS)
        Window("RecallDrop", id: WindowID.main) {
            MacRootView()
                .rootEnvironment(environment)
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            RecallDropCommands(environment: environment)
        }

        WindowGroup("Capture", id: WindowID.item, for: UUID.self) { $itemID in
            if let itemID {
                NavigationStack {
                    ItemDetailView(itemID: itemID)
                }
                .rootEnvironment(environment)
            }
        }
        .defaultSize(width: 760, height: 860)

        MenuBarExtra {
            MenuBarContentView()
                .rootEnvironment(environment)
        } label: {
            MenuBarLabel()
                .environment(environment)
        }
        .menuBarExtraStyle(.window)

        Settings {
            MacSettingsView()
                .rootEnvironment(environment)
        }
        #else
        WindowGroup {
            IOSRootView()
                .rootEnvironment(environment)
        }
        #endif
    }
}

extension View {
    /// Everything a top-level view needs: the environment, the store and the tint.
    func rootEnvironment(_ environment: AppEnvironment) -> some View {
        self
            .environment(environment)
            .modelContainer(environment.container)
            .tint(Color("AccentColor"))
    }
}
