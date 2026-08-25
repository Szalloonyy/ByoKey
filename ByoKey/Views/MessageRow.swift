//
//  MessageRow.swift
//  ByoKey
//
//  Darstellung einer einzelnen Nachricht.
//
//  Richtlinie 1.2 wird hier an zwei Stellen sichtbar:
//    • Markierte Inhalte sind verdeckt und müssen bewusst aufgedeckt werden.
//      Die Markierung schlägt die Fehlerdarstellung – sonst wäre der Filter
//      mit einem abgebrochenen Stream aushebelbar.
//    • Jede Antwort hat einen Melde-Eintrag und die Möglichkeit, das
//      verantwortliche Modell zu sperren.
//
//  `Equatable`: während eines Streams wird der Zustand häufig verändert.
//  Ohne diese Konformität würde SwiftUI jede sichtbare Zeile neu bauen –
//  inklusive komplettem Markdown-Parse – weil die Closures nicht vergleichbar
//  sind und die eingebaute Schnellprüfung deshalb immer "geändert" meldet.
//

import SwiftUI
import UIKit

struct MessageRow: View, Equatable {
    let message: ChatMessage
    let showCost: Bool
    let isStreaming: Bool
    let isRevealed: Bool
    let isSpeaking: Bool
    let voiceEnabled: Bool
    let onReveal: () -> Void
    let onReport: () -> Void
    let onBlockModel: () -> Void
    let onExportFiles: () -> Void
    let onSpeak: () -> Void
    let onPreviewAttachment: (Attachment) -> Void
    let onToggleAttachment: (Attachment) -> Void

    @State private var didCopy = false
    @ScaledMetric(relativeTo: .caption) private var avatarSize: CGFloat = 26

