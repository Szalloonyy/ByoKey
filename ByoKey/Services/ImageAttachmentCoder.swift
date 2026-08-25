//
//  ImageAttachmentCoder.swift
//  ByoKey
//
//  Ein eigenes Bild für die KI vorbereiten: verkleinern, als JPEG kodieren,
//  Kosten schätzen.
//
//  Warum überhaupt verkleinern? Ein Foto vom iPhone ist 4032 × 3024 Bildpunkte
//  und wiegt als Base64 rund vier Megabyte. Übertragen würde das nicht nur
//  lange dauern – es kostet auch: Modelle rechnen Bilder in Kacheln ab, und
//  die Zahl der Kacheln wächst mit der Fläche. Bei 1536 Bildpunkten an der
//  langen Kante erkennt jedes heutige Seh-Modell alles, was es erkennen kann,
//  und die Anfrage bleibt bezahlbar.
//

import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

enum ImageAttachmentCoder {

    /// Kantenlänge, auf die verkleinert wird.
    ///
    /// 1536 ist kein runder Zufallswert: die verbreiteten Seh-Modelle zerlegen
    /// ein Bild in Kacheln von 512 Bildpunkten. 1536 sind genau drei Kacheln –
    /// eine Kante darüber kostet eine ganze Kachelreihe mehr, ohne dass mehr
    /// zu erkennen wäre.
    static let maxPixel: CGFloat = 1536

    /// JPEG statt PNG: ein Foto als PNG ist um ein Vielfaches grösser, ohne
    /// dass ein Modell mehr darin sähe. Für Bildschirmfotos mit feinem Text
    /// ist 0,85 hoch genug, dass er lesbar bleibt.
    static let jpegQuality: CGFloat = 0.85

    /// Obergrenze für die Ausgangsdatei.
    static let maxSourceBytes = 40 * 1024 * 1024

    struct Prepared {
        var fileName: String
        var data: Data
        var width: Int
        var height: Int
    }

    enum Failure: LocalizedError, Equatable {
        case unreadable
        case tooLarge(bytes: Int)
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return Loc.tr("Dieses Bild lässt sich nicht lesen. Versuche es mit einem anderen Format – JPEG, PNG oder HEIC.")
            case .tooLarge(let bytes):
                return Loc.tr("Das Bild ist mit %@ zu groß. Höchstens %@ sind möglich.",
                              ByteFormat.string(bytes), ByteFormat.string(maxSourceBytes))
            case .encodingFailed:
                return Loc.tr("Das Bild konnte nicht für den Versand vorbereitet werden.")
            }
        }
    }

    /// Was der Dateiauswähler an Bildern anbietet.
    static let readableTypes: [UTType] = [.image, .jpeg, .png, .heic, .heif, .gif, .webP, .tiff]

    /// Ist das überhaupt ein Bild?
    ///
    /// Erst der eingetragene Typ, dann die Endung: nicht jede Datei aus der
    /// Dateien-App trägt einen erkannten Typ.
    nonisolated static func isImage(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .image)
        }
        let known: Set<String> = ["jpg", "jpeg", "png", "heic", "heif",
                                  "gif", "webp", "tiff", "tif", "bmp"]
        return known.contains(url.pathExtension.lowercased())
    }

    // MARK: - Vorbereiten

    /// Aus einer Adresse (Dateien-App).
    nonisolated static func prepare(url: URL) throws -> Prepared {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        // `resourceValues(forKeys: [.fileSizeKey])` und **nicht**
        // `FileManager.attributesOfItem`: letzteres liefert die Zeitstempel
        // der Datei gleich mit, und Apples Prüfung beim Hochladen zählt
        // Zeitstempel-Zugriffe zu den Schnittstellen, die einen erklärten
        // Grund im Privacy Manifest brauchen. Gebraucht wird hier nur die
        // Grösse – also auch nur die holen.
        guard let byteCount = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw Failure.unreadable
        }
        guard byteCount <= maxSourceBytes else { throw Failure.tooLarge(bytes: byteCount) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw Failure.unreadable
        }
        return try encode(source, fileName: url.lastPathComponent)
    }

    /// Aus Bytes (Fotomediathek). Der Name ist dort nicht immer bekannt.
    nonisolated static func prepare(data: Data, fileName: String) throws -> Prepared {
        guard data.count <= maxSourceBytes else { throw Failure.tooLarge(bytes: data.count) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw Failure.unreadable
        }
        return try encode(source, fileName: fileName)
    }

    private nonisolated static func encode(_ source: CGImageSource,
                                           fileName: String) throws -> Prepared {
        // `kCGImageSourceCreateThumbnailWithTransform` wendet die Drehung aus
        // den EXIF-Daten an. Ohne das käme ein hochkant aufgenommenes Foto
        // quer beim Modell an – und es beschriebe brav ein gekipptes Motiv.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw Failure.unreadable
        }
        guard let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: jpegQuality) else {
            throw Failure.encodingFailed
        }
        return Prepared(fileName: displayName(for: fileName),
                        data: data,
                        width: cgImage.width,
                        height: cgImage.height)
    }

    /// Der Anzeigename bekommt die Endung des **gesendeten** Formats.
    /// Ein „foto.heic", das als JPEG hinausgeht, wäre eine falsche Auskunft.
    private nonisolated static func displayName(for fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        let clean = base.isEmpty ? "Bild" : base
        return "\(clean).jpg"
    }

    // MARK: - Kosten

    /// Grobe Schätzung der Tokens, die ein Bild kostet.
    ///
    /// Nach der Kachelrechnung der verbreiteten Seh-Modelle: ein Grundbetrag
    /// plus ein Betrag je Kachel von 512 Bildpunkten. Die Anbieter rechnen im
    /// Detail unterschiedlich – deshalb steht in der Oberfläche „ca." davor,
    /// und abgerechnet wird ohnehin nach dem, was der Anbieter zurückmeldet.
    nonisolated static func tokenEstimate(width: Int, height: Int) -> Int {
        guard width > 0, height > 0 else { return 85 }
        let columns = Int((Double(width) / 512).rounded(.up))
        let rows = Int((Double(height) / 512).rounded(.up))
        return 85 + 170 * max(1, columns) * max(1, rows)
    }

    /// `data:image/jpeg;base64,…` – die Form, die sowohl die Chat-Schnittstelle
    /// als auch `input_references` bei OpenRouter entgegennimmt.
    nonisolated static func dataURL(_ data: Data) -> String {
        "data:image/jpeg;base64," + data.base64EncodedString()
    }
}
