//
//  DropShelf.swift
//  RecallDrop (macOS)
//
//  The persistent drop target: a small floating panel that stays above other
//  windows on every Space. Drag images, files or links from Finder, Safari or
//  any app onto it – onto the big zone for the default agent, or onto an
//  agent's tile to run that agent right away. Clicking it never steals focus.
//

import AppKit
import Observation
import SwiftUI
import SwiftData
import RecallDropKit

@MainActor
@Observable
final class DropShelfController {
    static let shared = DropShelfController()

    private(set) var isVisible = false
    @ObservationIgnored private var panel: NSPanel?

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.orderFrontRegardless()
        isVisible = true
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }

    fileprivate func panelDidClose() {
        isVisible = false
    }

    private func makePanel() -> NSPanel {
        let panel = ShelfPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 260),
            styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Drop Shelf"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onClose = { [weak self] in self?.panelDidClose() }
        panel.contentView = NSHostingView(rootView: DropShelfView().rootEnvironment(AppEnvironment.shared))

        if !panel.setFrameUsingName("RecallDropDropShelf"), let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 24, y: visible.midY - panel.frame.height / 2))
        }
        panel.setFrameAutosaveName("RecallDropDropShelf")
        return panel
    }
}

/// Reports the close button so the controller's state stays accurate.
final class ShelfPanel: NSPanel {
    var onClose: (() -> Void)?

    override func close() {
        super.close()
        onClose?()
    }
}

struct DropShelfView: View {
    @Environment(AppEnvironment.self) private var environment
    @Query(sort: [SortDescriptor(\AgentConfig.sortOrder), SortDescriptor(\AgentConfig.createdAt)])
    private var agents: [AgentConfig]

    @State private var targetedZone: String?
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "tray.and.arrow.down.fill")
                    .foregroundStyle(Color.accentColor)
                Text("Drop Shelf")
                    .font(.headline)
                Spacer()
                if environment.pipeline.busyCount > 0 {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            dropZone(id: "default", height: 84) {
                VStack(spacing: 3) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.title2)
                    Text("Capture")
                        .font(.callout.weight(.semibold))
                    Text(defaultDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } onDrop: { providers in
                await MacCaptureCoordinator.shared.capture(providers: providers)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
                ForEach(agents.prefix(5)) { agent in
                    dropZone(id: agent.id.uuidString, height: 54, tint: agent.agentColor.color) {
                        VStack(spacing: 2) {
                            Text(agent.emoji)
                            Text(agent.displayName)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                    } onDrop: { providers in
                        await MacCaptureCoordinator.shared.capture(providers: providers, agentIDs: [agent.id])
                    }
                }
                dropZone(id: "on-device", height: 54, tint: .gray) {
                    VStack(spacing: 2) {
                        Text("📱")
                        Text("On-Device")
                            .font(.caption2)
                    }
                } onDrop: { providers in
                    await MacCaptureCoordinator.shared.capture(providers: providers, agentIDs: [AgentPipeline.onDeviceAgentID])
                }
            }

            Text(status ?? "Drop onto an agent to analyze with it.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(14)
        .frame(width: 300)
        .background(.regularMaterial)
    }

    private var defaultDescription: String {
        if !environment.settings.autoAnalyze { return "Save without analysis" }
        if environment.settings.offlineOnly { return "On-device analysis" }
        return agents.first(where: \.isDefault).map { "with \($0.emoji) \($0.displayName)" } ?? "with the default agent"
    }

    private func dropZone<Label: View>(
        id: String,
        height: CGFloat,
        tint: Color = .accentColor,
        @ViewBuilder label: () -> Label,
        onDrop: @escaping ([NSItemProvider]) async -> Int
    ) -> some View {
        let isTargeted = targetedZone == id
        return RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(isTargeted ? tint.opacity(0.22) : Color.primary.opacity(0.05))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isTargeted ? tint : Color.primary.opacity(0.12),
                                  style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: isTargeted ? [] : [6, 4]))
            }
            .overlay { label() }
            .frame(height: height)
            .onDrop(of: ItemProviderLoader.supportedTypes, isTargeted: Binding(
                get: { targetedZone == id },
                set: { targeted in
                    if targeted {
                        targetedZone = id
                    } else if targetedZone == id {
                        targetedZone = nil
                    }
                }
            )) { providers in
                status = "Capturing…"
                Task {
                    let count = await onDrop(providers)
                    status = count > 0 ? "Captured \(count) item\(count == 1 ? "" : "s")." : "Nothing to capture in that drop."
                }
                return true
            }
    }
}
