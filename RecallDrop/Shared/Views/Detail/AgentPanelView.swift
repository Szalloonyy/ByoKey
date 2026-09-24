//
//  AgentPanelView.swift
//  RecallDrop
//
//  The agent interaction panel in the detail view: run or re-run agents,
//  switch between the results of different agents, check off next steps,
//  adopt suggested tags and inspect each agent's thought process.
//

import SwiftUI
import SwiftData
import RecallDropKit

struct AgentPanelView: View {
    @Bindable var item: CapturedItem
    let onChooseAgents: () -> Void
    let onChat: () -> Void

    @Environment(AppEnvironment.self) private var environment
    @Query(sort: [SortDescriptor(\AgentConfig.sortOrder), SortDescriptor(\AgentConfig.createdAt)])
    private var agents: [AgentConfig]
    @State private var selectedRunID: UUID?

    var body: some View {
        let runs = item.sortedRuns
        let selectedRun = runs.first { $0.id == selectedRunID } ?? runs.first

        VStack(alignment: .leading, spacing: 14) {
            PanelHeader("Agents", systemImage: "sparkles")
            controls

            if let phase = environment.pipeline.phase(for: item.id) {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(phase.label)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") {
                        environment.pipeline.cancel(item.id)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(10)
                .background(Theme.placeholderFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if runs.isEmpty {
                if !environment.pipeline.isBusy(item.id) {
                    Text(emptyHint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                if runs.count > 1 {
                    runSwitcher(runs, selected: selectedRun)
                }
                if let selectedRun {
                    AgentRunResultView(item: item, run: selectedRun)
                }
            }
        }
        .panelStyle()
    }

    private var emptyHint: String {
        if let reason = environment.settings.aiUnavailableReason {
            return "\(reason) You can still run the on-device analysis."
        }
        return "Run an agent to get a title, summary, next steps and tags for this capture."
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(agents) { agent in
                    Button {
                        environment.pipeline.run([agent.id], on: item)
                    } label: {
                        Text("\(agent.emoji) \(agent.displayName)")
                    }
                }
                Divider()
                Button("📱 \(LocalAnalysis.agentName)") {
                    environment.pipeline.run([AgentPipeline.onDeviceAgentID], on: item)
                }
                Button("Choose Several…", action: onChooseAgents)
            } label: {
                Label(item.agentRuns.isEmpty ? "Analyze" : "Run Again", systemImage: "play.fill")
            } primaryAction: {
                runPreferredAgent()
            }
            .fixedSize()
            .disabled(environment.pipeline.isBusy(item.id))

            Button(action: onChooseAgents) {
                Label("Agents", systemImage: "person.2.badge.gearshape")
            }
            .disabled(environment.pipeline.isBusy(item.id))

            Spacer(minLength: 0)

            Button(action: onChat) {
                Label("Chat", systemImage: "bubble.left.and.bubble.right.fill")
            }
            .buttonStyle(.borderedProminent)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    /// Re-runs the agent that last analyzed the item, or the default agent.
    private func runPreferredAgent() {
        if let last = item.lastUsedAgentId,
           last == AgentPipeline.onDeviceAgentID || agents.contains(where: { $0.id == last }) {
            environment.pipeline.run([last], on: item)
        } else if let agent = agents.first(where: \.isDefault) ?? agents.first {
            environment.pipeline.run([agent.id], on: item)
        }
    }

    private func runSwitcher(_ runs: [AgentRun], selected: AgentRun?) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(runs) { run in
                    let isSelected = run.id == selected?.id
                    Button {
                        selectedRunID = run.id
                    } label: {
                        HStack(spacing: 4) {
                            Text(run.agentEmoji)
                            Text(run.agentName)
                                .lineLimit(1)
                            Text(run.createdAt.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption.weight(isSelected ? .semibold : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(isSelected ? run.agentColor.color.opacity(0.2) : Theme.placeholderFill, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// One agent run: summary, steps, tags, thought process and metadata.
struct AgentRunResultView: View {
    @Bindable var item: CapturedItem
    let run: AgentRun

    @Environment(AppEnvironment.self) private var environment
    @State private var showsThoughts = false
    @State private var showsRaw = false

    /// Whether this run's results are what the item currently shows.
    private var isApplied: Bool {
        item.lastUsedAgentId == run.agentId && (item.aiSummary ?? "") == run.summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                AgentBadge(emoji: run.agentEmoji, name: run.agentName, color: run.agentColor)
                Spacer()
                if !isApplied {
                    Button("Use These Results") {
                        item.adopt(run)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if !run.summary.isEmpty {
                Text(run.summary)
                    .font(.body)
                    .textSelection(.enabled)
            }

            if !run.actionableSteps.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Next Steps")
                        .font(.subheadline.weight(.semibold))
                    ForEach(Array(run.actionableSteps.enumerated()), id: \.offset) { _, step in
                        stepRow(step)
                    }
                }
            }

            let newTags = run.tags.filter { !item.tags.contains($0) }
            if !newTags.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Suggested Tags")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    FlowLayout {
                        ForEach(newTags, id: \.self) { tag in
                            Button {
                                item.setTags(item.tags + [tag])
                            } label: {
                                Label("#\(tag)", systemImage: "plus")
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Theme.placeholderFill, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if !run.thoughtProcess.isEmpty {
                DisclosureGroup(isExpanded: $showsThoughts) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(run.thoughtProcess.enumerated()), id: \.offset) { index, thought in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(index + 1)")
                                    .font(.caption.monospacedDigit().weight(.bold))
                                    .foregroundStyle(run.agentColor.color)
                                    .frame(width: 18, alignment: .trailing)
                                Text(thought)
                                    .font(.callout)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Label("Thought Process", systemImage: "brain")
                        .font(.subheadline.weight(.semibold))
                }
            }

            metadata

            DisclosureGroup(isExpanded: $showsRaw) {
                ScrollView(.horizontal) {
                    Text(run.rawOutput.isEmpty ? "(generated on this device)" : run.rawOutput)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(.vertical, 4)
                }
            } label: {
                Text("Raw Response")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(run.agentColor.color.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func stepRow(_ step: String) -> some View {
        let isDone = item.completedActionItems.contains(step)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if isApplied {
                Button {
                    item.toggleActionItem(step)
                } label: {
                    Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isDone ? Color.green : Color.secondary)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isDone ? "Mark as not done" : "Mark as done")
            } else {
                Image(systemName: "arrow.right.circle")
                    .foregroundStyle(.secondary)
            }
            Text(step)
                .font(.callout)
                .strikethrough(isApplied && isDone)
                .foregroundStyle(isApplied && isDone ? .secondary : .primary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .contextMenu {
            Button {
                Clipboard.copy(step)
            } label: {
                Label("Copy Step", systemImage: "doc.on.doc")
            }
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if run.isOffline {
                    Label("On device", systemImage: "lock.shield")
                } else {
                    Label(run.modelIdentifier, systemImage: "cpu")
                        .lineLimit(1)
                    if let provider = run.provider {
                        Text(provider.displayName)
                    }
                }
                Text(String(format: "%.1f s", run.durationSeconds))
                if let tokens = run.tokenSummary {
                    Text(tokens)
                }
                if let confidence = run.confidence {
                    Text("\(Int((confidence * 100).rounded())) % sure")
                }
                if run.usedImage {
                    Image(systemName: "photo")
                        .accessibilityLabel("Image was analyzed")
                }
            }
            ForEach(run.adjustmentNotes, id: \.self) { note in
                Label(note, systemImage: "info.circle")
            }
            if !run.wasStructured {
                Label("The model did not return structured JSON; results were read from plain text.", systemImage: "info.circle")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}
