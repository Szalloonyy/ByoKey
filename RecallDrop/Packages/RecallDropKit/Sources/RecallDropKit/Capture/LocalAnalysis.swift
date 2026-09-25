//
//  LocalAnalysis.swift
//  RecallDropKit
//
//  The "Offline Only" analyzer: builds an AgentOutput from on-device OCR and
//  data detection without contacting any AI provider. The app feeds in
//  keywords and detected dates/links/phone numbers from Apple's
//  NaturalLanguage and NSDataDetector; this type decides what to make of them.
//

import Foundation

public struct LocalAnalysisInput: Sendable {
    public var kind: CaptureContext.Kind
    public var text: String?
    public var lines: [OCRLine]
    public var sourceURL: URL?
    public var linkTitle: String?
    public var keywords: [String]
    public var detectedDates: [Date]
    public var detectedLinks: [URL]
    public var detectedPhoneNumbers: [String]
    public var detectedAddresses: [String]

    public init(
        kind: CaptureContext.Kind,
        text: String? = nil,
        lines: [OCRLine] = [],
        sourceURL: URL? = nil,
        linkTitle: String? = nil,
        keywords: [String] = [],
        detectedDates: [Date] = [],
        detectedLinks: [URL] = [],
        detectedPhoneNumbers: [String] = [],
        detectedAddresses: [String] = []
    ) {
        self.kind = kind
        self.text = text
        self.lines = lines
        self.sourceURL = sourceURL
        self.linkTitle = linkTitle
        self.keywords = keywords
        self.detectedDates = detectedDates
        self.detectedLinks = detectedLinks
        self.detectedPhoneNumbers = detectedPhoneNumbers
        self.detectedAddresses = detectedAddresses
    }
}

public enum LocalAnalysis {
    public static let agentName = "On-Device Analysis"

    public static func analyze(_ input: LocalAnalysisInput, now: Date = Date(), locale: Locale = .current,
                               timeZone: TimeZone = .current) -> AgentOutput {
        let text = input.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let title = input.linkTitle?.nonEmpty
            ?? OCRLayout.headlineCandidate(input.lines)
            ?? TextHeuristics.fallbackTitle(from: text)
            ?? input.sourceURL.flatMap { TextHeuristics.sourceAppName(for: $0) }.map { "Saved from \($0)" }
            ?? input.kind.label

        var summary = TextHeuristics.previewSnippet(from: text, maxLength: 240)
        if summary.isEmpty, let url = input.sourceURL {
            summary = "Link to \(TextHeuristics.sourceAppName(for: url) ?? url.absoluteString)."
        }

        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        style.locale = locale
        style.timeZone = timeZone
        let futureDates = input.detectedDates
            .filter { $0 > now && $0 < now.addingTimeInterval(366 * 24 * 3600) }
            .sorted()

        var steps: [String] = []
        for date in futureDates.prefix(2) {
            steps.append("Follow up on \(date.formatted(style))")
        }
        let otherLinks = input.detectedLinks.filter { $0 != input.sourceURL }
        for link in otherLinks.prefix(3) {
            steps.append("Open \(link.absoluteString)")
        }
        for phone in input.detectedPhoneNumbers.prefix(2) {
            steps.append("Call \(phone)")
        }
        for address in input.detectedAddresses.prefix(2) {
            steps.append("Look up \(address) in Maps")
        }
        if input.kind == .link, let url = input.sourceURL, steps.isEmpty {
            steps.append("Read the page on \(TextHeuristics.sourceAppName(for: url) ?? "the web")")
        }

        var tags = TextHeuristics.hashtags(in: text)
        tags.append(contentsOf: input.keywords.prefix(5))
        if let url = input.sourceURL, let domain = TextHeuristics.domainTag(for: url) { tags.append(domain) }
        if !futureDates.isEmpty { tags.append("event") }

        var thoughts = ["Analyzed on this device – nothing was sent to an AI provider."]
        if !input.lines.isEmpty {
            let confidence = OCRLayout.averageConfidence(input.lines).map { " (average confidence \(Int(($0 * 100).rounded())) %)" } ?? ""
            thoughts.append("Recognized \(input.lines.count) line\(input.lines.count == 1 ? "" : "s") of text\(confidence).")
        } else if text.isEmpty, input.kind == .screenshot || input.kind == .photo {
            thoughts.append("No text was found in the image.")
        }
        var detected: [String] = []
        if !futureDates.isEmpty { detected.append("\(futureDates.count) upcoming date\(futureDates.count == 1 ? "" : "s")") }
        if !otherLinks.isEmpty { detected.append("\(otherLinks.count) link\(otherLinks.count == 1 ? "" : "s")") }
        if !input.detectedPhoneNumbers.isEmpty { detected.append("phone numbers") }
        if !input.detectedAddresses.isEmpty { detected.append("addresses") }
        if !detected.isEmpty { thoughts.append("Detected " + detected.joined(separator: ", ") + ".") }
        if !input.keywords.isEmpty { thoughts.append("Key terms: " + input.keywords.prefix(5).joined(separator: ", ") + ".") }

        return AgentOutput(
            title: TextHeuristics.truncate(title, maxLength: AgentOutputParser.maximumTitleLength),
            summary: summary,
            actionableSteps: steps,
            tags: TagNormalizer.normalize(tags, limit: 8),
            thoughtProcess: thoughts,
            suggestedReminder: futureDates.first
        )
    }
}
