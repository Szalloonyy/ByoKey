//
//  ImageStore.swift
//  ByoKey
//
//  Erzeugte Bilder liegen als einzelne Dateien im App-Container, nicht in der
//  Zustandsdatei.
//
//  Der Grund ist handfest: `byokey-state.json` wird bei jeder Änderung
//  komplett neu geschrieben. Ein einziges Bild in Base64 sind schnell zwei
//  Megabyte – die bei jedem getippten Zeichen mitgeschrieben würden. Die
//  Nachricht merkt sich deshalb nur den Dateinamen.
//

import Foundation

enum ImageStore {

    /// Ordner im App-Container. Wird beim Löschen aller Daten mit entfernt.
    ///
    /// Reine Pfadberechnung, **kein** Dateizugriff: `url(for:)` läuft beim
    /// Scrollen für jede Bildzeile durch, und dort noch ein `fileExists` plus
    /// ein `createDirectory` unterzubringen hiesse, drei Systemaufrufe pro
    /// Zeile pro Bildwiederholung zu bezahlen. Angelegt wird der Ordner dort,
    /// wo wirklich geschrieben wird.
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("byokey-bilder", isDirectory: true)
    }()

    private static func ensureDirectory() {
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func url(for name: String) -> URL? {
        // Nur der reine Dateiname zählt. Ein Name aus einer beschädigten
        // Zustandsdatei darf nicht aus dem Ordner herausführen.
        let clean = name.components(separatedBy: "/").last ?? name
        guard !clean.isEmpty, clean != ".", clean != ".." else { return nil }
        let target = directory.appendingPathComponent(clean)
        return FileManager.default.fileExists(atPath: target.path) ? target : nil
    }

    /// Legt ein Bild ab und liefert den Dateinamen für die Nachricht.
    @discardableResult
    static func save(_ data: Data, mimeType: String) -> String? {
        ensureDirectory()
        let name = "\(UUID().uuidString).\(fileExtension(for: mimeType, data: data))"
        let target = directory.appendingPathComponent(name)
        do {
            // Wie die Zustandsdatei: lesbar erst nach der ersten Entsperrung.
            try data.write(to: target,
                           options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return name
        } catch {
            return nil
        }
    }

    static func delete(_ name: String) {
        guard let target = url(for: name) else { return }
        try? FileManager.default.removeItem(at: target)
    }

    static func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Entfernt Bilder, auf die keine Nachricht mehr zeigt. Läuft beim Start:
    /// ein gelöschter Chat nimmt seine Bilder sonst nicht mit.
    static func removeOrphans(keeping used: Set<String>) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where !used.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Endung aus dem gemeldeten Typ – und wenn der fehlt oder falsch ist,
    /// aus den ersten Bytes. Die Anbieter sind sich bei diesem Feld nicht
    /// einig: mal `media_type`, mal `mime_type`, mal gar nichts.
    static func fileExtension(for mimeType: String, data: Data) -> String {
        switch mimeType.lowercased() {
        case let type where type.contains("png"):  return "png"
        case let type where type.contains("jpeg"), let type where type.contains("jpg"): return "jpg"
        case let type where type.contains("webp"): return "webp"
        case let type where type.contains("svg"):  return "svg"
        default: return sniff(data)
        }
    }

    /// Magische Bytes am Dateianfang.
    static func sniff(_ data: Data) -> String {
        let head = [UInt8](data.prefix(12))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if head.starts(with: [0xFF, 0xD8, 0xFF])       { return "jpg" }
        if head.count >= 12,
           Array(head[0..<4]) == Array("RIFF".utf8),
           Array(head[8..<12]) == Array("WEBP".utf8)   { return "webp" }
        return "png"
    }
}
