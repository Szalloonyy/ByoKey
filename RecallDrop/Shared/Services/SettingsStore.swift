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

        static let all = [
            provider, baseURLs, defaultModels, maxOutputTokens, offlineOnly, autoAnalyze, sendImages,
            useJSONMode, requestTimeout, responseLanguage, ocrAccuracy, ocrLanguageCorrection,
            fetchLinkPreviews, morningHour, eveningHour, weekendHour, gridDensity, showDropShelfAtLaunch,
            hideDockIcon, hotKeys, hasCompletedOnboarding, lastExternalChange
        ]
    }

    @ObservationIgnored private let defaults: UserDefaults

    // MARK: AI provider

    var provider: AIProviderKind {
        didSet { defaults.set(provider.rawValue, forKey: Key.provider) }
    }

    /// Per-provider base URL overrides (raw value → URL string).
    private(set) var baseURLOverrides: [String: String] {
        didSet { defaults.set(baseURLOverrides, forKey: Key.baseURLs) }
    }

    /// Per-provider default model (raw value → model ID).
    private(set) var defaultModels: [String: String] {
        didSet { defaults.set(defaultModels, forKey: Key.defaultModels) }
    }

    private(set) var maxOutputTokenOverrides: [String: Int] {
        didSet { defaults.set(maxOutputTokenOverrides, forKey: Key.maxOutputTokens) }
    }

    /// Only on-device OCR and analysis; no request reaches an AI provider.
    var offlineOnly: Bool {
        didSet { defaults.set(offlineOnly, forKey: Key.offlineOnly) }
    }

    /// Run the default agent on every new capture.
    var autoAnalyze: Bool {
        didSet { defaults.set(autoAnalyze, forKey: Key.autoAnalyze) }
    }

    /// Attach the image itself (not just the OCR text) to agent requests.
    var sendImages: Bool {
        didSet { defaults.set(sendImages, forKey: Key.sendImages) }
    }

    var useJSONMode: Bool {
        didSet { defaults.set(useJSONMode, forKey: Key.useJSONMode) }
    }

    var requestTimeout: Double {
        didSet { defaults.set(requestTimeout, forKey: Key.requestTimeout) }
    }

    var responseLanguage: PromptEnvironment.ResponseLanguage {
        didSet { defaults.set(responseLanguage.rawValue, forKey: Key.responseLanguage) }
    }

    // MARK: Capture

    var ocrAccuracy: OCRAccuracy {
        didSet { defaults.set(ocrAccuracy.rawValue, forKey: Key.ocrAccuracy) }
    }

    var ocrLanguageCorrection: Bool {
        didSet { defaults.set(ocrLanguageCorrection, forKey: Key.ocrLanguageCorrection) }
    }

    var fetchLinkPreviews: Bool {
        didSet { defaults.set(fetchLinkPreviews, forKey: Key.fetchLinkPreviews) }
    }

    // MARK: Reminders

    var morningHour: Int {
        didSet { defaults.set(morningHour, forKey: Key.morningHour) }
    }

    var eveningHour: Int {
        didSet { defaults.set(eveningHour, forKey: Key.eveningHour) }
    }

    var weekendHour: Int {
        didSet { defaults.set(weekendHour, forKey: Key.weekendHour) }
    }

    var reminderSchedule: ReminderSchedule {
        ReminderSchedule(morningHour: morningHour, eveningHour: eveningHour, weekendHour: weekendHour)
    }

    // MARK: Interface

    var gridDensity: GridDensity {
        didSet { defaults.set(gridDensity.rawValue, forKey: Key.gridDensity) }
    }

    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) }
    }

    // MARK: macOS

    var showDropShelfAtLaunch: Bool {
        didSet { defaults.set(showDropShelfAtLaunch, forKey: Key.showDropShelfAtLaunch) }
    }

    var hideDockIcon: Bool {
        didSet { defaults.set(hideDockIcon, forKey: Key.hideDockIcon) }
    }

    /// Global shortcuts as JSON (see HotKeyCenter on macOS).
    var hotKeysData: Data? {
        didSet { defaults.set(hotKeysData, forKey: Key.hotKeys) }
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

    /// Removes every stored preference; takes effect on the next launch.
    func resetAll() {
        for key in Key.all {
            defaults.removeObject(forKey: key)
        }
    }
}
