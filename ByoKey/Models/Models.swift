//
//  Models.swift
//  ByoKey
//
//  Alle persistierten Datenstrukturen. Bewusst als schlanke Codable-Structs,
//  damit der komplette Zustand als eine JSON-Datei im App-Container liegt und
//  mit einem einzigen Aufruf vollständig gelöscht werden kann
//  (App Store Richtlinie 5.1.1 – Datenkontrolle durch den Nutzer).
//

import Foundation

// MARK: - Decoder-Hilfe für vorwärtskompatibles Laden

extension KeyedDecodingContainer {
    /// Liest einen Wert oder liefert den Standard, falls der Schlüssel fehlt
    /// oder nicht dekodiert werden kann. Verhindert, dass ein neues Feld
    /// in einer späteren App-Version die gespeicherten Daten unlesbar macht.
    func decodeOr<T: Decodable>(_ type: T.Type, _ key: Key, _ fallback: T) -> T {
        // `try?` flacht das Optional ab (SE-0230): fehlender Schlüssel,
        // JSON-null und Wurf landen alle auf dem Fallback.
        (try? decodeIfPresent(type, forKey: key)) ?? fallback
    }

    /// Wie `decodeOr`, aber ein einzelnes defektes Element kostet nur dieses
    /// Element und nicht die gesamte Liste.
    ///
    /// Wichtig: `decodeOr([Conversation].self, …)` würde bei EINEM kaputten
    /// Eintrag das ganze Array verwerfen – also sämtliche Chats des Nutzers.
    func decodeLossyArray<Element: Decodable>(_ type: Element.Type, _ key: Key) -> [Element] {
        ((try? decodeIfPresent(LossyArray<Element>.self, forKey: key)) ?? nil)?.elements ?? []
    }
}

/// Dekodiert ein Array Element für Element und überspringt defekte Einträge.
struct LossyArray<Element: Decodable>: Decodable {
    let elements: [Element]

    /// Verbraucht einen Eintrag, ohne ihn zu interpretieren.
    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Element] = []
        while !container.isAtEnd {
            let indexBefore = container.currentIndex
            if let value = try? container.decode(Element.self) {
                result.append(value)
            } else if (try? container.decodeNil()) == true {
                // JSON-null: decodeNil() hat den Index bereits bewegt.
            } else {
                // Ein fehlgeschlagenes decode() bewegt den Index NICHT –
                // der Eintrag muss separat konsumiert werden.
                _ = try? container.decode(Skip.self)
            }
            // Sicherung gegen eine Endlosschleife, falls der Index doch steht.
            guard container.currentIndex > indexBefore else { break }
        }
        elements = result
    }
}

// MARK: - Projekt

/// Ein Projekt bündelt Chats mit gemeinsamen Vorgaben
/// (System-Prompt, Standardmodell) und eigener Kostenübersicht.
struct AIProject: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var systemPrompt: String
    var defaultModelID: String?
    var accentHex: String
    var createdAt: Date

    init(id: UUID = UUID(),
         name: String,
         systemPrompt: String = "",
         defaultModelID: String? = nil,
         accentHex: String = "#5B3E9A",
         createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.systemPrompt = systemPrompt
        self.defaultModelID = defaultModelID
        self.accentHex = accentHex
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, systemPrompt, defaultModelID, accentHex, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeOr(UUID.self, .id, UUID())
        name = c.decodeOr(String.self, .name, "Projekt")
        systemPrompt = c.decodeOr(String.self, .systemPrompt, "")
        defaultModelID = try? c.decodeIfPresent(String.self, forKey: .defaultModelID)
        accentHex = c.decodeOr(String.self, .accentHex, "#5B3E9A")
        createdAt = c.decodeOr(Date.self, .createdAt, Date())
    }
}

// MARK: - Angehängte Datei

/// Eine an eine Nachricht angehängte Datei – **ohne** ihren Inhalt.
///
/// Der Inhalt liegt unter `storedFileName` im Anhangsordner, aus
/// demselben Grund wie bei den Bildern: die Zustandsdatei wird bei jeder
/// Änderung komplett neu geschrieben.
///
/// Hier stehen nur die Kennzahlen – und die sind nicht Zierrat. `tokenEstimate`
/// entscheidet mit darüber, was in den Kontext passt und was eine Antwort
/// kostet; `originalCharacterCount` hält fest, ob gekürzt wurde. Ein Anhang,
/// von dem nur die Hälfte übertragen wurde, muss als solcher erkennbar sein –
/// sonst behauptet die KI, das ganze Dokument gelesen zu haben.
struct Attachment: Identifiable, Codable, Hashable {

    enum Kind: String, Codable {
        case pdf, text, code, image

        var symbolName: String {
            switch self {
            case .pdf:   return "doc.richtext"
            case .text:  return "doc.text"
            case .code:  return "chevron.left.forwardslash.chevron.right"
            case .image: return "photo"
            }
        }

        /// Bilder gehen als Bild hinaus, alles andere als ausgelesener Text.
        var isImage: Bool { self == .image }
    }

    var id: UUID
    /// Name, wie ihn der Nutzer kennt – zur Anzeige und für den Kontext.
    var fileName: String
    var kind: Kind
    /// Bei Dokumenten die Grösse der Originaldatei.
    ///
    /// Bei Bildern die Grösse der **gesendeten**, verkleinerten JPEG-Fassung –
    /// und nicht die des Originals. Das ist Absicht: die App sagt zu, dass der
    /// Nutzer sieht, was sein Gerät verlässt, und bei einem Bild ist genau das
    /// die gesendete Fassung. Beim Dokument ist es umgekehrt die Zeichenzahl,
    /// die das Übertragene beziffert.
    var byteCount: Int
    /// Länge des übertragenen Textes.
    var characterCount: Int
    /// Länge vor dem Kürzen. Gleich `characterCount`, wenn nichts wegfiel.
    var originalCharacterCount: Int
    /// Nur bei PDF.
    var pageCount: Int?
    var tokenEstimate: Int
    /// Die abgelegte Datei im Anhangsordner: bei Dokumenten der ausgelesene
    /// Text, bei Bildern das fertig verkleinerte JPEG.
    ///
    /// Der Schlüssel in der Zustandsdatei heisst weiterhin `textFileName` –
    /// eine Umbenennung dort hätte alle bestehenden Anhänge unauffindbar
    /// gemacht, ohne irgendetwas zu verbessern.
    var storedFileName: String
    /// Nur bei Bildern: die Kantenlängen des **gesendeten** Bildes.
    var pixelWidth: Int?
    var pixelHeight: Int?
    /// Geht der Anhang bei Folgefragen weiter mit?
    ///
    /// Standardmässig ja – sonst könnte die KI ab der zweiten Frage nichts
    /// mehr über das Dokument sagen, was die meisten Nutzer überrascht. Wer
    /// die Kosten drücken oder Platz für ein kleineres Modell schaffen will,
    /// schaltet ihn ab; der Anhang bleibt sichtbar und lässt sich jederzeit
    /// wieder zuschalten.
    var isActive: Bool

