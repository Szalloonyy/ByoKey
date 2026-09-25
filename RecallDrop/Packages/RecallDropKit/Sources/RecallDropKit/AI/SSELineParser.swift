//
//  SSELineParser.swift
//  RecallDropKit
//
//  Minimal Server-Sent Events reader for streaming completions.
//
//  `URLSession.AsyncBytes.lines` drops blank lines, so the usual "blank line
//  ends an event" rule cannot be relied on. Both OpenAI-style and Anthropic
//  streams put a complete JSON object on every `data:` line, so each data
//  line is treated as one finished event.
//

import Foundation

public struct SSEEvent: Sendable, Equatable {
    public var name: String?
    public var data: String

    public init(name: String? = nil, data: String) {
        self.name = name
        self.data = data
    }

    /// OpenAI-compatible streams end with `data: [DONE]`.
    public var isDoneMarker: Bool { data == "[DONE]" }
}

public struct SSELineParser: Sendable {
    private var pendingName: String?

    public init() {}

    /// Feeds one line. Returns an event when the line completes one.
    public mutating func consume(_ rawLine: String) -> SSEEvent? {
        var line = rawLine
        if line.hasSuffix("\r") { line.removeLast() }
        if line.isEmpty {
            pendingName = nil
            return nil
        }
        // Comment lines (": OPENROUTER PROCESSING") keep the connection alive.
        if line.hasPrefix(":") { return nil }

        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }

        switch field {
        case "event":
            pendingName = String(value)
            return nil
        case "data":
            let event = SSEEvent(name: pendingName, data: String(value))
            pendingName = nil
            return event
        default:
            // `id:` and `retry:` are irrelevant for completions.
            return nil
        }
    }
}
