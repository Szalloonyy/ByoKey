//
//  ImageFileLoader.swift
//  ByoKey
//
//  Erzeugte Bilder aus dem eigenen Ordner laden – ohne den URL-Lade-Stack.
//
//  Vorher stand hier `AsyncImage(url:)`. Das ist für Netzadressen gedacht und
//  geht deshalb durch `URLSession` samt Zwischenspeicher. Für eine Datei im
//  eigenen Container ist dieser Umweg nicht nur überflüssig, er war auch die
//  Ursache eines Fehlers: das Bild erschien direkt nach dem Erzeugen, und beim
//  nächsten Öffnen desselben Chats stand dort „Das Bild lässt sich nicht
//  anzeigen." Die Datei lag die ganze Zeit unversehrt im Ordner.
//
//  Eine Datei liest man mit dem Dateisystem. `ImageIO` kann dabei gleich
//  verkleinern, statt ein 1024×1024-PNG in voller Größe zu entpacken und
//  danach auf Handybreite zu schieben – das spart bei mehreren Bildern in
//  einem Chat sehr viel Arbeitsspeicher.
//

import Foundation
import ImageIO
import UIKit

/// Ein einzelner Platz für das Bild der Vollbildansicht.
///
/// Getrennt vom Vorschauspeicher, weil ein Eintrag bei 3000 Bildpunkten rund
/// 36 MB wiegt – im gemeinsamen Speicher hätte er alles andere verdrängt.
/// Wird beim Schliessen der Ansicht wieder freigegeben.
nonisolated(unsafe) private var fullSizeKey: String?
nonisolated(unsafe) private var fullSizeImage: UIImage?
nonisolated(unsafe) private var fullSizeGeneration = 0
private let fullSizeLock = NSLock()

/// Seitenverhältnisse. Getrennt von den Bildern und mit viel mehr Platz: ein
/// Verhältnis sind acht Byte, ein entpacktes Bild sind Megabyte. Die Ansicht
/// braucht das Verhältnis, **bevor** das Bild geladen ist – sonst wächst die
/// Blase beim Erscheinen des Bildes und der Verlauf springt.
nonisolated(unsafe) private let aspectRatios = NSCache<NSString, NSNumber>()

enum ImageFileLoader {

    /// Kantenlänge für die Anzeige im Chat.
    ///
    /// Die Blase ist auf einem grossen iPhone gut 330 Punkte breit, also rund
    /// 1000 Bildpunkte bei dreifacher Auflösung; auf dem iPad ist die Spalte
    /// auf 820 Punkte begrenzt, bei doppelter Auflösung also rund 1400. 1200
    /// ist der Kompromiss: auf dem iPhone mit Reserve, auf dem iPad ohne
    /// sichtbares Hochskalieren – und mit 5,8 MB je Bild noch bezahlbar.
    static let previewMaxPixel: CGFloat = 1200

    /// Obergrenze für die Vollbildansicht. Erlaubt das Hineinzoomen, ohne dass
    /// ein sehr großes Bild den Speicher sprengt: 3000² × 4 Byte sind bereits
    /// 36 MB, und darüber wird es schnell gefährlich.
    static let fullMaxPixel: CGFloat = 3000

    /// Lädt die Datei und verkleinert sie dabei auf `maxPixel` an der längeren
    /// Kante.
    ///
    /// Läuft absichtlich **nicht** auf dem Hauptaktor: das Entpacken eines
    /// großen Bildes dauert lange genug, um eine Bildlaufbewegung stocken zu
    /// lassen. `kCGImageSourceShouldCacheImmediately` sorgt dafür, dass die
    /// Arbeit auch wirklich hier passiert – ohne den Schlüssel entpackt
    /// CoreGraphics erst beim Zeichnen, also doch wieder auf dem Hauptthread.
    static func load(_ url: URL, maxPixel: CGFloat) -> UIImage? {
        let key = cacheKey(url, maxPixel)

        if isPreview(maxPixel) {
            if let held = ImageMemory.shared.image(for: key) { return held }
            guard let image = decode(url, maxPixel: maxPixel) else { return nil }
            ImageMemory.shared.store(image, for: key)
            return image
        }

        // Treffer-Prüfung und Generation in **einem** Abschnitt: läge ein
        // `releaseFullSize()` dazwischen, würde bereits die neue Generation
        // gelesen und das Bild landete nach dem Entpacken doch im Speicher.
        fullSizeLock.lock()
        if fullSizeKey == key, let image = fullSizeImage {
            fullSizeLock.unlock()
            return image
        }
        let generation = fullSizeGeneration
        fullSizeLock.unlock()

        guard let image = decode(url, maxPixel: maxPixel) else { return nil }

        fullSizeLock.lock()
        // Wurde die Ansicht während des Entpackens geschlossen, wären die
        // 36 MB sonst gerade wieder hineingeschrieben worden – und blieben
        // stehen, bis das nächste Bild geöffnet wird.
        if generation == fullSizeGeneration {
            fullSizeKey = key
            fullSizeImage = image
        }
        fullSizeLock.unlock()
        return image
    }

    /// Gibt das Bild der Vollbildansicht frei. Ohne diesen Aufruf blieben 36 MB
    /// stehen, bis das nächste Bild geöffnet wird.
    static func releaseFullSize() {
        fullSizeLock.lock()
        fullSizeGeneration &+= 1
        fullSizeKey = nil
        fullSizeImage = nil
        fullSizeLock.unlock()
    }