    init(id: UUID = UUID(),
         fileName: String,
         kind: Kind,
         byteCount: Int,
         characterCount: Int,
         originalCharacterCount: Int,
         pageCount: Int? = nil,
         tokenEstimate: Int,
         storedFileName: String,
         pixelWidth: Int? = nil,
         pixelHeight: Int? = nil,
         isActive: Bool = true) {
        self.id = id
        self.fileName = fileName
        self.kind = kind
        self.byteCount = byteCount
        self.characterCount = characterCount
        self.originalCharacterCount = originalCharacterCount
        self.pageCount = pageCount
        self.tokenEstimate = tokenEstimate
        self.storedFileName = storedFileName
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isActive = isActive
    }

    enum CodingKeys: String, CodingKey {
        case id, fileName, kind, byteCount, characterCount, originalCharacterCount
        case pageCount, tokenEstimate, isActive
        case pixelWidth, pixelHeight
        // Der Name im Code sagt, was drinsteht; der Name in der Datei bleibt,
        // damit bestehende Anhänge weiter gefunden werden.
        case storedFileName = "textFileName"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Ohne Kennung und ohne Textdatei ist der Eintrag wertlos: er zeigte
        // auf nichts und liesse sich nicht einmal anzeigen. Ein Wurf lässt
        // `decodeLossyArray` ihn überspringen, statt eine leere Kachel zu bauen.
        id = try c.decode(UUID.self, forKey: .id)
        storedFileName = try c.decode(String.self, forKey: .storedFileName)
        fileName = c.decodeOr(String.self, .fileName, "Datei")
        kind = c.decodeOr(Kind.self, .kind, .text)
        byteCount = max(0, c.decodeOr(Int.self, .byteCount, 0))
        characterCount = max(0, c.decodeOr(Int.self, .characterCount, 0))
        originalCharacterCount = max(characterCount,
                                     c.decodeOr(Int.self, .originalCharacterCount, characterCount))
        let rawPages: Int? = try? c.decodeIfPresent(Int.self, forKey: .pageCount)
        pageCount = rawPages.flatMap { $0 > 0 ? min($0, 100_000) : nil }
        tokenEstimate = min(max(0, c.decodeOr(Int.self, .tokenEstimate, 0)), 10_000_000)
        isActive = c.decodeOr(Bool.self, .isActive, true)
        let rawWidth: Int? = try? c.decodeIfPresent(Int.self, forKey: .pixelWidth)
        let rawHeight: Int? = try? c.decodeIfPresent(Int.self, forKey: .pixelHeight)
        pixelWidth = rawWidth.flatMap { $0 > 0 ? min($0, 100_000) : nil }
        pixelHeight = rawHeight.flatMap { $0 > 0 ? min($0, 100_000) : nil }
    }

    var isTruncated: Bool { originalCharacterCount > characterCount }

    /// Anteil des übertragenen Textes, 0…1.
    var transferredShare: Double {
        guard originalCharacterCount > 0 else { return 1 }
        return min(1, Double(characterCount) / Double(originalCharacterCount))
    }
}

// MARK: - Nachricht

struct ChatMessage: Identifiable, Codable, Hashable {

    enum Role: String, Codable {
        case system, user, assistant
    }

    var id: UUID
    var role: Role
    var text: String
    var createdAt: Date

    /// Verbrauch und Kosten, sofern der Anbieter sie zurückgemeldet hat.
    var promptTokens: Int?
    var completionTokens: Int?
    var costUSD: Double?
    /// true, wenn Tokens lokal geschätzt wurden (Anbieter lieferte keine Werte).
    var isEstimate: Bool
    var modelID: String?

    /// Fehlermeldung statt Antwort (z. B. HTTP 401).
    var isError: Bool
    /// Vom lokalen Inhaltsfilter markiert (Richtlinie 1.2).
    var isFlagged: Bool
    /// Vom Nutzer gemeldet (Richtlinie 1.2 – Meldemechanismus).
    var isReported: Bool
    /// Dateiname eines erzeugten Bildes im Bilderordner.
    /// Nur der Name – die Bytes stehen bewusst nicht in der Zustandsdatei,
    /// die bei jeder Änderung komplett neu geschrieben wird.
    var imageFileName: String?
    /// Breite geteilt durch Höhe des erzeugten Bildes.
    ///
    /// Steht hier, damit die Ansicht schon **vor** dem Laden weiß, wie hoch
    /// die Blase wird. Ohne diesen Wert zeigt sie erst eine kleine Ladeanzeige,
    /// wächst dann sprunghaft auf Bildhöhe – und schiebt dabei alles darunter
    /// nach unten. Genau das lässt den Verlauf beim Scrollen springen.
    var imageAspectRatio: Double?
    /// Vom Nutzer angehängte Dateien. Nur bei `role == .user`.
    var attachments: [Attachment]

    init(id: UUID = UUID(),
         role: Role,
         text: String,
         createdAt: Date = Date(),
         promptTokens: Int? = nil,
         completionTokens: Int? = nil,
         costUSD: Double? = nil,
         isEstimate: Bool = false,
         modelID: String? = nil,
         isError: Bool = false,
         isFlagged: Bool = false,
         isReported: Bool = false,
         imageFileName: String? = nil,
         imageAspectRatio: Double? = nil,
         attachments: [Attachment] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.costUSD = costUSD
        self.isEstimate = isEstimate
        self.modelID = modelID
        self.isError = isError
        self.isFlagged = isFlagged
        self.isReported = isReported
        self.imageFileName = imageFileName
        self.imageAspectRatio = imageAspectRatio
        self.attachments = attachments
    }

