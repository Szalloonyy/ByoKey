//
//  AgentOutputParser.swift
//  RecallDropKit
//
//  Turns a model reply into an `AgentOutput`. Models are asked for one JSON
//  object, but in practice they wrap it in code fences, add a sentence
//  before it, rename keys, return steps as objects, emit trailing commas or
//  get cut off mid-string. The parser tolerates all of that and falls back
//  to reading plain text when there is no JSON at all.
//

import Foundation

public struct ParsedAgentOutput: Sendable, Hashable {
    public var output: AgentOutput
    /// True when the reply contained the requested JSON object.
    public var wasStructured: Bool

    public init(output: AgentOutput, wasStructured: Bool) {
        self.output = output
        self.wasStructured = wasStructured
    }
}

public enum AgentOutputParser {
    public static let maximumTitleLength = 90
    public static let maximumListItems = 10

    public static func parse(_ raw: String, now: Date = Date(), timeZone: TimeZone = .current) -> ParsedAgentOutput {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let object = jsonDictionary(from: text) {
            let output = output(from: unwrapped(object), now: now, timeZone: timeZone)
            if !output.isEmpty {
                return ParsedAgentOutput(output: output, wasStructured: true)
            }
        }
        return ParsedAgentOutput(output: fallbackOutput(from: text), wasStructured: false)
    }

    // MARK: - JSON extraction

    /// Finds, repairs and decodes the first JSON object in `text`.
    public static func jsonDictionary(from text: String) -> [String: Any]? {
        var candidates: [String] = []
        if let fenced = fencedBlock(in: text) { candidates.append(fenced) }
        candidates.append(text)

        for candidate in candidates {
            guard let start = candidate.firstIndex(of: "{") else { continue }
            let tail = String(candidate[start...])
            if let balanced = balancedObject(in: tail) {
                if let object = decode(balanced) ?? decode(removingTrailingCommas(balanced)) {
                    return object
                }
            } else if let repaired = repairTruncated(tail) {
                return repaired
            }
        }
        return nil
    }

    static func fencedBlock(in text: String) -> String? {
        guard let open = text.range(of: "```") else { return nil }
        var contentStart = open.upperBound
        // Skip an info string such as "json".
        if let newline = text[contentStart...].firstIndex(of: "\n") {
            let info = text[contentStart..<newline].trimmingCharacters(in: .whitespaces)
            if info.allSatisfy({ $0.isLetter }) { contentStart = text.index(after: newline) }
        }
        guard let close = text.range(of: "```", range: contentStart..<text.endIndex) else {
            return String(text[contentStart...])
        }
        return String(text[contentStart..<close.lowerBound])
    }

