//
//  LinkMetadata.swift
//  RecallDropKit
//
//  Link previews for captured URLs: Open Graph / Twitter-card tags from the
//  page's HTML, plus oEmbed for X (Twitter) posts and YouTube videos, whose
//  pages expose little to non-browser clients.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct LinkMetadata: Sendable, Hashable, Codable {
    public var title: String?
    public var summary: String?
    public var siteName: String?
    public var imageURL: URL?
    public var author: String?
    public var canonicalURL: URL?
    /// Full text of the linked post when available (e.g. a tweet via oEmbed).
    public var bodyText: String?

    public init(title: String? = nil, summary: String? = nil, siteName: String? = nil, imageURL: URL? = nil,
                author: String? = nil, canonicalURL: URL? = nil, bodyText: String? = nil) {
        self.title = title
        self.summary = summary
        self.siteName = siteName
        self.imageURL = imageURL
        self.author = author
        self.canonicalURL = canonicalURL
        self.bodyText = bodyText
    }

    public var isEmpty: Bool {
        title == nil && summary == nil && imageURL == nil && bodyText == nil
    }

    /// Fills gaps in `self` with values from `other`.
    public func merged(with other: LinkMetadata) -> LinkMetadata {
        LinkMetadata(
            title: title ?? other.title,
            summary: summary ?? other.summary,
            siteName: siteName ?? other.siteName,
            imageURL: imageURL ?? other.imageURL,
            author: author ?? other.author,
            canonicalURL: canonicalURL ?? other.canonicalURL,
            bodyText: bodyText ?? other.bodyText
        )
    }
}

public enum HTMLMetadataParser {
    /// Meta tags live in <head>; there is no need to scan megabytes of body.
    public static let scanLimit = 600_000

    public static func parse(html fullHTML: String, baseURL: URL) -> LinkMetadata {
        let html = fullHTML.count > scanLimit ? String(fullHTML.prefix(scanLimit)) : fullHTML
        var meta: [String: String] = [:]

        for tag in matches(of: #"<meta\b[^>]*>"#, in: html) {
            let attributes = attributesOf(tag)
            guard let content = attributes["content"].map(decodeEntities)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty else { continue }
            for keyAttribute in ["property", "name", "itemprop"] {
                if let key = attributes[keyAttribute]?.lowercased(), meta[key] == nil {
                    meta[key] = content
                }
            }
        }

        var title = meta["og:title"] ?? meta["twitter:title"]
        if title == nil, let titleTag = firstCapture(of: #"<title\b[^>]*>([\s\S]*?)</title>"#, in: html) {
            title = decodeEntities(titleTag).trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }

        let imageString = meta["og:image:secure_url"] ?? meta["og:image"] ?? meta["og:image:url"]
            ?? meta["twitter:image"] ?? meta["twitter:image:src"] ?? meta["image"]
        let imageURL = imageString.flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }

        var canonical: URL?
        for tag in matches(of: #"<link\b[^>]*>"#, in: html) {
            let attributes = attributesOf(tag)
            if attributes["rel"]?.lowercased() == "canonical", let href = attributes["href"] {
                canonical = URL(string: decodeEntities(href), relativeTo: baseURL)?.absoluteURL
                break
            }
        }