    enum CodingKeys: String, CodingKey {
        case id, role, text, createdAt, promptTokens, completionTokens
        case costUSD, isEstimate, modelID, isError, isFlagged, isReported
        case imageFileName, imageAspectRatio, attachments
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeOr(UUID.self, .id, UUID())
        role = c.decodeOr(Role.self, .role, .assistant)
        text = c.decodeOr(String.self, .text, "")
        createdAt = c.decodeOr(Date.self, .createdAt, Date())
        // Unplausible Werte begrenzen: sonst kann eine manipulierte oder
        // beschädigte Datei die Summierung in tokens(forProject:) zum
        // Überlauf-Trap bringen.
        let rawPrompt: Int? = try? c.decodeIfPresent(Int.self, forKey: .promptTokens)
        let rawCompletion: Int? = try? c.decodeIfPresent(Int.self, forKey: .completionTokens)
        promptTokens = rawPrompt.map { min(max(0, $0), 10_000_000) }
        completionTokens = rawCompletion.map { min(max(0, $0), 10_000_000) }
        // Wie bei den Tokens auch nach unten begrenzen: ein negativer Betrag
        // aus einer beschädigten Datei zöge sonst die Chat-, Projekt- und
        // Monatssumme herunter, und der Budgetbalken zeigte weniger an, als
        // ausgegeben wurde.
        let rawCost: Double? = try? c.decodeIfPresent(Double.self, forKey: .costUSD)
        costUSD = rawCost.flatMap { $0.isFinite ? max(0, $0) : nil }
        isEstimate = c.decodeOr(Bool.self, .isEstimate, false)
        modelID = try? c.decodeIfPresent(String.self, forKey: .modelID)
        isError = c.decodeOr(Bool.self, .isError, false)
        isFlagged = c.decodeOr(Bool.self, .isFlagged, false)
        isReported = c.decodeOr(Bool.self, .isReported, false)
        imageFileName = try? c.decodeIfPresent(String.self, forKey: .imageFileName)
        // Unplausible Werte verwerfen: ein 0 oder NaN als Seitenverhältnis
        // ergäbe eine Blase mit unendlicher Höhe.
        let rawRatio: Double? = try? c.decodeIfPresent(Double.self, forKey: .imageAspectRatio)
        imageAspectRatio = rawRatio.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        attachments = c.decodeLossyArray(Attachment.self, .attachments)
    }

    var totalTokens: Int {
        (promptTokens ?? 0) + (completionTokens ?? 0)
    }
}

// MARK: - Unterhaltung

struct Conversation: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var projectID: UUID?
    var modelID: String
    var messages: [ChatMessage]
    var createdAt: Date
    var updatedAt: Date

    /// Hat der Nutzer den Titel selbst vergeben?
    ///
    /// Entscheidet mit darüber, ob ein leerer Chat bestehen bleibt: ein
    /// benannter Chat ist eine Absicht („hier kommt später der Umzug rein"),
    /// ein unbenannter leerer Chat ist ein Versehen.
    var titleWasEdited: Bool

    init(id: UUID = UUID(),
         title: String = Conversation.untitled,
         projectID: UUID? = nil,
         modelID: String,
         messages: [ChatMessage] = [],
         createdAt: Date = Date(),
         updatedAt: Date = Date(),
         titleWasEdited: Bool = false) {
        self.id = id
        self.title = title
        self.projectID = projectID
        self.modelID = modelID
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.titleWasEdited = titleWasEdited
    }

    enum CodingKeys: String, CodingKey {
        case id, title, projectID, modelID, messages, createdAt, updatedAt, titleWasEdited
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeOr(UUID.self, .id, UUID())
        title = c.decodeOr(String.self, .title, "Chat")
        projectID = try? c.decodeIfPresent(UUID.self, forKey: .projectID)
        modelID = c.decodeOr(String.self, .modelID, "")
        messages = c.decodeLossyArray(ChatMessage.self, .messages)
        createdAt = c.decodeOr(Date.self, .createdAt, Date())
        updatedAt = c.decodeOr(Date.self, .updatedAt, Date())
        // Bestände aus früheren Fassungen kennen das Merkmal nicht. `false`
        // ist die sichere Vorgabe: darüber entscheidet dann der Titel, und
        // ein selbst vergebener Titel schützt den Chat weiterhin.
        titleWasEdited = c.decodeOr(Bool.self, .titleWasEdited, false)
    }

    /// Der Titel, den ein frisch angelegter Chat trägt, bis die erste
    /// Nachricht ihn ersetzt. Steht hier und nicht als Literal an drei
    /// Stellen: an ihm hängt die Erkennung leerer Entwürfe.
    static let untitled = "Neuer Chat"

    /// Ein Chat ohne Inhalt **und** ohne eigenen Namen.
    ///
    /// Solche Chats entstehen beim Tippen auf „Neuer Chat“ und beim Löschen
    /// des letzten Chats. Sie enthalten nichts, was verloren gehen könnte –
    /// weder Nachrichten noch einen Namen –, und werden deshalb wieder
    /// abgeräumt, sobald man sie verlässt. Ohne diese Regel füllte sich die
    /// Seitenleiste mit beliebig vielen leeren Zeilen.
    ///
    /// Der Titelvergleich ist der Rückfall für Bestände aus früheren
    /// Fassungen, in denen `titleWasEdited` noch nicht mitgeschrieben wurde.
    var isEmptyDraft: Bool {
        guard !titleWasEdited else { return false }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty || name == Conversation.untitled || name == "Chat" else { return false }
        return !messages.contains { $0.role != .system }
    }

    var totalCostUSD: Double {
        messages.compactMap(\.costUSD).reduce(0, +)
    }

    var totalTokens: Int {
        messages.reduce(0) { $0 + $1.totalTokens }
    }

    /// Die Nachrichten, die im Verlauf erscheinen.
    ///
    /// Ohne Filter, und das ist kein Versehen: eine `ChatMessage` mit der
    /// Rolle `.system` entsteht in der ganzen App nirgends – die
    /// Sicherheitsregeln und der Projekt-Prompt sind `ChatTurn`s und werden
    /// erst in `buildTurns` gebaut, nie als Nachricht gespeichert. Der Filter
    /// legte also bei **jedem** Bildaufbau des Chats ein neues Array über alle
    /// Nachrichten an, nur um dasselbe zurückzugeben.
    ///
    /// Käme je eine gespeicherte System-Nachricht dazu, gehört der Filter
    /// hierher zurück.
    var visibleMessages: [ChatMessage] { messages }

    /// Alle Anhangs-Textdateien dieses Chats – fürs Aufräumen.
    var attachmentFileNames: [String] {
        messages.flatMap { $0.attachments.map(\.storedFileName) }
    }

    /// `nil` heisst: noch keine Nachricht. Der Ersatztext gehört in die
    /// Ansicht, wo er als Literal übersetzt wird.
    /// Nur so viel, wie eine einzeilige Zeile fassen kann.
    ///
    /// Vorher lief hier `visibleMessages` (ein neues Array über **alle**
    /// Nachrichten) und danach `replacingOccurrences` über den vollständigen
    /// Text der letzten Antwort – bei einer langen Antwort also 20 000 Zeichen,
    /// um eine Zeile mit `lineLimit(1)` zu füllen. In der Seitenleiste fällt
    /// das für jeden sichtbaren Chat an.
    var preview: String? {
        guard let last = messages.last(where: { $0.role != .system }) else { return nil }
        return String(last.text.prefix(140)).replacingOccurrences(of: "\n", with: " ")
    }
}

