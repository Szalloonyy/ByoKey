//
//  ModelCatalogStore.swift
//  RecallDrop
//
//  Live model lists per provider, cached on disk so pickers open instantly
//  and the pipeline knows each model's output ceiling.
//

import Foundation
import Observation
import RecallDropKit

@MainActor
@Observable
final class ModelCatalogStore {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded(Date)
        case failed(String)
    }

    private(set) var modelsByProvider: [AIProviderKind: [AIModelInfo]] = [:]
    private(set) var states: [AIProviderKind: LoadState] = [:]

    @ObservationIgnored private let cacheDirectory: URL

    init(cacheDirectory: URL = AppGroup.directory(named: "ModelCatalog")) {
        self.cacheDirectory = cacheDirectory
        for provider in AIProviderKind.allCases {
            if let cached = Self.readCache(provider, in: cacheDirectory) {
                modelsByProvider[provider] = cached.models
                states[provider] = .loaded(cached.fetchedAt)
            }
        }
    }

    func models(for provider: AIProviderKind) -> [AIModelInfo] {
        modelsByProvider[provider] ?? []
    }

    func state(for provider: AIProviderKind) -> LoadState {
        states[provider] ?? .idle
    }

    func info(for modelID: String, provider: AIProviderKind) -> AIModelInfo? {
        models(for: provider).first { $0.id == modelID }
    }

    /// Whether the cached list is missing or older than a day.
    func needsRefresh(_ provider: AIProviderKind) -> Bool {
        switch state(for: provider) {
        case .loaded(let date): Date().timeIntervalSince(date) > 24 * 3600
        case .loading: false
        case .idle, .failed: true
        }
    }

    func refresh(_ provider: AIProviderKind, settings: SettingsStore) async {
        guard state(for: provider) != .loading else { return }
        states[provider] = .loading
        do {
            let client = try AIClientFactory.makeClient(configuration: settings.providerConfiguration(for: provider))
            let models = try await client.listModels()
            let sorted = Self.sorted(models, provider: provider)
            modelsByProvider[provider] = sorted
            let now = Date()
            states[provider] = .loaded(now)
            Self.writeCache(CachedList(fetchedAt: now, models: sorted), provider: provider, in: cacheDirectory)
        } catch {
            let aiError = AIError.from(error)
            states[provider] = .failed(aiError.errorDescription ?? error.localizedDescription)
        }
    }

    /// Stores a list obtained elsewhere (e.g. by the connection test).
    func update(_ models: [AIModelInfo], for provider: AIProviderKind) {
        guard !models.isEmpty else { return }
        let sorted = Self.sorted(models, provider: provider)
        modelsByProvider[provider] = sorted
        let now = Date()
        states[provider] = .loaded(now)
        Self.writeCache(CachedList(fetchedAt: now, models: sorted), provider: provider, in: cacheDirectory)
    }

    func clearCache() {
        modelsByProvider = [:]
        states = [:]
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// Output ceiling for a request: the user's setting, capped by the model's own limit.
    func maxOutputTokens(model: String, provider: AIProviderKind, settings: SettingsStore) -> Int {
        let configured = settings.maxOutputTokens(for: provider)
        guard let limit = info(for: model, provider: provider)?.maxOutputTokens, limit > 0 else { return configured }
        return min(configured, limit)
    }

    // MARK: Sorting

    private static func sorted(_ models: [AIModelInfo], provider: AIProviderKind) -> [AIModelInfo] {
        switch provider {
        case .openRouter, .anthropic:
            // Newest first, as the providers present them.
            return models.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        case .openAI, .custom:
            return models.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        }
    }

    // MARK: Disk cache

    private struct CachedList: Codable {
        var fetchedAt: Date
        var models: [AIModelInfo]
    }

    private static func cacheURL(_ provider: AIProviderKind, in directory: URL) -> URL {
        directory.appending(path: "models-\(provider.rawValue).json")
    }

    private static func readCache(_ provider: AIProviderKind, in directory: URL) -> CachedList? {
        guard let data = try? Data(contentsOf: cacheURL(provider, in: directory)) else { return nil }
        return try? JSONDecoder().decode(CachedList.self, from: data)
    }

    private static func writeCache(_ list: CachedList, provider: AIProviderKind, in directory: URL) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: cacheURL(provider, in: directory), options: .atomic)
    }
}
