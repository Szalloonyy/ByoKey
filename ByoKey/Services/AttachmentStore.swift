//
//  AttachmentStore.swift
//  ByoKey
//
//  Der ausgelesene Text angehängter Dateien liegt als eigene Datei im
//  App-Container – nicht in der Zustandsdatei.
//
//  Derselbe Grund wie bei den Bildern: `byokey-state.json` wird bei **jeder**
//  Änderung vollständig neu geschrieben, auch bei jedem gestreamten Token
//  einer laufenden Antwort. Ein angehängtes 200-Seiten-PDF sind rund 400 000
//  Zeichen; die bei jedem Token mitzuschreiben würde die App zum Stehen
//  bringen und die Platte unnötig beanspruchen. Die Nachricht merkt sich
//  deshalb nur den Dateinamen und die Kennzahlen.
//

import Foundation

enum AttachmentStore {

    /// Reine Pfadberechnung, kein Dateizugriff – wie bei `ImageStore`.
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("byokey-anhaenge", isDirectory: true)
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

    /// Legt den ausgelesenen Text ab und liefert den Dateinamen.
    static func save(_ text: String) -> String? {
        ensureDirectory()
        let name = "\(UUID().uuidString).txt"
        let target = directory.appendingPathComponent(name)
        do {
            try Data(text.utf8).write(to: target,
                                      options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return name
        } catch {
            return nil
        }
    }

    /// Legt ein vorbereitetes Bild ab und liefert den Dateinamen.
    static func saveImage(_ data: Data) -> String? {
        ensureDirectory()
        let name = "\(UUID().uuidString).jpg"
        let target = directory.appendingPathComponent(name)
        do {
            try data.write(to: target,
                           options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return name
        } catch {
            return nil
        }
    }

    /// Die abgelegten Bilddaten. `nil`, wenn die Datei fehlt.
    static func imageData(for name: String) -> Data? {
        guard let target = url(for: name) else { return nil }
        return try? Data(contentsOf: target)
    }

    /// Der abgelegte Text. `nil`, wenn die Datei fehlt – etwa nach einer
    /// Wiederherstellung, bei der nur die Zustandsdatei zurückkam.
    static func text(for name: String) -> String? {
        guard let target = url(for: name),
              let data = try? Data(contentsOf: target) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ name: String) {
        guard let target = url(for: name) else { return }
        try? FileManager.default.removeItem(at: target)
    }

    static func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Entfernt Texte, auf die keine Nachricht mehr zeigt.
    ///
    /// Läuft beim Start. Fängt zwei Fälle: einen gelöschten Chat, der seine
    /// Anhänge sonst nicht mitnähme – und eine Datei, die der Nutzer angehängt,
    /// die Nachricht dann aber nie abgeschickt hat.
    static func removeOrphans(keeping used: Set<String>) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where !used.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: - Anlegen

    /// Baut aus einem ausgelesenen Text einen Anhang und legt ihn ab.
    ///
    /// `byteLimit` ist die Grenze, die das gewählte Modell verkraftet – in
    /// **UTF-8-Bytes**, nicht in Zeichen. Das ist kein Detail: `TokenEstimator`
    /// rechnet mit Bytes, und ein Zeichen kann eines sein oder fünfundzwanzig.
    /// Nach Zeichen gekürzt, ergäbe ein japanischer Text das Dreifache der
    /// zugesagten Tokenzahl und ein Text voller Emoji das Sechsfache – der
    /// Anbieter lehnte die Anfrage dann wegen Kontextüberlauf ab, nachdem die
    /// App gerade noch versichert hatte, es passe.
    ///
    /// Wird gekürzt, merkt sich der Anhang die ursprüngliche Länge: die
    /// Anzeige sagt es dem Nutzer, der Kontext sagt es dem Modell. Sonst
    /// behauptet die KI, das ganze Dokument gelesen zu haben.
    ///
    /// Läuft absichtlich abseits des Hauptaktors – `count` über 20 MB Text ist
    /// eine Unicode-Segmentierung über zwanzig Millionen Bytes.
    /// `byteLimit == nil` heisst ausdrücklich **keine Grenze**.
    ///
    /// Kein Zahlen-Sentinel wie 0: „kürze auf 0 Bytes" und „kürze gar nicht"
    /// sind zwei verschiedene Dinge, und die Verwechslung wäre teuer gewesen –
    /// ein erschöpftes Budget hätte die Datei ungekürzt durchgelassen, während
    /// der Dialog gerade eine Kürzung zugesagt hatte.
    nonisolated static func make(from extraction: FileTextExtractor.Extraction,
                                 byteLimit: Int?) -> Attachment? {
        let limited = byteLimit.map { clip(extraction.text, toBytes: $0) } ?? extraction.text
        guard let fileName = save(limited) else { return nil }

        let characters = limited.count
        return Attachment(fileName: extraction.fileName,
                          kind: extraction.kind,
                          byteCount: extraction.byteCount,
                          characterCount: characters,
                          // Schon beim Auslesen Gekürztes zählt mit: sonst
                          // wäre eine Kürzung an der 400 000-Zeichen-Grenze
                          // unsichtbar.
                          originalCharacterCount: max(characters, extraction.fullCharacterCount),
                          pageCount: extraction.pageCount,
                          tokenEstimate: TokenEstimator.estimate(limited),
                          storedFileName: fileName)
    }

    /// Legt ein vorbereitetes Bild ab und baut den Anhang dazu.
    ///
    /// Bilder werden **nicht** gekürzt – verkleinert wurden sie schon beim
    /// Vorbereiten. `characterCount` bleibt null: ein Bild hat keinen Text,
    /// und eine erfundene Zahl stünde nur falsch in der Anzeige.
    nonisolated static func make(from prepared: ImageAttachmentCoder.Prepared) -> Attachment? {
        guard let fileName = saveImage(prepared.data) else { return nil }
        return Attachment(fileName: prepared.fileName,
                          kind: .image,
                          byteCount: prepared.data.count,
                          characterCount: 0,
                          originalCharacterCount: 0,
                          pageCount: nil,
                          tokenEstimate: ImageAttachmentCoder.tokenEstimate(width: prepared.width,
                                                                           height: prepared.height),
                          storedFileName: fileName,
                          pixelWidth: prepared.width,
                          pixelHeight: prepared.height)
    }

    /// Schneidet an einer Zeichengrenze ab, gezählt in UTF-8-Bytes.
    ///
    /// Zeichenweise und nicht über `data.prefix`: mitten in einer
    /// Mehrbyte-Folge abzuschneiden ergäbe ungültiges UTF-8, und die Datei
    /// liesse sich hinterher nicht mehr einlesen.
    nonisolated static func clip(_ text: String, toBytes limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var out = String()
        out.reserveCapacity(limit)
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            if used + size > limit { break }
            out.append(character)
            used += size
        }
        return out
    }
}