// MARK: - Modell

/// Ein einzelnes KI-Modell eines Anbieters inklusive Preisen.
/// Preise sind USD pro Token (so liefert OpenRouter sie aus).
struct AIModel: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var providerID: String
    var contextLength: Int
    var promptPricePerToken: Double?
    var completionPricePerToken: Double?
    var summary: String?
    /// Was das Modell entgegennimmt bzw. ausgibt ("text", "audio", "image",
    /// "transcription"). Nur OpenRouter liefert diese Angaben; sonst nil.
    var inputModalities: [String]?
    var outputModalities: [String]?

    /// Kann das Modell aus Audio Text machen (Spracherkennung)?
    var isTranscriptionModel: Bool {
        let output = (outputModalities ?? []).map { $0.lowercased() }
        let input = (inputModalities ?? []).map { $0.lowercased() }
        if output.contains("transcription") { return true }
        return input.contains("audio") && output.contains("text")
    }

    /// Kann das Modell Bilder erzeugen?
    ///
    /// OpenRouter liefert die Modalitäten mit der Modell-Liste. Die übrigen
    /// Anbieter tun das nicht – dort hilft nur der Name. Die Liste ist
    /// bewusst kurz und trifft die dokumentierten Bildmodelle; ein
    /// unbekanntes Bildmodell lässt sich weiterhin von Hand ansprechen.
    var isImageModel: Bool {
        if (outputModalities ?? []).contains(where: { $0.lowercased() == "image" }) { return true }
        guard outputModalities == nil else { return false }
        let name = id.lowercased()
        let known = ["gpt-image", "dall-e", "flux", "imagen", "seedream",
                     "grok-imagine", "qwen-image", "stable-diffusion", "sdxl"]
        if known.contains(where: { name.contains($0) }) { return true }
        // „gemini-2.5-flash-image“, aber nicht „gemini-2.5-flash“.
        return name.contains("gemini") && name.contains("image")
    }

    /// Nimmt das Modell Bilder als **Eingabe** entgegen?
    ///
    /// `nil` heisst ausdrücklich „unbekannt": nur OpenRouter liefert die
    /// Modalitäten mit der Modell-Liste. Bei den übrigen Anbietern wird
    /// deshalb nicht geraten und auch nichts blockiert – wer dort ein Modell
    /// wählt, weiss in der Regel, was es kann.
    var acceptsImages: Bool? {
        guard let inputModalities else { return nil }
        return inputModalities.contains { $0.lowercased() == "image" }
    }

    /// Kann das Modell aus Text Audio machen (Sprachausgabe)?
    var isSpeechModel: Bool {
        let output = (outputModalities ?? []).map { $0.lowercased() }
        return output.contains("audio") || output.contains("speech")
    }

    /// Anbieterpräfix, z. B. "anthropic" aus "anthropic/claude-sonnet-4".
    var vendor: String {
        id.split(separator: "/").first.map(String.init) ?? providerID
    }

    /// Preisbestandteile, die **nicht** pro Token abgerechnet werden:
    /// Audio pro Sekunde, Bild pro Stück, Aufschlag pro Anfrage.
    /// Ohne diese Felder sah ein Sprachmodell wie ein kostenloses Modell aus.
    var audioPricePerUnit: Double?
    var requestPrice: Double?
    var imagePrice: Double?

    var hasPricing: Bool {
        promptPricePerToken != nil && completionPricePerToken != nil
    }

    /// Kostet das Modell etwas, das nicht in Tokens gemessen wird?
    var hasNonTokenCost: Bool {
        [audioPricePerUnit, requestPrice, imagePrice].contains { ($0 ?? 0) > 0 }
    }

    /// Sprachmodelle rechnen nach Audiolänge oder Zeichen ab. Die Modell-Liste
    /// meldet für sie oft `prompt: "0"` und `completion: "0"`, weil es dort
    /// schlicht keine Tokens gibt – „kostenlos" wäre daraus die falsche
    /// Schlussfolgerung und genau der Fehler, den die App vorher gemacht hat.
    var isAudioBilled: Bool {
        isTranscriptionModel || isSpeechModel
    }

    /// Preis pro 1 Mio. Prompt-Tokens in USD – die im Markt übliche Darstellung.
    var promptPricePerMillion: Double? {
        promptPricePerToken.map { $0 * 1_000_000 }
    }

    var completionPricePerMillion: Double? {
        completionPricePerToken.map { $0 * 1_000_000 }
    }

    var isFree: Bool {
        // OpenRouter markiert echte Gratis-Modelle mit dieser Endung. Das ist
        // die einzige Angabe, auf die man sich verlassen kann.
        if id.lowercased().hasSuffix(":free") { return true }
        guard hasPricing, !hasNonTokenCost, !isAudioBilled else { return false }
        return (promptPricePerToken ?? 0) == 0 && (completionPricePerToken ?? 0) == 0
    }

    /// Was in der Liste unter dem Modellnamen stehen soll, wenn keine
    /// Token-Preise greifen. `nil` heißt: normale Preisangabe zeigen.
    /// Der Rückgabewert ist der Textschlüssel; übersetzt wird in der Ansicht.
    var priceNote: String? {
        if isFree { return nil }
        guard (promptPricePerToken ?? 0) == 0, (completionPricePerToken ?? 0) == 0 else { return nil }
        if isAudioBilled {
            return isSpeechModel ? "Abrechnung nach Zeichen" : "Abrechnung nach Audiolänge"
        }
        if hasNonTokenCost { return "Abrechnung nach Nutzung" }
        return nil
    }
}

