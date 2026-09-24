//
//  SettingsStore.swift
//  RecallDrop
//
//  User preferences, persisted in the App Group's UserDefaults so the share
//  extension sees the same provider, models and agent defaults. Secrets are
//  not stored here – see KeychainStore.
//

import Foundation
import Observation
import RecallDropKit

enum OCRAccuracy: String, CaseIterable, Identifiable, Sendable {
    case accurate
    case fast

    var id: String { rawValue }
    var label: String { self == .accurate ? "Accurate" : "Fast" }
}

enum GridDensity: String, CaseIterable, Identifiable, Sendable {
    case compact
    case comfortable
    case large

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    /// Minimum card width in points.
    var minimumCardWidth: Double {
        switch self {
        case .compact: 150
        case .comfortable: 200
        case .large: 280
        }
    }
}

@MainActor
@Observable
final class SettingsStore {
    private enum Key {
        static let provider = "ai.provider"
        static let baseURLs = "ai.baseURLs"
        static let defaultModels = "ai.defaultModels"
        static let maxOutputTokens = "ai.maxOutputTokens"
        static let offlineOnly = "ai.offlineOnly"
        static let autoAnalyze = "capture.autoAnalyze"
        static let sendImages = "ai.sendImages"
        static let useJSONMode = "ai.useJSONMode"
        static let requestTimeout = "ai.requestTimeout"
        static let responseLanguage = "ai.responseLanguage"
        static let ocrAccuracy = "ocr.accuracy"
        static let ocrLanguageCorrection = "ocr.languageCorrection"
        static let fetchLinkPreviews = "capture.fetchLinkPreviews"
        static let morningHour = "reminders.morningHour"
        static let eveningHour = "reminders.eveningHour"
        static let weekendHour = "reminders.weekendHour"
        static let gridDensity = "ui.gridDensity"
        static let showDropShelfAtLaunch = "mac.showDropShelfAtLaunch"
        static let hideDockIcon = "mac.hideDockIcon"
        static let hotKeys = "mac.hotKeys"
        static let hasCompletedOnboarding = "ui.hasCompletedOnboarding"
        static let lastExternalChange = "sync.lastExternalChange"
        static let processingClaims = "sync.processingClaims"

        static let all = [
            provider, baseURLs, defaultModels, maxOutputTokens, offlineOnly, autoAnalyze, sendImages,
            useJSONMode, requestTimeout, responseLanguage, ocrAccuracy, ocrLanguageCorrection,
            fetchLinkPreviews, morningHour, eveningHour, weekendHour, gridDensity, showDropShelfAtLaunch,
            hideDockIcon, hotKeys, hasCompletedOnboarding, lastExternalChange, processingClaims
        ]
    }

    @ObservationIgnored private let defaults: UserDefaults
    /// Set while values are (re)loaded from the defaults, so they are not written back.
    @ObservationIgnored private var isLoading = false

    // MARK: AI provider

    var provider: AIProviderKind = .openRouter {
        didSet { store(provider.rawValue, Key.provider) }
    }

    /// Per-provider base URL overrides (raw value → URL string).
    private(set) var baseURLOverrides: [String: String] = [:] {
        didSet { store(baseURLOverrides, Key.baseURLs) }
    }

    /// Per-provider default model (raw value → model ID).
    private(set) var defaultModels: [String: String] = [:] {
        didSet { store(defaultModels, Key.defaultModels) }
    }

    private(set) var maxOutputTokenOverrides: [String: Int] = [:] {
        didSet { store(maxOutputTokenOverrides, Key.maxOutputTokens) }
    }

    /// Only on-device OCR and analysis; no request reaches an AI provider.
    var offlineOnly = false {
        didSet { store(offlineOnly, Key.offlineOnly) }
    }

    /// Run the default agent on every new capture.
    var autoAnalyze = true {
        didSet { store(autoAnalyze, Key.autoAnalyze) }
    }

    /// Attach the image itself (not just the OCR text) to agent requests.
    var sendImages = true {
        didSet { store(sendImages, Key.sendImages) }
    }

    var useJSONMode = true {
        didSet { store(useJSONMode, Key.useJSONMode) }
    }

    var requestTimeout = 120.0 {
        didSet { store(requestTimeout, Key.requestTimeout) }
    }

    var responseLanguage: PromptEnvironment.ResponseLanguage = .device {
        didSet { store(responseLanguage.rawValue, Key.responseLanguage) }
    }

    // MARK: Capture

    var ocrAccuracy: OCRAccuracy = .accurate {
        didSet { store(ocrAccuracy.rawValue, Key.ocrAccuracy) }
    }

