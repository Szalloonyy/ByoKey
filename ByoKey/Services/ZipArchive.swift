//
//  ZipArchive.swift
//  ByoKey
//
//  Minimaler ZIP-Schreiber. Bewusst selbst geschrieben statt Fremdbibliothek:
//
//  • Richtlinie 2.5.2 – die App lädt keinen Code nach und bindet nichts ein,
//    was bei der Prüfung erklärt werden müsste.
//  • Der Weg über NSFileCoordinator(.forUploading) erzeugt zwar auch ein ZIP,
//    ist aber nur halb dokumentiert und legt die Datei an einem Ort ab, den
//    das System jederzeit wieder aufräumen darf.
//  • Hier ist jedes Byte nachvollziehbar und ohne Gerät prüfbar.
//
//  Format: PKZIP, Methode 8 (Deflate) mit Rückfall auf 0 (unkomprimiert),
//  wenn die Kompression nichts bringt. Keine ZIP64-Erweiterung – für
//  Quelltextdateien liegt die 4-GB-Grenze weit außerhalb des Denkbaren.
//

import Foundation
import Compression

enum ZipArchive {

    struct Entry {
        let name: String
        let data: Data

        init(name: String, text: String) {
            self.name = name
            self.data = Data(text.utf8)
        }

        init(name: String, data: Data) {
            self.name = name
            self.data = data
        }
    }

    // MARK: - Öffentlich

    /// Packt die Einträge in ein ZIP im Speicher.
    static func archive(_ entries: [Entry], modified: Date = Date()) -> Data {
        var payload = Data()
        var central = Data()
        var count: UInt16 = 0

        let (dosTime, dosDate) = dosTimestamp(modified)

        for entry in entries {
            let nameBytes = Data(entry.name.utf8)
            guard nameBytes.count <= 0xFFFF else { continue }

            let crc = CRC32.checksum(entry.data)
            let deflated = deflate(entry.data)
            let stored = deflated ?? entry.data
            let method: UInt16 = deflated == nil ? 0 : 8
            let localOffset = UInt32(payload.count)

            // --- Lokaler Datei-Kopf ---
            put32(0x0403_4B50, into: &payload)      // Signatur
            put16(20, into: &payload)               // benötigte Version (2.0)
            put16(0x0800, into: &payload)           // Bit 11: Name ist UTF-8
            put16(method, into: &payload)
            put16(dosTime, into: &payload)
            put16(dosDate, into: &payload)
            put32(crc, into: &payload)
            put32(UInt32(stored.count), into: &payload)
            put32(UInt32(entry.data.count), into: &payload)
            put16(UInt16(nameBytes.count), into: &payload)
            put16(0, into: &payload)                // keine Zusatzfelder
            payload.append(nameBytes)
            payload.append(stored)

            // --- Eintrag im Zentralverzeichnis ---
            put32(0x0201_4B50, into: &central)      // Signatur
            put16(20, into: &central)               // erzeugt von Version 2.0
            put16(20, into: &central)               // benötigte Version
            put16(0x0800, into: &central)
            put16(method, into: &central)
            put16(dosTime, into: &central)
            put16(dosDate, into: &central)
            put32(crc, into: &central)
            put32(UInt32(stored.count), into: &central)
            put32(UInt32(entry.data.count), into: &central)
            put16(UInt16(nameBytes.count), into: &central)
            put16(0, into: &central)                // Zusatzfelder
            put16(0, into: &central)                // Kommentar
            put16(0, into: &central)                // Datenträger
            put16(0, into: &central)                // interne Attribute
            put32(0o100644 << 16, into: &central)   // Unix-Rechte rw-r--r--
            put32(localOffset, into: &central)
            central.append(nameBytes)

            count &+= 1
        }

        // --- Abschluss des Zentralverzeichnisses ---
        let centralOffset = UInt32(payload.count)
        var archive = payload
        archive.append(central)
        put32(0x0605_4B50, into: &archive)
        put16(0, into: &archive)                    // Datenträgernummer
        put16(0, into: &archive)                    // Datenträger mit Verzeichnisbeginn
        put16(count, into: &archive)
        put16(count, into: &archive)
        put32(UInt32(central.count), into: &archive)
        put32(centralOffset, into: &archive)
        put16(0, into: &archive)                    // Archivkommentar
        return archive
    }