// MARK: - Meldung (Richtlinie 1.2)

/// Lokal protokollierte Meldung eines anstößigen Inhalts.
struct ContentReport: Identifiable, Codable, Hashable {
    /// ACHTUNG: `rawValue` ist ein Persistenz-Schlüssel und darf sich NIE
    /// ändern. Früher standen hier die deutschen Anzeigetexte – eine
    /// Umformulierung hätte das gesamte Meldeprotokoll unlesbar gemacht,
    /// also genau den Nachweis, den Richtlinie 1.2 verlangt.
    /// Anzeigetexte stehen in `displayName` und dürfen frei geändert werden.
    enum Reason: String, Codable, CaseIterable, Identifiable {
        case hate
        case violence
        case sexual
        case selfHarm
        case misinformation
        case other

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .hate:           return "Hass oder Diskriminierung"
            case .violence:       return "Gewalt oder Bedrohung"
            case .sexual:         return "Sexueller Inhalt"
            case .selfHarm:       return "Selbstgefährdung"
            case .misinformation: return "Falschinformation"
            case .other:          return "Sonstiges"
            }
        }

        /// Datenbestand aus Versionen, die den Anzeigetext gespeichert haben.
        private static let legacyKeys: [String: Reason] = [
            "Hass oder Diskriminierung": .hate,
            "Gewalt oder Bedrohung": .violence,
            "Sexueller Inhalt": .sexual,
            "Selbstgefährdung": .selfHarm,
            "Falschinformation": .misinformation,
            "Sonstiges": .other
        ]

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Reason(rawValue: raw) ?? Reason.legacyKeys[raw] ?? .other
        }
    }

    var id: UUID
    var messageID: UUID
    var conversationID: UUID
    var modelID: String?
    var reason: Reason
    var note: String
    var excerpt: String
    var createdAt: Date

    init(id: UUID = UUID(),
         messageID: UUID,
         conversationID: UUID,
         modelID: String?,
         reason: Reason,
         note: String = "",
         excerpt: String,
         createdAt: Date = Date()) {
        self.id = id
        self.messageID = messageID
        self.conversationID = conversationID
        self.modelID = modelID
        self.reason = reason
        self.note = note
        self.excerpt = excerpt
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, messageID, conversationID, modelID, reason, note, excerpt, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeOr(UUID.self, .id, UUID())
        messageID = c.decodeOr(UUID.self, .messageID, UUID())
        conversationID = c.decodeOr(UUID.self, .conversationID, UUID())
        modelID = try? c.decodeIfPresent(String.self, forKey: .modelID)
        reason = c.decodeOr(Reason.self, .reason, .other)
        note = c.decodeOr(String.self, .note, "")
        excerpt = c.decodeOr(String.self, .excerpt, "")
        createdAt = c.decodeOr(Date.self, .createdAt, Date())
    }
}

// MARK: - Hinterlegte API-Schlüssel

/// Ein hinterlegter Schlüssel – **ohne** den Schlüssel selbst.
///
/// Der geheime Teil liegt ausschliesslich in der Keychain, unter dem Konto
/// `keychainAccount`. Hier steht nur, dass es ihn gibt, zu welchem Anbieter er
/// gehört und wie der Nutzer ihn genannt hat. Diese Trennung ist keine
/// Formsache: die Zustandsdatei liegt als lesbares JSON im App-Container, und
/// sowohl die Datenschutzerklärung als auch die Review-Notizen sagen zu, dass
/// Schlüssel die Keychain nie verlassen. Auch die verkürzte Darstellung
/// („sk-or-v1-…4f2a") wird deshalb **nicht** mitgeschrieben, sondern bei
/// Bedarf aus der Keychain gebildet.
///
/// Mehrere Einträge je Anbieter sind ausdrücklich vorgesehen: getrennte
/// Schlüssel für Arbeit und privat, einer mit Ausgabengrenze zum Ausprobieren,
/// einer pro Kunde. Welcher gerade benutzt wird, steht in
/// `AppSettings.activeCredentialByProvider`.
struct APICredential: Identifiable, Codable, Hashable {
    var id: UUID
    var providerID: String
    /// Vom Nutzer vergeben. Beim Anlegen aus dem Anbieternamen gebildet
    /// („OpenRouter", „OpenRouter 2"), danach frei änderbar.
    var name: String
    var createdAt: Date
    /// Wann die Verbindung zuletzt erfolgreich geprüft wurde. `nil` heisst
    /// „noch nie" – der Eintrag zeigt dann keinen Zeitpunkt an, statt einen
    /// zu erfinden.
    var lastVerifiedAt: Date?

