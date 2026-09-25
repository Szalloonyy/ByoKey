//
//  LibraryExport.swift
//  RecallDropKit
//
//  Portable export formats: a JSON document with the whole library (text
//  and metadata; images stay on the device) and Markdown for single captures.
//

import Foundation

public struct ExportedCapture: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var kind: String
    public var title: String
    public var summary: String?
    public var actionItems: [String]
    public var completedActionItems: [String]
    public var tags: [String]
    public var extractedText: String?
    public var notes: String?
    public var sourceURL: URL?
    public var sourceApp: String?
    public var reminderDate: Date?
    public var isPinned: Bool
    public var isArchived: Bool
    public var lastAgentName: String?

    public init(
        id: UUID,
        createdAt: Date,
        kind: String,
        title: String,
        summary: String? = nil,
        actionItems: [String] = [],
        completedActionItems: [String] = [],
        tags: [String] = [],
        extractedText: String? = nil,
        notes: String? = nil,
        sourceURL: URL? = nil,
        sourceApp: String? = nil,
        reminderDate: Date? = nil,
        isPinned: Bool = false,
        isArchived: Bool = false,
        lastAgentName: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.title = title
        self.summary = summary
        self.actionItems = actionItems
        self.completedActionItems = completedActionItems
        self.tags = tags
        self.extractedText = extractedText
        self.notes = notes
        self.sourceURL = sourceURL
        self.sourceApp = sourceApp
        self.reminderDate = reminderDate
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.lastAgentName = lastAgentName
    }
}

public struct LibraryExportDocument: Codable, Sendable {
    public static let formatIdentifier = "recalldrop-library"

    public var format: String
    public var version: Int
    public var exportedAt: Date
    public var captures: [ExportedCapture]
    public var agents: [AgentPersona]

    public init(exportedAt: Date = Date(), captures: [ExportedCapture], agents: [AgentPersona]) {
        self.format = Self.formatIdentifier
        self.version = 1
        self.exportedAt = exportedAt
        self.captures = captures
        self.agents = agents
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> LibraryExportDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LibraryExportDocument.self, from: data)
    }

    public static func suggestedFileName(for date: Date = Date(), calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        func twoDigits(_ value: Int?) -> String {
            let number = value ?? 1
            return number < 10 ? "0\(number)" : "\(number)"
        }
        return "RecallDrop Library \(parts.year ?? 0)-\(twoDigits(parts.month))-\(twoDigits(parts.day)).json"
    }
}

public enum CaptureMarkdownExporter {
    public static func markdown(for capture: ExportedCapture, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        style.locale = locale
        style.timeZone = timeZone

        var lines = ["# \(capture.title.isEmpty ? "Untitled Capture" : capture.title)", ""]
        if let summary = capture.summary?.nonEmpty {
            lines.append(contentsOf: summary.components(separatedBy: .newlines).map { "> \($0)" })
            lines.append("")
        }

        var meta = ["**Captured:** \(capture.createdAt.formatted(style))"]
        if let url = capture.sourceURL {
            let label = capture.sourceApp ?? url.host ?? url.absoluteString
            meta.append("**Source:** [\(label)](\(url.absoluteString))")
        }
        if let reminder = capture.reminderDate {
            meta.append("**Reminder:** \(reminder.formatted(style))")
        }
        lines.append(meta.joined(separator: " · "))
        if !capture.tags.isEmpty {
            lines.append("**Tags:** " + capture.tags.map { "#\($0)" }.joined(separator: " "))
        }
        if let agent = capture.lastAgentName?.nonEmpty {
            lines.append("**Analyzed by:** \(agent)")
        }

        if !capture.actionItems.isEmpty {
            lines.append(contentsOf: ["", "## Next Steps"])
            let completed = Set(capture.completedActionItems)
            lines.append(contentsOf: capture.actionItems.map { "- [\(completed.contains($0) ? "x" : " ")] \($0)" })
        }
        if let notes = capture.notes?.nonEmpty {
            lines.append(contentsOf: ["", "## Notes", notes])
        }
        if let text = capture.extractedText?.nonEmpty {
            lines.append(contentsOf: ["", "## Extracted Text", "", "```", text, "```"])
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
