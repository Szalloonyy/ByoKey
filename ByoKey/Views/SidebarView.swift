//
//  SidebarView.swift
//  ByoKey
//
//  Seitenleiste mit Projekten, Chat-Verlauf und Budget-Anzeige.
//  Auf dem iPhone einklappbar, auf dem iPad dauerhaft sichtbar.
//

import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var app
    @Binding var showSettings: Bool

    @State private var search = ""
    @State private var visibleConversations: [Conversation] = []
    @State private var editingProject: AIProject?
    @State private var isCreatingProject = false
    @State private var renameTarget: Conversation?
    @State private var renameText = ""
    /// Das Projekt, dessen Löschung bestätigt werden soll.
    @State private var projectToDelete: AIProject?

    /// Auslöser für die Neuberechnung. Enthält bewusst KEINEN
    /// Nachrichtentext: sonst würde jeder gestreamte Token eine Volltextsuche
    /// über alle Chats auslösen.
    private struct FilterKey: Equatable {
        var query: String
        var projectID: UUID?
        var ids: [UUID]
        var titles: [String]
        /// Ohne diesen Wert bliebe ein per „In Projekt verschieben"
        /// umgehängter Chat in der alten Liste stehen: `move(…)` ändert nur
        /// `projectID` und fasst `updatedAt` nicht an.
        var projectIDs: [UUID?]
        /// Ändert sich einmal pro abgeschlossener Antwort, nicht pro Token –
        /// ohne diesen Wert blieben Vorschau, Kosten und Sortierung stehen.
        var stamps: [Date]
    }

    /// Die Zeilen der Liste.
    ///
    /// Beim allerersten Bildaufbau ist `visibleConversations` noch leer –
    /// `.task` läuft erst danach. Auf dem iPhone entscheidet der
    /// zusammengeklappte `NavigationSplitView` aber genau in diesem ersten
    /// Durchlauf, ob er zur wiederhergestellten Auswahl durchschiebt. Ohne
    /// diesen Rückfall fände er keine Zeile mit passendem `tag` und bliebe in
    /// der Übersicht stehen – die gespeicherte Auswahl wäre wirkungslos.
    ///
    /// Der Rückfall liefert genau das, was `.task` gleich darauf setzt; es ist
    /// also kein zweiter Datenweg, nur ein früherer.
    private var rows: [Conversation] {
        if visibleConversations.isEmpty, search.isEmpty {
            return app.conversationList(inProject: app.selectedProjectID)
        }
        return visibleConversations
    }

    private var filterKey: FilterKey {
        FilterKey(query: search.trimmingCharacters(in: .whitespacesAndNewlines),
                  projectID: app.selectedProjectID,
                  ids: app.conversations.map(\.id),
                  titles: app.conversations.map(\.title),
                  projectIDs: app.conversations.map(\.projectID),
                  stamps: app.conversations.map(\.updatedAt))
    }

    var body: some View {
        // Die Auswahl läuft **nicht** direkt auf `app.selectedConversationID`,
        // sondern über `selectConversation`. Nur so bekommt der Zustand mit,
        // dass ein Chat verlassen wurde – und kann einen leeren, unbenannten
        // Entwurf dabei wieder abräumen. Auch das Zurück auf dem iPhone
        // schreibt hier durch (mit `nil`).
        List(selection: selectionBinding) {

            Section {
                Button {
                    app.newConversation(inProject: app.selectedProjectID)
                } label: {
                    Label("Neuer Chat", systemImage: "square.and.pencil")
                        .font(.subheadline.weight(.medium))
                        // Ohne diese beiden Zeilen ist nur der Text tippbar,
                        // nicht die ganze Zeile.
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)

                // Steht bewusst hier und nicht mehr nur im Menü oben rechts:
                // ein Projekt anzulegen ist ein Einstieg wie „Neuer Chat“,
                // keine Nebeneinstellung.
                Button {
                    isCreatingProject = true
                } label: {
                    Label("Neues Projekt", systemImage: "folder.badge.plus")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            } footer: {
                Text("Ein Projekt bündelt Chats und gibt ihnen einen festen System-Prompt und ein Standardmodell.")
            }

            projectSection

            Section("Chats") {
                if rows.isEmpty {
                    Text(search.isEmpty ? "Noch keine Chats" : "Keine Treffer")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(rows) { conversation in
                        ConversationRow(conversation: conversation)
                            .tag(conversation.id)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    app.deleteConversation(conversation.id)
                                } label: {
                                    Label("Löschen", systemImage: "trash")
                                }
                                Button {
                                    renameText = renameSeed(for: conversation)
                                    renameTarget = conversation
                                } label: {
                                    Label("Umbenennen", systemImage: "pencil")
                                }
                                .tint(Theme.accent)
                            }
                            .contextMenu {
                                moveMenu(for: conversation)
                                Button {
                                    renameText = renameSeed(for: conversation)
                                    renameTarget = conversation
                                } label: {
                                    Label("Umbenennen", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    app.deleteConversation(conversation.id)
                                } label: {
                                    Label("Löschen", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $search, placement: .automatic, prompt: "Chats durchsuchen")
        .task(id: filterKey) {
            let key = filterKey
            guard !key.query.isEmpty else {
                visibleConversations = app.conversationList(inProject: key.projectID)
                return
            }
            // Entprellen: die Volltextsuche läuft über jede Nachricht.
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            visibleConversations = app.conversationList(inProject: key.projectID).filter {
                $0.title.localizedCaseInsensitiveContains(key.query)
                || $0.messages.contains { $0.text.localizedCaseInsensitiveContains(key.query) }
            }
        }
        .navigationTitle("ByoKey")
        .safeAreaInset(edge: .bottom) {
            footer
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // Früher ein Menü mit „Neues Projekt“ und „Einstellungen“.
                // Das Anlegen steht jetzt oben in der Liste; für den einen
                // verbliebenen Eintrag lohnt kein Menü.
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Einstellungen")
            }
        }
        // Nachfragen, bevor ein Projekt verschwindet.
        //
        // Die Chats überleben – sie rutschen nur aus dem Projekt heraus.
        // Weg sind Name, Farbe, Standardmodell und vor allem der
        // System-Prompt, und der ist oft die eigentliche Arbeit an einem
        // Projekt. Ein Tipp im Kontextmenü genügte dafür bisher, ohne
        // Rückweg – während „Alle Daten löschen" ausdrücklich nachfragt.
        .confirmationDialog("Projekt löschen?",
                            isPresented: projectDeleteBinding,
                            titleVisibility: .visible,
                            presenting: projectToDelete) { project in
            Button("Löschen", role: .destructive) {
                app.deleteProject(project.id)
                projectToDelete = nil
            }
            Button("Abbrechen", role: .cancel) { projectToDelete = nil }
        } message: { project in
            Text(verbatim: Loc.tr("„%@“ wird mit System-Prompt, Farbe und Standardmodell gelöscht. Die Chats dieses Projekts bleiben erhalten und stehen danach ohne Projekt.",
                                  project.name))
        }
        .sheet(item: $editingProject) { project in
            ProjectEditorView(project: project)
        }
        .sheet(isPresented: $isCreatingProject) {
            ProjectEditorView(project: nil)
        }
        .alert("Chat umbenennen", isPresented: renameBinding) {
            TextField("Titel", text: $renameText)
            Button("Sichern") {
                if let target = renameTarget {
                    app.renameConversation(target.id, to: renameText)
                }
                renameTarget = nil
            }
            Button("Abbrechen", role: .cancel) { renameTarget = nil }
        }
    }

    // MARK: - Projekte

    private var projectSection: some View {
        Section("Projekte") {
            Button {
                app.selectedProjectID = nil
            } label: {
                HStack {
                    Label("Alle Chats", systemImage: "tray.full")
                        .font(.subheadline)
                    Spacer()
                    if app.selectedProjectID == nil {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ForEach(app.projects) { project in
                Button {
                    app.selectedProjectID = project.id
                } label: {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Color(hex: project.accentHex))
                            .frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(project.name)
                                .font(.subheadline)
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            Text("\(CostFormat.usd(app.costUSD(forProject: project.id))) · \(CostFormat.tokens(app.tokens(forProject: project.id))) Tokens")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        if app.selectedProjectID == project.id {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button {
                        editingProject = project
                    } label: {
                        Label("Bearbeiten", systemImage: "slider.horizontal.3")
                    }
                    Button(role: .destructive) {
                        projectToDelete = project
                    } label: {
                        Label("Projekt löschen", systemImage: "trash")
                    }
                }
            }
        }
    }

    private var projectDeleteBinding: Binding<Bool> {
        Binding(get: { projectToDelete != nil },
                set: { if !$0 { projectToDelete = nil } })
    }

    @ViewBuilder
    private func moveMenu(for conversation: Conversation) -> some View {
        Menu {
            Button("Ohne Projekt") {
                app.move(conversationID: conversation.id, toProject: nil)
            }
            ForEach(app.projects) { project in
                Button(project.name) {
                    app.move(conversationID: conversation.id, toProject: project.id)
                }
            }
        } label: {
            Label("In Projekt verschieben", systemImage: "folder")
        }
    }

    // MARK: - Fuß

    private var footer: some View {
        VStack(spacing: 10) {
            BudgetBar(spentUSD: app.monthCostUSD, budgetUSD: app.settings.monthlyBudgetUSD)

            Button {
                showSettings = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: app.isReadyToSend ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(app.isReadyToSend ? Theme.success : Theme.warning)
                    // Als Ternär bekäme der ganze Ausdruck den Typ `String`
                    // und „Einrichtung nötig" bliebe unübersetzt.
                    Group {
                        if app.isReadyToSend {
                            Text(verbatim: app.activeProvider.displayName)
                        } else {
                            Text("Einrichtung nötig")
                        }
                    }
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Image(systemName: "gearshape")
                        .foregroundStyle(Theme.textSecondary)
                }
                .font(.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .card(tint: Theme.surface)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .background(.bar)
    }

    /// Vorbelegung des Umbenennen-Feldes.
    ///
    /// Beim Vorgabetitel bleibt das Feld leer. Zum einen steht in der
    /// englischen Oberfläche sonst „Neuer Chat“ im Feld, während die Zeile
    /// darüber „New chat“ zeigt – der Titel liegt als deutscher Text im
    /// Datenmodell und wird nur bei der Anzeige nachgeschlagen. Zum anderen
    /// soll ein unverändert bestätigter Vorgabetitel den leeren Chat nicht
    /// dauerhaft festnageln; ein leeres Feld weist `renameConversation`
    /// ohnehin ab.
    private func renameSeed(for conversation: Conversation) -> String {
        conversation.title == Conversation.untitled ? "" : conversation.title
    }

    private var selectionBinding: Binding<UUID?> {
        Binding(
            get: { app.selectedConversationID },
            set: { app.selectConversation($0) }
        )
    }

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )
    }
}

// MARK: - Zeile

private struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // `Text(String)` schlägt nichts nach. Der Vorgabetitel steht als
            // deutscher Text im Datenmodell – ohne diese Weiche stünde in der
            // englischen Oberfläche eine Zeile „Neuer Chat“ direkt unter dem
            // Knopf „New chat“.
            Group {
                if conversation.title == Conversation.untitled {
                    Text("Neuer Chat")
                } else {
                    Text(verbatim: conversation.title)
                }
            }
                .font(.subheadline)
                .lineLimit(1)
                .foregroundStyle(Theme.textPrimary)
            HStack(spacing: 6) {
                Group {
                    if let preview = conversation.preview {
                        Text(verbatim: preview)
                    } else {
                        Text("Noch keine Nachrichten")
                    }
                }
                    .lineLimit(1)
                if conversation.totalCostUSD > 0 {
                    Text("·")
                    Text(CostFormat.usd(conversation.totalCostUSD))
                        .monospacedDigit()
                }
            }
            .font(.caption2)
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, 2)
    }
}