    init(id: UUID = UUID(),
         providerID: String,
         name: String,
         createdAt: Date = Date(),
         lastVerifiedAt: Date? = nil) {
        self.id = id
        self.providerID = providerID
        self.name = name
        self.createdAt = createdAt
        self.lastVerifiedAt = lastVerifiedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, providerID, name, createdAt, lastVerifiedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Hier wird **nicht** geraten, anders als sonst in dieser Datei:
        // ohne Kennung zeigt der Eintrag auf kein Keychain-Konto, ohne
        // Anbieter taucht er in keiner Liste auf. Eine erfundene Vorgabe
        // ergäbe eine unsichtbare Zeile, die sich nicht einmal löschen lässt.
        // Ein Wurf lässt `decodeLossyArray` den Eintrag überspringen – und
        // die Wiederherstellung aus der Keychain holt ihn zurück.
        id = try c.decode(UUID.self, forKey: .id)
        providerID = try c.decode(String.self, forKey: .providerID)
        let decodedName = c.decodeOr(String.self, .name, "")
        // Ein namenloser Eintrag wäre in der Liste eine leere Zeile.
        name = decodedName.isEmpty
            ? ProviderRegistry.providerOrDefault(id: providerID).displayName
            : decodedName
        createdAt = c.decodeOr(Date.self, .createdAt, Date())
        lastVerifiedAt = try? c.decodeIfPresent(Date.self, forKey: .lastVerifiedAt)
    }

    static let accountPrefix = "apikey.entry."

    /// Das Keychain-Konto dieses Eintrags.
    ///
    /// Die Kennung und nicht der Name: der Name ist änderbar, und eine
    /// Umbenennung darf den Schlüssel nicht unauffindbar machen.
    var keychainAccount: String { Self.accountPrefix + id.uuidString }

    /// Das Etikett, das neben dem Schlüssel in der Keychain liegt.
    ///
    /// Anbieter und Name, durch einen senkrechten Strich getrennt. Damit lässt
    /// sich der Eintrag auch dann noch zuordnen, wenn die Zustandsdatei fehlt –
    /// der Kontoname allein ist eine nackte UUID. Ein Geheimnis steht nicht
    /// darin, und die Keychain ist der bestgeschützte Ablageort des Systems.
    var keychainLabel: String { "\(providerID)|\(name)" }

    /// Baut einen Eintrag aus dem, was die Keychain selbst hergibt.
    ///
    /// `nil`, wenn sich Kennung oder Anbieter nicht sicher bestimmen lassen –
    /// lieber keinen Eintrag als einen, der ins Leere zeigt oder dessen
    /// Schlüssel womöglich an den falschen Anbieter ginge.
    init?(recoveredAccount account: String, label: String?) {
        guard account.hasPrefix(Self.accountPrefix),
              let id = UUID(uuidString: String(account.dropFirst(Self.accountPrefix.count)))
        else { return nil }
        let parts = (label ?? "").split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let providerID = String(parts[0])
        guard let provider = ProviderRegistry.provider(id: providerID) else { return nil }
        let name = String(parts[1])
        self.init(id: id,
                  providerID: providerID,
                  name: name.isEmpty ? provider.displayName : name)
    }
}

// MARK: - Einstellungen

/// Wo der Knopf „zum Ende springen" im Verlauf sitzt.
///
/// Geschmackssache – aber auch eine Frage, mit welcher Hand man das Gerät
/// hält. Auf einem grossen iPhone ist die rechte untere Ecke für Linkshänder
/// der unbequemste Punkt des Bildschirms.
enum ScrollButtonPosition: String, Codable, CaseIterable, Identifiable {
    case leading, center, trailing

    var id: String { rawValue }

    /// Deutscher Text = Übersetzungsschlüssel.
    var label: String {
        switch self {
        case .leading:  return "Links"
        case .center:   return "Mittig"
        case .trailing: return "Rechts"
        }
    }
}

/// Woher Spracherkennung und Sprachausgabe kommen.
enum VoiceEngine: String, Codable, CaseIterable, Identifiable {
    /// Apples Bordmittel. Funktioniert mit JEDEM Chat-Modell, kostet nichts
    /// zusätzlich, und die Aufnahme bleibt auf dem Gerät.
    case device
    /// Sprach-Endpunkte des API-Anbieters. Bessere Stimmen und oft bessere
    /// Erkennung, aber kostenpflichtig, und die Aufnahme verlässt das Gerät.
    case provider

    var id: String { rawValue }

    var label: String {
        switch self {
        case .device:   return "Auf dem Gerät"
        case .provider: return "Über den Anbieter"
        }
    }
}

struct AppSettings: Codable, Hashable {
    var activeProviderID: String
    var defaultModelID: String?
    var temperature: Double
    var maxTokens: Int
    var showCostPerMessage: Bool
    var monthlyBudgetUSD: Double
    var currencyCode: String
    /// Der Inhaltsfilter lässt sich nur abschwächen, nicht abschalten
    /// (Richtlinie 1.2 verlangt eine Filtermethode).
    var strictFilter: Bool

    // MARK: Sprachmodus
    var voiceEnabled: Bool
    var voiceEngine: VoiceEngine
    /// Antworten nach dem Eintreffen vorlesen.
    var speakAnswers: Bool
    /// Nach dem Vorlesen automatisch wieder zuhören (Gesprächsmodus).
    var handsFree: Bool
    var voiceLanguage: String
    /// Modell für die Spracherkennung beim Anbieter.
    var sttModelID: String
    /// Modell für die Sprachausgabe beim Anbieter.
    var ttsModelID: String
    /// Stimme beim Anbieter, z. B. "alloy".
    var ttsVoice: String
    /// Kennung der Systemstimme für die Ausgabe auf dem Gerät.
    /// Leer = iOS wählt die Standardstimme der Sprache.
    var deviceVoiceID: String
    /// Apples Erkennung darf auf Apple-Server ausweichen, wenn auf dem Gerät
    /// keine Unterstützung für die Sprache vorhanden ist. Standard: aus.
    var allowServerSpeechRecognition: Bool

    /// Welcher hinterlegte Schlüssel je Anbieter gerade benutzt wird.
    ///
    /// Je Anbieter gemerkt und nicht als ein einzelner Wert: wer für
    /// OpenRouter drei Schlüssel hat und zwischendurch zu Mistral wechselt,
    /// soll beim Zurückwechseln wieder bei seinem Schlüssel landen und nicht
    /// bei irgendeinem. Fehlt der Eintrag oder zeigt er auf einen gelöschten
    /// Schlüssel, gilt der erste des Anbieters.
    var activeCredentialByProvider: [String: UUID]

