//
//  ConsentView.swift
//  ByoKey
//
//  Zustimmungsdialog nach App Store Richtlinie 5.1.2(i).
//
//  Die vier Punkte, an denen Apple regelmäßig ablehnt, sind hier bewusst
//  sichtbar umgesetzt:
//    1. Anbieter wird beim Namen genannt (keine Formulierung wie "powered by AI").
//    2. Zweck ist konkret: "Nachrichten werden gesendet, um Antworten zu erzeugen".
//    3. Datenarten werden einzeln aufgezählt.
//    4. Zustimmung erfolgt durch aktives Tippen – nichts ist vorausgewählt,
//       und der Widerruf ist im selben Dialog benannt.
//
//  Der Dialog erscheint VOR dem ersten Netzwerkaufruf an den Anbieter.
//

import SwiftUI

struct ConsentView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let providerID: String
    var scope: ConsentScope = .text

    private var provider: any AIProviderProtocol {
        ProviderRegistry.providerOrDefault(id: providerID)
    }

    // MARK: Texte je Bereich
    //
    // Für Sprache gilt dieselbe Regel wie für Text (Richtlinie 5.1.2(i)),
    // aber es sind andere Daten: eine Aufnahme der eigenen Stimme ist etwas
    // anderes als getippter Text. Deshalb eine eigene Zustimmung mit eigener
    // Aufzählung – und nicht ein Haken, der beides mitnimmt.

    // Diese Texte entstehen als `String` und laufen deshalb nicht durch die
    // automatische Übersetzung von `Text(...)`. Ohne `Loc.tr` bliebe
    // ausgerechnet der Zustimmungsdialog – der Bildschirm, an dem Richtlinie
    // 5.1.2(i) hängt – auf Deutsch stehen.
    private var title: String {
        scope == .audio
            ? Loc.tr("Sprachaufnahmen an %@ übertragen?", Loc.tr(provider.legalEntity))
            : Loc.tr("Deine Nachrichten an %@ senden?", Loc.tr(provider.legalEntity))
    }

    private var intro: String {
        scope == .audio
            ? Loc.tr("Für Spracherkennung und Sprachausgabe beim Anbieter müssen Aufnahme und Text dein Gerät verlassen. Der Sprachmodus „Auf dem Gerät“ kommt ohne das aus.")
            : Loc.tr("Damit ein KI-Modell antworten kann, muss der Text dein Gerät verlassen. Ohne deine Zustimmung sendet ByoKey nichts.")
    }

    private var categories: [String] {
        guard scope == .audio else { return provider.dataCategories.map { Loc.tr($0) } }
        return [
            "Deine Sprachaufnahme als Audiodatei",
            "Der Text der Antwort, wenn du sie vorlesen lässt",
            "Die Kennung des gewählten Sprach- bzw. Vorlesemodells",
            "Dein API-Schlüssel – ausschließlich zur Anmeldung bei diesem Anbieter",
            "Deine IP-Adresse – technisch bedingt bei jeder Internetverbindung"
        ].map { Loc.tr($0) }
    }

    private var summary: String {
        guard scope == .audio else { return Loc.tr(provider.privacySummary) }
        return Loc.tr("""
        Die Aufnahme geht direkt von deinem iPhone an %@ und wird \
        dort in Text umgewandelt. Für das Vorlesen geht der Antworttext an denselben \
        Anbieter und kommt als Audiodatei zurück. Die Verarbeitung findet auf dessen \
        Servern statt, also außerhalb deines Geräts und möglicherweise außerhalb \
        der EU. Die Aufnahme wird nach dem Hochladen sofort vom Gerät gelöscht.
        """, Loc.tr(provider.legalEntity))
    }

    private var confirmLabel: String {
        scope == .audio
            ? Loc.tr("Ja, Sprache an %@ senden", provider.displayName)
            : Loc.tr("Ja, an %@ senden", provider.displayName)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {

                    header

                    section(title: "Was gesendet wird") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(categories, id: \.self) { item in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption)
                                        .foregroundStyle(Theme.accent)
                                        .padding(.top, 3)
                                        // Reine Verzierung – VoiceOver soll sie nicht vorlesen.
                                        .accessibilityHidden(true)
                                    Text(item)
                                        .font(.subheadline)
                                        .foregroundStyle(Theme.textPrimary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }

                    section(title: "Wohin es geht und wozu") {
                        Text(summary)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    section(title: "Wohin es nicht geht") {
                        VStack(alignment: .leading, spacing: 8) {
                            notSent(translated: Loc.tr("Dein API-Schlüssel geht an keinen anderen Empfänger als %@ – insbesondere nicht an ByoKey.", provider.displayName))
                            notSent("ByoKey betreibt keinen eigenen Server. Es gibt keine Analyse, kein Tracking und keine Werbe-IDs.")
                            if scope == .audio {
                                notSent("Die Aufnahme wird nicht gespeichert und liegt nach dem Hochladen nicht mehr auf dem Gerät.")
                            } else {
                                notSent("Chats, Projekte und Kostendaten bleiben auf diesem Gerät.")
                            }
                        }
                    }

                    revocationNote

                    if let url = provider.privacyPolicyURL {
                        Link(destination: url) {
                            Label("Datenschutzerklärung von \(provider.displayName)", systemImage: "arrow.up.right.square")
                                .font(.footnote.weight(.medium))
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .background { Theme.background.ignoresSafeArea() }
            .navigationTitle(scope == .audio ? "Sprach-Freigabe" : "Datenfreigabe")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                buttons
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
    }

    // MARK: - Teile

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .font(.title)
                .foregroundStyle(Theme.accent)
                // Reine Verzierung – VoiceOver soll sie nicht vorlesen.
                .accessibilityHidden(true)

            Text(title)
                .font(.title2.bold())
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(intro)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var revocationNote: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .foregroundStyle(Theme.accent)
                // Reine Verzierung – VoiceOver soll sie nicht vorlesen.
                .accessibilityHidden(true)
            Text(scope == .audio
                 ? "Du kannst die Freigabe jederzeit unter Einstellungen › Sprachmodus widerrufen. Danach wird keine Aufnahme mehr an \(provider.displayName) gesendet."
                 : "Du kannst die Freigabe jederzeit unter Einstellungen › Datenfreigabe widerrufen. Danach werden keine Nachrichten mehr an \(provider.displayName) gesendet.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(tint: Theme.surfaceAlt)
    }

    private var buttons: some View {
        VStack(spacing: 10) {
            Button {
                // Über setConsent, damit direkt danach die Modell-Liste
                // geladen wird. Sonst steht der Nutzer nach dem Zustimmen ohne
                // Modell da und kann trotzdem nicht senden.
                app.setConsent(true, for: provider.id, scope: scope)
                dismiss()
            } label: {
                Text(confirmLabel)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)

            Button {
                app.setConsent(false, for: provider.id, scope: scope)
                dismiss()
            } label: {
                Text("Nein, nichts senden")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(.bar)
    }

    private func section<Content: View>(title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(Theme.textSecondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `LocalizedStringKey`, damit die drei festen Zeilen übersetzt werden.
    /// Die vierte wird mit dem Anbieternamen gebaut und kommt fertig
    /// übersetzt aus `Loc.tr` – dafür `notSent(translated:)`.
    private func notSent(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.shield")
                .font(.caption)
                .foregroundStyle(Theme.success)
                .padding(.top, 3)
                // Reine Verzierung – VoiceOver soll sie nicht vorlesen.
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func notSent(translated text: String) -> some View {
        notSent(LocalizedStringKey(text))
    }
}
