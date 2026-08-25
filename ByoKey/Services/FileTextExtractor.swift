//
//  FileTextExtractor.swift
//  ByoKey
//
//  Text aus angehängten Dateien holen – auf dem Gerät, ohne Netz.
//
//  Was hier herauskommt, geht anschliessend als Teil der Nachricht an den
//  KI-Anbieter. Deshalb zwei Grundsätze:
//
//  1. **Nur Text.** Eine Datei, aus der sich kein lesbarer Text gewinnen
//     lässt, wird abgewiesen und nicht etwa als Byte-Salat übertragen. Das
//     schützt nicht nur die Antwortqualität, sondern auch das Geld des
//     Nutzers: 5 MB Binärdaten in Base64 wären ein vierstelliger Tokenbetrag
//     für nichts.
//  2. **Ehrliche Fehlermeldungen.** Ein eingescanntes PDF ohne Textebene ist
//     der häufigste Fall, in dem „nichts passiert". Die App sagt dann, woran
//     es liegt, statt eine leere Datei anzuhängen.
//

import Foundation
import PDFKit
import UniformTypeIdentifiers

enum FileTextExtractor {

    /// Was aus einer Datei herauskam – noch ungekürzt.
    struct Extraction {
        var fileName: String
        var text: String
        var byteCount: Int
        var kind: Attachment.Kind
        /// Nur bei PDF – und zwar die Zahl der **gelesenen** Seiten, nicht die
        /// des Dokuments. Bricht das Auslesen an der Obergrenze ab, wäre die
        /// volle Seitenzahl eine Falschangabe.
        var pageCount: Int?
        /// Zeichen des vollständigen Textes, bevor `maxCharacterCount` griff.
        ///
        /// Ohne diesen Wert wäre eine Kürzung schon **beim Auslesen** unsichtbar:
        /// die Kachel zeigte keine Kürzung an, und der Kontext bekäme den
        /// normalen Dateikopf – die KI hielte zwei Drittel eines Buches für das
        /// ganze.
        var fullCharacterCount: Int
    }

    enum Failure: LocalizedError, Equatable {
        case noAccess
        case pdfUnreadable
        case tooLarge(bytes: Int)
        case binary
        case pdfLocked
        case pdfWithoutText
        case empty

        /// Der deutsche Text ist zugleich der Schlüssel im Katalog.
        var errorDescription: String? {
            switch self {
            case .noAccess:
                return Loc.tr("Auf die Datei konnte nicht zugegriffen werden. Bitte wähle sie erneut aus.")
            case .pdfUnreadable:
                return Loc.tr("Dieses PDF lässt sich nicht öffnen. Möglicherweise ist die Datei beschädigt.")
            case .tooLarge(let bytes):
                return Loc.tr("Die Datei ist mit %@ zu groß. Höchstens %@ sind möglich.",
                              ByteFormat.string(bytes), ByteFormat.string(maxByteCount))
            case .binary:
                return Loc.tr("Diese Datei enthält keinen lesbaren Text. Anhängen lassen sich PDF, Textdateien und Quelltext.")
            case .pdfLocked:
                return Loc.tr("Das PDF ist mit einem Kennwort geschützt und lässt sich nicht lesen.")
            case .pdfWithoutText:
                return Loc.tr("Dieses PDF enthält nur Bilder – zum Beispiel einen Scan. Es steckt kein Text darin, den die App auslesen könnte.")
            case .empty:
                return Loc.tr("Die Datei ist leer.")
            }
        }
    }

    /// Obergrenze für die Rohdatei.
    ///
    /// Grosszügig gewählt: ein PDF mit 300 Seiten wiegt schnell 20 MB, und
    /// die eigentliche Grenze ist ohnehin nicht die Dateigrösse, sondern das
    /// Kontextfenster des Modells – darum kümmert sich die Ansicht.
    static let maxByteCount = 25 * 1024 * 1024

    /// Obergrenze für den ausgelesenen Text. Rund 100 000 Tokens; darüber
    /// hinaus kann kein heute erhältliches Modell etwas anfangen, und die
    /// Zeichenkette selbst würde den Arbeitsspeicher belasten.
    static let maxCharacterCount = 400_000

