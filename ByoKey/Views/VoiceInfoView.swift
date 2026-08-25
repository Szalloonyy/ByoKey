//
//  VoiceInfoView.swift
//  ByoKey
//
//  Erklärt, warum der Sprachmodus etwas anderes ist als das Chat-Modell.
//
//  Das ist keine Nebensächlichkeit: Wer "Sprachmodus" liest, erwartet oft,
//  dass jedes Modell in der Liste dann spricht. Tut es nicht. Ohne diese
//  Erklärung landet die Enttäuschung in den Bewertungen – und beim Support.
//

import SwiftUI

struct VoiceInfoView: View {
    @Environment(AppState.self) private var app

    private var provider: any AIProviderProtocol { app.activeProvider }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {

                header

                section("Ein Chat-Modell hört und spricht nicht") {
                    Text("""
                    Claude, Gemini, GPT und die anderen Modelle in der Liste verarbeiten \
                    Text. Sie bekommen Text, sie geben Text zurück. Selbst wenn das \
                    Modell „Voice“ im Namen trägt, ändert das nichts an dem, was über \
                    die Chat-Schnittstelle läuft.
                    """)
                    Text("""
                    Der Sprachmodus setzt deshalb zwei zusätzliche Bausteine davor und \
                    dahinter – das Modell selbst merkt davon nichts.
                    """)
                }

                pipeline

                section("Zwei Wege, das zu tun") {
                    optionCard(
                        title: "Auf dem Gerät",
                        badge: "Standard",
                        badgeColor: Theme.success,
                        points: [
                            "Funktioniert mit **jedem** Chat-Modell.",
                            "Kostet nichts zusätzlich.",
                            "Die Aufnahme verlässt dein iPhone nicht, solange iOS die Sprache auf dem Gerät erkennen kann.",
                            "Die Stimmen sind die des Systems – solide, aber nicht so natürlich wie die besten Anbieterstimmen."
                        ]
                    )
                    optionCard(
                        title: "Über den Anbieter",
                        badge: "kostenpflichtig",
                        badgeColor: Theme.warning,
                        points: [
                            "Braucht **zwei eigene Modelle**: eines für die Erkennung, eines für das Vorlesen.",
                            "Der Anbieter muss die Audio-Endpunkte überhaupt anbieten. OpenRouter und OpenAI tun das; ein beliebiger OpenAI-kompatibler Server nicht zwangsläufig.",
                            "Die Aufnahme wird übertragen – dafür gibt es eine eigene Freigabe.",
                            "Wird nach Anbieterpreis abgerechnet, zusätzlich zum Chat."
                        ]
                    )
                }

                section("Bei deinem aktuellen Anbieter") {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: provider.supportsAudio
                              ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(provider.supportsAudio ? Theme.success : Theme.danger)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(provider.displayName)
                                .font(.subheadline.weight(.semibold))
                            Text(provider.supportsAudio
                                 ? "bietet Audio-Endpunkte. In der Modell-Liste findest du dafür eigene Einträge – sie sind nicht dieselben wie dein Chat-Modell."
                                 : "bietet keine Audio-Endpunkte. Hier bleibt nur der Weg über das Gerät.")
                                .font(.footnote)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(tint: Theme.surfaceAlt)
                }

                section("Woran du ein Sprachmodell erkennst") {
                    Text("""
                    In der Modell-Liste des Anbieters stehen die Ein- und Ausgabearten. \
                    Ein Erkennungsmodell nimmt Audio entgegen und gibt Text aus, ein \
                    Vorlesemodell nimmt Text und gibt Audio aus. ByoKey filtert die Liste \
                    danach, sofern der Anbieter diese Angaben mitliefert – sonst trägst du \
                    die Kennung von Hand ein.
                    """)
                    Text("Typische Kennungen: `openai/whisper-1` fürs Erkennen, `openai/gpt-4o-mini-tts` fürs Vorlesen.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }

                section("Kosten") {
                    Text("""
                    Die Erkennung rechnet der Anbieter meist nach Audiolänge ab, das \
                    Vorlesen nach Zeichen. ByoKey rechnet die Erkennung mit, sofern der \
                    Anbieter die Kosten in der Antwort ausweist. Die Kosten fürs Vorlesen \
                    meldet er nicht zurück – sie erscheinen nur auf seiner Abrechnung.
                    """)
                }

                section("Datenschutz") {
                    Text("""
                    Auf dem Gerät erzwingt ByoKey die Erkennung ohne Serverkontakt, solange \
                    iOS die Sprache dafür unterstützt. Ist das nicht der Fall, würde die \
                    Aufnahme an Apple gehen – das passiert nur, wenn du es in den \
                    Einstellungen ausdrücklich erlaubst.
                    """)
                    Text("""
                    Beim Weg über den Anbieter gilt dieselbe Regel wie für Text: eigene \
                    Freigabe, jederzeit widerrufbar, und die Aufnahme wird nach dem \
                    Hochladen sofort vom Gerät gelöscht.
                    """)
                }
            }
            .padding(20)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .background { Theme.background.ignoresSafeArea() }
        .navigationTitle("Sprache und Modelle")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Bausteine

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "waveform.badge.mic")
                .font(.title)
                .foregroundStyle(Theme.accent)
            Text("Nicht jedes Modell kann sprechen")
                .font(.title2.bold())
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Die Kette sichtbar machen – ein Bild sagt hier mehr als drei Absätze.
    private var pipeline: some View {
        VStack(spacing: 0) {
            stage(icon: "mic.fill", title: "Deine Stimme", detail: "Aufnahme")
            connector(label: "Spracherkennung")
            stage(icon: "text.alignleft", title: "Text", detail: "das bekommt das Chat-Modell")
            connector(label: "Chat-Modell")
            stage(icon: "text.alignleft", title: "Antworttext", detail: "das gibt es zurück")
            connector(label: "Sprachausgabe")
            stage(icon: "speaker.wave.2.fill", title: "Gesprochene Antwort", detail: "Wiedergabe")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(tint: Theme.surfaceAlt)
    }

    private func stage(icon: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundStyle(Theme.accent)
                .frame(width: 26, height: 26)
                .background(Theme.surface, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func connector(label: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Theme.border)
                    .frame(width: 2, height: 22)
            }
            .frame(width: 26)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.accent)
            Spacer(minLength: 0)
        }
    }

    private func optionCard(title: LocalizedStringKey,
                            badge: LocalizedStringKey,
                            badgeColor: Color,
                            points: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(badge)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(badgeColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(badgeColor.opacity(0.14), in: Capsule())
            }
            ForEach(points, id: \.self) { point in
                HStack(alignment: .top, spacing: 8) {
                    Text("•").foregroundStyle(Theme.textSecondary)
                    // Erst übersetzen, dann Markdown auswerten: sonst
                    // ginge die Fettschrift beim Nachschlagen verloren.
                    Text(MarkdownParser.inline(Loc.tr(point)))
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(tint: Theme.surface)
    }

    private func section<Content: View>(_ title: LocalizedStringKey,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .font(.subheadline)
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
