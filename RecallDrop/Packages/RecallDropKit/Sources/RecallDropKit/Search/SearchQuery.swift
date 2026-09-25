//
//  SearchQuery.swift
//  RecallDropKit
//
//  Instant search over OCR text, titles, notes, summaries and tags.
//
//  Plain words must all match (anywhere, prefix-friendly for as-you-type).
//  Power-user syntax:
//      "exact phrase"    -word        #tag
//      is:pinned  is:archived  is:link  is:note  is:image
//      has:reminder  has:actions  is:unanalyzed  is:failed
//      agent:idea
//

import Foundation

public struct SearchQuery: Sendable, Hashable {
    public enum Flag: String, Sendable, Hashable, CaseIterable {
        case pinned, archived, link, note, image, reminder, actions, unanalyzed, failed
    }

    public var terms: [String] = []
    public var phrases: [String] = []
    public var excludedTerms: [String] = []
    public var requiredTags: [String] = []
    public var flags: Set<Flag> = []
    public var agentName: String?

    public init() {}

    public init(parsing input: String) {
        for token in Self.tokenize(input) {
            if token.quoted {
                let phrase = SearchText.fold(token.text)
                if !phrase.isEmpty { phrases.append(phrase) }
                continue
            }
            let text = token.text
            let lowered = text.lowercased()
            if lowered.hasPrefix("is:") || lowered.hasPrefix("has:") {
                let value = String(lowered.split(separator: ":", maxSplits: 1).last ?? "")
                if let flag = Self.flag(for: value) {
                    flags.insert(flag)
                    continue
                }
            }
            if lowered.hasPrefix("agent:") {
                let value = SearchText.fold(String(text.dropFirst("agent:".count)))
                if !value.isEmpty { agentName = value }
                continue
            }
            if text.hasPrefix("#"), text.count > 1 {
                if let tag = TagNormalizer.normalize(text) { requiredTags.append(tag) }
                continue
            }
            if text.hasPrefix("-"), text.count > 1 {
                let folded = SearchText.fold(String(text.dropFirst()))
                if !folded.isEmpty { excludedTerms.append(folded) }
                continue
            }
            let folded = SearchText.fold(text)
            if !folded.isEmpty { terms.append(folded) }
        }
    }

    public var isEmpty: Bool {
        terms.isEmpty && phrases.isEmpty && excludedTerms.isEmpty && requiredTags.isEmpty
            && flags.isEmpty && agentName == nil
    }

    /// Words worth highlighting in results.
    public var highlightTerms: [String] { phrases + terms }

    static func flag(for value: String) -> Flag? {
        switch value {
        case "pinned", "pin": .pinned
        case "archived", "archive": .archived
        case "link", "links", "url": .link
        case "note", "notes", "text": .note
        case "image", "images", "screenshot", "screenshots", "photo", "photos": .image
        case "reminder", "reminders", "due": .reminder
        case "actions", "action", "todo", "todos", "steps": .actions
        case "unanalyzed", "new", "pending": .unanalyzed
        case "failed", "error", "errors": .failed
        default: nil
        }
    }

    struct Token {
        var text: String
        var quoted: Bool
    }

    static func tokenize(_ input: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var inQuotes = false
        for character in input {
            if character == "\"" || character == "“" || character == "”" {
                if inQuotes {
                    if !current.isEmpty { tokens.append(Token(text: current, quoted: true)) }
                    current = ""
                    inQuotes = false
                } else {
                    if !current.isEmpty { tokens.append(Token(text: current, quoted: false)) }
                    current = ""
                    inQuotes = true
                }
            } else if character.isWhitespace && !inQuotes {
                if !current.isEmpty { tokens.append(Token(text: current, quoted: false)) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(Token(text: current, quoted: inQuotes)) }
        return tokens
    }
}

public enum SearchText {
    /// Case-, diacritic- and width-insensitive form used for matching.
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Everything searchable about an item, folded once and stored with it.
    public static func buildIndex(
        title: String,
        extractedText: String?,
        notes: String?,
        summary: String?,
        tags: [String],
        actionItems: [String],
        sourceURL: URL?,
        agentName: String?,
        extra: [String] = []
    ) -> String {
        var parts = [title]
        parts.append(contentsOf: tags)
        if let summary { parts.append(summary) }
        parts.append(contentsOf: actionItems)
        if let notes { parts.append(notes) }
        if let extractedText { parts.append(extractedText) }
        if let url = sourceURL {
            parts.append(url.absoluteString)
            if let app = TextHeuristics.sourceAppName(for: url) { parts.append(app) }
        }
        if let agentName { parts.append(agentName) }
        parts.append(contentsOf: extra)
        let joined = parts.filter { !$0.isEmpty }.joined(separator: "\n")
        return fold(joined.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression))
    }
}

/// The searchable projection of one captured item.
public struct SearchRecord: Sendable {
    public var foldedTitle: String
    public var foldedIndex: String
    public var tags: [String]
    public var flags: Set<SearchQuery.Flag>
    public var foldedAgentNames: [String]

    public init(foldedTitle: String, foldedIndex: String, tags: [String], flags: Set<SearchQuery.Flag>,
                foldedAgentNames: [String]) {
        self.foldedTitle = foldedTitle
        self.foldedIndex = foldedIndex
        self.tags = tags
        self.flags = flags
        self.foldedAgentNames = foldedAgentNames
    }
}

public enum SearchMatcher {
    /// Relevance score, or `nil` when the record does not match.
    public static func score(_ query: SearchQuery, record: SearchRecord) -> Double? {
        guard query.flags.isSubset(of: record.flags) else { return nil }
        for tag in query.requiredTags where !record.tags.contains(tag) {
            return nil
        }
        if let agent = query.agentName, !record.foldedAgentNames.contains(where: { $0.contains(agent) }) {
            return nil
        }
        for excluded in query.excludedTerms where record.foldedIndex.contains(excluded) {
            return nil
        }

        var score = 1.0
        for phrase in query.phrases {
            guard record.foldedIndex.contains(phrase) else { return nil }
            score += record.foldedTitle.contains(phrase) ? 8 : 3
        }
        for term in query.terms {
            guard record.foldedIndex.contains(term) else { return nil }
            if record.foldedTitle.contains(term) {
                score += 6
                if record.foldedTitle.hasPrefix(term) || record.foldedTitle.contains(" " + term) { score += 2 }
            }
            if record.tags.contains(where: { $0.hasPrefix(term) }) { score += 4 }
            if record.foldedIndex.contains(" " + term) || record.foldedIndex.hasPrefix(term)
                || record.foldedIndex.contains("\n" + term) {
                score += 1
            }
        }
        return score
    }
}

public enum SearchSnippet {
    /// A short excerpt of `text` around the first match of any term.
    public static func make(from text: String, terms: [String], radius: Int = 60) -> String? {
        guard !text.isEmpty else { return nil }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        var firstMatch: Range<String.Index>?
        for term in terms where !term.isEmpty {
            if let range = text.range(of: term, options: options),
               firstMatch == nil || range.lowerBound < firstMatch!.lowerBound {
                firstMatch = range
            }
        }
        guard let match = firstMatch else { return nil }
        let start = text.index(match.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(match.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        var snippet = TextHeuristics.collapseWhitespace(String(text[start..<end]))
        if start > text.startIndex { snippet = "…" + snippet }
        if end < text.endIndex { snippet += "…" }
        return snippet
    }
}
