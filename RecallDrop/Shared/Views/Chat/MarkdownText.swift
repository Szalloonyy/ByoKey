//
//  MarkdownText.swift
//  RecallDrop
//
//  Renders the Markdown that chat answers use: headings, bullet and numbered
//  lists, quotes, code blocks and inline formatting. Inline styling comes
//  from AttributedString's Markdown parser; blocks are laid out here.
//

import SwiftUI

struct MarkdownText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(headingFont(level))
        case .paragraph(let text):
            inline(text)
        case .bullet(let text, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                inline(text)
            }
            .padding(.leading, CGFloat(depth) * 14)
        case .numbered(let number, let text, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).")
                    .monospacedDigit()
                inline(text)
            }
            .padding(.leading, CGFloat(depth) * 14)
        case .quote(let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                inline(text)
                    .foregroundStyle(.secondary)
            }
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .padding(10)
            }
            .background(Theme.placeholderFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .rule:
            Divider()
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case ...1: Font.title3.weight(.bold)
        case 2: Font.headline
        default: Font.subheadline.weight(.semibold)
        }
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return Text(attributed)
        }
        return Text(text)
    }
}

enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(String, depth: Int)
    case numbered(Int, String, depth: Int)
    case quote(String)
    case code(String)
    case rule

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var inCode = false

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph.removeAll()
            }
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(codeLines.joined(separator: "\n")))
                    codeLines.removeAll()
                    inCode = false
                } else {
                    flushParagraph()
                    inCode = true
                }
                continue
            }
            if inCode {
                codeLines.append(rawLine)
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            let depth = (rawLine.prefix { $0 == " " }.count) / 2
            if trimmed == "---" || trimmed == "***" {
                flushParagraph()
                blocks.append(.rule)
            } else if let heading = heading(in: trimmed) {
                flushParagraph()
                blocks.append(heading)
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                flushParagraph()
                blocks.append(.bullet(String(trimmed.dropFirst(2)), depth: depth))
            } else if let (number, text) = numberedItem(trimmed) {
                flushParagraph()
                blocks.append(.numbered(number, text, depth: depth))
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else {
                paragraph.append(trimmed)
            }
        }
        if inCode, !codeLines.isEmpty { blocks.append(.code(codeLines.joined(separator: "\n"))) }
        flushParagraph()
        return blocks
    }

    private static func heading(in line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: String(line.dropFirst(hashes + 1)))
    }

    private static func numberedItem(_ line: String) -> (Int, String)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3, let number = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (number, String(rest.dropFirst(2)))
    }
}
