//
//  MacHUD.swift
//  RecallDrop (macOS)
//
//  A short floating message at the top of the screen for actions started by
//  a global shortcut while another app is in front – RecallDrop's own toast
//  only appears inside its windows.
//

import AppKit
import SwiftUI

@MainActor
final class MacHUD {
    static let shared = MacHUD()

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ message: String) {
        let panel = panel ?? makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: HUDMessageView(message: message))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2,
                                         y: visible.maxY - panel.frame.height - 12))
        }
        panel.orderFrontRegardless()

        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 48),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }
}

private struct HUDMessageView: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "tray.and.arrow.down.fill")
            .font(.callout.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(8)
            .fixedSize()
    }
}
