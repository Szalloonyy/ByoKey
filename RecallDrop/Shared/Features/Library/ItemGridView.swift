//
//  ItemGridView.swift
//  RecallDrop
//
//  The visual masonry grid. Items are distributed into columns by their
//  estimated height (RecallDropKit.MasonryDistributor); every column is a
//  LazyVStack, so only visible cards are built even for large libraries.
//

import SwiftUI
import SwiftData
import RecallDropKit

struct ItemGridView: View {
    let items: [CapturedItem]
    var highlightTerms: [String] = []

    @Environment(AppEnvironment.self) private var environment

    private let spacing: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            let density = environment.settings.gridDensity
            let horizontalPadding: CGFloat = 16
            let available = max(proxy.size.width - horizontalPadding * 2, 1)
            let columns = MasonryDistributor.columnCount(
                forWidth: Double(available),
                minimumColumnWidth: density.minimumCardWidth,
                spacing: Double(spacing),
                maximumColumns: 7
            )
            let columnWidth = (available - spacing * CGFloat(columns - 1)) / CGFloat(columns)

            ScrollView {
                MasonryColumns(items: items, columns: columns, columnWidth: columnWidth, spacing: spacing) { item in
                    NavigationLink(value: item.id) {
                        ItemCardView(item: item, highlightTerms: highlightTerms)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { ItemContextMenu(item: item) }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 12)
            }
        }
    }
}

struct MasonryColumns<Content: View>: View {
    let items: [CapturedItem]
    let columns: Int
    let columnWidth: CGFloat
    let spacing: CGFloat
    @ViewBuilder let content: (CapturedItem) -> Content

    var body: some View {
        let heights = items.map { Double(Self.estimatedHeight(of: $0, width: columnWidth)) }
        let buckets = MasonryDistributor.distribute(heights: heights, columns: columns, spacing: Double(spacing))
        HStack(alignment: .top, spacing: spacing) {
            ForEach(buckets.indices, id: \.self) { column in
                LazyVStack(spacing: spacing) {
                    ForEach(buckets[column].map { items[$0] }) { item in
                        content(item)
                    }
                }
                .frame(width: columnWidth, alignment: .top)
            }
        }
    }

    /// Rough card height used only to balance the columns.
    static func estimatedHeight(of item: CapturedItem, width: CGFloat) -> CGFloat {
        var height: CGFloat = 64
        if item.hasImage {
            height += width * CGFloat(item.aspectRatio)
        } else if item.kind == .link {
            height += 52
        } else {
            height += 90
        }
        if item.lastUsedAgentName != nil || item.reminderDate != nil { height += 22 }
        return height
    }
}

/// Actions available on every card (context menu) and in the detail view's menu.
struct ItemContextMenu: View {
    let item: CapturedItem

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Button {
            item.isPinned.toggle()
            item.touch()
        } label: {
            Label(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash" : "pin")
        }

        Menu {
            AgentRunMenuContent(item: item)
        } label: {
            Label("Run Agent", systemImage: "sparkles")
        }

        Menu {
            ReminderMenuContent(
                schedule: environment.settings.reminderSchedule,
                hasReminder: item.hasReminder,
                onSelect: { date in Task { await environment.reminders.schedule(item, at: date) } },
                onClear: { environment.reminders.cancelReminder(for: item) }
            )
        } label: {
            Label("Remind Me", systemImage: "bell")
        }

        Divider()

        if let text = item.extractedText?.trimmedNonEmpty {
            Button {
                Clipboard.copy(text)
            } label: {
                Label("Copy Text", systemImage: "doc.on.doc")
            }
        }
        Button {
            Clipboard.copy(item.markdownExport)
        } label: {
            Label("Copy as Markdown", systemImage: "doc.plaintext")
        }
        if let url = item.sourceURL {
            Link(destination: url) {
                Label("Open Link", systemImage: "safari")
            }
        }

        Divider()

        Button {
            item.isArchived.toggle()
            item.touch()
        } label: {
            Label(item.isArchived ? "Move to Inbox" : "Archive", systemImage: item.isArchived ? "tray.and.arrow.up" : "archivebox")
        }
        Button(role: .destructive) {
            LibraryMaintenance.delete([item], environment: environment)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

/// One button per agent, plus the on-device analyzer.
struct AgentRunMenuContent: View {
    let item: CapturedItem

    @Environment(AppEnvironment.self) private var environment
    @Query(sort: [SortDescriptor(\AgentConfig.sortOrder), SortDescriptor(\AgentConfig.createdAt)])
    private var agents: [AgentConfig]

    var body: some View {
        ForEach(agents) { agent in
            Button("\(agent.emoji) \(agent.displayName)") {
                environment.pipeline.run([agent.id], on: item)
            }
        }
        if agents.count > 1 {
            Button("⛓ Run All Agents in Sequence") {
                environment.pipeline.run(agents.map(\.id), on: item)
            }
        }
        Divider()
        Button("📱 \(LocalAnalysis.agentName)") {
            environment.pipeline.run([AgentPipeline.onDeviceAgentID], on: item)
        }
    }
}
