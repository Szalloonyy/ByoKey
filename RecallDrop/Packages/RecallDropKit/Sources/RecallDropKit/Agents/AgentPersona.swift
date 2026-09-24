//
//  AgentPersona.swift
//  RecallDropKit
//
//  The value type behind every agent. The app persists personas as
//  SwiftData `AgentConfig` records; the pipeline, the Markdown import/export
//  and the prompt builder work with this Sendable struct.
//

import Foundation

public struct AgentPersona: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Role, analytical framework and output guidance. RecallDrop appends its
    /// own output contract at run time, so imported prompts work unchanged.
    public var systemPrompt: String
    /// Model ID on the active provider. Empty means "use the global default".
    public var assignedModel: String
    public var temperature: Double
    public var isDefault: Bool
    /// One-line description shown in lists ("Distills the core idea…").
    public var roleDescription: String
    public var emoji: String
    public var colorName: String
    /// Set for personas that ship with the app; allows "Reset to Default".
    public var builtInKey: String?

    public init(
        id: UUID = UUID(),
        name: String,
        systemPrompt: String,
        assignedModel: String = "",
        temperature: Double = 0.5,
        isDefault: Bool = false,
        roleDescription: String = "",
        emoji: String = "🤖",
        colorName: String = AgentColor.indigo.rawValue,
        builtInKey: String? = nil
    ) {
        self.id = id
        self.name = name
        self.systemPrompt = systemPrompt
        self.assignedModel = assignedModel
        self.temperature = temperature
        self.isDefault = isDefault
        self.roleDescription = roleDescription
        self.emoji = emoji
        self.colorName = colorName
        self.builtInKey = builtInKey
    }

    public var isBuiltIn: Bool { builtInKey != nil }

    public var usesDefaultModel: Bool {
        assignedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The model to call: the per-agent override or the global default.
    public func resolvedModel(defaultModel: String) -> String {
        usesDefaultModel ? defaultModel : assignedModel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var color: AgentColor { AgentColor(loose: colorName) }

    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Agent" : trimmed
    }

    /// A copy with a new identity, used by "Duplicate".
    public func duplicated(nameSuffix: String = " Copy") -> AgentPersona {
        var copy = self
        copy.id = UUID()
        copy.name = displayName + nameSuffix
        copy.isDefault = false
        copy.builtInKey = nil
        return copy
    }
}

public enum AgentColor: String, CaseIterable, Codable, Sendable, Identifiable {
    case purple, indigo, blue, cyan, teal, mint, green, yellow, orange, red, pink, brown, gray

    public var id: String { rawValue }

    public var displayName: String { rawValue.capitalized }

    /// Accepts the loose color names found in persona files ("violet", "grey", "lime", …).
    public init(loose name: String) {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let exact = AgentColor(rawValue: key) {
            self = exact
            return
        }
        switch key {
        case "violet", "lavender", "magenta", "fuchsia": self = .purple
        case "navy", "darkblue", "royalblue": self = .indigo
        case "skyblue", "lightblue", "aqua", "turquoise": self = .cyan
        case "emerald", "lime", "olive", "forest": self = .green
        case "seafoam", "aquamarine": self = .mint
        case "gold", "amber": self = .yellow
        case "coral", "salmon", "peach": self = .orange
        case "crimson", "maroon", "scarlet": self = .red
        case "rose", "hotpink": self = .pink
        case "tan", "beige", "chocolate": self = .brown
        case "grey", "silver", "black", "white", "slate": self = .gray
        default: self = .indigo
        }
    }
}

extension AgentPersona {
    /// Emoji offered in the agent editor.
    public static let suggestedEmoji: [String] = [
        "💡", "✅", "🎨", "🔎", "🧠", "📝", "🚀", "🛒", "📚", "💼",
        "🧪", "🗺️", "🎯", "🔧", "📈", "🧭", "🎬", "🍳", "✈️", "💬"
    ]
}