    /// The first complete `{…}` in `text`, respecting strings and escapes.
    static func balancedObject(in text: String) -> String? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                switch character {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 { return String(text[text.startIndex...index]) }
                default: break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    static func decode(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func removingTrailingCommas(_ json: String) -> String {
        json.replacingOccurrences(of: #",\s*([}\]])"#, with: "$1", options: .regularExpression)
    }

    /// Closes strings and brackets left open by a cut-off reply. When the cut
    /// happened inside a key or right after a colon, the incomplete member is
    /// dropped by retrying from earlier commas.
    static func repairTruncated(_ text: String) -> [String: Any]? {
        var cutPoints: [String.Index] = [text.endIndex]
        var inString = false
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "," {
                cutPoints.append(index)
            }
            index = text.index(after: index)
        }

        for cut in cutPoints.reversed().prefix(40) {
            let prefix = String(text[..<cut])
            if let closed = closingBrackets(for: prefix), let object = decode(closed) {
                return object
            }
        }
        return nil
    }

    private static func closingBrackets(for text: String) -> String? {
        var stack: [Character] = []
        var inString = false
        var escaped = false
        for character in text {
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"": inString = true
            case "{": stack.append("}")
            case "[": stack.append("]")
            case "}", "]":
                guard !stack.isEmpty else { return nil }
                stack.removeLast()
            default: break
            }
        }
        var result = text
        if inString {
            if escaped { result.removeLast() }
            result.append("\"")
        }
        while let last = result.last, last.isWhitespace || last == "," || last == ":" {
            result.removeLast()
        }
        result.append(contentsOf: stack.reversed())
        return result
    }

    /// `{"result": {"title": …}}` → the inner object.
    static func unwrapped(_ object: [String: Any]) -> [String: Any] {
        let known = Set((titleKeys + summaryKeys + stepKeys + tagKeys).map(normalizedKey))
        if object.keys.contains(where: { known.contains(normalizedKey($0)) }) { return object }
        let nested = object.values.compactMap { $0 as? [String: Any] }
        if nested.count == 1, let inner = nested.first { return inner }
        return object
    }

    // MARK: - Field mapping

    static let titleKeys = ["title", "headline", "name", "subject"]
    static let summaryKeys = ["summary", "description", "overview", "coreIdea", "idea", "insight", "gist", "tldr"]
    static let stepKeys = ["actionableSteps", "actionItems", "actions", "steps", "nextSteps", "todos", "todo", "tasks",
                           "followUps", "followUpAngles", "angles"]
    static let tagKeys = ["tags", "keywords", "labels", "topics", "hashtags", "categories"]
    static let thoughtKeys = ["thoughtProcess", "thoughts", "reasoning", "analysis", "rationale", "observations", "thinking"]
    static let reminderKeys = ["suggestedReminder", "reminder", "reminderDate", "remindAt", "followUp", "followUpDate",
                               "dueDate", "deadline"]
    static let confidenceKeys = ["confidence", "certainty", "score"]

    static func normalizedKey(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func output(from object: [String: Any], now: Date, timeZone: TimeZone) -> AgentOutput {
        var normalized: [String: Any] = [:]
        for (key, value) in object {
            let normalizedKey = normalizedKey(key)
            if normalized[normalizedKey] == nil { normalized[normalizedKey] = value }
        }
        func value(_ keys: [String]) -> Any? {
            for key in keys {
                if let value = normalized[normalizedKey(key)], !(value is NSNull) { return value }
            }
            return nil
        }

        let title = cleanTitle(string(value(titleKeys)) ?? "")
        let summary = (string(value(summaryKeys)) ?? stringList(value(summaryKeys), splitting: .lines).joined(separator: " "))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let steps = Array(stringList(value(stepKeys), splitting: .lines).prefix(maximumListItems))
        let tags = TagNormalizer.normalize(stringList(value(tagKeys), splitting: .commas))
        let thoughts = Array(stringList(value(thoughtKeys), splitting: .lines).prefix(maximumListItems))
        let reminder = reminderDate(value(reminderKeys), now: now, timeZone: timeZone)
        let confidence = confidenceValue(value(confidenceKeys))

        return AgentOutput(
            title: title,
            summary: summary,
            actionableSteps: steps,
            tags: tags,
            thoughtProcess: thoughts,
            suggestedReminder: reminder,
            confidence: confidence
        )
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let string as String: return string
        case let int as Int: return String(int)
        case let double as Double: return String(double)
        default: return nil
        }
    }

    enum SplitStyle {
        case lines
        case commas
    }

    static func stringList(_ value: Any?, splitting: SplitStyle) -> [String] {
        switch value {
        case let array as [Any]:
            return array.compactMap(listItem).map(cleanListItem).filter { !$0.isEmpty }
        case let string as String:
            let separators: CharacterSet = splitting == .lines ? .newlines : CharacterSet(charactersIn: ",;\n")
            return string.components(separatedBy: separators).map(cleanListItem).filter { !$0.isEmpty }
        default:
            return []
        }
    }

    private static func listItem(_ element: Any) -> String? {
        if let string = element as? String { return string }
        if let int = element as? Int { return String(int) }
        if let double = element as? Double { return String(double) }
        if let object = element as? [String: Any] {
            for key in ["text", "step", "title", "action", "task", "description", "name", "value", "content", "tag"] {
                if let string = object[key] as? String, !string.isEmpty {
                    if let detail = (object["details"] ?? object["detail"]) as? String, !detail.isEmpty, key != "description" {
                        return "\(string) – \(detail)"
                    }
                    return string
                }
            }
            let strings = object.values.compactMap { $0 as? String }
            return strings.isEmpty ? nil : strings.joined(separator: " – ")
        }
        return nil
    }

    static func cleanListItem(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: #"^(?:[-*]\s*\[[ xX]\]\s+|[-*•–]\s+|\d{1,2}[.)]\s+|\[[ xX]\]\s+)"#,
                                         with: "", options: .regularExpression)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'").union(.whitespaces))
        if text.count > 300 { text = TextHeuristics.truncate(text, maxLength: 300) }
        return text
    }

