//
//  ComposerView.swift
//  ByoKey
//
//  Eingabefeld, das mit dem Text mitwächst (eine bis acht Zeilen),
//  danach scrollt. Der Senden-Knopf wird während eines laufenden Streams
//  zum Stopp-Knopf.
//

import SwiftUI

struct ComposerView: View {
    @Binding var draft: String
    let isStreaming: Bool
    let isReady: Bool
    let placeholder: LocalizedStringKey
    /// Der Knopf öffnet den Vollbild-Sprachmodus. Bewusst kein zweiter
    /// Diktier-Pfad im Eingabefeld: die iOS-Tastatur hat dafür schon eine
    /// Taste, und zwei Aufnahmewege würden sich um die Audio-Sitzung streiten.
    let showsVoiceButton: Bool
    /// Noch nicht abgeschickte Anhänge. Sie stehen über dem Eingabefeld und
    /// wandern beim Senden in die Nachricht.
    let attachments: [Attachment]
    /// Läuft gerade ein Auslesevorgang? Ein 200-Seiten-PDF dauert spürbar.
    let isAttaching: Bool
    let onAttachPhoto: () -> Void
    let onAttachFile: () -> Void
    let onRemoveAttachment: (UUID) -> Void
    let onSend: () -> Void
    let onStop: () -> Void
    let onVoice: () -> Void
    /// Öffnet das Rückmeldeformular. Der Hinweis darunter ist Pflichttext
    /// (Richtlinie 1.2 – Antworten stammen von fremden Modellen); der
    /// Feedback-Knopf steht bewusst in derselben Zeile, weil genau dort die
    /// Frage aufkommt, wem man eine falsche Antwort meldet.
    let onFeedback: () -> Void

    @FocusState private var isFocused: Bool

    private var canSend: Bool {
        guard isReady, !isAttaching else { return false }
        // Eine angehängte Datei genügt: wer ein PDF anhängt und nichts dazu
        // schreibt, meint „fasse das zusammen". Den Satz setzt der Zustand
        // sichtbar in die Nachricht ein.
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachments.isEmpty
    }

