//
//  AgencyGalleryView.swift
//  RecallDrop
//
//  Browse persona files from a GitHub repository – by default
//  msitarzewski/agency-agents – and add them as RecallDrop agents.
//

import SwiftUI
import RecallDropKit

struct AgencyGalleryView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var repository = "\(AgencyAgentsCatalog.defaultOwner)/\(AgencyAgentsCatalog.defaultRepository)"
    @State private var branch = AgencyAgentsCatalog.defaultBranch
    @State private var entries: [AgencyAgentEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var previewEntry: AgencyAgentEntry?

    private var catalog: AgencyAgentsCatalog? {
        let parts = repository.split(separator: "/").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return AgencyAgentsCatalog(owner: parts[0], repository: parts[1], branch: branch.trimmedNonEmpty ?? "main")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("owner/repository", text: $repository)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        TextField("branch", text: $branch)
                            .frame(maxWidth: 90)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        Button("Load") { Task { await load() } }
                            .disabled(catalog == nil || isLoading)
                    }
                } footer: {
                    if let catalog {
                        Link("Open \(catalog.owner)/\(catalog.repository) on GitHub", destination: catalog.repositoryURL)
                            .font(.caption)
                    }
                }

                if isLoading {
                    HStack {
                        ProgressView()
                        Text("Loading agents…")
                            .foregroundStyle(.secondary)
                    }
                } else if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }

                ForEach(groupedEntries, id: \.category) { group in
                    Section(group.category) {
                        ForEach(group.entries) { entry in
                            Button {
                                previewEntry = entry
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.name)
                                            .foregroundStyle(.primary)
                                        Text(entry.path)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search agents")
            .navigationTitle("Agent Gallery")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
            .sheet(item: $previewEntry) { entry in
                if let catalog {
                    AgencyAgentPreview(entry: entry, catalog: catalog)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 600)
        #endif
    }

    private var groupedEntries: [(category: String, entries: [AgencyAgentEntry])] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = query.isEmpty ? entries : entries.filter {
            $0.name.lowercased().contains(query) || $0.category.lowercased().contains(query)
        }
        let grouped = Dictionary(grouping: filtered, by: \.category)
        return grouped.keys.sorted().map { ($0, grouped[$0] ?? []) }
    }

    private func load() async {
        guard let catalog else {
            errorMessage = "Enter the repository as owner/name."
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            entries = try await catalog.fetchEntries()
            if entries.isEmpty { errorMessage = "No persona files were found in this repository." }
        } catch {
            entries = []
            errorMessage = error.localizedDescription
        }
    }
}

private struct AgencyAgentPreview: View {
    let entry: AgencyAgentEntry
    let catalog: AgencyAgentsCatalog

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var markdown: String?
    @State private var persona: AgentPersona?
    @State private var errorMessage: String?
    @State private var didImport = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let persona {
                        HStack(spacing: 14) {
                            Text(persona.emoji)
                                .font(.largeTitle)
                                .frame(width: 60, height: 60)
                                .background(persona.color.color.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(persona.displayName)
                                    .font(.title3.weight(.bold))
                                Text(entry.category)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if !persona.roleDescription.isEmpty {
                            Text(persona.roleDescription)
                                .font(.callout)
                        }
                        Text(persona.systemPrompt)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.placeholderFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } else {
                        ProgressView("Loading \(entry.name)…")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                }
                .padding()
            }
            .navigationTitle(entry.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(didImport ? "Added" : "Add Agent") { addAgent() }
                        .disabled(markdown == nil || didImport)
                }
            }
            .task { await load() }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }

    private func load() async {
        do {
            let text = try await catalog.fetchMarkdown(for: entry)
            markdown = text
            persona = try PersonaMarkdownCodec.decode(text, fallbackName: entry.name)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addAgent() {
        guard let markdown else { return }
        do {
            let agent = try environment.agents.importMarkdown(markdown, fallbackName: entry.name, source: entry.webURL.absoluteString)
            didImport = true
            environment.router.showToast("Added “\(agent.displayName)” to your agents")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