    /// Was der Dateiauswähler anbietet.
    ///
    /// Bewusst eng: was hier nicht steht, lässt sich gar nicht erst auswählen
    /// und ist ausgegraut. Das ist ehrlicher, als jede Datei anzunehmen und
    /// danach die Hälfte abzulehnen. `.text` und `.sourceCode` sind Oberbegriffe –
    /// Markdown, PHP, Swift, Python und Dutzende weitere erben davon und sind
    /// damit eingeschlossen, ohne einzeln genannt zu werden.
    static let readableTypes: [UTType] = [
        .pdf,
        .text,
        .plainText,
        .sourceCode,
        .json,
        .xml,
        .html,
        .commaSeparatedText,
        .yaml,
        .log
    ]

    // MARK: - Lesen

    /// Liest eine vom Dateiauswähler gelieferte Adresse aus.
    ///
    /// Läuft absichtlich **nicht** auf dem Hauptaktor: ein 20-MB-PDF zu
    /// zerlegen dauert Sekunden, und die Oberfläche soll dabei nicht stehen.
    nonisolated static func extract(from url: URL) throws -> Extraction {
        // Dateien aus der Dateien-App liegen ausserhalb des App-Containers.
        // Ohne diesen Riegel ist jeder Lesezugriff darauf verboten.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        // `resourceValues(forKeys: [.fileSizeKey])` und **nicht**
        // `FileManager.attributesOfItem`: letzteres liefert die Zeitstempel
        // der Datei gleich mit, und Apples Prüfung beim Hochladen zählt
        // Zeitstempel-Zugriffe zu den Schnittstellen, die einen erklärten
        // Grund im Privacy Manifest brauchen. Gebraucht wird hier nur die
        // Grösse – also auch nur die holen.
        guard let byteCount = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            // Keine Auskunft über die Datei heisst fast immer: kein Lesezugriff.
            // „Die Datei ist leer" wäre hier die falsche Fährte.
            throw Failure.noAccess
        }
        guard byteCount <= maxByteCount else { throw Failure.tooLarge(bytes: byteCount) }
        guard byteCount > 0 else { throw Failure.empty }

