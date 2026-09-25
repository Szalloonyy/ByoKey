//
//  AISettingsView.swift
//  RecallDrop
//
//  Bring-your-own-key setup: provider, API key (Keychain), server address,
//  default model, connection test and request options – plus the
//  "Offline Only" switch that keeps every capture on the device.
//

import SwiftUI
import RecallDropKit

struct AISettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var apiKeyInput = ""
    @State private var storedKeyMask: String?
    @State private var keyMessage: String?
    @State private var baseURLInput = ""
    @State private var baseURLError: String?
    @State private var testResult: ConnectionTestResult?
    @State private var isTesting = false
    @State private var isModelPickerPresented = false
    /// The model field is edited locally and stored on Return or when it loses
    /// focus; an empty field means the provider's default.
    @State private var modelInput = ""
    @FocusState private var isModelFieldFocused: Bool

    var body: some View {
        @Bindable var settings = environment.settings
        let provider = settings.provider

        Form {
            Section {
                Toggle(isOn: $settings.offlineOnly) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Offline Only", systemImage: "lock.shield")
                        Text("Use only Apple's on-device text recognition and analysis. Nothing is sent to an AI provider.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Group {
                Section {
                    Picker("Provider", selection: $settings.provider) {
                        ForEach(AIProviderKind.allCases) { kind in
                            Label(kind.displayName, systemImage: kind.symbolName).tag(kind)
                        }
                    }
                    Text(provider.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Provider")
                }

                apiKeySection(provider)
                serverSection(provider)
                modelSection(provider)
                testSection(provider)
                advancedSection(provider)
            }
            .disabled(settings.offlineOnly)
        }
        .formStyle(.grouped)
        .navigationTitle("AI Provider")
        .onAppear { loadFields(for: provider) }
        .onChange(of: settings.activeDefaultModel) { _, model in
            // e.g. picked in the model browser
            if !isModelFieldFocused { modelInput = model }
        }
        .onChange(of: settings.provider) { _, newProvider in
            loadFields(for: newProvider)
            testResult = nil
            environment.pipeline.resumePendingWork()
        }
        .onChange(of: settings.offlineOnly) {
            // Captures waiting for AI start once it is available again.
            environment.pipeline.resumePendingWork()
        }
        .sheet(isPresented: $isModelPickerPresented) {
            ModelPickerView(provider: provider, selection: defaultModelBinding(provider))
        }
    }

    // MARK: Sections

    private func apiKeySection(_ provider: AIProviderKind) -> some View {
        Section {
            if let storedKeyMask {
                LabeledContent("Stored Key") {
                    Text(storedKeyMask)
                        .monospaced()
                        .foregroundStyle(.secondary)
                }
            }
            SecureField(provider.apiKeyPlaceholder, text: $apiKeyInput)
                .textContentType(.password)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit { saveKey(for: provider) }
            HStack {
                Button(storedKeyMask == nil ? "Save Key" : "Replace Key") {
                    saveKey(for: provider)
                }
                .disabled(apiKeyInput.trimmedNonEmpty == nil)
                if storedKeyMask != nil {
                    Spacer()
                    Button("Remove Key", role: .destructive) {
                        KeychainStore.removeAPIKey(for: provider)
                        environment.settings.noteAPIKeyChange()
                        storedKeyMask = nil
                        keyMessage = "Key removed from the Keychain."
                    }
                }
            }
            .buttonStyle(.borderless)
            if let keyMessage {
                Text(keyMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(provider.requiresAPIKey ? "API Key" : "API Key (Optional)")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Keys are stored in the Keychain on this device and sent only to \(provider.displayName).")
                if let url = provider.apiKeyURL {
                    Link("Get a \(provider.displayName) key", destination: url)
                }
            }
        }
    }

    private func serverSection(_ provider: AIProviderKind) -> some View {
        let settings = environment.settings
        return Section {
            TextField("Base URL", text: $baseURLInput)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .onSubmit { applyBaseURL(for: provider) }
            HStack {
                Button("Apply") { applyBaseURL(for: provider) }
                    .disabled(baseURLInput.trimmedNonEmpty == nil)
                if settings.hasCustomBaseURL(for: provider) {
                    Spacer()
                    Button("Reset to Default") {
                        settings.setBaseURL(nil, for: provider)
                        baseURLInput = settings.baseURL(for: provider).absoluteString
                        baseURLError = nil
                    }
                }
            }
            .buttonStyle(.borderless)
            if let baseURLError {
                Text(baseURLError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if provider == .custom {
                ForEach(LocalServerPreset.all) { preset in
                    Button {
                        baseURLInput = preset.baseURL.absoluteString
                        applyBaseURL(for: provider)
                        if !preset.suggestedModel.isEmpty {
                            settings.setDefaultModel(preset.suggestedModel, for: .custom)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Use \(preset.name)")
                            Text(preset.note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
        } header: {
            Text("Server")
        } footer: {
            if provider == .custom {
                Text("Any OpenAI-compatible endpoint works. Plain HTTP is allowed for local servers (localhost, .local and LAN addresses).")
            } else {
                Text("Only change this to use a compatible proxy or gateway.")
            }
        }
    }

    private func modelSection(_ provider: AIProviderKind) -> some View {
        let settings = environment.settings
        let catalog = environment.catalog
        let model = settings.defaultModel(for: provider)
        let info = catalog.info(for: model, provider: provider)

        return Section {
            TextField("Model ID", text: $modelInput, prompt: Text(provider.defaultModel))
                .monospaced()
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .focused($isModelFieldFocused)
                .onSubmit { commitModel(for: provider) }
                .onChange(of: isModelFieldFocused) { _, focused in
                    if !focused { commitModel(for: provider) }
                }
            Button {
                isModelPickerPresented = true
            } label: {
                Label("Browse \(provider.displayName) Models…", systemImage: "list.bullet.rectangle")
            }
            .buttonStyle(.borderless)
            if let info {
                ModelInfoBadges(model: info)
            } else if !ModelCapabilities.likelySupportsVision(model) {
                Label("This model may not read images; agents will fall back to the extracted text.", systemImage: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Default Model")
        } footer: {
            Text("Used by every agent without its own model override. Pick a vision-capable model to let agents see your screenshots.")
        }
    }

    private func testSection(_ provider: AIProviderKind) -> some View {
        Section {
            Button {
                Task { await runConnectionTest(provider) }
            } label: {
                HStack {
                    Label("Test Connection", systemImage: "bolt.horizontal.circle")
                    Spacer()
                    if isTesting { ProgressView().controlSize(.small) }
                }
            }
            .disabled(isTesting)

            if let testResult {
                VStack(alignment: .leading, spacing: 6) {
                    Label(testResult.title, systemImage: icon(for: testResult.outcome))
                        .foregroundStyle(color(for: testResult.outcome))
                        .font(.callout.weight(.semibold))
                    ForEach(testResult.details, id: \.self) { detail in
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let latency = testResult.latency {
                        Text("Round trip: \(latency, format: .number.precision(.fractionLength(1))) s")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func advancedSection(_ provider: AIProviderKind) -> some View {
        @Bindable var settings = environment.settings
        return Section {
            Toggle("Send Images to the Model", isOn: $settings.sendImages)
            Toggle("Request JSON Output (OpenAI)", isOn: $settings.useJSONMode)
            Picker("Answer Language", selection: $settings.responseLanguage) {
                ForEach(PromptEnvironment.ResponseLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            Stepper(value: maxTokensBinding(provider), in: 512...64_000, step: 512) {
                LabeledContent("Max Output Tokens", value: "\(settings.maxOutputTokens(for: provider))")
            }
            Stepper(value: $settings.requestTimeout, in: 30...600, step: 30) {
                LabeledContent("Request Timeout", value: "\(Int(settings.requestTimeout)) s")
            }
        } header: {
            Text("Advanced")
        } footer: {
            Text("When a model rejects images, a custom temperature or the output limit, RecallDrop retries automatically without it.")
        }
    }

    // MARK: Actions

    private func loadFields(for provider: AIProviderKind) {
        let key = KeychainStore.apiKey(for: provider)
        storedKeyMask = key.map(KeychainStore.masked)
        apiKeyInput = ""
        keyMessage = nil
        baseURLInput = environment.settings.baseURL(for: provider).absoluteString
        baseURLError = nil
        modelInput = environment.settings.defaultModel(for: provider)
    }

    private func commitModel(for provider: AIProviderKind) {
        environment.settings.setDefaultModel(modelInput, for: provider)
        modelInput = environment.settings.defaultModel(for: provider)
    }

    private func saveKey(for provider: AIProviderKind) {
        guard let key = apiKeyInput.trimmedNonEmpty else { return }
        if KeychainStore.setAPIKey(key, for: provider) {
            storedKeyMask = KeychainStore.masked(key)
            apiKeyInput = ""
            keyMessage = "Saved to the Keychain."
            environment.settings.noteAPIKeyChange()
            environment.pipeline.resumePendingWork()
            Task { await runConnectionTest(provider) }
        } else {
            keyMessage = "The key could not be saved to the Keychain."
        }
    }

    private func applyBaseURL(for provider: AIProviderKind) {
        if environment.settings.setBaseURL(baseURLInput, for: provider) {
            baseURLInput = environment.settings.baseURL(for: provider).absoluteString
            baseURLError = nil
        } else {
            baseURLError = "That is not a valid http(s) address."
        }
    }

    private func runConnectionTest(_ provider: AIProviderKind) async {
        isTesting = true
        defer { isTesting = false }
        let settings = environment.settings
        do {
            let client = try AIClientFactory.makeClient(configuration: settings.providerConfiguration(for: provider))
            let result = await AIConnectionTester.run(client: client, model: settings.defaultModel(for: provider))
            testResult = result
            environment.catalog.update(result.availableModels, for: provider)
        } catch {
            let aiError = AIError.from(error)
            testResult = ConnectionTestResult(outcome: .failure, title: aiError.errorDescription ?? "Failed",
                                              details: [aiError.recoverySuggestion].compactMap { $0 })
        }
    }

    // MARK: Bindings

    private func defaultModelBinding(_ provider: AIProviderKind) -> Binding<String> {
        let settings = environment.settings
        return Binding(
            get: { settings.defaultModel(for: provider) },
            set: { settings.setDefaultModel($0, for: provider) }
        )
    }

    private func maxTokensBinding(_ provider: AIProviderKind) -> Binding<Int> {
        let settings = environment.settings
        return Binding(
            get: { settings.maxOutputTokens(for: provider) },
            set: { settings.setMaxOutputTokens($0, for: provider) }
        )
    }

    private func icon(for outcome: ConnectionTestResult.Outcome) -> String {
        switch outcome {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .failure: "xmark.octagon.fill"
        }
    }

    private func color(for outcome: ConnectionTestResult.Outcome) -> Color {
        switch outcome {
        case .success: .green
        case .warning: .orange
        case .failure: .red
        }
    }
}

/// Vision, context and price badges for a model.
struct ModelInfoBadges: View {
    let model: AIModelInfo

    var body: some View {
        HStack(spacing: 8) {
            if model.effectiveVisionSupport {
                Label("Vision", systemImage: "eye")
            } else {
                Label("Text only", systemImage: "eye.slash")
            }
            if let context = model.contextLength {
                Text("\(Self.compact(context)) context")
            }
            if model.isFree {
                Text("Free")
                    .foregroundStyle(.green)
            } else if let input = model.promptPricePerMillion, let output = model.completionPricePerMillion {
                Text("$\(input, format: .number.precision(.fractionLength(0...2))) / $\(output, format: .number.precision(.fractionLength(0...2))) per 1M")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    static func compact(_ tokens: Int) -> String {
        switch tokens {
        case 1_000_000...: "\(tokens / 1_000_000)M"
        case 1000...: "\(tokens / 1000)K"
        default: "\(tokens)"
        }
    }
}