    nonisolated static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message == rhs.message
            && lhs.showCost == rhs.showCost
            && lhs.isStreaming == rhs.isStreaming
            && lhs.isRevealed == rhs.isRevealed
            && lhs.isSpeaking == rhs.isSpeaking
            && lhs.voiceEnabled == rhs.voiceEnabled
    }

    /// Steuert, ob "Dateien exportieren" im Menü erscheint.
    private var hasCode: Bool {
        CodeArtifactExtractor.containsCode(message.text)
    }

    var body: some View {
        switch message.role {
        case .user:
            userMessage
        case .assistant:
            assistantMessage
        case .system:
            EmptyView()
        }
    }

    // MARK: - Nutzer

    private var userMessage: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(message.attachments) { attachment in
                    attachmentChip(attachment)
                }

                Text(message.text)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(message.isFlagged ? Theme.warning.opacity(0.12) : Theme.userBubble,
                                in: RoundedRectangle(cornerRadius: Theme.bubbleCorner, style: .continuous))

                if message.isFlagged {
                    Label("Vom Inhaltsfilter blockiert", systemImage: "hand.raised.fill")
                        .font(.caption2)
                        .foregroundStyle(Theme.warning)
                }
            }
        }
    }

    /// Eine angehängte Datei über der Nachricht.
    ///
    /// Abgeschaltete Anhänge verschwinden **nicht**, sie werden blass und
    /// durchgestrichen. Ein Anhang, der einfach weg wäre, sähe wie ein Fehler
    /// aus; so bleibt sichtbar, dass er zur Nachricht gehört und sich mit
    /// einem Tippen zurückholen lässt.
    private func attachmentChip(_ attachment: Attachment) -> some View {
        Button {
            onPreviewAttachment(attachment)
        } label: {
            if attachment.kind.isImage {
                imageChipLabel(attachment)
            } else {
                fileChipLabel(attachment)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                onPreviewAttachment(attachment)
            } label: {
                if attachment.kind.isImage {
                    Label("Bild ansehen", systemImage: "eye")
                } else {
                    Label("Inhalt ansehen", systemImage: "doc.text.magnifyingglass")
                }
            }
            Button {
                onToggleAttachment(attachment)
            } label: {
                if attachment.isActive {
                    Label("Nicht mehr mitschicken", systemImage: "minus.circle")
                } else {
                    Label("Wieder mitschicken", systemImage: "plus.circle")
                }
            }
        }
        .accessibilityLabel(Loc.tr("Anhang %@", attachment.fileName))
        .accessibilityHint(attachment.isActive
                           ? Loc.tr("Wird bei Folgefragen mitgeschickt.")
                           : Loc.tr("Wird nicht mehr mitgeschickt."))
    }

    /// Die Kachel für Text, PDF und Quelltext: Symbol, Name, Kennzahlen.
    private func fileChipLabel(_ attachment: Attachment) -> some View {
        HStack(spacing: 8) {
            Image(systemName: attachment.kind.symbolName)
                .font(.caption)
                .foregroundStyle(attachment.isActive ? Theme.accent : Theme.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: attachment.fileName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .strikethrough(!attachment.isActive)
                Text(verbatim: attachmentDetail(attachment))
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surfaceAlt,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(attachment.isActive ? 1 : 0.55)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Die Kachel für ein Bild.
    ///
    /// Hier steht das Bild selbst und nicht ein Symbol mit Dateinamen: bei
    /// einem Bild ist das Aussehen der Inhalt. Wer drei Vorlagen angehängt
    /// hat, erkennt an „Foto 2.jpg" nicht, welche davon er gerade abschaltet.
    private func imageChipLabel(_ attachment: Attachment) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            AttachmentThumbnail(attachment: attachment, side: 140)
                .overlay {
                    // Abgeschaltet: sichtbar bleiben, aber erkennbar nicht
                    // mitgeschickt. Beim Bild reicht Blässe allein nicht –
                    // ein blasses Foto sieht aus wie ein blasses Foto.
                    if !attachment.isActive {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Theme.background.opacity(0.55))
                            .overlay {
                                Image(systemName: "minus.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                    }
                }
            Text(verbatim: attachmentDetail(attachment))
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// „PDF · 12 Seiten · ca. 8,4k Tokens · gekürzt"
    private func attachmentDetail(_ attachment: Attachment) -> String {
        var parts: [String] = []
        switch attachment.kind {
        case .pdf:  parts.append(Loc.tr("PDF"))
        case .code: parts.append(Loc.tr("Quelltext"))
        case .text: parts.append(Loc.tr("Text"))
        case .image: parts.append(Loc.tr("Bild"))
        }
        if let width = attachment.pixelWidth, let height = attachment.pixelHeight {
            parts.append(Loc.tr("%lld × %lld", width, height))
        }
        if let pages = attachment.pageCount {
            parts.append(Loc.tr("Seiten: %lld", pages))
        }
        parts.append(Loc.tr("ca. %@ Tokens", CostFormat.tokens(attachment.tokenEstimate)))
        if attachment.isTruncated {
            parts.append(Loc.tr("gekürzt"))
        }
        if !attachment.isActive {
            parts.append(Loc.tr("abgeschaltet"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Antwort

    private var assistantMessage: some View {
        HStack(alignment: .top, spacing: 12) {
            avatar

            VStack(alignment: .leading, spacing: 8) {
                // Reihenfolge ist sicherheitsrelevant: Markierung zuerst.
                if message.isFlagged && !isRevealed {
                    flaggedPlaceholder
                } else if message.isError {
                    errorBody
                } else if message.text.isEmpty && message.imageFileName == nil && !isStreaming {
                    Text("Keine Antwort erhalten.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    if !message.text.isEmpty {
                        MarkdownView(text: message.text)
                            .equatable()
                    }
                    if let name = message.imageFileName {
                        if let url = ImageStore.url(for: name) {
                            generatedImage(url, aspectRatio: message.imageAspectRatio)
                        } else {
                            // Die Nachricht kennt den Dateinamen, die Datei
                            // ist aber weg – etwa weil iOS den Container
                            // aufgeräumt hat. Das kommentarlos wegzulassen
                            // wäre die schlechtere Antwort.
                            Label("Dieses Bild liegt nicht mehr auf dem Gerät.",
                                  systemImage: "photo.badge.exclamationmark")
                                .font(.footnote)
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.vertical, 12)
                        }
                    }
                    if isStreaming {
                        TypingIndicator()
                    }
                }

                // Bei verdeckter Antwort **keine** Fußzeile. Sonst liessen sich
                // „Antwort kopieren" und „Vorlesen" auf einen Text anwenden,
                // den der Nutzer noch gar nicht freigegeben hat – die Zusage
                // aus Richtlinie 1.2, markierte Inhalte erst nach
                // ausdrücklichem Antippen zugänglich zu machen, wäre damit
                // gebrochen. „Melden" bleibt über die Warnkarte erreichbar.
                if !isStreaming && !(message.isFlagged && !isRevealed)
                    && (!message.text.isEmpty || message.totalTokens > 0
                        || message.imageFileName != nil) {
                    footer
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Erzeugtes Bild.
    ///
    /// Die eigentliche Ansicht steckt in `GeneratedImageView`. Hier stand
    /// vorher `AsyncImage(url:)` – die falsche Wahl für eine Datei aus dem
    /// eigenen Container, siehe `ImageFileLoader`.
    ///
    /// Gesichert wird über `PhotoLibrarySaver` (nur Schreibzugriff), deshalb
    /// steht `NSPhotoLibraryAddUsageDescription` in der `Info.plist`. Ohne
    /// diesen Zwecktext beendet iOS die App beim Antippen.
    private func generatedImage(_ url: URL, aspectRatio: Double?) -> some View {
        GeneratedImageView(url: url, aspectRatio: aspectRatio)
    }

    private var avatar: some View {
        Circle()
            .fill(message.isError ? Theme.danger.opacity(0.15) : Theme.accentSoft)
            .frame(width: avatarSize, height: avatarSize)
            .overlay {
                Image(systemName: message.isError ? "exclamationmark.triangle.fill" : "sparkle")
                    .font(.caption)
                    .foregroundStyle(message.isError ? Theme.danger : Theme.accent)
            }
            .accessibilityHidden(true)
    }

    private var errorBody: some View {
        // Bei Fehlern steht in `text` kein Modellinhalt, sondern eine
        // Meldung der App – die gehört übersetzt.
        Text(LocalizedStringKey(message.text))
            .font(.subheadline)
            .foregroundStyle(Theme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(tint: Theme.danger.opacity(0.08))
    }

    private var flaggedPlaceholder: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Inhalt vom Filter markiert", systemImage: "eye.slash.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.warning)
            Text("Diese Antwort könnte anstößige oder gefährliche Inhalte enthalten. Sie wird erst nach deinem ausdrücklichen Tippen angezeigt.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Button("Trotzdem anzeigen", action: onReveal)
                    .font(.footnote.weight(.semibold))
                Button("Melden", action: onReport)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.danger)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(tint: Theme.warning.opacity(0.10))
    }

    private var footer: some View {
        // `spacing: 0` und feste 44x44-Felder: die Tippflächen liegen damit
        // bündig aneinander, die Glyphen sitzen mittig darin und in gleichem
        // Abstand. Mit zusätzlichem Abstand zwischen den Feldern standen die
        // Symbole ungleichmäßig und rutschten zusammen nach rechts weg.
        HStack(alignment: .center, spacing: 0) {
            if showCost {
                MessageCostFooter(message: message)
                    .padding(.leading, 2)
            }

            Spacer(minLength: 8)

            if message.isReported {
                Label("Gemeldet", systemImage: "flag.fill")
                    .font(.caption2)
                    .foregroundStyle(Theme.warning)
                    .padding(.trailing, 6)
            }

            if hasCode {
                Button(action: onExportFiles) {
                    Image(systemName: "folder.badge.plus")
                        .font(.body)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .accessibilityLabel("Dateien aus dieser Antwort exportieren")
            }

            Button {
                UIPasteboard.general.string = message.text
                didCopy = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    didCopy = false
                }
            } label: {
                // 44x44: Apples Mindestgröße für Tippziele. Die Glyphe
                // selbst ist kleiner und sitzt mittig in dieser Fläche.
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.body)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .accessibilityLabel("Antwort kopieren")

            Menu {
                if hasCode {
                    Button(action: onExportFiles) {
                        Label("Dateien exportieren", systemImage: "folder.badge.plus")
                    }
                }
                if voiceEnabled {
                    Button(action: onSpeak) {
                        Label(isSpeaking ? "Vorlesen stoppen" : "Vorlesen",
                              systemImage: isSpeaking ? "speaker.slash" : "speaker.wave.2")
                    }
                }
                Divider()
                Button(role: .destructive, action: onReport) {
                    Label("Inhalt melden", systemImage: "flag")
                }
                if let modelID = message.modelID, !modelID.isEmpty {
                    Button(role: .destructive, action: onBlockModel) {
                        Label("Modell sperren", systemImage: "nosign")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Weitere Aktionen")
        }
        // Die 44er-Felder ragen rechts über den Text der Blase hinaus.
        // Ohne diesen Ausgleich stünde das letzte Symbol optisch zu weit
        // innen; mit ihm fluchtet es mit der Kante darüber.
        .padding(.trailing, -12)
        .padding(.top, -8)
    }
}

// MARK: - Schreibanzeige

struct TypingIndicator: View {
    @State private var isAnimating = false
    /// „Bewegung reduzieren" gilt auch für eine Dauerbewegung aus drei
    /// Punkten. Sie läuft, solange eine Antwort eintrifft – bei einer langen
    /// Antwort also minutenlang, und für manche Menschen ist genau das der
    /// Grund, warum sie die Einstellung eingeschaltet haben.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Theme.textSecondary)
                    .frame(width: 5, height: 5)
                    .opacity(reduceMotion ? 0.55 : (isAnimating ? 1 : 0.25))
                    .animation(
                        reduceMotion
                        ? nil
                        : .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.18),
                        value: isAnimating
                    )
            }
        }
        .onAppear { isAnimating = !reduceMotion }
        // Ohne .accessibilityElement hätte das Label kein Element, an dem es
        // hängen könnte – VoiceOver sägte gar nichts an.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Antwort wird geschrieben")
    }
}
