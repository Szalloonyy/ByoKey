//
//  AgencyAgentsCatalog.swift
//  RecallDropKit
//
//  Browses a GitHub repository of persona files – by default
//  github.com/msitarzewski/agency-agents – so users can import agents with
//  one tap. Uses the public, unauthenticated GitHub API (one request for the
//  whole tree) and raw.githubusercontent.com for the files themselves.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AgencyAgentEntry: Sendable, Hashable, Identifiable {
    public var path: String
    public var category: String
    public var name: String
    public var rawURL: URL
    public var webURL: URL

    public var id: String { path }
}

public enum CatalogError: Error, LocalizedError, Sendable, Equatable {
    case http(Int)
    case rateLimited
    case invalidRepository
    case notMarkdown

    public var errorDescription: String? {
        switch self {
        case .http(let status): "GitHub returned status \(status)."
        case .rateLimited: "GitHub's hourly limit for anonymous requests is used up. Try again later."
        case .invalidRepository: "That repository could not be found."
        case .notMarkdown: "The link does not point to a Markdown file."
        }
    }
}

public struct AgencyAgentsCatalog: Sendable {
    public static let defaultOwner = "msitarzewski"
    public static let defaultRepository = "agency-agents"
    public static let defaultBranch = "main"

    public var owner: String
    public var repository: String
    public var branch: String
    private let transport: any HTTPTransport

    public init(
        owner: String = AgencyAgentsCatalog.defaultOwner,
        repository: String = AgencyAgentsCatalog.defaultRepository,
        branch: String = AgencyAgentsCatalog.defaultBranch,
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        self.owner = owner
        self.repository = repository
        self.branch = branch
        self.transport = transport
    }

    public var repositoryURL: URL {
        URL(string: "https://github.com/\(owner)/\(repository)")!
    }

    public func fetchEntries() async throws -> [AgencyAgentEntry] {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repository)/git/trees/\(branch)?recursive=1") else {
            throw CatalogError.invalidRepository
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("RecallDrop", forHTTPHeaderField: "User-Agent")
        let response = try await transport.send(request)
        switch response.statusCode {
        case 200: break
        case 403, 429: throw CatalogError.rateLimited
        case 404, 409, 422: throw CatalogError.invalidRepository
        default: throw CatalogError.http(response.statusCode)
        }
        return try Self.parseTree(response.body, owner: owner, repository: repository, branch: branch)
    }

    public func fetchMarkdown(for entry: AgencyAgentEntry) async throws -> String {
        try await Self.fetchMarkdown(from: entry.rawURL, transport: transport)
    }

    /// Downloads a persona file from any URL; GitHub page links are converted to raw links.
    public static func fetchMarkdown(from url: URL, transport: any HTTPTransport = URLSessionTransport()) async throws -> String {
        let resolved = rawURL(forGitHubURL: url) ?? url
        var request = URLRequest(url: resolved)
        request.timeoutInterval = 30
        request.setValue("RecallDrop", forHTTPHeaderField: "User-Agent")
        let response = try await transport.send(request)
        guard response.isSuccess else { throw CatalogError.http(response.statusCode) }
        let text = String(decoding: response.body, as: UTF8.self)
        let contentType = response.headers["content-type"]?.lowercased() ?? ""
        if contentType.contains("text/html") || text.lowercased().hasPrefix("<!doctype html") {
            throw CatalogError.notMarkdown
        }
        return text
    }

    /// `github.com/o/r/blob/branch/path.md` → `raw.githubusercontent.com/o/r/branch/path.md`.
    public static func rawURL(forGitHubURL url: URL) -> URL? {
        guard let host = url.host?.lowercased() else { return nil }
        if host == "raw.githubusercontent.com" { return url }
        guard host == "github.com" || host == "www.github.com" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 5, parts[2] == "blob" || parts[2] == "raw" else { return nil }
        let owner = parts[0]
        let repository = parts[1]
        let rest = parts[3...].joined(separator: "/")
        return URL(string: "https://raw.githubusercontent.com/\(owner)/\(repository)/\(rest)")
    }

    static let excludedFileNames: Set<String> = [
        "readme.md", "contributing.md", "license.md", "changelog.md", "code_of_conduct.md",
        "security.md", "agents.md", "claude.md", "template.md", "pull_request_template.md"
    ]

    public static func parseTree(_ data: Data, owner: String, repository: String, branch: String) throws -> [AgencyAgentEntry] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tree = object["tree"] as? [[String: Any]] else {
            throw CatalogError.invalidRepository
        }
        var entries: [AgencyAgentEntry] = []
        for item in tree {
            guard (item["type"] as? String) == "blob",
                  let path = item["path"] as? String,
                  path.lowercased().hasSuffix(".md") else { continue }
            let components = path.split(separator: "/").map(String.init)
            guard components.count >= 2,
                  !components.contains(where: { $0.hasPrefix(".") }),
                  let fileName = components.last,
                  !excludedFileNames.contains(fileName.lowercased()) else { continue }
            let folder = components[0]
            guard !["docs", "doc", "examples", "scripts", "assets", "images", ".github"].contains(folder.lowercased()) else { continue }

            let encodedPath = components
                .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
                .joined(separator: "/")
            guard let raw = URL(string: "https://raw.githubusercontent.com/\(owner)/\(repository)/\(branch)/\(encodedPath)"),
                  let web = URL(string: "https://github.com/\(owner)/\(repository)/blob/\(branch)/\(encodedPath)") else { continue }

            var baseName = String(fileName.dropLast(3))
            let folderPrefix = folder.lowercased() + "-"
            if baseName.lowercased().hasPrefix(folderPrefix), baseName.count > folderPrefix.count {
                baseName = String(baseName.dropFirst(folderPrefix.count))
            }
            entries.append(AgencyAgentEntry(
                path: path,
                category: PersonaMarkdownCodec.prettifiedName(folder),
                name: PersonaMarkdownCodec.prettifiedName(baseName),
                rawURL: raw,
                webURL: web
            ))
        }
        return entries.sorted {
            ($0.category, $0.name) < ($1.category, $1.name)
        }
    }
}