    private static func isPreview(_ maxPixel: CGFloat) -> Bool {
        maxPixel <= previewMaxPixel
    }

    /// Nur aus dem Zwischenspeicher – ohne Datei-Zugriff, ohne Entpacken.
    ///
    /// Damit kann die Ansicht ein bereits gesehenes Bild **sofort beim ersten
    /// Zeichnen** anzeigen. Der Verlauf gibt entpackte Bilder frei, sobald
    /// ihre Zeile aus dem Bild scrollt (siehe `GeneratedImageView`); ohne
    /// diesen Weg begänne jede zurückkehrende Zeile wieder bei der
    /// Ladeanzeige.
    static func cached(_ url: URL, maxPixel: CGFloat) -> UIImage? {
        guard isPreview(maxPixel) else { return nil }
        return ImageMemory.shared.image(for: cacheKey(url, maxPixel))
    }

    /// Steckt die Bilder eines Chats fest, solange er offen ist.
    ///
    /// Nur die letzten paar: ein Chat mit fünfzig Bildern hielte sonst
    /// hunderte Megabyte unverdrängbar fest. Gebraucht wird der Riegel
    /// ohnehin für das Ende des Verlaufs – dort setzt die Ansicht auf.
    static func pinPreviews(fileNames: [String]) {
        let recent = fileNames.suffix(12)
        ImageMemory.shared.pin(recent.map { key(fileName: $0, maxPixel: previewMaxPixel) })
    }

    /// Das Seitenverhältnis, mit dem die Blase ihren Platz reserviert.
    /// `nil` heisst: das System kann die Datei nicht anzeigen (SVG etwa) –
    /// dann soll gar kein Kasten reserviert werden.
    ///
    /// **Genau eine Quelle, und der Wert wird festgeschrieben.** Das ist der
    /// Punkt der ganzen Übung: würde die Ansicht das Verhältnis mal aus der
    /// Nachricht, mal aus dem entpackten Bild und mal aus dem Dateikopf
    /// nehmen, käme beim Zurückscrollen ein anderer Wert heraus als beim
    /// ersten Aufbau – und die Zeile spränge trotz Platzhalter. Besonders
    /// hinterhältig: bei EXIF-Orientierung 5–8 ist das entpackte Bild gedreht,
    /// das Verhältnis also der Kehrwert des Kopfwerts.
    static func reservedAspectRatio(for url: URL, known: Double?) -> Double? {
        let key = url.lastPathComponent as NSString
        if let cached = aspectRatios.object(forKey: key) {
            // 0 ist die Merkmarke für „kann iOS nicht anzeigen".
            return cached.doubleValue > 0 ? cached.doubleValue : nil
        }
        if let known, known.isFinite, known > 0 {
            aspectRatios.setObject(NSNumber(value: known), forKey: key)
            return known
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            aspectRatios.setObject(NSNumber(value: 0), forKey: key)
            return nil
        }
        let ratio = aspectRatio(in: source) ?? 1
        aspectRatios.setObject(NSNumber(value: ratio), forKey: key)
        return ratio
    }

    /// Dasselbe aus Daten, die ohnehin schon im Speicher liegen – für den
    /// Moment, in dem ein Bild vom Anbieter ankommt. Der Wert wandert dann in
    /// die Nachricht und übersteht damit auch einen Neustart.
    static func aspectRatio(of data: Data) -> Double? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return aspectRatio(in: source)
    }

    private static func aspectRatio(in source: CGImageSource) -> Double? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        // `kCGImagePropertyPixelWidth` ist die rohe Pixelbreite, ohne die
        // Drehung aus den EXIF-Daten. Beim Entpacken wird sie angewandt
        // (`kCGImageSourceCreateThumbnailWithTransform`) – ohne diese
        // Umkehrung stünden Kopfwert und Bild bei gedrehten Aufnahmen
        // hochkant gegeneinander.
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let isRotated = (5...8).contains(orientation)
        return isRotated ? height / width : width / height
    }

    /// `true`, wenn das System das Format überhaupt anzeigen kann. SVG kann es
    /// nicht – dafür braucht die Ansicht eine eigene, ehrlichere Meldung als
    /// „lässt sich nicht anzeigen“.
    static func isDisplayable(_ url: URL) -> Bool {
        CGImageSourceCreateWithURL(url as CFURL, nil) != nil
    }

    /// Der Dateiname genügt als Schlüssel – er ist eine UUID. Die Kantenlänge
    /// gehört mit hinein, damit Vorschau und Vollbild nicht kollidieren.
    ///
    /// **Eine** Funktion für alle Stellen: baut das Festpinnen den Schlüssel
    /// selbst nach, wird es bei der kleinsten Abweichung still wirkungslos.
    static func key(fileName: String, maxPixel: CGFloat) -> String {
        "\(fileName)#\(Int(maxPixel))"
    }

    private static func cacheKey(_ url: URL, _ maxPixel: CGFloat) -> String {
        key(fileName: url.lastPathComponent, maxPixel: maxPixel)
    }

    private static func decode(_ url: URL, maxPixel: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            // Kein Bildformat, das ImageIO kennt – etwa SVG.
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return UIImage(cgImage: cgImage)
        }
        if let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return UIImage(cgImage: cgImage)
        }
        // Letzter Versuch über UIKit. Manche Formate kommen hier durch,
        // wenn ImageIO sie nicht als Quelle akzeptiert hat.
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }
}
