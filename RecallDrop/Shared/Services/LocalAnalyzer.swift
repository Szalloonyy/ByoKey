//
//  LocalAnalyzer.swift
//  RecallDrop
//
//  "Offline Only" analysis: Apple's NaturalLanguage framework finds names
//  and key nouns, NSDataDetector finds dates, links, phone numbers and
//  addresses. RecallDropKit's LocalAnalysis turns that into a title,
//  summary, next steps and tags. Nothing leaves the device.
//

import Foundation
import NaturalLanguage
import RecallDropKit

struct DetectedData: Sendable {
    var dates: [Date] = []
    var links: [URL] = []
    var phoneNumbers: [String] = []
    var addresses: [String] = []
}

enum LocalAnalyzer {
    /// Text beyond this length adds little and slows tagging down.
    static let maxAnalyzedCharacters = 20_000

    static func analyze(
        kind: CaptureKind,
        text: String?,
        lines: [OCRLine],
        sourceURL: URL?,
        linkTitle: String?,
        now: Date = Date()
    ) -> AgentOutput {
        let analyzedText = String((text ?? "").prefix(maxAnalyzedCharacters))
        let detected = detectData(in: analyzedText)
        let input = LocalAnalysisInput(
            kind: kind.contextKind,
            text: text,
            lines: lines,
            sourceURL: sourceURL,
            linkTitle: linkTitle,
            keywords: keywords(in: analyzedText),
            detectedDates: detected.dates,
            detectedLinks: detected.links,
            detectedPhoneNumbers: detected.phoneNumbers,
            detectedAddresses: detected.addresses
        )
        return LocalAnalysis.analyze(input, now: now)
    }

    /// Names (people, places, organizations) first, then frequent nouns.
    static func keywords(in text: String, limit: Int = 6) -> [String] {
        guard text.count >= 3 else { return [] }
        var scores: [String: Int] = [:]
        var display: [String: String] = [:]
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .omitOther, .joinNames]
        let tagger = NLTagger(tagSchemes: [.nameType, .lexicalClass])
        tagger.string = text

        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: options) { tag, range in
            if let tag, tag == .personalName || tag == .placeName || tag == .organizationName {
                let word = String(text[range])
                let key = word.lowercased()
                scores[key, default: 0] += 3
                display[key] = display[key] ?? word
            }
            return true
        }
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: options) { tag, range in
            guard tag == .noun else { return true }
            let word = String(text[range])
            let key = word.lowercased()
            guard word.count >= 4, word.count <= 24, !stopWords.contains(key),
                  word.contains(where: \.isLetter), !word.contains(where: \.isNumber) else { return true }
            scores[key, default: 0] += 1
            display[key] = display[key] ?? key
            return true
        }

        return scores
            .sorted { lhs, rhs in lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value }
            .prefix(limit)
            .compactMap { display[$0.key] }
    }

    static func detectData(in text: String) -> DetectedData {
        var result = DetectedData()
        guard !text.isEmpty else { return result }
        let types: NSTextCheckingResult.CheckingType = [.date, .link, .phoneNumber, .address]
        guard let detector = try? NSDataDetector(types: types.rawValue) else { return result }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, options: [], range: range) {
            switch match.resultType {
            case .date:
                if let date = match.date { result.dates.append(date) }
            case .link:
                if let url = match.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                    result.links.append(url)
                }
            case .phoneNumber:
                if let number = match.phoneNumber { result.phoneNumbers.append(number) }
            case .address:
                if let swiftRange = Range(match.range, in: text) {
                    result.addresses.append(TextHeuristics.collapseWhitespace(String(text[swiftRange])))
                }
            default:
                break
            }
        }
        return result
    }

    /// Interface and filler words that make poor tags.
    private static let stopWords: Set<String> = [
        "like", "likes", "reply", "replies", "share", "follow", "following", "followers", "comment", "comments",
        "view", "views", "post", "posts", "home", "search", "profile", "message", "messages", "photo", "photos",
        "video", "videos", "time", "today", "yesterday", "thing", "things", "people", "something", "anything",
        "screenshot", "image", "page", "link", "click", "button", "account", "notification", "notifications",
        "https", "http", "www", "more", "less", "reels", "story", "stories"
    ]
}
