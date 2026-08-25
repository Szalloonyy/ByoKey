//
//  OnboardingView.swift
//  ByoKey
//
//  Pflicht-Einstieg vor der ersten Nutzung.
//
//  Richtlinie 1.2 verlangt bei Apps mit nutzergenerierten Inhalten, dass der
//  Nutzer Bedingungen mit Null-Toleranz-Klausel gegenüber anstößigen
//  Inhalten aktiv akzeptiert. Ohne Zustimmung erscheint die Chat-Oberfläche
//  gar nicht erst – es kann also nichts gesendet werden.
//

import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var app
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                welcomePage.tag(0)
                howItWorksPage.tag(1)
                termsPage.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            footer
        }
        .background { Theme.background.ignoresSafeArea() }
    }

    // MARK: - Seiten

    private var welcomePage: some View {
        pageLayout {
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 54))
                .foregroundStyle(Theme.accent)
                .padding(.bottom, 8)
                // Reine Verzierung – VoiceOver soll sie nicht vorlesen.
                .accessibilityHidden(true)

            Text("Willkommen bei ByoKey")
                .font(.largeTitle.bold())
                .foregroundStyle(Theme.textPrimary)

            Text("Ein ruhiger Arbeitsplatz für KI-Modelle – mit deinem eigenen API-Schlüssel und einer Kostenanzeige, die dir nichts verschweigt.")
                .font(.body)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var howItWorksPage: some View {
        pageLayout {
            Text("So funktioniert es")
                .font(.title.bold())
                .foregroundStyle(Theme.textPrimary)

            VStack(alignment: .leading, spacing: 18) {
                bullet(icon: "key.fill",
                       title: "Dein Schlüssel, dein Konto",
                       text: "Du hinterlegst deinen eigenen API-Schlüssel, zum Beispiel von OpenRouter. Er wird in der iOS-Keychain gespeichert, verlässt dein Gerät nicht und wird ausschließlich an die offizielle Schnittstelle des Anbieters gesendet.")
                bullet(icon: "eurosign.circle.fill",
                       title: "Kosten immer sichtbar",
                       text: "Nach jeder Antwort siehst du Tokens und Kosten – pro Nachricht, pro Chat, pro Projekt und pro Monat.")
                bullet(icon: "folder.fill",
                       title: "Projekte statt Chaos",
                       text: "Jedes Projekt kann einen eigenen System-Prompt und ein Standardmodell haben.")
                bullet(icon: "lock.shield.fill",
                       title: "Ohne eigenen Server",
                       text: "ByoKey betreibt keinen Zwischenserver. Chats und Projekte liegen nur auf deinem Gerät.")
            }
        }
    }

    private var termsPage: some View {
        pageLayout {
            Text("Nutzungsbedingungen")
                .font(.title.bold())
                .foregroundStyle(Theme.textPrimary)

            VStack(alignment: .leading, spacing: 14) {
                paragraph("ByoKey stellt Antworten von KI-Modellen dritter Anbieter dar. Diese Antworten können falsch, unvollständig oder unangemessen sein. Prüfe wichtige Angaben immer nach. ByoKey ist kein Ersatz für medizinische, rechtliche oder finanzielle Beratung.")

                calloutBox {
                    Text("Null-Toleranz gegenüber anstößigen Inhalten")
                        .font(.subheadline.bold())
                        .foregroundStyle(Theme.textPrimary)
                    Text("Du verpflichtest dich, ByoKey nicht zu nutzen, um Inhalte zu erzeugen, die Minderjährige sexualisieren, zu Gewalt aufrufen, Personen bedrohen, Hass verbreiten oder Anleitungen zu Waffen und Schadsoftware liefern. Ein Inhaltsfilter prüft Ein- und Ausgaben. Verstöße kannst du direkt in der App melden; wir gehen Meldungen nach und können Inhalte und Modelle sperren.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }

                paragraph("Du bist für die Kosten verantwortlich, die bei deinem API-Anbieter entstehen. Die Kostenanzeige in ByoKey ist eine Hilfe, aber keine Abrechnung – maßgeblich ist immer die Abrechnung deines Anbieters.")

                paragraph("Quelltext, den ein Modell erzeugt und den du als Archiv sicherst, ist ungeprüft. Sieh ihn durch, bevor du ihn ausführst oder veröffentlichst.")

                HStack(spacing: 16) {
                    if let url = AppInfo.termsURL {
                        Link("Vollständige Bedingungen", destination: url)
                    }
                    if let url = AppInfo.privacyPolicyURL {
                        Link("Datenschutz", destination: url)
                    }
                }
                .font(.footnote.weight(.medium))
            }
        }
    }

    // MARK: - Bausteine

    private var footer: some View {
        VStack(spacing: 10) {
            if page < 2 {
                Button {
                    withAnimation { page += 1 }
                } label: {
                    Text("Weiter")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    app.consent.acceptTerms()
                } label: {
                    Text("Bedingungen akzeptieren und starten")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)

                Text("Mit dem Fortfahren bestätigst du die Nutzungsbedingungen inklusive der Null-Toleranz-Regel. Es wird noch nichts gesendet – die Freigabe für den KI-Anbieter fragen wir separat ab.")
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .padding(.top, 8)
    }

    private func pageLayout<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Spacer(minLength: 40)
                content()
                Spacer(minLength: 40)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity)
        }
    }

    private func bullet(icon: String, title: LocalizedStringKey, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundStyle(Theme.textPrimary)
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func paragraph(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func calloutBox<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card(tint: Theme.accentSoft)
    }
}
