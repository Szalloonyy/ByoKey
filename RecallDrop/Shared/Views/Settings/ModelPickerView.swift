//
//  ModelPickerView.swift
//  RecallDrop
//
//  Searchable list of the models a provider offers, with vision, context
//  and price information, plus free entry of any model ID.
//

import SwiftUI
import RecallDropKit

struct ModelPickerView: View {
    let provider: AIProviderKind
    @Binding var selection: String

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var visionOnly = true
    @State private var customID = ""

    private var catalog: ModelCatalogStore { environment.catalog }

    private var filteredModels: [AIModelInfo] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return catalog.models(for: provider).filter { model in
            (!visionOnly || model.effectiveVisionSupport)
                && (query.isEmpty || model.id.lowercased().contains(query) || model.displayName.lowercased().contains(query))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Enter a model ID", text: $customID)
                            .monospaced()
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        Button("Use") {
                            if let id = customID.trimmedNonEmpty {
                                selection = id
                                dismiss()
                            }
                        }
                        .disabled(customID.trimmedNonEmpty == nil)
                    }
                    Toggle("Vision-Capable Models Only", isOn: $visionOnly)
                } footer: {
                    Text("Current: \(selection.isEmpty ? "default model" : selection)")
                }

                switch catalog.state(for: provider) {
                case .loading:
                    HStack {
                        ProgressView()
                        Text("Loading models…")
                            .foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Button("Try Again") { Task { await refresh() } }
                    }
                case .idle, .loaded:
                    EmptyView()
                }

                Section("\(filteredModels.count) Models") {
                    ForEach(filteredModels) { model in
                        Button {
                            selection = model.id
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(model.displayName)
                                        .foregroundStyle(.primary)
                                    if model.displayName != model.id {
                                        Text(model.id)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    ModelInfoBadges(model: model)
                                }
                                Spacer()
                                if model.id == selection {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search models")
            .navigationTitle("\(provider.displayName) Models")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(catalog.state(for: provider) == .loading)
                }
            }
            .task {
                if catalog.needsRefresh(provider) { await refresh() }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }

    private func refresh() async {
        await catalog.refresh(provider, settings: environment.settings)
    }
}