    var ocrLanguageCorrection = true {
        didSet { store(ocrLanguageCorrection, Key.ocrLanguageCorrection) }
    }

    var fetchLinkPreviews = true {
        didSet { store(fetchLinkPreviews, Key.fetchLinkPreviews) }
    }

    // MARK: Reminders

    var morningHour = 9 {
        didSet { store(morningHour, Key.morningHour) }
    }

    var eveningHour = 20 {
        didSet { store(eveningHour, Key.eveningHour) }
    }

    var weekendHour = 10 {
        didSet { store(weekendHour, Key.weekendHour) }
    }

    var reminderSchedule: ReminderSchedule {
        ReminderSchedule(morningHour: morningHour, eveningHour: eveningHour, weekendHour: weekendHour)
    }

    // MARK: Interface

    var gridDensity: GridDensity = .comfortable {
        didSet { store(gridDensity.rawValue, Key.gridDensity) }
    }

    var hasCompletedOnboarding = false {
        didSet { store(hasCompletedOnboarding, Key.hasCompletedOnboarding) }
    }

    // MARK: macOS

    var showDropShelfAtLaunch = false {
        didSet { store(showDropShelfAtLaunch, Key.showDropShelfAtLaunch) }
    }

    var hideDockIcon = false {
        didSet { store(hideDockIcon, Key.hideDockIcon) }
    }

    /// Global shortcuts as JSON (see HotKeyCenter on macOS).
    var hotKeysData: Data? = nil {
        didSet { store(hotKeysData, Key.hotKeys) }
    }

    // MARK: Init

