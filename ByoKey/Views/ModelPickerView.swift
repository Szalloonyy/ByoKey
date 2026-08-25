//
//  ModelPickerView.swift
//  ByoKey
//
//  Modellauswahl mit Preisen. Die Preise kommen live vom Anbieter, damit die
//  Kostenanzeige nicht auf einer veralteten Tabelle im Binary beruht.
//

import SwiftUI

struct ModelPickerView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let selectedModelID: String?
    let onSelect: (String) -> Void

    @State private var search = ""
    @State private var onlyFree = false
    @State private var grouped: [(vendor: String, models: [AIModel])] = []

    /// Die Liste hat oft mehrere hundert Einträge. Ohne diesen Schlüssel
    /// würde bei jedem Tastendruck – und bei jeder unbeteiligten
    /// Zustandsänderung – neu gefiltert, gruppiert und sortiert.
    private struct GroupKey: Equatable {
        var query: String
        var onlyFree: Bool
        var modelIDs: [String]
    }

    private var groupKey: GroupKey {
        GroupKey(query: search.trimmingCharacters(in: .whitespacesAndNewlines),
                 onlyFree: onlyFree,
                 modelIDs: app.availableModels.map(\.id))
    }

    private static func group(_ models: [AIModel],
                              query: String,
                              onlyFree: Bool) -> [(vendor: String, models: [AIModel])] {
        var models = models
        if !query.isEmpty {
            models = models.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
            }
        }
        if onlyFree {
            models = models.filter(\.isFree)
        }
        return Dictionary(grouping: models, by: \.vendor)
            .map { (vendor: $0.key, models: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.vendor < $1.vendor }
    }

    var body: some View {
        NavigationStack {
            Group {
                if app.isLoadingModels && app.models.isEmpty {
                    ProgressView("Modelle werden geladen …")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = app.modelsError, app.models.isEmpty {
                    ContentUnavailableView {
                        Label("Modelle nicht geladen", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(LocalizedStringKey(error))
                    } actions: {
                        Button("Erneut versuchen") {
                            Task { await app.refreshModels(force: true) }
                        }
                    }
                } else {
                    list
                }
            }
            .navigationTitle("Modell wählen")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Modell suchen")
            .task(id: groupKey) {
                let key = groupKey
                if !key.query.isEmpty {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard !Task.isCancelled else { return }
                }
                grouped = Self.group(app.availableModels, query: key.query, onlyFree: key.onlyFree)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await app.refreshModels(force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Modell-Liste neu laden")
                    .disabled(app.isLoadingModels)
                }
            }
        }
    }

    private var list: some View {
        List {
            Section {
                Toggle("Nur kostenlose Modelle", isOn: $onlyFree)
                    .font(.subheadline)
            }

            ForEach(grouped, id: \.vendor) { group in
                Section(group.vendor) {
                    ForEach(group.models) { model in
                        Button {
                            onSelect(model.id)
                            dismiss()
                        } label: {
                            row(for: model)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                app.blockModel(model.id)
                            } label: {
                                Label("Sperren", systemImage: "nosign")
                            }
                        }
                    }
                }
            }

            if !app.blockedModelIDs.isEmpty {
                Section("Gesperrte Modelle") {
                    ForEach(Array(app.blockedModelIDs).sorted(), id: \.self) { id in
                        HStack {
                            Text(id)
                                .font(.footnote)
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Button("Freigeben") { app.unblockModel(id) }
                                .font(.caption.weight(.semibold))
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func row(for model: AIModel) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    if model.isImageModel {
                        Text("Bild")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Theme.accentSoft, in: Capsule())
                    }
                    if model.isFree {
                        Text("kostenlos")
                            .foregroundStyle(Theme.success)
                    } else if let note = model.priceNote {
                        // Sprach- und Bildmodelle haben keine Token-Preise.
                        // Hier stand vorher „kostenlos", was schlicht falsch war.
                        Text(LocalizedStringKey(note))
                            .foregroundStyle(Theme.warning)
                    } else {
                        priceText(perMillion: model.promptPricePerMillion)
                        Text("→")
                        priceText(perMillion: model.completionPricePerMillion)
                    }
                    if let context = CostFormat.contextTokens(model.contextLength) {
                        Text("·")
                        Text("\(context) Kontext")
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
            }

            Spacer(minLength: 4)

            if model.id == selectedModelID {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