        let fileName = url.lastPathComponent
        if isPDF(url) {
            let result = try pdfText(at: url)
            return Extraction(fileName: fileName,
                              text: result.text,
                              byteCount: byteCount,
                              kind: .pdf,
                              pageCount: result.pagesRead,
                              fullCharacterCount: result.fullCharacterCount)
        }

        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw Failure.noAccess
        }
        guard let text = decodeText(data) else { throw Failure.binary }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.empty
        }

        // Auch Textdateien haben eine Obergrenze – und eine Kürzung hier muss
        // genauso sichtbar werden wie eine später wegen des Kontextfensters.
        let full = text.count
        let limited = full > maxCharacterCount ? String(text.prefix(maxCharacterCount)) : text

        return Extraction(fileName: fileName,
                          text: limited,
                          byteCount: byteCount,
                          kind: isSourceCode(url) ? .code : .text,
                          pageCount: nil,
                          fullCharacterCount: full)
    }

    // MARK: - PDF

    private nonisolated static func pdfText(at url: URL) throws -> (text: String,
                                                                    pagesRead: Int,
                                                                    fullCharacterCount: Int) {
        guard let document = PDFDocument(url: url) else { throw Failure.pdfUnreadable }
        if document.isEncrypted && document.isLocked { throw Failure.pdfLocked }

        var parts: [String] = []
        var characters = 0
        var pagesRead = 0
        // Erst die tatsächlich gelesene Menge zählen, dann entscheiden, ob
        // abgebrochen wird. Die volle Zeichenzahl ergibt sich aus allen
        // Seiten – auch denen, die nicht mehr mitkommen.
        var fullCharacters = 0
        var stopped = false

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let text = page.string else { continue }
            fullCharacters += text.count
            if stopped { continue }
            // Seitenzahl mitgeben: fragt der Nutzer später „was steht auf
            // Seite 12", findet das Modell die Stelle nur so.
            parts.append(Loc.tr("[Seite %lld]", index + 1) + "\n" + text)
            characters += text.count
            pagesRead += 1
            if characters > maxCharacterCount { stopped = true }
        }

        // Geprüft wird `characters`, **nicht** der zusammengesetzte Text: der
        // enthält die selbst erzeugten Seitenmarken und ist deshalb nie leer.
        // `PDFPage.string` liefert bei einer reinen Bildseite oft "" statt nil –
        // ein eingescanntes Dokument wäre sonst als Anhang aus fünfzig
        // Zeilen „[Seite N]" durchgegangen. Genau der Fall, den die Meldung
        // eigentlich abfangen soll.
        guard characters > 0 else { throw Failure.pdfWithoutText }

        let joined = parts.joined(separator: "\n\n")
        return (joined, pagesRead, max(fullCharacters, joined.count))
    }

    private nonisolated static func isPDF(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "pdf" { return true }
        let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        return type?.conforms(to: .pdf) ?? false
    }

    private nonisolated static func isSourceCode(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           type.conforms(to: .sourceCode) {
            return true
        }
        // Rückfall über die Endung: nicht jede Datei trägt einen erkannten
        // Typ, `.env` und `.gitignore` etwa gar keinen.
        let known: Set<String> = [
            "swift", "php", "js", "ts", "jsx", "tsx", "py", "rb", "go", "rs",
            "java", "kt", "c", "h", "cpp", "hpp", "m", "mm", "cs", "sh", "bash",
            "sql", "css", "scss", "html", "htm", "xml", "json", "yaml", "yml",
            "toml", "ini", "conf", "gradle", "pl", "lua", "r", "dart", "vue"
        ]
        return known.contains(url.pathExtension.lowercased())
    }

    // MARK: - Text

    /// Wandelt Bytes in Text – oder `nil`, wenn es keine Textdatei ist.
    ///
    /// Die Reihenfolge ist nicht beliebig: UTF-8 zuerst, weil praktisch alles
    /// Heutige so kodiert ist. Danach die beiden UTF-16-Varianten, die sich an
    /// ihrer Bytefolgemarke erkennen lassen. Zuletzt Windows-1252 – das nimmt
    /// **jede** Bytefolge an und muss deshalb ganz hinten stehen, sonst
    /// verwandelte es defekte UTF-8-Daten stillschweigend in Zeichensalat.
    nonisolated static func decodeText(_ data: Data) -> String? {
        // Die Bytefolgemarke steht **vor** der Binärprüfung, und das ist der
        // Punkt: eine UTF-16-Datei enthält für jedes ASCII-Zeichen ein
        // Nullbyte. Andersherum geprüft, würde jede aus Windows exportierte
        // Textdatei als „Binärdatei" abgewiesen – mit einer Meldung, die dem
        // Nutzer sagt, er solle doch eine Textdatei nehmen.
        // UTF-32LE beginnt mit denselben zwei Bytes und danach zwei Nullbytes.
        // Ohne diesen Ausschluss dekodierte `.utf16` es zu Text mit
        // eingestreuten U+0000, und die Nullzeichen wanderten in die Anfrage.
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return nil }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            guard let text = String(data: data, encoding: .utf16) else { return nil }
            // Auch hier gilt „nur Text": eine umbenannte Binärdatei, die
            // zufällig mit der Marke beginnt, käme sonst an `isBinary` vorbei.
            return text.unicodeScalars.contains("\0") ? nil : text
        }

        guard !isBinary(data) else { return nil }

        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        return String(data: data, encoding: .isoLatin1)
    }

    /// Grobe, aber verlässliche Unterscheidung: Textdateien enthalten keine
    /// Nullbytes. Geprüft wird nur der Anfang – das genügt und kostet nichts.
    private nonisolated static func isBinary(_ data: Data) -> Bool {
        let head = data.prefix(8192)
        guard !head.isEmpty else { return true }
        if head.contains(0) { return true }
        // Zweiter Hinweis: sehr viele Steuerzeichen ausserhalb von Zeilenumbruch,
        // Wagenrücklauf und Tabulator.
        let control = head.filter { $0 < 0x09 || ($0 > 0x0D && $0 < 0x20) }.count
        return Double(control) / Double(head.count) > 0.1
    }
}

// MARK: - Grössenangabe

enum ByteFormat {
    /// „2,4 MB". Über `ByteCountFormatter`, damit die Trennzeichen zur
    /// eingestellten Sprache passen.
    static func string(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
