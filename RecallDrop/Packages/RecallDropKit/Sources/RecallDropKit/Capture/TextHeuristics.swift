//
//  TextHeuristics.swift
//  RecallDropKit
//
//  Small, deterministic text helpers used for titles, tags and previews –
//  and for the on-device analysis in "Offline Only" mode.
//

import Foundation

public enum TextHeuristics {
    /// Truncates at a word boundary and appends "…".
    public static func truncate(_ text: String, maxLength: Int) -> String {
        guard maxLength > 1, text.count > maxLength else { return text }
        let hardCut = text.prefix(maxLength - 1)
        // The cut already falls between two words.
        if hardCut.endIndex < text.endIndex, text[hardCut.endIndex].isWhitespace {
            return hardCut.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        if let space = hardCut.lastIndex(where: { $0.isWhitespace }),
           hardCut.distance(from: hardCut.startIndex, to: space) > maxLength / 2 {
            return hardCut[..<space].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) + "…"
        }
        return hardCut.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    public static func collapseWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `#Design` and `#ux_tips` → ["design", "ux-tips"].
    public static func hashtags(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_&/])#([\p{L}\p{N}_]{2,40})"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let tags = regex.matches(in: text, range: range).compactMap { match -> String? in
            guard let tagRange = Range(match.range(at: 1), in: text) else { return nil }
            let tag = String(text[tagRange])
            // "#1" or "#2024" are rankings or years, not topics.
            return tag.allSatisfy(\.isNumber) ? nil : tag
        }
        return TagNormalizer.normalize(tags)
    }

    public static func urls(in text: String) -> [URL] {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>"'”“)\]]+"#, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        return regex.matches(in: text, range: range).compactMap { match -> URL? in
            guard let urlRange = Range(match.range, in: text) else { return nil }
            var candidate = String(text[urlRange])
            while let last = candidate.last, ".,;:!?".contains(last) { candidate.removeLast() }
            guard seen.insert(candidate).inserted else { return nil }
            return URL(string: candidate)
        }
    }

    /// The URL when `text` is nothing but a link (common for shared text).
    public static func standaloneURL(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url
    }

    static let knownSources: [(hosts: [String], name: String, tag: String)] = [
        (["instagram.com", "instagr.am"], "Instagram", "instagram"),
        (["x.com", "twitter.com", "t.co"], "X", "x"),
        (["threads.net", "threads.com"], "Threads", "threads"),
        (["tiktok.com"], "TikTok", "tiktok"),
        (["youtube.com", "youtu.be"], "YouTube", "youtube"),
        (["reddit.com", "redd.it"], "Reddit", "reddit"),
        (["linkedin.com", "lnkd.in"], "LinkedIn", "linkedin"),
        (["facebook.com", "fb.com", "fb.watch"], "Facebook", "facebook"),
        (["pinterest.com", "pin.it"], "Pinterest", "pinterest"),
        (["medium.com"], "Medium", "medium"),
        (["substack.com"], "Substack", "substack"),
        (["github.com", "gist.github.com"], "GitHub", "github"),
        (["dribbble.com"], "Dribbble", "dribbble"),
        (["behance.net"], "Behance", "behance"),
        (["bsky.app"], "Bluesky", "bluesky"),
        (["news.ycombinator.com"], "Hacker News", "hacker-news"),
        (["apps.apple.com"], "App Store", "app-store"),
        (["amazon.com", "amazon.de", "amazon.co.uk", "amzn.to", "a.co"], "Amazon", "shopping")
    ]

    static func bareHost(of url: URL) -> String? {
        guard var host = url.host?.lowercased() else { return nil }
        for prefix in ["www.", "m.", "mobile."] where host.hasPrefix(prefix) {
            host.removeFirst(prefix.count)
        }
        return host
    }

    static func knownSource(for url: URL) -> (hosts: [String], name: String, tag: String)? {
        guard let host = bareHost(of: url) else { return nil }
        return knownSources.first { entry in
            entry.hosts.contains { host == $0 || host.hasSuffix("." + $0) }
        }
    }

    /// "Instagram" for instagram.com links, the bare host otherwise.
    public static func sourceAppName(for url: URL) -> String? {
        if let known = knownSource(for: url) { return known.name }
        return bareHost(of: url)
    }

    /// A tag derived from the link's site ("instagram", "github", "nytimes").
    public static func domainTag(for url: URL) -> String? {
        if let known = knownSource(for: url) { return known.tag }
        guard let host = bareHost(of: url) else { return nil }
        let parts = host.split(separator: ".")
        guard parts.count >= 2 else { return TagNormalizer.normalize(host) }
        return TagNormalizer.normalize(String(parts[parts.count - 2]))
    }

    /// First line that reads like a title (letters, reasonable length).
    public static func fallbackTitle(from text: String, maxLength: Int = 70) -> String? {
        let lines = text.components(separatedBy: .newlines)
            .map(collapseWhitespace)
            .filter { !$0.isEmpty }
        for line in lines.prefix(12) {
            let letters = line.filter(\.isLetter).count
            guard letters >= 3, !isChrome(line) else { continue }
            if line.count > maxLength, let sentenceEnd = line.firstIndex(where: { ".!?".contains($0) }),
               line.distance(from: line.startIndex, to: sentenceEnd) >= 12 {
                return truncate(String(line[...sentenceEnd]), maxLength: maxLength)
            }
            return truncate(line, maxLength: maxLength)
        }
        return nil
    }

    /// Status-bar and social-media interface text that makes a bad title.
    public static func isChrome(_ line: String) -> Bool {
        let lowered = line.lowercased().trimmingCharacters(in: .whitespaces)
        if lowered.range(of: #"^\d{1,2}[:.]\d{2}(\s?(am|pm))?$"#, options: .regularExpression) != nil { return true }
        if lowered.range(of: #"^\d{1,3}\s?%$"#, options: .regularExpression) != nil { return true }
        let chrome: Set<String> = [
            "follow", "following", "like", "reply", "share", "repost", "retweet", "comment", "comments",
            "send message", "message", "more", "back", "done", "cancel", "search", "home", "explore",
            "reels", "profile", "notifications", "sponsored", "see translation", "translate post", "for you"
        ]
        return chrome.contains(lowered)
    }

    /// The first `maxLength` characters of meaningful text, on one line.
    public static func previewSnippet(from text: String, maxLength: Int = 280) -> String {
        let meaningful = text.components(separatedBy: .newlines)
            .map(collapseWhitespace)
            .filter { !$0.isEmpty && !isChrome($0) }
            .joined(separator: " ")
        return truncate(meaningful, maxLength: maxLength)
    }
}
