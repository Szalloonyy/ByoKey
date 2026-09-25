//
//  AgentChoiceChips.swift
//  RecallDrop
//
//  A horizontal agent picker used when capturing or sharing:
//  "Just Save", the on-device analyzer, or one of the agents.
//

import SwiftUI
import RecallDropKit

enum AgentChoice: Hashable, Sendable {
    case none
    case onDevice
    case agent(UUID)

    var agentIDs: [UUID] {
        switch self {
        case .none: []
        case .onDevice: [AgentPipeline.onDeviceAgentID]
        case .agent(let id): [id]
        }
    }

    /// The choice matching a list of agent IDs (first agent wins).
    init(agentIDs: [UUID]) {
        if let first = agentIDs.first {
            self = first == AgentPipeline.onDeviceAgentID ? .onDevice : .agent(first)
        } else {
            self = .none
        }
    }
}

struct AgentChoiceChips: View {
    let agents: [AgentConfig]
    @Binding var selection: AgentChoice
    var showsOnDevice = true

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "Just Save", emoji: "📥", color: .gray, choice: .none)
                if showsOnDevice {
                    chip(title: "On-Device", emoji: "📱", color: .gray, choice: .onDevice)
                }
                ForEach(agents) { agent in
                    chip(title: agent.displayName, emoji: agent.emoji, color: agent.agentColor.color, choice: .agent(agent.id))
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
    }

    private func chip(title: String, emoji: String, color: Color, choice: AgentChoice) -> some View {
        let isSelected = selection == choice
        return Button {
            selection = choice
        } label: {
            HStack(spacing: 5) {
                Text(emoji)
                Text(title)
                    .lineLimit(1)
            }
            .font(.subheadline.weight(isSelected ? .semibold : .regular))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? color.opacity(0.22) : Theme.placeholderFill, in: Capsule())
            .overlay {
                Capsule().strokeBorder(isSelected ? color : Color.clear, lineWidth: 1.5)
            }
            .foregroundStyle(isSelected ? color : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