    init(defaults: UserDefaults = AppGroup.makeUserDefaults()) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.autoAnalyze: true,
            Key.sendImages: true,
            Key.useJSONMode: true,
            Key.requestTimeout: 120.0,
            Key.ocrLanguageCorrection: true,
            Key.fetchLinkPreviews: true,
            Key.morningHour: 9,
            Key.eveningHour: 20,
            Key.weekendHour: 10
        ])
        reload()
    }

    /// Reads every preference from the defaults (registered values apply to missing keys).
    private func reload() {
        isLoading = true
        defer { isLoading = false }
        provider = defaults.string(forKey: Key.provider).flatMap(AIProviderKind.init(rawValue:)) ?? .openRouter
        baseURLOverrides = defaults.dictionary(forKey: Key.baseURLs) as? [String: String] ?? [:]
        defaultModels = defaults.dictionary(forKey: Key.defaultModels) as? [String: String] ?? [:]
        maxOutputTokenOverrides = defaults.dictionary(forKey: Key.maxOutputTokens) as? [String: Int] ?? [:]
        offlineOnly = defaults.bool(forKey: Key.offlineOnly)
        autoAnalyze = defaults.bool(forKey: Key.autoAnalyze)
        sendImages = defaults.bool(forKey: Key.sendImages)
        useJSONMode = defaults.bool(forKey: Key.useJSONMode)
        requestTimeout = min(max(defaults.double(forKey: Key.requestTimeout), 20), 600)
        responseLanguage = defaults.string(forKey: Key.responseLanguage)
            .flatMap(PromptEnvironment.ResponseLanguage.init(rawValue:)) ?? .device
        ocrAccuracy = defaults.string(forKey: Key.ocrAccuracy).flatMap(OCRAccuracy.init(rawValue:)) ?? .accurate
        ocrLanguageCorrection = defaults.bool(forKey: Key.ocrLanguageCorrection)
        fetchLinkPreviews = defaults.bool(forKey: Key.fetchLinkPreviews)
        morningHour = defaults.integer(forKey: Key.morningHour)
        eveningHour = defaults.integer(forKey: Key.eveningHour)
        weekendHour = defaults.integer(forKey: Key.weekendHour)
        gridDensity = defaults.string(forKey: Key.gridDensity).flatMap(GridDensity.init(rawValue:)) ?? .comfortable
        hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
        showDropShelfAtLaunch = defaults.bool(forKey: Key.showDropShelfAtLaunch)
        hideDockIcon = defaults.bool(forKey: Key.hideDockIcon)
        hotKeysData = defaults.data(forKey: Key.hotKeys)
    }

    private func store(_ value: Any?, _ key: String) {
        guard !isLoading else { return }
        defaults.set(value, forKey: key)
    }

    // MARK: Per-provider values

    func baseURL(for provider: AIProviderKind) -> URL {
        if let string = baseURLOverrides[provider.rawValue], let url = provider.normalizedBaseURL(from: string) {
            return url
        }
        return provider.defaultBaseURL
    }

    func hasCustomBaseURL(for provider: AIProviderKind) -> Bool {
        baseURLOverrides[provider.rawValue] != nil
    }

    /// Stores a base URL; returns false when the input is not a valid address.
    @discardableResult
    func setBaseURL(_ input: String?, for provider: AIProviderKind) -> Bool {
        guard let input = input?.trimmedNonEmpty else {
            baseURLOverrides.removeValue(forKey: provider.rawValue)
            return true
        }
        guard let url = provider.normalizedBaseURL(from: input) else { return false }
        if url == provider.defaultBaseURL {
            baseURLOverrides.removeValue(forKey: provider.rawValue)
        } else {
            baseURLOverrides[provider.rawValue] = url.absoluteString
        }
        return true
    }

    func defaultModel(for provider: AIProviderKind) -> String {
        defaultModels[provider.rawValue]?.trimmedNonEmpty ?? provider.defaultModel
    }

    func setDefaultModel(_ model: String, for provider: AIProviderKind) {
        if let model = model.trimmedNonEmpty {
            defaultModels[provider.rawValue] = model
        } else {
            defaultModels.removeValue(forKey: provider.rawValue)
        }
    }

    func maxOutputTokens(for provider: AIProviderKind) -> Int {
        maxOutputTokenOverrides[provider.rawValue] ?? provider.defaultMaxOutputTokens
    }

    func setMaxOutputTokens(_ value: Int, for provider: AIProviderKind) {
        let clamped = min(max(value, 256), 128_000)
        if clamped == provider.defaultMaxOutputTokens {
            maxOutputTokenOverrides.removeValue(forKey: provider.rawValue)
        } else {
            maxOutputTokenOverrides[provider.rawValue] = clamped
        }
    }

    var activeDefaultModel: String { defaultModel(for: provider) }

    /// Everything needed to build a client for `provider` (defaults to the active one).
    func providerConfiguration(for provider: AIProviderKind? = nil) -> AIProviderConfiguration {
        let kind = provider ?? self.provider
        return AIProviderConfiguration(
            kind: kind,
            baseURL: baseURL(for: kind),
            apiKey: KeychainStore.apiKey(for: kind),
            requestTimeout: requestTimeout
        )
    }

    /// Whether agents can run right now; `nil` means ready, otherwise the reason.
    var aiUnavailableReason: String? {
        if offlineOnly { return "Offline Only is on." }
        if provider.requiresAPIKey, !KeychainStore.hasAPIKey(for: provider) {
            return "Add your \(provider.displayName) API key in Settings."
        }
        return nil
    }

    // MARK: Cross-process change marker

    /// Written by the share extension after it saved something.
    func markExternalChange() {
        defaults.set(Date().timeIntervalSince1970, forKey: Key.lastExternalChange)
    }

    var lastExternalChange: TimeInterval {
        defaults.double(forKey: Key.lastExternalChange)
    }

    /// Removes every stored preference and returns to the defaults right away.
    func resetAll() {
        for key in Key.all {
            defaults.removeObject(forKey: key)
        }
        reload()
    }

    // MARK: Cross-process processing claims

    /// How long a claim keeps the app away from an item the share extension works on.
    nonisolated static let claimLifetime: TimeInterval = 180

    /// Marks items the share extension is processing, so the app does not
    /// start the same work at the same time.
    func claimProcessing(of itemIDs: [UUID]) {
        guard !itemIDs.isEmpty else { return }
        var claims = liveClaims()
        let now = Date().timeIntervalSince1970
        for itemID in itemIDs {
            claims[itemID.uuidString] = now
        }
        defaults.set(claims, forKey: Key.processingClaims)
    }

    func releaseProcessing(of itemIDs: [UUID]) {
        guard !itemIDs.isEmpty else { return }
        var claims = liveClaims()
        for itemID in itemIDs {
            claims.removeValue(forKey: itemID.uuidString)
        }
        defaults.set(claims, forKey: Key.processingClaims)
    }

    /// Claims younger than `claimLifetime`, by item.
    func activeProcessingClaims() -> [UUID: Date] {
        var result: [UUID: Date] = [:]
        for (key, time) in liveClaims() {
            if let itemID = UUID(uuidString: key) {
                result[itemID] = Date(timeIntervalSince1970: time)
            }
        }
        return result
    }

    private func liveClaims() -> [String: Double] {
        let stored = defaults.dictionary(forKey: Key.processingClaims) as? [String: Double] ?? [:]
        let cutoff = Date().timeIntervalSince1970 - Self.claimLifetime
        return stored.filter { $0.value > cutoff }
    }
}
