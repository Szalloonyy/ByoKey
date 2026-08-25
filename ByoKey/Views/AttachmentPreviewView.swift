//
//  AttachmentPreviewView.swift
//  ByoKey
//
//  Zeigt, was von einer angehängten Datei tatsächlich an den Anbieter geht.
//
//  Das ist keine Bequemlichkeit, sondern die Einlösung eines Versprechens:
//  die App sagt zu, dass der Nutzer sieht, was sein Gerät verlässt. Bei einem
//  PDF ist das nicht selbstverständlich – zwischen dem, was auf dem Papier
//  steht, und dem, was die Textebene hergibt, liegen manchmal Welten.
//

import SwiftUI
import UIKit

struct AttachmentPreviewView: View {
    @Environment(\.dismiss) private var dismiss

    let attachment: Attachment
    /// `nil`, wenn die Textdatei nicht mehr da ist.
    let text: String?

    var body: some View {
        NavigationStack {
            Group {
                if attachment.kind.isImage {
                    imageBody
                } else {
                    textBody
                }
            }
            .background { Theme.background.ignoresSafeArea() }
            .navigationTitle(Text(verbatim: attachment.fileName))
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top) { summary }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private var textBody: some View {
        Group {
            if let text, !text.isEmpty {
                ScrollView {
                    Text(verbatim: text)
                        .font(.footnote.monospaced())
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            } else {
                ContentUnavailableView("Inhalt nicht mehr vorhanden",
                                       systemImage: "doc.questionmark",
                                       description: Text("Der ausgelesene Text dieser Datei liegt nicht mehr auf dem Gerät. Häng die Datei erneut an, wenn die KI weiter darauf zugreifen soll."))
            }
        }
    }

    /// Beim Bild ist die Vorschau das Bild – und zwar genau das verkleinerte,
    /// das an den Anbieter geht, nicht das Original aus der Mediathek. Das ist
    /// der Sinn dieser Ansicht: zu zeigen, was das Gerät verlässt.
    private var imageBody: some View {
        Group {
            if AttachmentStore.url(for: attachment.storedFileName) != nil {
                ScrollView {
                    AttachmentFullImage(attachment: attachment)
                        .padding(16)
                }
            } else {
                ContentUnavailableView("Inhalt nicht mehr vorhanden",
                                       systemImage: "photo.badge.exclamationmark",
                                       description: Text("Dieses Bild liegt nicht mehr auf dem Gerät. Häng es erneut an, wenn die KI weiter darauf zugreifen soll."))
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: line)
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
            if attachment.isTruncated {
                Label {
                    Text(verbatim: Loc.tr("Gekürzt: übertragen werden die ersten %lld %% des Textes. Die KI wird darauf hingewiesen.",
                                          max(1, Int((attachment.transferredShare * 100).rounded(.down)))))
                } icon: {
                    Image(systemName: "scissors")
                }
                .font(.caption2)
                .foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
            }
            if !attachment.isActive {
                Label("Dieser Anhang wird gerade nicht mitgeschickt.",
                      systemImage: "minus.circle")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var line: String {
        var parts: [String] = [ByteFormat.string(attachment.byteCount)]
        if let width = attachment.pixelWidth, let height = attachment.pixelHeight {
            parts.append(Loc.tr("%lld × %lld", width, height))
        }
        if let pages = attachment.pageCount {
            parts.append(Loc.tr("Seiten: %lld", pages))
        }
        // Ein Bild hat keine Zeichen. Eine Null stünde hier nur im Weg.
        if !attachment.kind.isImage {
            parts.append(Loc.tr("Zeichen: %@", CostFormat.tokens(attachment.characterCount)))
        }
        parts.append(Loc.tr("ca. %@ Tokens", CostFormat.tokens(attachment.tokenEstimate)))
        return parts.joined(separator: " · ")
    }
}

/// Das Bild in voller Breite.
///
/// Eigene kleine Ansicht statt `AttachmentThumbnail`: die Kachel entpackt auf
/// 480 Bildpunkte und schneidet quadratisch zu – hier soll das ganze Bild in
/// seinem Seitenverhältnis zu sehen sein.
///
/// Entpackt wird auf `previewMaxPixel` und **nicht** höher. Alles darüber
/// landet in `ImageFileLoader` im Einzelplatz für die Vollbildansicht, und der
/// wird nur von `GeneratedImageView` (und von „Alle Daten löschen") wieder
/// freigegeben: ein einmal geöffneter
/// Anhang hielte sonst dauerhaft mehrere Megabyte fest, unerreichbar für die
/// Verdrängung bei Speicherwarnung. Ein angehängtes Bild ist ohnehin auf 1536
/// Bildpunkte verkleinert – der Unterschied wäre auf dem Blatt nicht zu sehen.
private struct AttachmentFullImage: View {
    let attachment: Attachment
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.surfaceAlt)
                    .frame(height: 240)
                    .overlay { ProgressView() }
            }
        }
        .task(id: attachment.storedFileName) {
            guard let url = AttachmentStore.url(for: attachment.storedFileName) else { return }
            let loaded = await Task.detached(priority: .userInitiated) {
                ImageFileLoader.load(url, maxPixel: ImageFileLoader.previewMaxPixel)
            }.value
            image = loaded
        }
    }
}