    /// Sprache der Oberfläche. `.system` folgt der Einstellung des Geräts.
    var language: AppLanguage
    /// Seite, auf der der Knopf „zum Ende springen" erscheint.
    var scrollButtonPosition: ScrollButtonPosition

    static let `default` = AppSettings(
        activeProviderID: OpenRouterProvider.identifier,
        defaultModelID: nil,
        temperature: 0.7,
        maxTokens: 2048,
        showCostPerMessage: true,
        monthlyBudgetUSD: 10,
        currencyCode: "USD",
        strictFilter: true,
        voiceEnabled: true,
        voiceEngine: .device,
        speakAnswers: false,
        handsFree: false,
        voiceLanguage: "de-DE",
        sttModelID: "openai/whisper-1",
        ttsModelID: "openai/gpt-4o-mini-tts",
        ttsVoice: "alloy",
        deviceVoiceID: "",
        allowServerSpeechRecognition: false,
        language: .system,
        scrollButtonPosition: .center
    )

    /// Passende Standard-Modellkennungen. OpenRouter verlangt das
    /// Anbieter-Präfix ("openai/whisper-1"), die direkte OpenAI-Schnittstelle
    /// lehnt genau das mit HTTP 400 ab.
    static func defaultAudioModels(for providerID: String) -> (stt: String, tts: String) {
        switch providerID {
        case OpenRouterProvider.identifier:
            return ("openai/whisper-1", "openai/gpt-4o-mini-tts")
        case "openai":
            return ("whisper-1", "gpt-4o-mini-tts")
        default:
            // Bei den übrigen Anbietern heißen die Sprachmodelle jeweils
            // anders. Lieber leer lassen und den Nutzer aus der gefilterten
            // Liste wählen lassen, als eine Kennung zu raten, die der Anbieter
            // mit HTTP 400 quittiert.
            return ("", "")
        }
    }

    /// Welche Stimmenkennung für den gerade eingestellten Weg gilt.
    /// Die beiden Werte sind nicht austauschbar: "alloy" ist ein Name beim
    /// Anbieter, die Gerätestimme eine lange Apple-Kennung.
    var activeVoiceIdentifier: String {
        voiceEngine == .device ? deviceVoiceID : ttsVoice
    }

    enum CodingKeys: String, CodingKey {
        case activeProviderID, defaultModelID, temperature, maxTokens
        case showCostPerMessage, monthlyBudgetUSD, currencyCode, strictFilter
        case voiceEnabled, voiceEngine, speakAnswers, handsFree, voiceLanguage
        case sttModelID, ttsModelID, ttsVoice, deviceVoiceID, allowServerSpeechRecognition
        case language, scrollButtonPosition
        case activeCredentialByProvider
    }

    init(activeProviderID: String,
         defaultModelID: String?,
         temperature: Double,
         maxTokens: Int,
         showCostPerMessage: Bool,
         monthlyBudgetUSD: Double,
         currencyCode: String,
         strictFilter: Bool,
         voiceEnabled: Bool,
         voiceEngine: VoiceEngine,
         speakAnswers: Bool,
         handsFree: Bool,
         voiceLanguage: String,
         sttModelID: String,
         ttsModelID: String,
         ttsVoice: String,
         deviceVoiceID: String,
         allowServerSpeechRecognition: Bool,
         language: AppLanguage,
         scrollButtonPosition: ScrollButtonPosition = .center,
         activeCredentialByProvider: [String: UUID] = [:]) {
        self.activeProviderID = activeProviderID
        self.defaultModelID = defaultModelID
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.showCostPerMessage = showCostPerMessage
        self.monthlyBudgetUSD = monthlyBudgetUSD
        self.currencyCode = currencyCode
        self.strictFilter = strictFilter
        self.voiceEnabled = voiceEnabled
        self.voiceEngine = voiceEngine
        self.speakAnswers = speakAnswers
        self.handsFree = handsFree
        self.voiceLanguage = voiceLanguage
        self.sttModelID = sttModelID
        self.ttsModelID = ttsModelID
        self.ttsVoice = ttsVoice
        self.deviceVoiceID = deviceVoiceID
        self.allowServerSpeechRecognition = allowServerSpeechRecognition
        self.language = language
        self.scrollButtonPosition = scrollButtonPosition
        self.activeCredentialByProvider = activeCredentialByProvider
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings.default
        activeProviderID = c.decodeOr(String.self, .activeProviderID, d.activeProviderID)
        defaultModelID = try? c.decodeIfPresent(String.self, forKey: .defaultModelID)
        // Werte begrenzen: eine beschädigte Datei darf keine unsinnigen
        // Parameter an den Anbieter schicken.
        let rawTemperature = c.decodeOr(Double.self, .temperature, d.temperature)
        temperature = rawTemperature.isFinite ? min(max(0, rawTemperature), 2) : d.temperature
        maxTokens = min(max(64, c.decodeOr(Int.self, .maxTokens, d.maxTokens)), 128_000)
        showCostPerMessage = c.decodeOr(Bool.self, .showCostPerMessage, d.showCostPerMessage)
        let rawBudget = c.decodeOr(Double.self, .monthlyBudgetUSD, d.monthlyBudgetUSD)
        monthlyBudgetUSD = rawBudget.isFinite ? max(0, rawBudget) : d.monthlyBudgetUSD
        currencyCode = c.decodeOr(String.self, .currencyCode, d.currencyCode)
        strictFilter = c.decodeOr(Bool.self, .strictFilter, d.strictFilter)
        voiceEnabled = c.decodeOr(Bool.self, .voiceEnabled, d.voiceEnabled)
        voiceEngine = c.decodeOr(VoiceEngine.self, .voiceEngine, d.voiceEngine)
        speakAnswers = c.decodeOr(Bool.self, .speakAnswers, d.speakAnswers)
        handsFree = c.decodeOr(Bool.self, .handsFree, d.handsFree)
        voiceLanguage = c.decodeOr(String.self, .voiceLanguage, d.voiceLanguage)
        sttModelID = c.decodeOr(String.self, .sttModelID, d.sttModelID)
        ttsModelID = c.decodeOr(String.self, .ttsModelID, d.ttsModelID)
        ttsVoice = c.decodeOr(String.self, .ttsVoice, d.ttsVoice)
        deviceVoiceID = c.decodeOr(String.self, .deviceVoiceID, d.deviceVoiceID)
        allowServerSpeechRecognition = c.decodeOr(Bool.self, .allowServerSpeechRecognition,
                                                  d.allowServerSpeechRecognition)
        language = c.decodeOr(AppLanguage.self, .language, d.language)
        scrollButtonPosition = c.decodeOr(ScrollButtonPosition.self, .scrollButtonPosition,
                                          d.scrollButtonPosition)
        activeCredentialByProvider = c.decodeOr([String: UUID].self, .activeCredentialByProvider, [:])
    }
}

