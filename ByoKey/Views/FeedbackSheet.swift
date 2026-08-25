//
//  FeedbackSheet.swift
//  ByoKey
//
//  Rückmeldung an den Entwickler. Bewusst getrennt von „Inhalt melden":
//  eine Meldung betrifft eine konkrete Antwort und ist nach Richtlinie 1.2
//  Pflicht, eine Rückmeldung betrifft die App und ist freiwillig.
//
//  Der Weg ist derselbe wie bei der Meldung – eine vorbereitete E-Mail an die
//  veröffentlichte Support-Adresse. Ohne eingerichtetes Mailkonto erscheint
//  die Adresse zum Kopieren, statt dass der Knopf wirkungslos bleibt.
//

import SwiftUI
import UIKit

struct FeedbackSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    enum Topic: String, CaseIterable, Identifiable {
        case idea, bug, praise, other
        var id: String { rawValue }

        /// Deutscher Text = Übersetzungsschlüssel.
        var label: String {
            switch self {
            case .idea:   return "Vorschlag"
            case .bug:    return "Fehler in der App"
            case .praise: return "Lob"
            case .other:  return "Sonstiges"
            }
        }
    }

    @State private var topic: Topic = .idea
    @State private var text = ""
    @State private var mailFallback = false

    private var canSend: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 5
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Anliegen", selection: $topic) {
                        ForEach(Topic.allCases) { item in
                            Text(LocalizedStringKey(item.label)).tag(item)
                        }
                    }
                } footer: {
                    Text("Antworten kommen von KI-Modellen dritter Anbieter. Wenn dir etwas auffällt – eine falsche Antwort, ein Fehler in der App, ein fehlendes Modell – schreib es hier auf.")
                }

                Section {
                    TextField("Was möchtest du uns sagen?", text: $text, axis: .vertical)
                        .lineLimit(4...12)
                } header: {
                    Text("Deine Rückmeldung")
                } footer: {
                    Text("Es wird nichts automatisch mitgeschickt: kein Chat, kein Schlüssel, keine Kennung. Nur der Text, den du hier schreibst, sowie App-Version und iOS-Version – damit wir Fehler zuordnen können.")
                }

                Section {
                    Button("Rückmeldung senden") { send() }
                        .disabled(!canSend)
                    Button("Adresse kopieren") {
                        UIPasteboard.general.string = AppInfo.supportEmail
                    }
                    .foregroundStyle(Theme.textSecondary)
                } footer: {
                    Text("Die Rückmeldung geht als E-Mail an \(AppInfo.supportEmail).")
                }
            }
            .navigationTitle("Feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
            .alert("Keine E-Mail möglich", isPresented: $mailFallback) {
                Button("Adresse kopieren") {
                    UIPasteboard.general.string = AppInfo.supportEmail
                    dismiss()
                }
                Button("Schließen", role: .cancel) { dismiss() }
            } message: {
                Text("Auf diesem Gerät ist kein Mailkonto eingerichtet. Schreib uns bitte an \(AppInfo.supportEmail).")
            }
        }
    }

    private func send() {
        let body = """
        \(Loc.tr(topic.label))

        \(text)

        ---
        App: ByoKey \(AppInfo.version)
        iOS: \(UIDevice.current.systemVersion)
        Sprache: \(app.settings.language.rawValue)
        """
        guard let url = AppInfo.reportMailURL(subject: "ByoKey – Feedback", body: body) else {
            mailFallback = true
            return
        }
        openURL(url) { accepted in
            if accepted { dismiss() } else { mailFallback = true }
        }
    }
}
