//
//  PersonaMarkdownCodec.swift
//  RecallDropKit
//
//  Reads and writes agent personas as Markdown with YAML front matter – the
//  format used by github.com/msitarzewski/agency-agents and by Claude Code
//  subagents:
//
//      ---
//      name: Frontend Developer
//      description: Expert frontend developer specializing in …
//      color: cyan
//      ---
//
//      # Frontend Developer Agent Personality
//      …
//
//  Only the small YAML subset these files use is supported: scalars, quoted
//  strings, block scalars (| and >) and simple lists.
//

import Foundation

public enum PersonaImportError: Error, LocalizedError, Sendable, Equatable {
    case empty
    case missingPrompt
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .empty: "The file is empty."
        case .missingPrompt: "The file has no prompt text below its front matter."
        case .tooLarge: "The file is too large to be an agent prompt."
        }
    }
}

public enum PersonaMarkdownCodec {
    /// Prompts longer than this are almost certainly not persona files.
    public static let maximumCharacters = 200_000

    /// Claude Code model aliases that are not real model IDs.
    static let ignoredModelValues: Set<String> = ["", "inherit", "default", "sonnet", "opus", "haiku"]

    // MARK: Decoding

    public static func decode(_ markdown: String, fallbackName: String? = nil) throws -> AgentPersona {
        let text = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PersonaImportError.empty }
        guard text.count <= maximumCharacters else { throw PersonaImportError.tooLarge }

