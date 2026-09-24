//
//  MacSettingsView.swift
//  RecallDrop (macOS)
//
//  The Settings window (⌘,), including the Mac-only menu bar, Drop Shelf,
//  global shortcut and launch-at-login options.
//

import AppKit
import CoreGraphics
import ServiceManagement
import SwiftUI

struct MacSettingsView: View {
    var body: some View {
        TabView {
            NavigationStack { CaptureSettingsView() }
                .tabItem { Label("General", systemImage: "gearshape") }
            NavigationStack { AISettingsView() }
                .tabItem { Label("AI Provider", systemImage: "cpu") }
            NavigationStack { MenuBarSettingsView() }
                .tabItem { Label("Menu Bar & Shortcuts", systemImage: "command") }
            NavigationStack { ReminderSettingsView() }
                .tabItem { Label("Reminders", systemImage: "bell") }
            NavigationStack { DataSettingsView() }
                .tabItem { Label("Data", systemImage: "externaldrive") }
        }
        .frame(width: 680, height: 600)
    }
}

struct MenuBarSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var bindings = HotKeyBindings()
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?
    @State private var hasScreenRecording = ScreenCaptureService.hasPermission

    var body: some View {
        @Bindable var settings = environment.settings
        Form {
            Section("Menu Bar") {
                Toggle("Show Drop Shelf When RecallDrop Starts", isOn: $settings.showDropShelfAtLaunch)
                Toggle("Hide Dock Icon", isOn: $settings.hideDockIcon)
                    .onChange(of: settings.hideDockIcon) { _, hide in
                        MacAppDelegate.applyActivationPolicy(hideDockIcon: hide)
                    }
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            try LaunchAtLogin.setEnabled(enabled)
                            launchError = nil
                        } catch {
                            launchError = error.localizedDescription
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    }
                if let launchError {
                    Text(launchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section {
                ForEach(HotKeyAction.allCases) { action in
                    LabeledContent(action.title) {
                        HStack {
                            if HotKeyCenter.shared.conflicts.contains(action) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .help("Another app already uses this shortcut.")
                            }
                            ShortcutRecorderView(combo: bindings.combo(for: action)) { combo in
                                bindings.set(combo, for: action)
                                bindings.save(to: environment.settings)
                                HotKeyCenter.shared.apply(bindings)
                            }
                        }
                    }
                }
                Button("Restore Default Shortcuts") {
                    bindings = HotKeyBindings()
                    bindings.save(to: environment.settings)
                    HotKeyCenter.shared.apply(bindings)
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Global Shortcuts")
            } footer: {
                Text("Shortcuts work in every app. Click a shortcut and press a new combination with ⌘, ⌥ or ⌃; press Delete to turn it off.")
            }

            Section {
                LabeledContent("Screen Recording", value: hasScreenRecording ? "Allowed" : "Not Allowed")
                if !hasScreenRecording {
                    Button("Open Privacy Settings") {
                        _ = CGRequestScreenCaptureAccess()
                        if let url = ScreenCaptureService.settingsURL { NSWorkspace.shared.open(url) }
                    }
                }
            } header: {
                Text("Screen Capture")
            } footer: {
                Text("Needed only for “Capture Screen Region”. Dropping or pasting screenshots works without it.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Menu Bar & Shortcuts")
        .onAppear {
            bindings = HotKeyBindings.load(from: environment.settings)
            hasScreenRecording = ScreenCaptureService.hasPermission
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