// MARK: - Persistenz-Container

/// Der komplette persistierte Zustand – ohne API-Schlüssel.
/// Schlüssel liegen ausschließlich in der Keychain (siehe KeychainStore).
struct PersistedState: Codable {
    var version: Int
    var projects: [AIProject]
    var conversations: [Conversation]
    var settings: AppSettings
    var blockedModelIDs: [String]
    var reports: [ContentReport]
    var customPricing: [String: PricePair]
    /// Die hinterlegten Schlüssel – nur Kennung, Anbieter und Name. Der
    /// geheime Teil steht in der Keychain, siehe `APICredential`.
    var credentials: [APICredential]
    /// Wo der Nutzer zuletzt war. `nil` heisst ausdrücklich **Übersicht** –
    /// deshalb optional und nicht etwa „der zuletzt benutzte Chat". Ohne
    /// diesen Wert landete jeder Start im jüngsten Chat, auch wenn die App
    /// aus der Übersicht heraus geschlossen wurde.
    var selectedConversationID: UUID?
    var selectedProjectID: UUID?
    /// Stand die Auswahl überhaupt in der Datei?
    ///
    /// `decodeIfPresent` kann „Schlüssel fehlt" (Datei aus einer Fassung vor
    /// dieser Änderung) nicht von „ausdrücklich keine Auswahl" unterscheiden.
    /// Ohne diese Unterscheidung landete jede bestehende Installation nach
    /// dem Update einmalig in der Übersicht statt im zuletzt benutzten Chat.
    ///
    /// Bewusst **nicht** in `CodingKeys`: der Wert wird nie geschrieben, er
    /// entsteht beim Lesen.
    var hasStoredSelection: Bool = false

    struct PricePair: Codable, Hashable {
        var prompt: Double
        var completion: Double
    }

    /// Beim Ändern des Formats erhöhen und in `AppState.load()` migrieren.
    static let currentVersion = 1

    static let empty = PersistedState(
        version: PersistedState.currentVersion,
        projects: [],
        conversations: [],
        settings: .default,
        blockedModelIDs: [],
        reports: [],
        customPricing: [:],
        credentials: [],
        selectedConversationID: nil,
        selectedProjectID: nil
    )

    enum CodingKeys: String, CodingKey {
        case version, projects, conversations, settings, blockedModelIDs, reports, customPricing
        case credentials
        case selectedConversationID, selectedProjectID
    }

    init(version: Int,
         projects: [AIProject],
         conversations: [Conversation],
         settings: AppSettings,
         blockedModelIDs: [String],
         reports: [ContentReport],
         customPricing: [String: PricePair],
         credentials: [APICredential] = [],
         selectedConversationID: UUID? = nil,
         selectedProjectID: UUID? = nil) {
        self.version = version
        self.projects = projects
        self.conversations = conversations
        self.settings = settings
        self.blockedModelIDs = blockedModelIDs
        self.reports = reports
        self.customPricing = customPricing
        self.credentials = credentials
        self.selectedConversationID = selectedConversationID
        self.selectedProjectID = selectedProjectID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.decodeOr(Int.self, .version, 1)
        // Elementweise dekodieren: ein defekter Eintrag darf nicht die
        // gesamte Chat- oder Projektliste kosten.
        projects = c.decodeLossyArray(AIProject.self, .projects)
        conversations = c.decodeLossyArray(Conversation.self, .conversations)
        settings = c.decodeOr(AppSettings.self, .settings, .default)
        blockedModelIDs = c.decodeLossyArray(String.self, .blockedModelIDs)
        reports = c.decodeLossyArray(ContentReport.self, .reports)
        customPricing = c.decodeOr([String: PricePair].self, .customPricing, [:])
        credentials = c.decodeLossyArray(APICredential.self, .credentials)
        // Fehlt der Schlüssel – etwa in einer Datei aus einer älteren
        // Fassung – bleibt es bei `nil`, und die App startet in der
        // Übersicht. Das ist der harmlosere von zwei Fällen.
        selectedConversationID = try? c.decodeIfPresent(UUID.self, forKey: .selectedConversationID)
        selectedProjectID = try? c.decodeIfPresent(UUID.self, forKey: .selectedProjectID)
        hasStoredSelection = c.contains(.selectedConversationID)
    }

    /// Von Hand, nicht synthetisiert – und das ist der ganze Punkt.
    ///
    /// Die synthetisierte Fassung benutzt für Optionals `encodeIfPresent`.
    /// Bei `nil` fehlte der Schlüssel dann in der Datei, und `contains` beim
    /// Lesen könnte „der Nutzer war in der Übersicht" nicht von „Datei aus
    /// einer älteren Fassung" unterscheiden – die App landete beim nächsten
    /// Start doch wieder im letzten Chat. `encodeNil` schreibt ein
    /// ausdrückliches `null`, und damit stimmt die Unterscheidung.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(projects, forKey: .projects)
        try c.encode(conversations, forKey: .conversations)
        try c.encode(settings, forKey: .settings)
        try c.encode(blockedModelIDs, forKey: .blockedModelIDs)
        try c.encode(reports, forKey: .reports)
        try c.encode(customPricing, forKey: .customPricing)
        try c.encode(credentials, forKey: .credentials)

        if let selectedConversationID {
            try c.encode(selectedConversationID, forKey: .selectedConversationID)
        } else {
            try c.encodeNil(forKey: .selectedConversationID)
        }
        if let selectedProjectID {
            try c.encode(selectedProjectID, forKey: .selectedProjectID)
        } else {
            try c.encodeNil(forKey: .selectedProjectID)
        }
    }
}
