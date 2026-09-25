//
//  Badges.swift
//  RecallDrop
//
//  Small status elements shown on cards and in the detail view.
//

import SwiftUI
import RecallDropKit

/// Emoji + name of the agent that last analyzed an item.
struct AgentBadge: View {
    let emoji: String
    let name: String
    let color: AgentColor
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Text(emoji)
            if !compact {
                Text(name)
                    .lineLimit(1)
            }
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.color.opacity(0.16), in: Capsule())
        .foregroundStyle(color.color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Analyzed by \(name)")
    }
}

/// Bell with a relative time; turns red once the reminder is due.
struct ReminderBadge: View {
    let date: Date
    var showsText = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let overdue = date <= timeline.date
            HStack(spacing: 3) {
                Image(systemName: overdue ? "bell.badge.fill" : "bell.fill")
                if showsText {
                    Text(date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                        .lineLimit(1)
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(overdue ? Color.red : Color.orange)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(overdue ? "Reminder due" : "Reminder \(date.formatted(date: .abbreviated, time: .shortened))")
        }
    }
}

/// Pipeline progress, pending or failed state for an item.
struct ProcessingBadge: View {
    let item: CapturedItem
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        if let phase = environment.pipeline.phase(for: item.id) {
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                Text(phase.label)
                    .lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else if item.processingState == .failed {
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.red)
                .help(item.processingError ?? "Analysis failed")
        } else if environment.pipeline.isWaitingForAI(item) {
            Label("Waiting for AI", systemImage: "hourglass")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help(environment.settings.aiUnavailableReason ?? "Waiting for an AI provider")
        } else if item.processingState == .pending {
            Label("Waiting", systemImage: "hourglass")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// A tag as a capsule, optionally removable.
struct TagChip: View {
    let tag: String
    var isSelected = false
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text("#\(tag)")
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove tag \(tag)")
            }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Theme.placeholderFill, in: Capsule())
        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
    }
}

/// Wraps children onto new lines when they run out of horizontal space.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        let width: CGFloat
        if let proposed = proposal.width, proposed.isFinite {
            width = proposed
        } else {
            width = widest
        }
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// Quick reminder choices with the concrete time underneath.
struct ReminderPresetGrid: View {
    let schedule: ReminderSchedule
    var presets: [ReminderPreset] = ReminderPreset.allCases
    let onSelect: (Date) -> Void

    var body: some View {
        let now = Date()
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
            ForEach(presets) { preset in
                let date = preset.date(relativeTo: now, schedule: schedule)
                Button {
                    onSelect(date)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: preset.symbolName)
                            .font(.title3)
                        Text(preset.title)
                            .font(.caption.weight(.semibold))
                        Text(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Theme.placeholderFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Menu with the reminder presets, for toolbars and context menus.
struct ReminderMenuContent: View {
    let schedule: ReminderSchedule
    let hasReminder: Bool
    let onSelect: (Date) -> Void
    let onClear: () -> Void

    var body: some View {
        let now = Date()
        ForEach(ReminderPreset.allCases) { preset in
            let date = preset.date(relativeTo: now, schedule: schedule)
            Button {
                onSelect(date)
            } label: {
                Label("\(preset.title) · \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))",
                      systemImage: preset.symbolName)
            }
        }
        if hasReminder {
            Divider()
            Button(role: .destructive, action: onClear) {
                Label("Remove Reminder", systemImage: "bell.slash")
            }
        }
    }
}
