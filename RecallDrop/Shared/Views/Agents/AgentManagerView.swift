//
//  AgentManagerView.swift
//  RecallDrop
//
//  View, create, import and export agent personas. Built-in agents can be
//  edited and reset; custom agents can also be deleted.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import RecallDropKit

struct AgentEditorRoute: Hashable {
    let agentID: UUID
}

/// Navigation stack for the Agents section.
struct AgentsStack: View {
    @State private var path: [AgentEditorRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            AgentManagerView(path: $path)
                .navigationDestination(for: AgentEditorRoute.self) { route in
                    AgentEditorView(agentID: route.agentID)
                }
        }
    }
}

struct AgentManagerView: View {
    @Binding var path: [AgentEditorRoute]

    @Environment(AppEnvironment.self) private var environment
    @Query(sort: [SortDescriptor(\AgentConfig.sortOrder), SortDescriptor(\AgentConfig.createdAt)])
    private var agents: [AgentConfig]

    @State private var isFileImporterPresented = false
    @State private var importMode: AgentImportSheet.Mode?
    @State private var isGalleryPresented = false
    @State private var importError: String?

    var body: some View {
        let builtIns = agents.filter(\.isBuiltIn)
        let custom = agents.filter { !$0.isBuiltIn }

        List {
            Section {
                Text("Agents are specialized personas that analyze your captures. Each one has its own prompt, model and temperature. Import more from the agency-agents collection or write your own.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Built-in") {
                ForEach(builtIns) { agent in
                    NavigationLink(value: AgentEditorRoute(agentID: agent.id)) {
                        AgentRow(agent: agent)
                    }
                }
                .onMove { source, destination in
                    environment.agents.move(builtIns, from: source, to: destination)
                }
            }

            Section("Your Agents") {
                if custom.isEmpty {
                    Text("Create an agent or import one to see it here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(custom) { agent in
                    NavigationLink(value: AgentEditorRoute(agentID: agent.id)) {
                        AgentRow(agent: agent)
                    }
                    .contextMenu {
                        Button {
                            let copy = environment.agents.duplicate(agent)
                            path.append(AgentEditorRoute(agentID: copy.id))
                        } label: {
                            Label("Duplicate", systemImage: "plus.square.on.square")
                        }
                        Button(role: .destructive) {
                            environment.agents.delete(agent)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets { environment.agents.delete(custom[index]) }
                }
                .onMove { source, destination in
                    environment.agents.move(custom, from: source, to: destination)
                }
            }
        }
        .navigationTitle("Agents")
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                EditButton()
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        let agent = environment.agents.createBlank()
                        path.append(AgentEditorRoute(agentID: agent.id))
                    } label: {
                        Label("New Agent", systemImage: "plus")
                    }
                    Divider()
                    Button {
                        isGalleryPresented = true
                    } label: {
                        Label("Browse agency-agents…", systemImage: "square.grid.2x2")
                    }
                    Button {
                        isFileImporterPresented = true
                    } label: {
                        Label("Import Markdown File…", systemImage: "doc.badge.plus")
                    }
                    Button {
                        importMode = .url
                    } label: {
                        Label("Import from URL…", systemImage: "link.badge.plus")
                    }
                    Button {
                        importMode = .paste
                    } label: {
                        Label("Paste Markdown…", systemImage: "doc.on.clipboard")
                    }
                } label: {
                    Label("Add Agent", systemImage: "plus")
                }
            }
        }
        .fileImporter(isPresented: $isFileImporterPresented, allowedContentTypes: [.text], allowsMultipleSelection: true) { result in
            importFiles(result)
        }
        .sheet(isPresented: $isGalleryPresented) {
            AgencyGalleryView()
        }
        .sheet(item: $importMode) { mode in
            AgentImportSheet(mode: mode) { agent in
                path.append(AgentEditorRoute(agentID: agent.id))
            }
        }
        .alert("Import Failed", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    private func importFiles(_ result: Result<[URL], any Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let urls):
            var failures: [String] = []
            var lastImported: AgentConfig?
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let markdown = try String(contentsOf: url, encoding: .utf8)
                    lastImported = try environment.agents.importMarkdown(markdown, fallbackName: url.lastPathComponent,
                                                                          source: url.lastPathComponent)
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if !failures.isEmpty {
                importError = failures.joined(separator: "\n")
            } else if urls.count == 1, let lastImported {
                path.append(AgentEditorRoute(agentID: lastImported.id))
            }
        }
    }
}

// MARK: - Import sheet

struct AgentImportSheet: View {
    enum Mode: String, Identifiable {
        case paste
        case url

        var id: String { rawValue }
    }

    let mode: Mode
    let onImported: (AgentConfig) -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var markdown = ""
    @State private var urlString = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                switch mode {
                case .paste:
                    Section {
                        TextEditor(text: $markdown)
                            .font(.system(.callout, design: .monospaced))
                            .frame(minHeight: 260)
                    } header: {
                        Text("Persona Markdown")
                    } footer: {
                        Text("Paste a persona file with optional YAML front matter (name, description, color, model, temperature).")
                    }
                case .url:
                    Section {
                        TextField("https://github.com/…/agent.md", text: $urlString)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            #endif
                    } header: {
                        Text("File URL")
                    } footer: {
                        Text("GitHub file links are converted to raw downloads automatically, e.g. a persona from github.com/msitarzewski/agency-agents.")
                    }
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(mode == .paste ? "Paste Agent" : "Import from URL")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView()
                    } else {
                        Button("Import") { Task { await importAgent() } }
                            .disabled(mode == .paste ? markdown.trimmedNonEmpty == nil : urlString.trimmedNonEmpty == nil)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 440)
        #endif
    }

    private func importAgent() async {
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let agent: AgentConfig
            switch mode {
            case .paste:
                agent = try environment.agents.importMarkdown(markdown, source: "Pasted")
            case .url:
                guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
                      let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
                    errorMessage = "Enter a valid web address."
                    return
                }
                agent = try await environment.agents.importMarkdown(from: url)
            }
            onImported(agent)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Markdown file for `.fileExporter`.
struct MarkdownFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
