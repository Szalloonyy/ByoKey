//
//  AttachmentThumbnail.swift
//  ByoKey
//
//  Vorschaubild eines angehängten Bildes.
//
//  Eigene Ansicht statt `AsyncImage`: die Datei liegt im App-Container, und
//  `AsyncImage` ginge dafür durch den URL-Lade-Stack. Genau dieser Umweg war
//  schon einmal die Ursache dafür, dass ein Bild nach dem Verlassen des Chats
//  nicht mehr angezeigt wurde – siehe `ImageFileLoader`.
//

import SwiftUI
import UIKit

struct AttachmentThumbnail: View {
    let attachment: Attachment
    var side: CGFloat = 120

    /// Aus dem Zwischenspeicher vorbelegt, damit ein schon gesehenes Bild
    /// beim Zurückscrollen nicht wieder mit einem grauen Kasten beginnt.
    @State private var image: UIImage?

    init(attachment: Attachment, side: CGFloat = 120) {
        self.attachment = attachment
        self.side = side
        // Ohne Dateizugriff: `AttachmentStore.url(for:)` fragt das Dateisystem
        // (`fileExists`), und dieser Initialisierer läuft in der Kachelleiste
        // über dem Eingabefeld bei **jedem** Tastendruck erneut. Aus dem
        // Zwischenspeicher zu lesen genügt hier – ist nichts drin, lädt
        // `task` gleich darauf ohnehin von der Platte.
        _image = State(initialValue: ImageMemory.shared.image(
            for: ImageFileLoader.key(fileName: attachment.storedFileName,
                                     maxPixel: Self.decodePixel)))
    }

    /// Einmal für alle Grössen entpackt: die Kachel in der Nachricht ist
    /// 140 Punkte breit, auf einem Gerät mit dreifacher Auflösung also gut
    /// 420 Bildpunkte. Ein zweiter Eintrag für die kleine Kachel über dem
    /// Eingabefeld brächte nichts als einen zweiten Speicherplatz.
    private static let decodePixel: CGFloat = 480

    var body: some View {
        ZStack {
            Theme.surfaceAlt
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        }
        .task(id: attachment.storedFileName) {
            guard image == nil,
                  let url = AttachmentStore.url(for: attachment.storedFileName) else { return }
            // Die Kantenlänge **vorher** in eine lokale Konstante holen.
            //
            // `AttachmentThumbnail` ist eine `View` und damit an den
            // Hauptaktor gebunden – seine statischen Eigenschaften also auch.
            // Ein `Task.detached` läuft ausserhalb; `Self.decodePixel` von
            // dort zu lesen ist in Swift 6 ein Fehler und in Swift 5 bereits
            // eine Warnung. Ein `CGFloat` ist `Sendable`, die Kopie darf
            // mitgehen.
            let maxPixel = Self.decodePixel
            // Abseits des Hauptaktors: das Entpacken eines Bildes dauert lange
            // genug, um eine Bildlaufbewegung stocken zu lassen.
            let loaded = await Task.detached(priority: .userInitiated) {
                ImageFileLoader.load(url, maxPixel: maxPixel)
            }.value
            image = loaded
        }
    }
}
