//
//  AgentLibrary.swift
//  RecallDrop
//
//  Manages the stored agents: seeding the built-ins, keeping exactly one
//  default, creating, duplicating, deleting, and Markdown import/export in
//  the agency-agents format.
//

import Foundation
import SwiftData
import RecallDropKit

@MainActor
final class AgentLibrary {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    private var context: ModelContext { container.mainContext }

    var allAgents: [AgentConfig] { AgentConfig.allSorted(in: context) }

    /// Inserts built-in agents that are missing (first launch, or new ones in an update).
    func seedBuiltInsIfNeeded() {
        let existing = allAgents
        let existingKeys = Set(existing.compactMap(\.builtInKey))
        let existingIDs = Set(existing.map(\.id))
        var nextOrder = (existing.map(\.sortOrder).max() ?? -1) + 1
        var inserted = false
        for persona in BuiltInPersonas.all
        where !existingKeys.contains(persona.builtInKey ?? "") && !existingIDs.contains(persona.id) {
            var seeded = persona
            // Only the very first seeding may set the default.
            seeded.isDefault = existing.isEmpty && persona.isDefault
            context.insert(AgentConfig(persona: seeded, sortOrder: nextOrder))
            nextOrder += 1
            inserted = true
        }
        if inserted { save() }
        ensureSingleDefault()
    }

    func defaultAgent() -> AgentConfig? {
        let agents = allAgents
        return agents.first(where: \.isDefault) ?? agents.first
    }

    func setDefault(_ agent: AgentConfig) {
        for other in allAgents where other.isDefault && other.id != agent.id {
            other.isDefault = false
        }
        agent.isDefault = true
        save()
    }

    @discardableResult
    func create(from persona: AgentPersona, importSource: String? = nil) -> AgentConfig {
        let order = (allAgents.map(\.sortOrder).max() ?? -1) + 1
        var newPersona = persona
        newPersona.isDefault = false
        newPersona.builtInKey = nil
        if AgentConfig.fetch(id: newPersona.id, in: context) != nil {
            newPersona.id = UUID()
        }
        let agent = AgentConfig(persona: newPersona, sortOrder: order)
        agent.importSource = importSource
        context.insert(agent)
        save()
        return agent
    }

    @discardableResult
    func createBlank() -> AgentConfig {
        create(from: AgentPersona(
            name: "New Agent",
            systemPrompt: Self.blankPromptTemplate,
            roleDescription: "Describe what this agent is good at.",
            emoji: "🤖",
            colorName: AgentColor.teal.rawValue
        ))
    }

    @discardableResult
    func duplicate(_ agent: AgentConfig) -> AgentConfig {
        create(from: agent.persona.duplicated())
    }

    /// Built-in agents can be edited and reset, but not deleted.
    func delete(_ agent: AgentConfig) {
        guard !agent.isBuiltIn else { return }
        let wasDefault = agent.isDefault
        context.delete(agent)
        save()
        if wasDefault { ensureSingleDefault() }
    }

    /// Reorders `displayed` (the agents of one list section) like `List.onMove`:
    /// `destination` is an index in `displayed`. Agents outside the section
    /// keep their positions.
    func move(_ displayed: [AgentConfig], from source: IndexSet, to destination: Int) {
        let moving = source.compactMap { displayed.indices.contains($0) ? displayed[$0] : nil }
        var reordered = displayed.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertion = destination - source.filter { $0 < destination }.count
        reordered.insert(contentsOf: moving, at: max(0, min(insertion, reordered.count)))

        let sectionIDs = Set(displayed.map(\.id))
        var next = reordered.makeIterator()
        let merged = allAgents.map { agent in
            sectionIDs.contains(agent.id) ? (next.next() ?? agent) : agent
        }
        for (index, agent) in merged.enumerated() {
            agent.sortOrder = index
        }
        save()
    }

    // MARK: Import / export

    @discardableResult
    func importMarkdown(_ markdown: String, fallbackName: String? = nil, source: String? = nil) throws -> AgentConfig {
        let persona = try PersonaMarkdownCodec.decode(markdown, fallbackName: fallbackName)
        return create(from: persona, importSource: source)
    }

    func importMarkdown(from url: URL) async throws -> AgentConfig {
        let markdown = try await AgencyAgentsCatalog.fetchMarkdown(from: url)
        return try importMarkdown(markdown, fallbackName: url.lastPathComponent, source: url.absoluteString)
    }

    func exportMarkdown(_ agent: AgentConfig) -> String {
        PersonaMarkdownCodec.encode(agent.persona)
    }

    // MARK: Private

    private func ensureSingleDefault() {
        let agents = allAgents
        let defaults = agents.filter(\.isDefault)
        if defaults.count == 1 { return }
        for agent in defaults.dropFirst() { agent.isDefault = false }
        if defaults.isEmpty, let first = agents.first(where: { $0.builtInKey == BuiltInPersonas.Key.ideaExtractor.rawValue }) ?? agents.first {
            first.isDefault = true
        }
        save()
    }

    private func save() {
        guard context.hasChanges else { return }
        try? context.save()
    }

    static let blankPromptTemplate = """
    # New Agent

    You are **New Agent**, a specialist who …

    ## 🧠 Your Identity & Memory
    - **Role**: …
    - **Personality**: …

    ## 🎯 Your Core Mission
    - …

    ## 🚨 Critical Rules You Must Follow
    - Ground everything in what the capture actually shows.

    ## 📋 How to Fill the Output
    - **title**: …
    - **summary**: …
    - **actionableSteps**: …
    - **tags**: …
    - **thoughtProcess**: …

    ## 💭 Your Communication Style
    - …
    """
}