    static func cleanTitle(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"^(?i)title\s*:\s*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "**", with: "")
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'*_`").union(.whitespaces))
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return TextHeuristics.truncate(text, maxLength: maximumTitleLength)
    }

    static func reminderDate(_ value: Any?, now: Date, timeZone: TimeZone) -> Date? {
        var date: Date?
        switch value {
        case let string as String:
            let lowered = string.lowercased().trimmingCharacters(in: .whitespaces)
            guard !["", "null", "none", "n/a", "no"].contains(lowered) else { return nil }
            date = FlexibleDateParser.parse(string, timeZone: timeZone)
        default:
            // Accept Unix timestamps in seconds or milliseconds.
            guard let seconds = ClientSupport.double(value) else { return nil }
            date = Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
        }
        guard let date, date > now.addingTimeInterval(60), date < now.addingTimeInterval(2 * 365 * 24 * 3600) else {
            return nil
        }
        return date
    }

    static func confidenceValue(_ value: Any?) -> Double? {
        var number: Double?
        if let string = value as? String {
            number = Double(string.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
        } else {
            number = ClientSupport.double(value)
        }
        guard var confidence = number, confidence.isFinite, confidence >= 0 else { return nil }
        if confidence > 1, confidence <= 100 { confidence /= 100 }
        return min(confidence, 1)
    }

    // MARK: - Plain-text fallback

    static func fallbackOutput(from text: String) -> AgentOutput {
        let stripped = text.replacingOccurrences(of: #"```[A-Za-z]*"#, with: "", options: .regularExpression)
        let lines = stripped.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var title = ""
        var summaryParts: [String] = []
        var steps: [String] = []
        var tags: [String] = []

        for line in lines {
            let lowered = line.lowercased()
            if lowered.hasPrefix("tags:") || lowered.hasPrefix("keywords:") {
                let list = line.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
                tags.append(contentsOf: list.components(separatedBy: CharacterSet(charactersIn: ",;")))
                continue
            }
            if isBullet(line) {
                steps.append(cleanListItem(line))
                continue
            }
            if title.isEmpty {
                let candidate = cleanTitle(line)
                if line.count <= maximumTitleLength + 10 {
                    title = candidate
                    continue
                }
                title = TextHeuristics.fallbackTitle(from: line) ?? candidate
            }
            let cleaned = line.replacingOccurrences(of: #"^(?i)(summary|description)\s*:\s*"#, with: "",
                                                    options: .regularExpression)
            summaryParts.append(cleaned.replacingOccurrences(of: "**", with: ""))
        }

        tags.append(contentsOf: TextHeuristics.hashtags(in: text))
        return AgentOutput(
            title: title,
            summary: TextHeuristics.truncate(summaryParts.joined(separator: " "), maxLength: 800),
            actionableSteps: Array(steps.filter { !$0.isEmpty }.prefix(maximumListItems)),
            tags: TagNormalizer.normalize(tags)
        )
    }

    static func isBullet(_ line: String) -> Bool {
        line.range(of: #"^(?:[-*•–]\s+|\d{1,2}[.)]\s+|\[[ xX]\]\s+)"#, options: .regularExpression) != nil
    }
}
