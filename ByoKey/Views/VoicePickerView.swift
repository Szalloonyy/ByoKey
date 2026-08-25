//
//  VoicePickerView.swift
//  ByoKey
//
//  Stimmenauswahl für den Geräte-Modus.
//
//  Warum eine eigene Ansicht statt eines Auswahlmenüs: Die Stimmen eines
//  iPhones unterscheiden sich stark in der Qualität, und man hört den
//  Unterschied sofort – sieht ihn aber nicht. Eine flache Liste mit Namen
//  lässt den Nutzer raten. Hier steht die Qualitätsstufe daneben, und jede
//  Stimme lässt sich vor der Auswahl anhören.
//
//  Zur häufigsten Frage („warum nicht die Siri-Stimme?"): Apple gibt die
//  Siri-Stimmen Fremd-Apps nicht frei. Was hier steht, ist alles, was das
//  System herausgibt – mehr geht ohne private Schnittstellen nicht, und die
//  führen zur Ablehnung. Die Premium-Stimmen kommen nah heran und sind
//  kostenlos nachladbar; der Hinweis dazu steht unten in der Ansicht.
//

import SwiftUI
import AVFoundation

struct VoicePickerView: View {
    @Environment(AppState.self) private var app

    let language: String
    @Binding var selection: String

    @State private var voices: [AVSpeechSynthesisVoice] = []
    @State private var personalVoiceRequested = false
    /// Gepuffert, weil `speechVoices()` sonst bei jedem Bildaufbau der Liste
    /// erneut über alle installierten Stimmen laufen würde.
    @State private var hasPersonalVoice = false
    @State private var previewing: String?

    private var grouped: [(title: String, note: String, voices: [AVSpeechSynthesisVoice])] {
        let personal = voices.filter { $0.voiceTraits.contains(.isPersonalVoice) }
        let premium  = voices.filter { $0.quality == .premium && !$0.voiceTraits.contains(.isPersonalVoice) }
        let enhanced = voices.filter { $0.quality == .enhanced && !$0.voiceTraits.contains(.isPersonalVoice) }
        let standard = voices.filter { $0.quality == .default  && !$0.voiceTraits.contains(.isPersonalVoice) }

        return [
            ("Persönliche Stimme", "In den Bedienungshilfen aufgenommen. Bleibt auf dem Gerät.", personal),
            ("Premium", "Die natürlichsten Systemstimmen. Größter Download.", premium),
            ("Erweitert", "Deutlich besser als Standard, kleinerer Download.", enhanced),
            ("Standard", "Immer vorhanden, klingt am maschinellsten.", standard)
        ].filter { !$0.2.isEmpty }
    }

    var body: some View {
        List {
            Section {
                row(title: Text("Systemstandard"),
                    subtitle: "Die Stimme, die iOS für diese Sprache vorgibt.",
                    identifier: "",
                    canPreview: false)
            }

            ForEach(grouped, id: \.title) { group in
                Section {
                    ForEach(group.voices, id: \.identifier) { voice in
                        // Stimmennamen sind Eigennamen. Als Schlüssel wären
                        // sie ein Risiko: hiesse eine persönliche Stimme
                        // „Premium“ oder „Standard“, ersetzte der Katalog den
                        // Namen durch seine Übersetzung.
                        row(title: Text(verbatim: voice.name),
                            subtitle: LocalizedStringKey(subtitle(for: voice)),
                            identifier: voice.identifier,
                            canPreview: true)
                    }
                } header: {
                    Text(LocalizedStringKey(group.title))
                } footer: {
                    Text(LocalizedStringKey(group.note))
                }
            }

            if !hasPersonalVoice {
                Section {
                    Button("Persönliche Stimme freigeben") {
                        Task {
                            personalVoiceRequested = true
                            _ = await SpeechService.requestPersonalVoiceAccess()
                            reload()
                        }
                    }
                    .disabled(personalVoiceRequested)
                } footer: {
                    Text("Wenn du in den Bedienungshilfen eine persönliche Stimme aufgenommen hast, kannst du sie hier freigeben. Sie verlässt das Gerät nicht.")
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Bessere Stimmen nachladen", systemImage: "arrow.down.circle")
                        .font(.subheadline.weight(.semibold))
                    Text("Einstellungen › Bedienungshilfen › Gesprochene Inhalte › Stimmen › Deutsch. Dort lädst du die Stimmen in „Premium“ herunter – kostenlos. Danach erscheinen sie hier.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    Label("Und die Siri-Stimme?", systemImage: "questionmark.circle")
                        .font(.subheadline.weight(.semibold))
                    Text("Die gibt Apple anderen Apps nicht frei – sie ist Siri vorbehalten. Diese Liste enthält alles, was das System herausgibt. Wenn du es noch natürlicher möchtest, ist der Weg über die Sprachmodelle deines Anbieters die bessere Wahl; der kostet dann allerdings.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Stimme")
        .navigationBarTitleDisplayMode(.inline)
        .task { reload() }
        .onDisappear { app.speech.stopSpeaking() }
    }

    // MARK: - Bausteine

    private func row(title: Text,
                     subtitle: LocalizedStringKey,
                     identifier: String,
                     canPreview: Bool) -> some View {
        HStack(spacing: 12) {
            Button {
                selection = identifier
                app.scheduleSave()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: selection == identifier ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selection == identifier ? Theme.accent : Theme.textSecondary)

                    VStack(alignment: .leading, spacing: 2) {
                        title
                            .foregroundStyle(Theme.textPrimary)
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if canPreview {
                Button {
                    previewing = identifier
                    app.speech.previewDeviceVoice(identifier: identifier, language: language)
                } label: {
                    Image(systemName: isPreviewing(identifier) ? "speaker.wave.2.fill" : "play.circle")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .padding(.trailing, -10)
                .accessibilityLabel("Hörprobe abspielen")
            }
        }
    }

    private func isPreviewing(_ identifier: String) -> Bool {
        previewing == identifier && app.speech.phase == .speaking
    }

    /// Sprachkennung plus Merkmale. Die Merkmale sind Worte und werden
    /// deshalb einzeln übersetzt, bevor sie zusammengesetzt werden – als
    /// fertiger Satz fände der Katalog keinen Schlüssel mehr.
    private func subtitle(for voice: AVSpeechSynthesisVoice) -> String {
        var parts: [String] = [voice.language]
        if voice.voiceTraits.contains(.isNoveltyVoice) { parts.append(Loc.tr("Spassstimme")) }
        if voice.gender == .female { parts.append(Loc.tr("weiblich")) }
        if voice.gender == .male { parts.append(Loc.tr("männlich")) }
        return parts.joined(separator: " · ")
    }

    private func reload() {
        voices = SpeechService.deviceVoices(language: language)
        hasPersonalVoice = SpeechService.hasPersonalVoice
    }
}
