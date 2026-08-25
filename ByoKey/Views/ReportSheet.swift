//
//  ReportSheet.swift
//  ByoKey
//
//  Meldemechanismus nach App Store Richtlinie 1.2:
//  "A mechanism to report offensive content and timely responses to concerns."
//
//  Die Meldung wird lokal protokolliert (sichtbar unter Einstellungen ›
//  Meldungen) und lässt sich mit einem Tippen als E-Mail an die
//  veröffentlichte Support-Adresse senden. Zusätzlich kann das
//  verantwortliche Modell direkt gesperrt werden – das ist die BYOK-Entsprechung
//  zu "the ability to block abusive users from the service".
//

import SwiftUI
import UIKit

struct ReportSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let message: ChatMessage
    let conversationID: UUID

    @State private var reason: ContentReport.Reason = .other
    @State private var note = ""
    @State private var blockModel = false
    @State private var sendMail = true
    @State private var mailFallback = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Was ist das Problem?") {
                    Picker("Grund", selection: $reason) {
                        ForEach(ContentReport.Reason.allCases) { item in
                            Text(LocalizedStringKey(item.displayName)).tag(item)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("Beschreibung (optional)") {
                    TextField("Was ist passiert?", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section("Betroffene Antwort") {
                    Text(String(message.text.prefix(400)))
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                    if let modelID = message.modelID, !modelID.isEmpty {
                        LabeledContent("Modell", value: modelID)
                            .font(.footnote)
                    }
                }

                Section {
                    if let modelID = message.modelID, !modelID.isEmpty {
                        Toggle("Modell \"\(modelID)\" sperren", isOn: $blockModel)
                    }
                    Toggle("Meldung zusätzlich per E-Mail senden", isOn: $sendMail)
                } footer: {
                    Text("Meldungen gehen an \(AppInfo.supportEmail). Wir sehen sie durch und passen den Inhaltsfilter an. Gesperrte Modelle lassen sich in den Einstellungen wieder freigeben.")
                }
            }
            .navigationTitle("Inhalt melden")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Melden") { submit() }
                        .fontWeight(.semibold)
                }
            }
            .alert("E-Mail-App nicht verfügbar", isPresented: $mailFallback) {
                Button("Adresse kopieren") {
                    UIPasteboard.general.string = AppInfo.supportEmail
                    dismiss()
                }
                Button("Schließen", role: .cancel) { dismiss() }
            } message: {
                Text("Deine Meldung ist gespeichert und unter Einstellungen › Meldungen einsehbar. Bitte sende sie zusätzlich an \(AppInfo.supportEmail).")
            }
        }
    }

    private func submit() {
        // Die Meldung wird IMMER lokal erfasst – auch wenn der Mailversand
        // scheitert. Sonst wäre der Melde-Knopf auf einem Gerät ohne
        // eingerichtetes Mailkonto wirkungslos (Richtlinie 1.2).
        app.report(message: message, in: conversationID, reason: reason, note: note)

        if blockModel, let modelID = message.modelID {
            app.blockModel(modelID)
        }

        guard sendMail else {
            dismiss()
            return
        }

        let body = """
        Grund: \(reason.displayName)
        Modell: \(message.modelID ?? "unbekannt")
        App-Version: \(AppInfo.version)
        Zeitpunkt: \(message.createdAt.formatted())

        Beschreibung:
        \(note.isEmpty ? "–" : note)

        Auszug der Antwort:
        \(String(message.text.prefix(1000)))
        """

        guard let url = AppInfo.reportMailURL(subject: "ByoKey – Inhaltsmeldung", body: body) else {
            mailFallback = true
            return
        }

        openURL(url) { accepted in
            if accepted {
                dismiss()
            } else {
                mailFallback = true
            }
        }
    }
}