    /// Schreibt das Archiv in einen temporären Ordner und liefert die Adresse.
    /// Von dort holt das Teilen-Blatt die Datei ab.
    static func write(_ entries: [Entry], filename: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("byokey-export", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent(sanitizeFilename(filename))
        // Vorherige Ausgabe mit gleichem Namen ersetzen.
        try? FileManager.default.removeItem(at: url)
        try archive(entries).write(to: url, options: .atomic)
        return url
    }

    /// Legt eine einzelne Datei zum Teilen ab.
    static func writeSingle(name: String, text: String, subfolder: String = "") throws -> URL {
        var directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("byokey-export", isDirectory: true)
        if !subfolder.isEmpty {
            directory = directory.appendingPathComponent(sanitizeFilename(subfolder), isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent(sanitizeFilename(name))
        try? FileManager.default.removeItem(at: url)
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    /// Legt alle Dateien einzeln in einem Ordner ab und liefert dessen Adresse.
    /// Grundlage der Seitenvorschau: relative Verweise wie
    /// `<link href="style.css">` funktionieren nur, wenn die Nachbardateien
    /// tatsächlich danebenliegen.
    static func writePreview(_ artifacts: [CodeArtifact]) throws -> URL {
        let directory = previewDirectory
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for artifact in artifacts {
            let relative = sanitizeRelativePath(artifact.filename)
            let target = directory.appendingPathComponent(relative)
            let parent = target.deletingLastPathComponent()
            if parent.path != directory.path {
                try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            let content = relative.lowercased().hasSuffix(".html")
                || relative.lowercased().hasSuffix(".htm")
                ? withContentSecurityPolicy(artifact.code)
                : artifact.code
            try? Data(content.utf8).write(to: target, options: .atomic)
        }
        return directory
    }

    /// Setzt eine Content-Security-Policy an den Anfang jeder HTML-Datei der
    /// Vorschau.
    ///
    /// **Warum das nötig ist:** `decidePolicyFor navigationAction` in der
    /// Vorschau fängt nur *Navigationen* ab – Haupt- und Unterrahmen. Für
    /// Unterressourcen ruft WebKit ihn gar nicht auf. Ohne diese Zeilen gingen
    /// also `<img src="https://…">`, ein entferntes Stylesheet, eine Webschrift
    /// sowie `fetch`, `XMLHttpRequest` und `navigator.sendBeacon` aus dem vom
    /// Modell erzeugten JavaScript ungefragt ins Netz. Der Antwortkörper würde
    /// zwar verworfen, die Anfrage samt Adresse hätte das Gerät aber verlassen –
    /// und damit wären gleich drei Zusagen falsch: „kein Byte ohne Zustimmung",
    /// „jede Netzadresse wird abgewiesen" und die Antwort „uneingeschränkter
    /// Webzugriff: nein" im Fragebogen zur Altersfreigabe.
    ///
    /// Erlaubt bleibt alles Lokale (`file:`, `data:`, `blob:`) samt eingebettetem
    /// JavaScript, damit die Vorschau ihren Zweck behält. Verboten ist jedes
    /// Schema, das ins Netz führt – CSP arbeitet mit Positivlisten, `http:` und
    /// `https:` stehen schlicht nicht darauf.
    static func withContentSecurityPolicy(_ html: String) -> String {
        let policy = [
            "default-src 'self' file: data: blob:",
            "script-src 'self' file: data: blob: 'unsafe-inline' 'unsafe-eval'",
            "style-src 'self' file: data: 'unsafe-inline'",
            "img-src 'self' file: data: blob:",
            "font-src 'self' file: data:",
            "media-src 'self' file: data: blob:",
            "connect-src 'self' file: data:",
            "frame-src 'self' file:",
            "object-src 'none'",
            "base-uri 'none'",
            "form-action 'none'"
        ].joined(separator: "; ")
        let tag = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">"

        // Muss vor der ersten Ressource stehen, sonst greift sie für diese
        // nicht mehr. `<head>` ist die richtige Stelle; fehlt es, kommt die
        // Zeile ganz nach vorn – Browser ergänzen den Kopf dann selbst.
        // Nicht auf „<head" prüfen: das trifft auch „<header>", und dort
        // ignorieren Browser die Regel vollständig – die Vorschau stünde dann
        // wieder offen. Deshalb genau die zwei gültigen Formen.
        for opening in ["<head>", "<head "] {
            guard let range = html.range(of: opening, options: .caseInsensitive) else { continue }
            guard let close = html.range(of: ">", range: range.lowerBound..<html.endIndex) else { continue }
            return html.replacingCharacters(in: close.upperBound..<close.upperBound, with: "\n" + tag)
        }
        if let range = html.range(of: "<html", options: .caseInsensitive),
           let close = html.range(of: ">", range: range.upperBound..<html.endIndex) {
            return html.replacingCharacters(in: close.upperBound..<close.upperBound,
                                            with: "\n<head>" + tag + "</head>")
        }
        return tag + "\n" + html
    }

    static var previewDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("byokey-vorschau", isDirectory: true)
    }

    /// Räumt den Vorschauordner auf. Getrennt vom Ausgabeordner, weil beide
    /// unabhängig voneinander offen und wieder zu sein können.
    static func clearPreview() {
        try? FileManager.default.removeItem(at: previewDirectory)
    }

    /// Räumt den Ausgabeordner auf. Wird beim Schließen des Blattes gerufen,
    /// damit keine Quelltexte länger als nötig im temporären Ordner liegen.
    static func clearExports() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("byokey-export", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        clearPreview()
    }

    /// Entfernt Pfadtrenner und Steuerzeichen aus einem Dateinamen.
    /// Ohne das könnte ein Modell mit "../../irgendwas" aus dem Ordner
    /// ausbrechen.
    static func sanitizeFilename(_ raw: String) -> String {
        var name = raw
            .replacingOccurrences(of: "\\", with: "/")
            .components(separatedBy: "/")
            .last ?? raw
        name = name.components(separatedBy: .controlCharacters).joined()
        name = name.replacingOccurrences(of: "..", with: ".")
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix(".") { name.removeFirst() }
        // Ein Name aus lauter Punkten ergäbe ".", und das zeigt auf den
        // Ordner selbst – removeItem() würde dann den Ausgabeordner samt
        // gerade geschriebenem Archiv löschen.
        if name.trimmingCharacters(in: CharacterSet(charactersIn: ".")).isEmpty { name = "" }
        if name.isEmpty { name = "datei.txt" }
        return String(name.prefix(120))
    }

    /// Wie `sanitizeFilename`, lässt aber Unterordner zu ("src/app.js").
    /// Jeder Bestandteil wird einzeln geprüft.
    static func sanitizeRelativePath(_ raw: String) -> String {
        let parts = raw
            .replacingOccurrences(of: "\\", with: "/")
            .components(separatedBy: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .map { component -> String in
                // Führender Punkt bleibt erhalten: ".gitignore" ist ein
                // gültiger Name, und "." bzw. ".." sind eine Zeile darüber
                // bereits herausgefiltert.
                let value = component.components(separatedBy: .controlCharacters).joined()
                return String(value.prefix(80))
            }
            .filter { !$0.isEmpty }

        guard !parts.isEmpty else { return "datei.txt" }
        return parts.suffix(4).joined(separator: "/")
    }

    // MARK: - Intern

    private static func deflate(_ data: Data) -> Data? {
        guard data.count > 64 else { return nil }
        let capacity = data.count
        var output = Data(count: capacity)

        let written = output.withUnsafeMutableBytes { destination -> Int in
            data.withUnsafeBytes { source -> Int in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                // COMPRESSION_ZLIB ist bei Apple das rohe DEFLATE-Format –
                // genau das, was ZIP-Methode 8 erwartet (kein zlib-Kopf).
                return compression_encode_buffer(destinationBase, capacity,
                                                 sourceBase, data.count,
                                                 nil, COMPRESSION_ZLIB)
            }
        }

        // 0 heißt "passt nicht in den Puffer" oder Fehler. Wird die Datei
        // durch Kompression nicht kleiner, lohnt sie sich nicht.
        guard written > 0, written < data.count else { return nil }
        return output.prefix(written)
    }

    private static func put16(_ value: UInt16, into data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private static func put32(_ value: UInt32, into data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private static func dosTimestamp(_ date: Date) -> (time: UInt16, date: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)

        // Das MS-DOS-Format kennt keine Jahre vor 1980.
        let year = min(max(parts.year ?? 1980, 1980), 2107)
        let month = min(max(parts.month ?? 1, 1), 12)
        let day = min(max(parts.day ?? 1, 1), 31)
        let hour = min(max(parts.hour ?? 0, 0), 23)
        let minute = min(max(parts.minute ?? 0, 0), 59)
        let second = min(max(parts.second ?? 0, 0), 59)

        let time = UInt16((hour << 11) | (minute << 5) | (second / 2))
        let dosDate = UInt16(((year - 1980) << 9) | (month << 5) | day)
        return (time, dosDate)
    }
}

// MARK: - Prüfsumme

enum CRC32 {
    private static let table: [UInt32] = (0...255).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
