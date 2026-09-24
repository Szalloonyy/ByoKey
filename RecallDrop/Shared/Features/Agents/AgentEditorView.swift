//
//  AgentEditorView.swift
//  RecallDrop
//
//  Edit one agent: identity, model override, temperature and the system
//  prompt. Changes are saved when leaving the editor (or with Save).
//

import SwiftUI
import SwiftData
import RecallDropKit

struct AgentEditorView: View {
    let agentID: UUID
    @Query private var matches: [AgentConfig]

    init(agentID: UUID) {
        self.agentID = agentID
        _matches = Query(filter: #Predicate<AgentConfig> { $0.id == agentID })
    }

    var body: some View {
        if let agent = matches.first {
            AgentEditorForm(agent: agent)
                .id(agent.id)
        } else {
            ContentUnavailableView("Agent Not Found", systemImage: "person.crop.circle.badge.questionmark",
                                   description: Text("It may have been deleted."))
        }
    }
}

private struct AgentEditorForm: View {
    let agent: AgentConfig

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AgentPersona
    @State private var isModelPickerPresented = false
    @State private var isExporterPresented = false
    @State private var isDeleteConfirmationPresented = false
    @State private var isResetConfirmationPresented = false
    @State private var exportURL: URL?

    init(agent: AgentConfig) {
        self.agent = agent
        _draft = State(initialValue: agent.persona)
    }

    private var hasChanges: Bool { draft != agent.persona }