    var body: some View {
        VStack(spacing: 6) {
            if !attachments.isEmpty || isAttaching {
                attachmentStrip
            }

            HStack(alignment: .bottom, spacing: 6) {
                // Die beiden Knöpfe stehen eng beieinander und **innerhalb**
                // eines eigenen Abstands: vorher lagen zehn Punkte zwischen
                // ihnen, dazu die Luft in ihren Trefferflächen – zusammen gut
                // dreissig Punkte zwischen den beiden Zeichen. Sie wirkten
                // dadurch weder zusammengehörig noch getrennt, sondern
                // verstreut.
                HStack(spacing: 2) {
                    // Ein Menü statt eines Knopfes: Fotos und Dateien liegen
                    // auf dem iPhone an verschiedenen Orten, und ein dritter
                    // Knopf in dieser Zeile wäre einer zu viel.
                    Menu {
                        Button {
                            onAttachPhoto()
                        } label: {
                            Label("Foto auswählen", systemImage: "photo.on.rectangle")
                        }
                        Button {
                            onAttachFile()
                        } label: {
                            Label("Datei auswählen", systemImage: "folder")
                        }
                    } label: {
                        composerLabel(systemName: "paperclip",
                                      isEnabled: isReady && !isAttaching)
                    }
                    .disabled(!isReady || isAttaching)
                    .accessibilityLabel("Anhängen")

                    if showsVoiceButton {
                        composerButton(systemName: "waveform",
                                       label: "Sprachmodus öffnen",
                                       isEnabled: isReady,
                                       action: onVoice)
                    }
                }
                .padding(.leading, 2)

                TextField(placeholder, text: $draft, axis: .vertical)
                    .lineLimit(1...8)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                    .focused($isFocused)
                    .disabled(!isReady)
                    .padding(.vertical, 11)
                    // Ohne diese Mindesthöhe ist das Feld niedriger als der
                    // Sprachknopf daneben. Die Zeile ist unten ausgerichtet –
                    // der Text sass dadurch spürbar unterhalb der Mitte.
                    // Mit gleicher Höhe steht er mittig, und mehrzeilig
                    // wächst das Feld wie vorher nach oben.
                    .frame(minHeight: 44)
                    .submitLabel(.return)

                Button {
                    if isStreaming {
                        onStop()
                    } else if canSend {
                        onSend()
                    }
                } label: {
                    Image(systemName: isStreaming ? "stop.fill" : "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(buttonForeground)
                        .frame(width: 32, height: 32)
                        .background(buttonBackground, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!isStreaming && !canSend)
                .padding(.trailing, 8)
                // (44 − 32) / 2: sitzt bei einer Zeile mittig und bleibt
                // beim Wachsen des Feldes unten am Rand.
                .padding(.bottom, 6)
                .accessibilityLabel(isStreaming ? "Antwort stoppen" : "Nachricht senden")
            }
            .background(Theme.surface,
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(isFocused ? Theme.accent.opacity(0.6) : Theme.border, lineWidth: 1)
            }

            // Ein Absatz aus Fließtext und angehängtem Knopf: bei großer
            // Schrift bricht die Zeile um, statt den Knopf abzuschneiden.
            VStack(spacing: 2) {
                Text("KI kann Fehler machen. Bitte überprüfe die Antworten.")
                Button(action: onFeedback) {
                    Text("Gib uns Feedback")
                        .underline()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .accessibilityLabel("Rückmeldung geben")
            }
            .font(.caption2)
            .foregroundStyle(Theme.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .background(Theme.background)
    }

    /// Ein Knopf links im Eingabefeld.
    ///
    /// Jeder bekommt eine eigene runde Fläche. Das ist der Unterschied
    /// zwischen „zwei Zeichen nebeneinander" und „zwei Knöpfen": ohne die
    /// Fläche verschwimmen Büroklammer und Wellenlinie zu einer Gruppe, und
    /// man sieht nicht, wo der eine aufhört und der andere anfängt.
    ///
    /// Sichtbar sind 32 Punkte, tippbar bleiben 42 × 44 – Apple verlangt für
    /// Trefferflächen rund 44 Punkte, und die Fläche darf ruhig grösser sein
    /// als das, was man sieht.
    private func composerButton(systemName: String,
                                label: LocalizedStringKey,
                                isEnabled: Bool,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            composerLabel(systemName: systemName, isEnabled: isEnabled)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }

    /// Die runde Fläche – geteilt zwischen Knopf und Menü, damit beide gleich
    /// aussehen und gleich gross zu treffen sind.
    private func composerLabel(systemName: String, isEnabled: Bool) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(isEnabled ? Theme.accent : Theme.textSecondary)
            .frame(width: 32, height: 32)
            .background(isEnabled ? Theme.accentSoft : Theme.surfaceAlt, in: Circle())
            .frame(width: 42, height: 44)
            .contentShape(Rectangle())
    }

    /// Die noch nicht abgeschickten Anhänge.
    ///
    /// Waagerecht scrollend statt umbrechend: bei drei Dateien wüchse die
    /// Leiste sonst über das halbe Bild und schöbe das Eingabefeld nach unten,
    /// während man tippt.
    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if isAttaching {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        // Neutral formuliert: ein Foto wird nicht „gelesen",
                        // es wird verkleinert und kodiert.
                        Text("Anhang wird vorbereitet …")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Theme.surfaceAlt, in: Capsule())
                }

                ForEach(attachments) { attachment in
                    HStack(spacing: 7) {
                        if attachment.kind.isImage {
                            AttachmentThumbnail(attachment: attachment, side: 34)
                        } else {
                            Image(systemName: attachment.kind.symbolName)
                                .font(.caption)
                                .foregroundStyle(Theme.accent)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: attachment.fileName)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            // Die Kürzung gehört schon hierher, nicht erst in
                            // die abgeschickte Nachricht: zwischen „Gekürzt
                            // anhängen" und dem Senden wäre sie sonst
                            // unsichtbar.
                            Text(verbatim: attachment.isTruncated
                                 ? Loc.tr("ca. %@ Tokens · gekürzt",
                                          CostFormat.tokens(attachment.tokenEstimate))
                                 : Loc.tr("ca. %@ Tokens",
                                          CostFormat.tokens(attachment.tokenEstimate)))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Button {
                            onRemoveAttachment(attachment.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Loc.tr("Anhang %@ entfernen", attachment.fileName))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Theme.surfaceAlt, in: Capsule())
                    .frame(maxWidth: 260)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var buttonBackground: Color {
        if isStreaming { return Theme.danger }
        return canSend ? Theme.accent : Theme.border
    }

    private var buttonForeground: Color {
        (isStreaming || canSend) ? .white : Theme.textSecondary
    }
}