        let (fields, rawBody) = splitFrontMatter(text)
        let body = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw PersonaImportError.missingPrompt }

        let name = fields["name"]?.nonEmpty
            ?? fields["title"]?.nonEmpty
            ?? headingName(in: body)
            ?? fallbackName.map(prettifiedName)
            ?? "Imported Agent"

        var description = fields["description"]?.nonEmpty ?? firstParagraph(in: body) ?? ""
        description = TextHeuristics.truncate(description.replacingOccurrences(of: "\n", with: " "), maxLength: 240)

        let color = fields["color"]?.nonEmpty.map { AgentColor(loose: $0) } ?? defaultColor(for: name)
        let emoji = fields["emoji"]?.nonEmpty ?? fields["icon"]?.nonEmpty ?? suggestedEmoji(for: name + " " + description)

        var model = fields["model"]?.trimmingCharacters(in: .whitespaces) ?? ""
        if ignoredModelValues.contains(model.lowercased()) { model = "" }

        var temperature = 0.5
        if let value = fields["temperature"].flatMap(Double.init), value.isFinite {
            temperature = min(max(value, 0), 2)
        }

        return AgentPersona(
            name: TextHeuristics.truncate(name, maxLength: 60),
            systemPrompt: body,
            assignedModel: model,
            temperature: temperature,
            roleDescription: description,
            emoji: String(emoji.prefix(2)),
            colorName: color.rawValue
        )
    }

    /// Splits `---` front matter from the body and parses it.
    public static func splitFrontMatter(_ text: String) -> (fields: [String: String], body: String) {
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return ([:], text)
        }
        guard let closing = lines.indices.dropFirst().first(where: {
            let trimmed = lines[$0].trimmingCharacters(in: .whitespaces)
            return trimmed == "---" || trimmed == "..."
        }) else {
            return ([:], text)
        }
        let fields = parseYAML(Array(lines[1..<closing]))
        let body = lines[(closing + 1)...].joined(separator: "\n")
        return (fields, body)
    }

    static func parseYAML(_ lines: [String]) -> [String: String] {
        var fields: [String: String] = [:]
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            index += 1
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  !line.hasPrefix(" "), !line.hasPrefix("\t"),
                  let colon = line.firstIndex(of: ":") else { continue }

            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)

            if value.hasPrefix("|") || value.hasPrefix(">") {
                let folded = value.hasPrefix(">")
                var block: [String] = []
                while index < lines.count,
                      lines[index].hasPrefix(" ") || lines[index].hasPrefix("\t")
                        || lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    block.append(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                while block.last?.isEmpty == true { block.removeLast() }
                value = folded
                    ? block.split(separator: "", omittingEmptySubsequences: true)
                        .map { $0.joined(separator: " ") }.joined(separator: "\n")
                    : block.joined(separator: "\n")
            } else if value.isEmpty {
                var items: [String] = []
                while index < lines.count {
                    let item = lines[index].trimmingCharacters(in: .whitespaces)
                    guard item.hasPrefix("- ") else { break }
                    items.append(unquoted(String(item.dropFirst(2))))
                    index += 1
                }
                value = items.joined(separator: ", ")
            } else if value.hasPrefix("[") && value.hasSuffix("]") {
                value = value.dropFirst().dropLast()
                    .split(separator: ",")
                    .map { unquoted($0.trimmingCharacters(in: .whitespaces)) }
                    .joined(separator: ", ")
            } else {
                value = unquoted(value)
            }
            fields[key] = value
        }
        return fields
    }

    static func unquoted(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            var result = ""
            var escaping = false
            for character in value.dropFirst().dropLast() {
                if escaping {
                    switch character {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    default: result.append(character)
                    }
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else {
                    result.append(character)
                }
            }
            return result
        }
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        // Plain scalars may carry a trailing comment.
        if let comment = value.range(of: " #") {
            return String(value[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return value
    }

    static func headingName(in body: String) -> String? {
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("# ") else { continue }
            var name = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            for suffix in [" Agent Personality", " Personality", " Agent"] where name.hasSuffix(suffix) {
                name.removeLast(suffix.count)
                break
            }
            name = name.replacingOccurrences(of: "*", with: "")
            return name.nonEmpty
        }
        return nil
    }

    static func firstParagraph(in body: String) -> String? {
        let paragraphs = body.components(separatedBy: "\n\n")
        for paragraph in paragraphs {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("-"), !trimmed.hasPrefix("```") else { continue }
            return trimmed.replacingOccurrences(of: "**", with: "")
        }
        return nil
    }

    /// `"design-ui-designer"` → `"Design UI Designer"`.
    public static func prettifiedName(_ raw: String) -> String {
        var base = raw
        if let dot = base.lastIndex(of: "."), base[dot...].count <= 9 { base = String(base[..<dot]) }
        let acronyms: [String: String] = [
            "ui": "UI", "ux": "UX", "ai": "AI", "api": "API", "seo": "SEO", "qa": "QA", "ios": "iOS",
            "ml": "ML", "llm": "LLM", "devops": "DevOps", "xr": "XR", "ar": "AR", "vr": "VR", "cto": "CTO", "ceo": "CEO"
        ]
        return base
            .split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
            .map { word in
                let lowered = word.lowercased()
                return acronyms[lowered] ?? lowered.prefix(1).uppercased() + lowered.dropFirst()
            }
            .joined(separator: " ")
    }

    static func defaultColor(for name: String) -> AgentColor {
        // djb2 – stable across launches, unlike Hasher.
        var hash: UInt64 = 5381
        for scalar in name.unicodeScalars {
            hash = (hash &* 33) &+ UInt64(scalar.value)
        }
        let palette = AgentColor.allCases.filter { $0 != .gray && $0 != .brown }
        return palette[Int(hash % UInt64(palette.count))]
    }

    static func suggestedEmoji(for text: String) -> String {
        let lowered = text.lowercased()
        let table: [(keywords: [String], emoji: String)] = [
            (["design", "ui", "ux", "visual", "brand"], "🎨"),
            (["research", "analyst", "investigat"], "🔎"),
            (["market", "growth", "seo", "social"], "📈"),
            (["write", "writer", "content", "copy", "editor"], "📝"),
            (["engineer", "developer", "code", "devops", "backend", "frontend"], "🔧"),
            (["test", "qa", "quality"], "🧪"),
            (["product", "strategy", "roadmap"], "🧭"),
            (["support", "customer", "community"], "💬"),
            (["finance", "sales", "business"], "💼"),
            (["data", "analytics", "metrics"], "📊"),
            (["security", "privacy"], "🛡️"),
            (["plan", "project", "task", "action"], "✅"),
            (["idea", "creative", "brainstorm"], "💡")
        ]
        for entry in table where entry.keywords.contains(where: lowered.contains) {
            return entry.emoji
        }
        return "🤖"
    }

    // MARK: Encoding

    public static func encode(_ persona: AgentPersona) -> String {
        var lines = ["---", "name: \(yamlScalar(persona.displayName))"]
        if !persona.roleDescription.isEmpty { lines.append("description: \(yamlScalar(persona.roleDescription))") }
        lines.append("color: \(persona.color.rawValue)")
        if !persona.emoji.isEmpty { lines.append("emoji: \(yamlScalar(persona.emoji))") }
        if !persona.usesDefaultModel { lines.append("model: \(yamlScalar(persona.assignedModel))") }
        let temperature = (persona.temperature * 100).rounded() / 100
        lines.append("temperature: \(temperature)")
        lines.append("source: RecallDrop")
        lines.append("---")
        return lines.joined(separator: "\n") + "\n\n" + persona.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    static func yamlScalar(_ value: String) -> String {
        let reservedStarts = Set("-?:,[]{}#&*!|>'\"%@`")
        let needsQuotes = value.isEmpty
            || value.contains(": ") || value.contains(" #") || value.contains("\n")
            || value.hasPrefix(" ") || value.hasSuffix(" ")
            || value.first.map { reservedStarts.contains($0) } == true
            || ["true", "false", "null", "yes", "no", "~"].contains(value.lowercased())
            || Double(value) != nil
        guard needsQuotes else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    public static func fileName(for persona: AgentPersona) -> String {
        slug(persona.displayName) + ".md"
    }

    public static func slug(_ name: String) -> String {
        var result = ""
        var lastWasDash = false
        for character in name.lowercased() {
            if character.isLetter || character.isNumber {
                result.append(character)
                lastWasDash = false
            } else if !lastWasDash, !result.isEmpty {
                result.append("-")
                lastWasDash = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result.isEmpty ? "agent" : result
    }
}
