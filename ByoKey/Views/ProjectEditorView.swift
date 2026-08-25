//
//  ProjectEditorView.swift
//  ByoKey
//
//  Anlegen und Bearbeiten eines Projekts: Name, Farbe, System-Prompt und
//  Standardmodell. Genau diese Vorgaben gelten dann für jeden Chat im Projekt.
//

import SwiftUI

struct ProjectEditorView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    /// nil bedeutet: neues Projekt anlegen.
    let project: AIProject?

    @State private var name = ""
    @State private var systemPrompt = ""
    @State private var accentHex = Theme.projectColors[0]
    @State private var defaultModelID: String?
    @State private var showModelPicker = false
    @State private var didLoad = false
    @State private var promptWarning: String?

    private var isNew: Bool { project == nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("z. B. Logistik-Analysen", text: $name)
                }

                Section("Farbe") {
                    HStack(spacing: 14) {
                        ForEach(Theme.projectColors, id: \.self) { hex in
                            Button {
                                accentHex = hex
                            } label: {
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 26, height: 26)
                                    .overlay {
                                        Circle()
                                            .strokeBorder(Theme.textPrimary,
                                                          lineWidth: accentHex == hex ? 2 : 0)
                                            .padding(-3)
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Farbe \(hex)")
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    TextField("Du bist ein erfahrener Programmier-Assistent …",
                              text: $systemPrompt,
                              axis: .vertical)
                        .lineLimit(4...12)
                } header: {
                    Text("System-Prompt")
                } footer: {
                    Text("Wird jedem Chat dieses Projekts vorangestellt. Die verbindlichen Sicherheitsregeln der App bleiben davon unberührt.")
                }

                Section("Standardmodell") {
                    Button {
                        showModelPicker = true
                    } label: {
                        HStack {
                            Group {
                                if let id = defaultModelID {
                                    Text(verbatim: app.model(id: id)?.name ?? id)
                                } else {
                                    Text("App-Standard verwenden")
                                }
                            }
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    if defaultModelID != nil {
                        Button("Zurücksetzen", role: .destructive) {
                            defaultModelID = nil
                        }
                    }
                }

                if let project {
                    Section("Verbrauch") {
                        LabeledContent("Kosten gesamt",
                                       value: CostFormat.usd(app.costUSD(forProject: project.id)))
                        LabeledContent("Tokens gesamt",
                                       value: CostFormat.tokens(app.tokens(forProject: project.id)))
                    }
                }
            }
            .navigationTitle(isNew ? "Neues Projekt" : "Projekt bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") { save() }
                        .fontWeight(.semibold)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .sheet(isPresented: $showModelPicker) {
                ModelPickerView(selectedModelID: defaultModelID) { modelID in
                    defaultModelID = modelID
                }
            }
            .onAppear {
                // Nur einmal laden. Präsentiert die Ansicht das
                // Modell-Blatt, kann SwiftUI ein erneutes onAppear auslösen –
                // das würde die Eingaben des Nutzers überschreiben.
                guard !didLoad else { return }
                didLoad = true
                load()
            }
            .alert("Projekt-Prompt nicht zulässig", isPresented: promptWarningBinding) {
                Button("OK", role: .cancel) { promptWarning = nil }
            } message: {
                Text(LocalizedStringKey(promptWarning ?? ""))
            }
        }
    }

    private func load() {
        guard let project else { return }
        name = project.name
        systemPrompt = project.systemPrompt
        accentHex = project.accentHex
        defaultModelID = project.defaultModelID
    }

    private var promptWarningBinding: Binding<Bool> {
        Binding(get: { promptWarning != nil },
                set: { if !$0 { promptWarning = nil } })
    }

    private func save() {
        // Der Projekt-Prompt geht wörtlich an den Anbieter und war bisher der
        // einzige Text in der App, der den Filter nicht passiert.
        let verdict = ContentModeration.screenInput(systemPrompt, strict: app.settings.strictFilter)
        if verdict.isBlocked {
            promptWarning = verdict.explanation
            return
        }

        let updated = AIProject(
            id: project?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            systemPrompt: systemPrompt,
            defaultModelID: defaultModelID,
            accentHex: accentHex,
            createdAt: project?.createdAt ?? Date()
        )
        app.upsert(project: updated)
        if isNew {
            // Frisch angelegt: gleich hineinwechseln. Sonst legt man ein
            // Projekt an, die Seitenleiste sieht unverändert aus, und der
            // nächste Chat landet weiter ausserhalb.
            app.selectedProjectID = updated.id
            // Und gleich einen Chat darin öffnen. Nicht nur der Bequemlichkeit
            // wegen: bliebe der bisher gewählte Chat stehen, zeigte die
            // Seitenleiste das neue (leere) Projekt und die Detailspalte einen
            // Chat, der dort gar nicht gelistet ist. Genau diesen Widerspruch
            // löst der Programmstart auf, indem er die Projektauswahl
            // verwirft – die Arbeit des Nutzers wäre also wieder weg.
            app.newConversation(inProject: updated.id)
        }
        dismiss()
    }
}
