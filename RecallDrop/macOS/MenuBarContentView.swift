//
//  MenuBarContentView.swift
//  RecallDrop (macOS)
//
//  The MenuBarExtra panel: a drop zone, quick capture actions, a field for
//  fleeting ideas and the most recent captures with one-click agent runs.
//

import AppKit
import SwiftUI
import SwiftData
import RecallDropKit

struct MenuBarContentView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \CapturedItem.createdAt, order: .reverse) private var items: [CapturedItem]
    @Query(sort: [SortDescriptor(\AgentConfig.sortOrder), SortDescriptor(\AgentConfig.createdAt)])
    private var agents: [AgentConfig]

    @State private var noteText = ""
    @State private var isDropTargeted = false
    @FocusState private var isNoteFocused: Bool

    private var recentItems: [CapturedItem] {
        Array(items.lazy.filter { !$0.isArchived }.prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            dropZone
            quickActions
            noteField
            Divider()
            recentSection
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 380)
        .onAppear {
            MacCaptureCoordinator.shared.openWindowAction = openWindow
        }
        .overlay(alignment: .bottom) {
            if let message = environment.router.toastMessage {
                Text(message)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 48)
                    .task(id: message) {
                        try? await Task.sleep(nanoseconds: 2_200_000_000)
                        environment.router.toastMessage = nil
                    }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down.fill")
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Theme.brandGradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("RecallDrop")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open") {
                MacCaptureCoordinator.shared.openMainWindow()
            }
            .controlSize(.small)
        }
    }

    private var statusText: String {
        let busy = environment.pipeline.busyCount
        if busy > 0 { return "Analyzing \(busy) capture\(busy == 1 ? "" : "s")…" }
        if environment.settings.offlineOnly { return "Offline Only – on-device analysis" }
        if let reason = environment.settings.aiUnavailableReason { return reason }
        let agent = agents.first(where: \.isDefault)?.displayName ?? "default agent"
        return "New captures go to \(agent)"
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                          style: StrokeStyle(lineWidth: isDropTargeted ? 2.5 : 1.5, dash: [7, 5]))
            .background((isDropTargeted ? Color.accentColor.opacity(0.1) : Color.clear),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(height: 74)
            .overlay {
                VStack(spacing: 4) {
                    Image(systemName: "arrow.down.to.line.compact")
                        .font(.title3)
                    Text("Drop images, files or links here")
                        .font(.callout)
                }
                .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)
            }
            .onDrop(of: ItemProviderLoader.supportedTypes, isTargeted: $isDropTargeted) { providers in
                Task {
                    let count = await MacCaptureCoordinator.shared.capture(providers: providers)
                    environment.router.showToast(count > 0 ? "Captured \(count) item\(count == 1 ? "" : "s")." : "Nothing to capture.")
                }
                return true
            }
    }

    private var quickActions: some View {
        HStack(spacing: 8) {
            quickButton("Paste", systemImage: "doc.on.clipboard") {
                Task { await MacCaptureCoordinator.shared.captureClipboard() }
            }
            quickButton("Screenshot", systemImage: "rectangle.dashed") {
                Task { await MacCaptureCoordinator.shared.captureScreenRegion() }
            }
            quickButton("Import", systemImage: "photo.badge.plus") {
                MacCaptureCoordinator.shared.importFiles()
            }
            quickButton(DropShelfController.shared.isVisible ? "Hide Shelf" : "Drop Shelf", systemImage: "tray.2") {
                DropShelfController.shared.toggle()
            }
        }
    }

    private func quickButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Theme.placeholderFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var noteField: some View {
        HStack(spacing: 8) {
            Image(systemName: "lightbulb")
                .foregroundStyle(.secondary)
            TextField("Jot down a fleeting idea…", text: $noteText)
                .textFieldStyle(.plain)
                .focused($isNoteFocused)
                .onSubmit(saveNote)
            if noteText.trimmedNonEmpty != nil {
                Button("Save", action: saveNote)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.placeholderFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func saveNote() {
        let text = noteText
        guard text.trimmedNonEmpty != nil else { return }
        noteText = ""
        Task {
            await environment.capture.captureText(text)
            environment.router.showToast("Idea saved.")
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        Text("Recent")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        if recentItems.isEmpty {
            Text("Nothing captured yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 6) {
                ForEach(recentItems) { item in
                    MenuBarRecentRow(item: item, agents: Array(agents.prefix(4)))
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            SettingsLink {
                Label("Settings…", systemImage: "gearshape")
            }
            .buttonStyle(.borderless)
            Spacer()
            Button("Quit RecallDrop") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
        }
        .font(.callout)
    }
}

private struct MenuBarRecentRow: View {
    let item: CapturedItem
    let agents: [AgentConfig]

    @Environment(AppEnvironment.self) private var environment
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                MacCaptureCoordinator.shared.open(itemID: item.id)
            } label: {
                HStack(spacing: 10) {
                    thumbnail
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayTitle)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            if let phase = environment.pipeline.phase(for: item.id) {
                                ProgressView()
                                    .controlSize(.mini)
                                Text(phase.label)
                            } else {
                                Text(item.createdAt.formatted(.relative(presentation: .named)))
                                if let name = item.lastUsedAgentName {
                                    Text("· \(item.lastUsedAgentEmoji ?? "") \(name)")
                                }
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 2) {
                ForEach(agents) { agent in
                    Button {
                        environment.pipeline.run([agent.id], on: item)
                    } label: {
                        Text(agent.emoji)
                            .frame(width: 24, height: 24)
                            .background(agent.agentColor.color.opacity(isHovered ? 0.18 : 0.08), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("Run \(agent.displayName)")
                    .disabled(environment.pipeline.isBusy(item.id))
                }
            }
        }
        .padding(6)
        .background(isHovered ? Theme.placeholderFill : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if item.hasImage {
            CaptureImageView(cacheKey: item.thumbnailCacheKey, data: item.thumbnailData, maxPixelSize: 120)
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Image(systemName: item.kind.symbolName)
                .frame(width: 36, height: 36)
                .background(Theme.placeholderFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

/// Menu bar icon; switches to sparkles while agents are working.
struct MenuBarLabel: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Image(systemName: environment.pipeline.busyCount > 0 ? "sparkles" : "tray.and.arrow.down.fill")
            .accessibilityLabel("RecallDrop")
    }
}
