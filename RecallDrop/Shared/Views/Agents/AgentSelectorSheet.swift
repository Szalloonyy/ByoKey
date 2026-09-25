//
//  AgentSelectorSheet.swift
//  RecallDrop
//
//  Bottom sheet to pick one agent – or several, run as a chain where each
//  agent builds on the previous agents' results.
//

import SwiftUI
import SwiftData
import RecallDropKit

struct AgentSelectorSheet: View {
    let item: CapturedItem

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\AgentConfig.sortOrder), SortDescriptor(\AgentConfig.createdAt)])
    private var agents: [AgentConfig]

    @State private var isChainMode = false
    @State private var chain: [UUID] = []

    var body: some View {
        NavigationStack {
            List {
                if let reason = environment.settings.aiUnavailableReason {
                    Section {
                        Label(reason, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    Toggle(isOn: $isChainMode.animation()) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Chain Several Agents")
                            Text("Agents run in the order you tap them; each sees the earlier results.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Agents") {
                    ForEach(agents) { agent in
                        Button {
                            select(agent.id)
                        } label: {
                            AgentRow(agent: agent, chainPosition: chain.firstIndex(of: agent.id).map { $0 + 1 },
                                     showsChainIndicator: isChainMode)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section {
                    Button {
                        environment.pipeline.run([AgentPipeline.onDeviceAgentID], on: item)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Text("📱")
                                .font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(LocalAnalysis.agentName)
                                    .font(.body.weight(.medium))
                                Text("Title, tags and next steps from text recognition and data detection. Never leaves this device.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle(isChainMode ? "Build a Chain" : "Run an Agent")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if isChainMode {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Run \(chain.count)") {
                            environment.pipeline.run(chain, on: item)
                            dismiss()
                        }
                        .disabled(chain.isEmpty)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }

    private func select(_ agentID: UUID) {
        if isChainMode {
            if let index = chain.firstIndex(of: agentID) {
                chain.remove(at: index)
            } else {
                chain.append(agentID)
            }
        } else {
            environment.pipeline.run([agentID], on: item)
            dismiss()
        }
    }
}

/// Agent row used in pickers and the agent manager.
struct AgentRow: View {
    let agent: AgentConfig
    var chainPosition: Int?
    var showsChainIndicator = false

    var body: some View {
        HStack(spacing: 12) {
            Text(agent.emoji)
                .font(.title2)
                .frame(width: 40, height: 40)
                .background(agent.agentColor.color.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.displayName)
                        .font(.body.weight(.medium))
                    if agent.isDefault {
                        Text("Default")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }
                if !agent.roleDescription.isEmpty {
                    Text(agent.roleDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(agent.preferredModel ?? "Default model")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if showsChainIndicator {
                if let chainPosition {
                    Text("\(chainPosition)")
                        .font(.callout.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(agent.agentColor.color, in: Circle())
                } else {
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.5)
                        .frame(width: 26, height: 26)
                }
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}
