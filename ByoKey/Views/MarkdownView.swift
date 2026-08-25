//
//  MarkdownView.swift
//  ByoKey
//
//  Eigener, abhängigkeitsfreier Markdown-Renderer.
//  Bewusst ohne Fremdbibliothek: weniger Angriffsfläche, kein SPM-Auflösen
//  beim Build und nichts, was Apple bei der Prüfung als nachgeladenen Code
//  auffassen könnte (Richtlinie 2.5.2).
//

import SwiftUI

// MARK: - Blockmodell

enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullets([String])
    case numbered([String])
    case quote(String)
    case code(language: String?, code: String)
    case divider
}

struct MarkdownElement: Identifiable {
    let id: Int
    let block: MarkdownBlock
}

// MARK: - Parser

enum MarkdownParser {

    static func parse(_ text: String) -> [MarkdownElement] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbered: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }
        func flushBullets() {
            guard !bullets.isEmpty else { return }
            blocks.append(.bullets(bullets))
            bullets.removeAll()
        }
        func flushNumbered() {
            guard !numbered.isEmpty else { return }
            blocks.append(.numbered(numbered))
            numbered.removeAll()
        }
        func flushAll() {
            flushParagraph(); flushBullets(); flushNumbered()
        }

        let lines = text.components(separatedBy: "\n")
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Code-Block
            if trimmed.hasPrefix("```") {
                flushAll()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count {
                    if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") { break }
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: language.isEmpty ? nil : language,
                                    code: code.joined(separator: "\n")))
                index += 1
                continue
            }

            if trimmed.isEmpty {
                flushAll()
                index += 1
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushAll()
                blocks.append(.divider)
                index += 1
                continue
            }

            // Überschrift
            let hashes = trimmed.prefix { $0 == "#" }.count
            if hashes > 0, hashes <= 6, trimmed.dropFirst(hashes).hasPrefix(" ") {
                flushAll()
                let content = String(trimmed.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: hashes, text: content))
                index += 1
                continue
            }

            // Zitat
            if trimmed.hasPrefix("> ") {
                flushAll()
                blocks.append(.quote(String(trimmed.dropFirst(2))))
                index += 1
                continue
            }

            // Aufzählung
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                flushParagraph(); flushNumbered()
                bullets.append(String(trimmed.dropFirst(2)))
                index += 1
                continue
            }

            // Nummerierte Liste
            if let item = numberedItem(trimmed) {
                flushParagraph(); flushBullets()
                numbered.append(item)
                index += 1
                continue
            }

            flushBullets(); flushNumbered()
            paragraph.append(line)
            index += 1
        }

        flushAll()
        return blocks.enumerated().map { MarkdownElement(id: $0.offset, block: $0.element) }
    }

    /// "3. Text" -> "Text"; sonst nil.
    private static func numberedItem(_ line: String) -> String? {
        var digits = 0
        var cursor = line.startIndex
        while cursor < line.endIndex, line[cursor].isNumber {
            digits += 1
            cursor = line.index(after: cursor)
        }
        guard digits > 0, digits <= 3, cursor < line.endIndex, line[cursor] == "." else { return nil }
        cursor = line.index(after: cursor)
        guard cursor < line.endIndex, line[cursor] == " " else { return nil }
        cursor = line.index(after: cursor)
        return String(line[cursor...])
    }

    /// Kleiner Zwischenspeicher: während eines Streams wird derselbe Absatz
    /// viele Male neu gerendert, und `AttributedString(markdown:)` ist teuer.
    @MainActor private static var inlineCache: [String: AttributedString] = [:]
    @MainActor private static var inlineOrder: [String] = []

    /// Inline-Auszeichnungen (fett, kursiv, Links, Inline-Code).
    @MainActor
    static func inline(_ source: String) -> AttributedString {
        if let cached = inlineCache[source] { return cached }

        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible

        var result: AttributedString
        if var attributed = try? AttributedString(markdown: source, options: options) {
            // Inline-Code sichtbar machen: Monospace plus dezente Fläche.
            let codeRanges = attributed.runs.compactMap { run -> Range<AttributedString.Index>? in
                guard let intent = run.inlinePresentationIntent, intent.contains(.code) else { return nil }
                return run.range
            }
            for range in codeRanges {
                attributed[range].font = .system(.callout, design: .monospaced)
                attributed[range].backgroundColor = Theme.surfaceAlt
            }
            result = attributed
        } else {
            result = AttributedString(source)
        }

        // Lange Absätze **nicht** aufnehmen.
        //
        // Der Schlüssel ist der vollständige Quelltext des Absatzes. Während
        // eines Streams wächst der letzte Absatz mit jedem Textstück, und jeder
        // Zwischenstand wäre ein eigener, dauerhafter Eintrag: nach einer
        // langen Antwort bestünde der Zwischenspeicher fast nur noch aus
        // Zwischenständen, die nie wieder getroffen werden – und hätte die
        // fertigen Absätze älterer Nachrichten verdrängt, also genau das, wofür
        // es ihn gibt. Die Obergrenze deckelt zugleich den Speicherbedarf.
        guard source.utf16.count <= 1_200 else { return result }

        inlineCache[source] = result
        inlineOrder.append(source)
        if inlineOrder.count > 400 {
            inlineCache.removeValue(forKey: inlineOrder.removeFirst())
        }
        return result
    }
}

// MARK: - Darstellung

struct MarkdownView: View, Equatable {
    let text: String

    nonisolated static func == (lhs: MarkdownView, rhs: MarkdownView) -> Bool {
        lhs.text == rhs.text
    }

    private var elements: [MarkdownElement] {
        MarkdownParser.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(elements) { element in
                view(for: element.block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkdownParser.inline(text))
                .font(headingFont(level))
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, level <= 2 ? 6 : 2)

        case .paragraph(let text):
            Text(MarkdownParser.inline(text))
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .foregroundStyle(Theme.textSecondary)
                        Text(MarkdownParser.inline(item))
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.body)
            .textSelection(.enabled)

        case .numbered(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .foregroundStyle(Theme.textSecondary)
                            .monospacedDigit()
                        Text(MarkdownParser.inline(item))
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.body)
            .textSelection(.enabled)

        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                Rectangle()
                    .fill(Theme.accent.opacity(0.5))
                    .frame(width: 3)
                Text(MarkdownParser.inline(text))
                    .font(.body)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .code(let language, let code):
            CodeBlockView(language: language, code: code)
                .equatable()

        case .divider:
            Rectangle()
                .fill(Theme.border)
                .frame(height: 1)
                .padding(.vertical, 4)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2.bold()
        case 2: return .title3.bold()
        case 3: return .headline
        default: return .subheadline.bold()
        }
    }
}