    var body: some View {
        Form {
            identitySection
            modelSection
            temperatureSection
            promptSection
            actionsSection
        }
        .formStyle(.grouped)
        .navigationTitle(draft.displayName)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(!hasChanges)
            }
            if hasChanges {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Revert") { draft = agent.persona }
                }
            }
        }
        .sheet(isPresented: $isModelPickerPresented) {
            ModelPickerView(provider: environment.settings.provider, selection: $draft.assignedModel)
        }
        .fileExporter(
            isPresented: $isExporterPresented,
            document: MarkdownFileDocument(text: PersonaMarkdownCodec.encode(draft)),
            contentType: .plainText,
            defaultFilename: PersonaMarkdownCodec.fileName(for: draft)
        ) { _ in }
        .confirmationDialog("Delete “\(agent.displayName)”?", isPresented: $isDeleteConfirmationPresented, titleVisibility: .visible) {
            Button("Delete Agent", role: .destructive) {
                environment.agents.delete(agent)
                dismiss()
            }
        } message: {
            Text("Results this agent produced stay with your captures.")
        }
        .confirmationDialog("Reset to the original prompt and settings?", isPresented: $isResetConfirmationPresented,
                            titleVisibility: .visible) {
            Button("Reset", role: .destructive) {
                agent.resetToBuiltIn()
                draft = agent.persona
            }
        }
        .task(id: draft) {
            let markdown = PersonaMarkdownCodec.encode(draft)
            let fileName = PersonaMarkdownCodec.fileName(for: draft)
            exportURL = ShareableFiles.markdownFile(named: fileName, contents: markdown)
        }
        .onDisappear {
            if hasChanges { save() }
        }
    }

    // MARK: Sections

    private var identitySection: some View {
        Section("Identity") {
            HStack(spacing: 12) {
                Menu {
                    ForEach(AgentPersona.suggestedEmoji, id: \.self) { emoji in
                        Button(emoji) { draft.emoji = emoji }
                    }
                } label: {
                    Text(draft.emoji.isEmpty ? "🤖" : draft.emoji)
                        .font(.largeTitle)
                        .frame(width: 56, height: 56)
                        .background(draft.color.color.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .accessibilityLabel("Choose emoji")

                VStack(alignment: .leading, spacing: 6) {
                    TextField("Name", text: $draft.name)
                        .font(.headline)
                    TextField("Emoji", text: $draft.emoji)
                        .font(.caption)
                        .onChange(of: draft.emoji) { _, newValue in
                            if newValue.count > 2 { draft.emoji = String(newValue.prefix(2)) }
                        }
                }
            }

            TextField("What is this agent good at?", text: $draft.roleDescription, axis: .vertical)
                .lineLimit(2...4)

            VStack(alignment: .leading, spacing: 8) {
                Text("Color")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(AgentColor.allCases) { color in
                            Button {
                                draft.colorName = color.rawValue
                            } label: {
                                Circle()
                                    .fill(color.color)
                                    .frame(width: 26, height: 26)
                                    .overlay {
                                        if draft.color == color {
                                            Image(systemName: "checkmark")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(color.displayName)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var modelSection: some View {
        let settings = environment.settings
        return Section {
            Toggle("Use Default Model", isOn: Binding(
                get: { draft.usesDefaultModel },
                set: { useDefault in
                    draft.assignedModel = useDefault ? "" : settings.activeDefaultModel
                }
            ))
            if draft.usesDefaultModel {
                LabeledContent("Default", value: settings.activeDefaultModel)
            } else {
                HStack {
                    TextField("Model ID", text: $draft.assignedModel)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    Button("Browse…") { isModelPickerPresented = true }
                }
            }
        } header: {
            Text("Model")
        } footer: {
            Text("Model IDs refer to the active provider (\(settings.provider.displayName)). If you switch providers, agents with an override may need a new model.")
        }
    }

    private var temperatureSection: some View {
        Section {
            Slider(value: $draft.temperature, in: 0...2, step: 0.05) {
                Text("Temperature")
            } minimumValueLabel: {
                Text("0")
            } maximumValueLabel: {
                Text("2")
            }
        } header: {
            HStack {
                Text("Temperature")
                Spacer()
                Text(draft.temperature, format: .number.precision(.fractionLength(2)))
                    .monospacedDigit()
            }
        } footer: {
            Text(temperatureHint)
        }
    }

    private var temperatureHint: String {
        switch draft.temperature {
        case ..<0.35: "Focused and consistent – good for extracting facts and tasks."
        case ..<0.9: "Balanced – precise but with some variety."
        default: "Creative – more varied ideas, less predictable. Anthropic caps at 1.0; some newer models use a fixed value."
        }
    }

    private var promptSection: some View {
        Section {
            TextEditor(text: $draft.systemPrompt)
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 300)
            DisclosureGroup("Output contract added at run time") {
                Text(AgentPromptBuilder.outputContract(environment: PromptEnvironment(responseLanguage: environment.settings.responseLanguage)))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } header: {
            Text("System Prompt")
        } footer: {
            Text("Describe the role, how to analyze a capture and how to fill title, summary, steps and tags. RecallDrop appends its JSON output contract automatically, so personas from agency-agents work unchanged.")
        }
    }

    private var actionsSection: some View {
        Section {
            if agent.isDefault {
                Label("This is the default agent for new captures", systemImage: "star.fill")
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    save()
                    environment.agents.setDefault(agent)
                } label: {
                    Label("Make Default Agent", systemImage: "star")
                }
            }
            if let exportURL {
                ShareLink(item: exportURL) {
                    Label("Share as Markdown", systemImage: "square.and.arrow.up")
                }
            }
            Button {
                isExporterPresented = true
            } label: {
                Label("Export Markdown File…", systemImage: "doc.badge.arrow.up")
            }
            Button {
                save()
                _ = environment.agents.duplicate(agent)
                environment.router.showToast("Duplicated “\(agent.displayName)”")
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            if agent.isBuiltIn {
                Button {
                    isResetConfirmationPresented = true
                } label: {
                    Label("Reset to Original", systemImage: "arrow.counterclockwise")
                }
            } else {
                Button(role: .destructive) {
                    isDeleteConfirmationPresented = true
                } label: {
                    Label("Delete Agent", systemImage: "trash")
                }
            }
        } header: {
            Text("Actions")
        } footer: {
            if let source = agent.importSource {
                Text("Imported from \(source)")
            }
        }
    }

    private func save() {
        guard hasChanges else { return }
        agent.apply(draft)
        try? agent.modelContext?.save()
    }
}