        return LinkMetadata(
            title: title.map(collapseWhitespace),
            summary: (meta["og:description"] ?? meta["twitter:description"] ?? meta["description"]).map(collapseWhitespace),
            siteName: meta["og:site_name"] ?? meta["application-name"],
            imageURL: imageURL,
            author: meta["author"] ?? meta["article:author"] ?? meta["twitter:creator"],
            canonicalURL: canonical
        )
    }

    // MARK: Helpers

    static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    static func firstCapture(of pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    static func attributesOf(_ tag: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#
        ) else { return [:] }
        var result: [String: String] = [:]
        for match in regex.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
            guard let nameRange = Range(match.range(at: 1), in: tag) else { continue }
            let name = tag[nameRange].lowercased()
            var value = ""
            for group in 2...4 {
                if let range = Range(match.range(at: group), in: tag) {
                    value = String(tag[range])
                    break
                }
            }
            if result[name] == nil { result[name] = value }
        }
        return result
    }

    public static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
            "mdash": "—", "ndash": "–", "hellip": "…", "rsquo": "’", "lsquo": "‘",
            "rdquo": "”", "ldquo": "“", "middot": "·", "copy": "©", "reg": "®", "trade": "™"
        ]
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "&",
                  let semicolon = text[index...].prefix(12).firstIndex(of: ";") else {
                result.append(character)
                index = text.index(after: index)
                continue
            }
            let entity = String(text[text.index(after: index)..<semicolon])
            var replacement: String?
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                replacement = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if entity.hasPrefix("#") {
                replacement = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = named[entity.lowercased()]
            }
            if let replacement {
                result.append(replacement)
                index = text.index(after: semicolon)
            } else {
                result.append(character)
                index = text.index(after: index)
            }
        }
        return result
    }

    /// Removes tags, turning <br> and paragraph ends into line breaks.
    public static func plainText(fromHTML html: String) -> String {
        var text = html.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)</p>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        text = decodeEntities(text)
        return text
            .components(separatedBy: .newlines)
            .map { collapseWhitespace($0) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func collapseWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// oEmbed endpoints that work without authentication.
public enum OEmbedProvider: String, Sendable, Hashable {
    case twitter
    case youtube

    public init?(url: URL) {
        guard let host = url.host?.lowercased() else { return nil }
        let bareHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        switch bareHost {
        case "twitter.com", "x.com", "mobile.twitter.com", "mobile.x.com":
            guard url.path.contains("/status/") else { return nil }
            self = .twitter
        case "youtube.com", "m.youtube.com", "music.youtube.com":
            guard url.path.hasPrefix("/watch") || url.path.hasPrefix("/shorts/") || url.path.hasPrefix("/live/") else { return nil }
            self = .youtube
        case "youtu.be":
            self = .youtube
        default:
            return nil
        }
    }

    public func endpoint(for url: URL) -> URL? {
        var components: URLComponents?
        switch self {
        case .twitter:
            components = URLComponents(string: "https://publish.twitter.com/oembed")
            components?.queryItems = [
                URLQueryItem(name: "url", value: url.absoluteString),
                URLQueryItem(name: "omit_script", value: "1"),
                URLQueryItem(name: "dnt", value: "true")
            ]
        case .youtube:
            components = URLComponents(string: "https://www.youtube.com/oembed")
            components?.queryItems = [
                URLQueryItem(name: "url", value: url.absoluteString),
                URLQueryItem(name: "format", value: "json")
            ]
        }
        return components?.url
    }

    public func parse(_ data: Data) -> LinkMetadata? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let author = object["author_name"] as? String
        switch self {
        case .twitter:
            guard let html = object["html"] as? String else { return nil }
            let paragraph = HTMLMetadataParser.firstCapture(of: #"<p\b[^>]*>([\s\S]*?)</p>"#, in: html) ?? html
            let text = HTMLMetadataParser.plainText(fromHTML: paragraph)
            return LinkMetadata(
                title: author.map { "\($0) on X" },
                summary: text.nonEmpty.map { TextHeuristics.truncate($0, maxLength: 280) },
                siteName: "X",
                author: author,
                bodyText: text.nonEmpty
            )
        case .youtube:
            return LinkMetadata(
                title: object["title"] as? String,
                summary: author.map { "Video by \($0)" },
                siteName: "YouTube",
                imageURL: (object["thumbnail_url"] as? String).flatMap(URL.init(string:)),
                author: author
            )
        }
    }
}

public enum LinkMetadataFetcher {
    public static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// oEmbed first (when the site supports it), then the page's own meta tags.
    public static func fetch(_ url: URL, transport: any HTTPTransport = URLSessionTransport()) async -> LinkMetadata {
        var metadata = LinkMetadata()

        if let provider = OEmbedProvider(url: url), let endpoint = provider.endpoint(for: url) {
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = 15
            if let response = try? await transport.send(request), response.isSuccess,
               let parsed = provider.parse(response.body) {
                metadata = parsed
            }
        }

        if metadata.title == nil || metadata.imageURL == nil || metadata.summary == nil {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
            if let response = try? await transport.send(request), response.isSuccess {
                let contentType = response.headers["content-type"]?.lowercased() ?? "text/html"
                if contentType.contains("html") || contentType.contains("xml") {
                    let html = String(decoding: response.body.prefix(2_000_000), as: UTF8.self)
                    metadata = metadata.merged(with: HTMLMetadataParser.parse(html: html, baseURL: url))
                } else if contentType.hasPrefix("image/") {
                    metadata.imageURL = metadata.imageURL ?? url
                }
            }
        }

        if metadata.siteName == nil { metadata.siteName = TextHeuristics.sourceAppName(for: url) }
        return metadata
    }
}
