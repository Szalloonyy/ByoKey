//
//  OCRLayout.swift
//  RecallDropKit
//
//  Turns recognized text lines (as produced by Apple's Vision framework) into
//  readable text: reading order, paragraph breaks, and a headline guess.
//  Coordinates are normalized to 0…1 with the origin at the bottom left,
//  exactly like Vision's bounding boxes.
//

import Foundation

public struct OCRLine: Sendable, Hashable, Codable {
    public var text: String
    public var confidence: Double
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(text: String, confidence: Double, x: Double, y: Double, width: Double, height: Double) {
        self.text = text
        self.confidence = confidence
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var top: Double { y + height }
    public var midY: Double { y + height / 2 }
}

public enum OCRLayout {
    /// Lines sorted top-to-bottom, then left-to-right within a visual row.
    public static func rows(_ lines: [OCRLine]) -> [[OCRLine]] {
        let sorted = lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.top > $1.top }
        guard !sorted.isEmpty else { return [] }
        let tolerance = medianHeight(sorted) * 0.5

        var rows: [[OCRLine]] = []
        for line in sorted {
            if let lastRow = rows.last, let reference = lastRow.first,
               abs(reference.midY - line.midY) <= tolerance {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.map { $0.sorted { $0.x < $1.x } }
    }

    public static func readingOrder(_ lines: [OCRLine]) -> [OCRLine] {
        rows(lines).flatMap { $0 }
    }

    /// Text in reading order with a blank line where the vertical gap
    /// suggests a new paragraph or section.
    public static func joinedText(_ lines: [OCRLine]) -> String {
        let rows = rows(lines)
        guard !rows.isEmpty else { return "" }
        let lineHeight = medianHeight(rows.flatMap { $0 })
        var output: [String] = []
        var previousBottom: Double?
        for row in rows {
            let text = row.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: "  ")
            let top = row.map(\.top).max() ?? 0
            if let previousBottom, previousBottom - top > lineHeight * 1.2 {
                output.append("")
            }
            output.append(text)
            previousBottom = row.map(\.y).min() ?? 0
        }
        return output.joined(separator: "\n")
    }

    /// The most prominent line near the top – usually the post or page title.
    public static func headlineCandidate(_ lines: [OCRLine]) -> String? {
        let candidates = lines.filter { line in
            let text = line.text.trimmingCharacters(in: .whitespaces)
            let letters = text.filter(\.isLetter).count
            return line.top > 0.35 && text.count >= 4 && text.count <= 90 && letters >= 3
                && line.confidence >= 0.4 && !TextHeuristics.isChrome(text)
                && TextHeuristics.standaloneURL(in: text) == nil
        }
        guard let best = candidates.max(by: { lhs, rhs in
            // Larger text wins; among similar sizes the higher one wins.
            if abs(lhs.height - rhs.height) > 0.003 { return lhs.height < rhs.height }
            return lhs.top < rhs.top
        }) else {
            return nil
        }
        // A headline only stands out when it is clearly larger than body text.
        let median = medianHeight(lines)
        guard best.height >= median * 1.15 || lines.count <= 3 else { return nil }
        return TextHeuristics.collapseWhitespace(best.text)
    }

    public static func averageConfidence(_ lines: [OCRLine]) -> Double? {
        guard !lines.isEmpty else { return nil }
        let weighted = lines.reduce(into: (sum: 0.0, weight: 0.0)) { result, line in
            let weight = Double(max(line.text.count, 1))
            result.sum += line.confidence * weight
            result.weight += weight
        }
        return weighted.weight > 0 ? weighted.sum / weighted.weight : nil
    }

    static func medianHeight(_ lines: [OCRLine]) -> Double {
        let heights = lines.map(\.height).filter { $0 > 0 }.sorted()
        guard !heights.isEmpty else { return 0.02 }
        return heights[heights.count / 2]
    }
}
