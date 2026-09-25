//
//  AgentConfig+Logic.swift
//  RecallDrop
//
//  Bridges the stored `AgentConfig` and the `AgentPersona` value type the
//  pipeline, the prompt builder and Markdown import/export work with.
//

import Foundation
import SwiftData
import RecallDropKit

extension AgentConfig {
    convenience init(persona: AgentPersona, sortOrder: Int) {
        self.init(id: persona.id, name: persona.displayName)
        self.sortOrder = sortOrder
        self.isBuiltIn = persona.builtInKey != nil
        self.builtInKey = persona.builtInKey
        apply(persona)
    }

    var persona: AgentPersona {
        AgentPersona(
            id: id,
            name: name,
            systemPrompt: systemInstructions,
            assignedModel: preferredModel ?? "",
            temperature: temperature,
            isDefault: isDefault,
            roleDescription: roleDescription,
            emoji: emoji,
            colorName: colorName,
            builtInKey: builtInKey
        )
    }

    var agentColor: AgentColor { AgentColor(loose: colorName) }

    var displayName: String { persona.displayName }

    var usesDefaultModel: Bool { preferredModel?.trimmedNonEmpty == nil }

    /// Copies editable fields from `persona`. Identity and built-in status stay.
    func apply(_ persona: AgentPersona) {
        name = persona.displayName
        roleDescription = persona.roleDescription
        systemInstructions = persona.systemPrompt
        preferredModel = persona.assignedModel.trimmedNonEmpty
        temperature = min(max(persona.temperature, 0), 2)
        emoji = persona.emoji.trimmedNonEmpty ?? "🤖"
        colorName = persona.color.rawValue
        updatedAt = Date()
    }

    /// Restores a built-in agent's shipped prompt and settings.
    func resetToBuiltIn() {
        guard let builtInKey, let original = BuiltInPersonas.persona(forBuiltInKey: builtInKey) else { return }
        apply(original)
    }

    static func fetch(id agentID: UUID, in context: ModelContext) -> AgentConfig? {
        var descriptor = FetchDescriptor<AgentConfig>(predicate: #Predicate { $0.id == agentID })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    static func allSorted(in context: ModelContext) -> [AgentConfig] {
        let descriptor = FetchDescriptor<AgentConfig>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }
}
