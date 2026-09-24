//
//  AgentOutput.swift
//  RecallDropKit
//
//  The structured result every agent produces, whatever its persona.
//

import Foundation

public struct AgentOutput: Codable, Hashable, Sendable {
    public var title: String
    public var summary: String
    public var actionableSteps: [String]
    public var tags: [String]
    /// The agent's reasoning, shown as the "thought breakdown" in the detail view.
    public var thoughtProcess: [String]
    public var suggestedReminder: Date?
    public var confidence: Double?

    public init(
        title: String = "",
        summary: String = "",
        actionableSteps: [String] = [],
        tags: [String] = [],
        thoughtProcess: [String] = [],
        suggestedReminder: Date? = nil,
        confidence: Double? = nil
    ) {
        self.title = title
        self.summary = summary
        self.actionableSteps = actionableSteps
        self.tags = tags
        self.thoughtProcess = thoughtProcess
        self.suggestedReminder = suggestedReminder
        self.confidence = confidence
    }

    public var isEmpty: Bool {
        title.isEmpty && summary.isEmpty && actionableSteps.isEmpty && tags.isEmpty
    }
}

/// Tag hygiene shared by agents, the tag editor and imports.
public enum TagNormalizer {
    public static let maximumLength = 32

    /// `"#Product Design"` → `"product-design"`. Returns nil for empty input.
    public static func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("#") { text.removeFirst() }
        text = text.lowercased()
        var result = ""
        var lastWasDash = false
        for character in text {
            if character.isLetter || character.isNumber || character == "+" || character == "." {
                result.append(character)
                lastWasDash = false
            } else if character.isWhitespace || character == "-" || character == "_" || character == "/" {
                if !lastWasDash, !result.isEmpty {
                    result.append("-")
                    lastWasDash = true
                }
            }
        }
        while result.hasSuffix("-") || result.hasSuffix(".") { result.removeLast() }
        if result.count > maximumLength {
            result = String(result.prefix(maximumLength))
            while result.hasSuffix("-") { result.removeLast() }
        }
        return result.isEmpty ? nil : result
    }

    /// Normalizes, removes duplicates (keeping order) and caps the count.
    public static func normalize(_ tags: [String], limit: Int = 12) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in tags {
            guard let normalized = normalize(tag), seen.insert(normalized).inserted else { continue }
            result.append(normalized)
            if result.count == limit { break }
        }
        return result
    }

    /// Adds `new` tags to `existing` without duplicates.
    public static func merge(_ existing: [String], with new: [String], limit: Int = 20) -> [String] {
        normalize(existing + new, limit: limit)
    }
}
