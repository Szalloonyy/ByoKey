//
//  QuickNotePanel.swift
//  RecallDrop (macOS)
//
//  A Spotlight-style floating field for fleeting ideas, opened with a global
//  shortcut from any app. Return saves, Escape closes.
//

import AppKit
import SwiftUI
import RecallDropKit

@MainActor
final class QuickNotePanelController {
    static let shared = QuickNotePanelController()

    private var panel: KeyablePanel?

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: QuickNoteView { [weak self] in self?.hide() }
            .rootEnvironment(AppEnvironment.shared))
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.maxY - visible.height * 0.28))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> KeyablePanel {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 120),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        return panel
    }
}

/// A non-activating panel that can still receive keyboard input.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct QuickNoteView: View {
    let onClose: () -> Void

    @Environment(AppEnvironment.self) private var environment
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "lightbulb.fill")
                    .font(.title2)
                    .foregroundStyle(.yellow)
                TextField("Capture a fleeting idea…", text: $text)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isFocused)
                    .onSubmit(save)
            }
            Text("Return to save · Esc to close · analyzed by your default agent")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 560)
        .background(.regularMaterial)
        .onAppear { isFocused = true }
        .onExitCommand(perform: onClose)
    }

    private func save() {
        let note = text
        guard note.trimmedNonEmpty != nil else {
            onClose()
            return
        }
        text = ""
        onClose()
        Task { _ = await environment.capture.captureText(note) }
    }
}
