//
//  AIProvider.swift
//  ByoKey
//
//  Abstraktion über KI-Anbieter. Ein neuer Anbieter braucht nur eine weitere
//  Implementierung dieses Protokolls plus einen Eintrag in der ProviderRegistry.
//
//  WICHTIG (App Store Richtlinie 5.1.2(i)): Jeder Anbieter muss offenlegen,
//  wohin die Daten fließen. `displayName`, `dataCategories` und
//  `privacySummary` werden wörtlich im Zustimmungsdialog angezeigt – Apple
//  lehnt generische Formulierungen wie "powered by AI" ab.
//

import Foundation

// MARK: - Anfrage

struct ChatTurn: Codable, Hashable {
    let role: String
    let content: String
    /// Angehängte Bilder als Data-URLs (`data:image/jpeg;base64,…`).
    ///
    /// Nur bei Nachrichten des Nutzers, und nur solche Anhänge, die der Nutzer
    /// zugeschaltet gelassen hat.
    ///
    /// **Nicht** gefiltert nach dem, was das Modell kann: ob ein Modell Bilder
    /// entgegennimmt, weiss allein der Anbieter, und seine Modell-Liste ist
    /// nicht immer aktuell. Ein Bild hier stillschweigend wegzulassen hiesse,
    /// eine Antwort zu bekommen, die das Bild ignoriert, ohne dass jemand es
    /// sagt. Lehnt der Anbieter ab, steht der Grund in der Fehlermeldung – und
    /// die Chat-Ansicht warnt ohnehin vorher, wenn die Modell-Liste „nur
    /// Text" meldet.
    ///
    /// Der Inhaltsfilter sieht die Bilder **nicht** – er arbeitet auf Text.
    /// Das steht so auch in den Review-Notizen: für Bildinhalte tragen die
    /// Moderation des Anbieters und die Melde- und Sperrfunktion der App.
    var images: [String] = []

    /// Was diese Bilder im Kontextfenster und in der Abrechnung kosten.
    ///
    /// Getrennt geführt und **nicht** aus `images` errechnet: die Data-URL
    /// verrät die Kantenlängen nicht, und die Kachelrechnung braucht sie.
    /// Ohne dieses Feld zählte `TokenEstimator.estimate(turns:)` ein Bild mit
    /// null – und genau dieser Wert ist es, der bei Anbietern ohne
    /// Verbrauchsmeldung in der Kostenanzeige landet.
    ///
    /// Geht **nicht** mit in den JSON-Rumpf: `messagePayload` ignoriert ihn.
    var imageTokens: Int = 0

    /// Wie die Nachricht im JSON-Rumpf aussieht.
    ///
    /// Ohne Bilder die schlichte Form `{"role":…,"content":"…"}`, die jeder
    /// Anbieter versteht. Mit Bildern die Teileform, wie sie die
    /// OpenAI-kompatible Schnittstelle vorsieht. Bewusst **nur dann**: manche
    /// Endpunkte stolpern über eine Teileliste, wenn gar kein Bild dabei ist.
    ///
    /// Der Text steht vorn. Modelle lesen die Anweisung sonst erst nach dem
    /// Bild und beziehen sie schlechter darauf.
    var messagePayload: [String: Any] {
        guard !images.isEmpty else {
            return ["role": role, "content": content]
        }
        var parts: [[String: Any]] = []
        if !content.isEmpty {
            parts.append(["type": "text", "text": content])
        }
        for url in images {
            parts.append(["type": "image_url", "image_url": ["url": url]])
        }
        return ["role": role, "content": parts]
    }
}

struct ChatCompletionRequest {
    var modelID: String
    var turns: [ChatTurn]
    var temperature: Double
    var maxTokens: Int?
}

// MARK: - Stream-Ereignisse

enum StreamEvent {
    /// Ein Textstück der Antwort.
    case token(String)
    /// Vom Anbieter gemeldeter Verbrauch. `costUSD` liefert nur OpenRouter.
    ///
    /// Die Zahlen sind bewusst optional: `nil` heißt "nicht gemeldet" und ist
    /// etwas anderes als 0. Mit `?? 0` würde ein fehlender Wert als exakte
    /// Null gelten und die halben Kosten eines langen Kontexts verschlucken.
    case usage(prompt: Int?, completion: Int?, costUSD: Double?)
    /// Der Stream ist regulär beendet.
    case finished
}

// MARK: - Fehler

/// Ein erzeugtes Bild samt gemeldeter Kosten.
struct GeneratedImage {
    var data: Data
    var mimeType: String
    /// Nur OpenRouter meldet einen USD-Betrag zurück.
    var costUSD: Double?
}

/// Ergebnis einer Spracherkennung beim Anbieter.
struct TranscriptionResult {
    var text: String
    /// Nur OpenRouter meldet die Kosten zurück; sonst nil.
    var costUSD: Double?
    var seconds: Double?
}

enum ProviderError: LocalizedError, Equatable {
    case missingKey(provider: String)
    case consentRequired(provider: String)
    case badURL
    case invalidResponse
    case http(status: Int, message: String)
    case blockedByFilter(reason: String)
    case modelBlocked
    case cancelled
    case audioUnsupported(provider: String)
    case emptyTranscript
    case imageUnsupported(provider: String)
    case referencesUnsupported(provider: String)
    case emptyImage

    /// Der deutsche Text ist zugleich der Schlüssel im String-Katalog.
    /// Deshalb `Loc.tr` und Platzhalter statt Swift-Interpolation: ein fertig
    /// zusammengesetzter Satz findet keinen Eintrag mehr und bliebe in jeder
    /// Sprache deutsch. Diese Meldungen landen als Nachrichtentext im Verlauf
    /// und werden dort nicht noch einmal nachgeschlagen.
    var errorDescription: String? {
        switch self {
        case .missingKey(let provider):
            return Loc.tr("Kein API-Schlüssel für %@ hinterlegt. Du kannst ihn in den Einstellungen eintragen.", provider)
        case .consentRequired(let provider):
            return Loc.tr("Die Datenfreigabe an %@ wurde noch nicht erteilt. Ohne Zustimmung sendet ByoKey nichts.", provider)
        case .badURL:
            return Loc.tr("Die Adresse des Anbieters ist ungültig.")
        case .invalidResponse:
            return Loc.tr("Der Anbieter hat eine unerwartete Antwort geliefert.")
        case .http(let status, let message):
            switch status {
            case 401, 403:
                return Loc.tr("Der API-Schlüssel wurde abgelehnt (HTTP %lld). Bitte prüfe ihn in den Einstellungen. %@", status, message)
            case 402:
                return Loc.tr("Das Guthaben beim Anbieter reicht nicht aus (HTTP 402). %@", message)
            case 429:
                return Loc.tr("Zu viele Anfragen (HTTP 429). Bitte kurz warten. %@", message)
            default:
                return Loc.tr("Anbieterfehler (HTTP %lld). %@", status, message)
            }
        case .blockedByFilter(let reason):
            return reason
        case .modelBlocked:
            return Loc.tr("Dieses Modell hast du gesperrt. Du kannst die Sperre in den Einstellungen aufheben.")
        case .cancelled:
            return Loc.tr("Die Anfrage wurde abgebrochen.")
        case .audioUnsupported(let provider):
            return Loc.tr("%@ bietet keine Sprach-Endpunkte. Nutze den Sprachmodus „Auf dem Gerät“ oder wähle einen Anbieter mit Audio-Unterstützung.", provider)
        case .emptyTranscript:
            return Loc.tr("Es wurde nichts erkannt. Bitte noch einmal sprechen.")
        case .imageUnsupported(let provider):
            return Loc.tr("%@ erzeugt keine Bilder. Wähle einen Anbieter mit Bildmodellen oder ein Modell, das Bilder ausgeben kann.", provider)
        case .referencesUnsupported(let provider):
            return Loc.tr("%@ nimmt bei der Bilderzeugung keine Vorlagenbilder entgegen. Entferne das Bild – oder wechsle zu einem Anbieter, der Vorlagen unterstützt.", provider)
        case .emptyImage:
            return Loc.tr("Der Anbieter hat kein Bild zurückgeliefert.")
        }
    }
}

// MARK: - Protokoll

/// Bewusst NICHT von Identifiable abgeleitet: `any AIProviderProtocol` bleibt
/// dadurch frei von assoziierten Typen und lässt sich in SwiftUI-Listen und
/// KeyPaths (\.id) ohne Umweg verwenden.
protocol AIProviderProtocol {
    var id: String { get }
    var displayName: String { get }
    /// Firma bzw. juristische Einheit, die die Daten empfängt – wird im
    /// Zustimmungsdialog namentlich genannt (Richtlinie 5.1.2(i)).
    var legalEntity: String { get }
    /// Konkrete Datenkategorien, die das Gerät verlassen.
    var dataCategories: [String] { get }
    /// Ein bis zwei Sätze zur Verarbeitung beim Anbieter.
    var privacySummary: String { get }
    var privacyPolicyURL: URL? { get }
    var apiHost: String { get }
    var keyPlaceholder: String { get }
    var keychainAccount: String { get }
    /// Liefert der Anbieter Preisangaben mit der Modell-Liste?
    var providesPricing: Bool { get }

    /// Vollständige Adresse des Bild-Endpunkts, oder nil, wenn der Anbieter
    /// keine Bilder erzeugt.
    ///
    /// Bewusst die ganze Adresse und nicht nur ein Pfadstück: vier der fünf
    /// Anbieter mit Bilderzeugung hören auf `/images/generations`, OpenRouter
    /// dagegen auf `/images`.
    var imageEndpoint: String? { get }

    /// Nimmt der Bild-Endpunkt dieses Anbieters **Referenzbilder** entgegen?
    ///
    /// Nur OpenRouter kann das über `input_references`. Die übrigen sprechen
    /// `/images/generations`, und dort gibt es kein Feld dafür – Bild-zu-Bild
    /// läuft bei OpenAI über einen eigenen Endpunkt mit mehrteiligem Rumpf.
    /// Statt zu raten sagt die App, wo es geht und wo nicht.
    var supportsImageReferences: Bool { get }

    /// Zusatzfelder, die dieser Anbieter braucht, um Base64 statt einer
    /// Adresse zu liefern. Drei Schreibweisen für dieselbe Sache:
    /// OpenAI braucht nichts, Together will `"base64"`, xAI und Google
    /// wollen `"b64_json"`.
    var imageRequestExtras: [String: String] { get }

    /// Basis-Adresse der Audio-Endpunkte, oder nil, wenn der Anbieter keine hat.
    ///
    /// Beide unterstützten Anbieter sprechen dieselbe, OpenAI-kompatible
    /// Schnittstelle (`/audio/transcriptions`, `/audio/speech`). Deshalb steht
    /// die Umsetzung einmal in der Erweiterung unten und nicht doppelt in den
    /// beiden Anbietern.
    var audioBaseURL: String? { get }

    func fetchModels(apiKey: String) async throws -> [AIModel]
    func streamCompletion(_ request: ChatCompletionRequest, apiKey: String) -> AsyncThrowingStream<StreamEvent, Error>
    func transcribe(audio: Data, fileExtension: String, modelID: String,
                    language: String?, apiKey: String) async throws -> TranscriptionResult
    func synthesize(text: String, modelID: String, voice: String, apiKey: String) async throws -> Data
    func generateImage(prompt: String, modelID: String, apiKey: String,
                       references: [String]) async throws -> GeneratedImage
}

/// Antwort der Bild-Endpunkte. Ein Typ für alle fünf Anbieter, weil sich die
/// Felder nur ergänzen und nicht widersprechen: Base64 steht überall unter
/// `data[].b64_json`, uneinig sind sie sich nur beim Formatfeld
/// (`media_type` / `mime_type` / `output_format` / gar nichts).
private struct ImagePayload: Decodable {
    struct Entry: Decodable {
        let b64Json: String?
        let mediaType: String?
        let mimeType: String?
    }
    struct Usage: Decodable {
        let cost: Double?
    }
    let data: [Entry]?
    let outputFormat: String?
    let usage: Usage?
}

/// Antwort der Erkennungs-Endpunkte.
///
/// Bewusst auf Dateiebene und nicht in `transcribe` verschachtelt: Methoden in
/// einer Protokoll-Erweiterung sind implizit generisch über `Self`, und in
/// einer generischen Funktion darf kein Typ deklariert werden. Der Compiler
/// meldet das als „Type 'Payload' cannot be nested in generic function".
private struct TranscriptionPayload: Decodable {
    struct Usage: Decodable {
        let cost: Double?
        let seconds: Double?
    }
    let text: String?
    let usage: Usage?
}

extension AIProviderProtocol {

    var keychainAccount: String { "apikey.\(id)" }

    // MARK: - Bilder

    /// Standard: keine Bilderzeugung.
    var imageEndpoint: String? { nil }
    var imageRequestExtras: [String: String] { [:] }
    var supportsImageReferences: Bool { false }
    var canGenerateImages: Bool { imageEndpoint != nil }

    /// Erzeugt ein Bild. Alle fünf Anbieter mit Bilderzeugung nehmen
    /// `model` + `prompt` und liefern Base64 unter `data[].b64_json`.
    /// Der Torwächter für Richtlinie 5.1.2(i), **im Netz-Layer**.
    ///
    /// Vorher lagen die Prüfungen ausschliesslich in `AppState` und in zwei
    /// Ansichten. Das war lückenlos, aber nur solange niemand einen neuen
    /// Aufrufpfad einbaut – und die Review-Notizen behaupten ausdrücklich,
    /// die Sperre liege im Modell-Layer und nicht in der Oberfläche. Jetzt
    /// stimmt der Satz wörtlich: hier kommt keine Anfrage vorbei.
    func requireConsent(scope: ConsentScope = .text) throws {
        guard ConsentGate.isGranted(id, scope: scope) else {
            throw ProviderError.consentRequired(provider: displayName)
        }
    }

    func generateImage(prompt: String, modelID: String, apiKey: String,
                       references: [String] = []) async throws -> GeneratedImage {
        try requireConsent()
        guard let endpoint = imageEndpoint, let url = URL(string: endpoint) else {
            throw ProviderError.imageUnsupported(provider: displayName)
        }
        // Lieber gar nicht senden als stillschweigend weglassen: wer ein
        // Referenzbild anhängt und ein Bild ohne jeden Bezug zurückbekommt,
        // sucht den Fehler bei sich.
        guard references.isEmpty || supportsImageReferences else {
            throw ProviderError.referencesUnsupported(provider: displayName)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = ["model": modelID, "prompt": prompt, "n": 1]
        if !references.isEmpty {
            // Form laut OpenRouter: dieselben Teile wie in einer Chat-Nachricht,
            // die Adresse darf eine Data-URL sein.
            body["input_references"] = references.map { url in
                ["type": "image_url", "image_url": ["url": url]]
            }
        }
        for (key, value) in imageRequestExtras { body[key] = value }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Bilderzeugung dauert deutlich länger als eine Textantwort.
        let (data, response) = try await ProviderHTTP.sharedSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.http(status: http.statusCode,
                                     message: ProviderHTTP.errorMessage(from: data))
        }

        guard let payload = try? ProviderHTTP.jsonDecoder.decode(ImagePayload.self, from: data),
              let entry = payload.data?.first,
              let base64 = entry.b64Json,
              let bytes = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              !bytes.isEmpty else {
            throw ProviderError.emptyImage
        }

        // Formatangabe: jeder Anbieter nennt das Feld anders, einer gar nicht.
        // Fehlt sie, entscheiden die ersten Bytes.
        let type = entry.mediaType ?? entry.mimeType
            ?? payload.outputFormat.map { "image/\($0)" }
            ?? "image/\(ImageStore.sniff(bytes))"

        return GeneratedImage(data: bytes, mimeType: type, costUSD: payload.usage?.cost)
    }

    /// Standard: keine Audio-Unterstützung. Anbieter, die welche haben,
    /// überschreiben diese Eigenschaft.
    var audioBaseURL: String? { nil }

    var supportsAudio: Bool { audioBaseURL != nil }

    // MARK: - Spracherkennung

    /// Sendet die Aufnahme als multipart/form-data. Diese Form versteht sowohl
    /// OpenAI als auch OpenRouter; OpenRouters JSON-Variante mit base64 wäre
    /// nur bei einem der beiden nutzbar.
    func transcribe(audio: Data, fileExtension: String, modelID: String,
                    language: String?, apiKey: String) async throws -> TranscriptionResult {
        try requireConsent(scope: .audio)
        guard let base = audioBaseURL,
              let url = URL(string: "\(base)/audio/transcriptions") else {
            throw ProviderError.audioUnsupported(provider: displayName)
        }

        let boundary = "byokey-\(UUID().uuidString)"
        var fields: [String: String] = ["model": modelID, "response_format": "json"]
        if let language, !language.isEmpty {
            // Nur der Sprachcode, nicht die Region: "de" statt "de-DE".
            fields["language"] = String(language.prefix(2))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = ProviderHTTP.multipartBody(boundary: boundary,
                                                      fields: fields,
                                                      fileField: "file",
                                                      filename: "aufnahme.\(fileExtension)",
                                                      mimeType: ProviderHTTP.mimeType(for: fileExtension),
                                                      fileData: audio)

        let (data, response) = try await ProviderHTTP.sharedSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.http(status: http.statusCode,
                                     message: ProviderHTTP.errorMessage(from: data))
        }

        guard let decoded = try? ProviderHTTP.jsonDecoder.decode(TranscriptionPayload.self, from: data),
              let text = decoded.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw ProviderError.emptyTranscript
        }
        return TranscriptionResult(text: text,
                                   costUSD: decoded.usage?.cost,
                                   seconds: decoded.usage?.seconds)
    }

    // MARK: - Sprachausgabe

    /// Liefert MP3-Daten. `response_format` wird ausdrücklich gesetzt:
    /// OpenRouter antwortet sonst mit rohem PCM, das AVAudioPlayer nicht
    /// ohne Weiteres abspielt.
    func synthesize(text: String, modelID: String, voice: String, apiKey: String) async throws -> Data {
        try requireConsent(scope: .audio)
        guard let base = audioBaseURL,
              let url = URL(string: "\(base)/audio/speech") else {
            throw ProviderError.audioUnsupported(provider: displayName)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": modelID,
            "input": String(text.prefix(4000)),
            "voice": voice,
            "response_format": "mp3"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await ProviderHTTP.sharedSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.http(status: http.statusCode,
                                     message: ProviderHTTP.errorMessage(from: data))
        }
        guard data.count > 128 else { throw ProviderError.invalidResponse }
        return data
    }
}

// MARK: - Gemeinsame Netzwerk-Helfer

enum ProviderHTTP {

    static var jsonDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    /// Liest bis zu 8 KB Fehlertext und versucht, die Anbieter-Fehlermeldung
    /// herauszuziehen, damit der Nutzer nicht nur einen Statuscode sieht.
    static func errorMessage(from data: Data) -> String {
        KeychainStore.redactingSecrets(in: rawErrorMessage(from: data))
    }

    /// Der Text des Anbieters, ungefiltert.
    ///
    /// Getrennt, damit das Schwärzen **eine** Stelle ist: dieser Text landet
    /// über die Fehlermeldung als Nachricht im Verlauf und damit in der
    /// Zustandsdatei. Mehrere Dienste schreiben bei HTTP 401 den abgelehnten
    /// Schlüssel in verkürzter Form in ihre Antwort.
    private static func rawErrorMessage(from data: Data) -> String {
        guard !data.isEmpty else { return "" }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data.prefix(300), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        // Manche Anbieter (Groq, Ollama, vLLM) liefern `error` direkt als Text.
        if let message = object["error"] as? String { return message }
        if let message = object["message"] as? String { return message }
        if let detail = object["detail"] as? String { return detail }
        return ""
    }

    /// Baut einen multipart/form-data-Rumpf. Die Feldnamen sind fest verdrahtet
    /// und enthalten keine Nutzereingaben – deshalb genügt hier eine einfache
    /// Verkettung ohne weitere Bereinigung.
    static func multipartBody(boundary: String,
                              fields: [String: String],
                              fileField: String,
                              filename: String,
                              mimeType: String,
                              fileData: Data) -> Data {
        var body = Data()
        let newline = "\r\n"

        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            body.append(Data("--\(boundary)\(newline)".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(key)\"\(newline)\(newline)".utf8))
            body.append(Data("\(value)\(newline)".utf8))
        }

        body.append(Data("--\(boundary)\(newline)".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\"\(newline)".utf8))
        body.append(Data("Content-Type: \(mimeType)\(newline)\(newline)".utf8))
        body.append(fileData)
        body.append(Data(newline.utf8))
        body.append(Data("--\(boundary)--\(newline)".utf8))
        return body
    }

    static func mimeType(for fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "m4a", "mp4": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "caf": return "audio/x-caf"
        case "flac": return "audio/flac"
        default: return "application/octet-stream"
        }
    }

    /// Sammelt den Rumpf einer fehlerhaften Streaming-Antwort.
    static func drain(_ bytes: URLSession.AsyncBytes, limit: Int = 8_192) async -> Data {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= limit { break }
            }
        } catch {
            // Teilweise gelesener Rumpf reicht für die Fehlermeldung.
        }
        return data
    }

    static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        // Bei Streams ist das die maximale Pause ZWISCHEN zwei Paketen.
        config.timeoutIntervalForRequest = 60
        // Keine enge Gesamtgrenze: lange Antworten laufen über 10 Minuten
        // hinaus. Gegen hängende Verbindungen schützt der Request-Timeout.
        config.timeoutIntervalForResource = 3_600
        // Ohne Netz sofort scheitern, statt den Nutzer vor einer endlosen
        // Tippanzeige sitzen zu lassen.
        config.waitsForConnectivity = false
        // Kein Caching von Antworten mit potenziell privaten Inhalten.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()
}

// MARK: - Registry

/// Zentrale Liste aller unterstützten Anbieter.
/// Ein weiterer Anbieter = eine weitere Zeile hier.
enum ProviderRegistry {

    /// Für Version 1.0 bewusst nur benannte Anbieter.
    ///
    /// `OpenAICompatibleProvider.custom` ist implementiert, steht hier aber
    /// absichtlich NICHT drin: Richtlinie 5.1.2(i) verlangt, dass der
    /// Empfänger der Daten im Zustimmungsdialog namentlich genannt wird.
    /// Bei einer frei eintragbaren URL ist der Empfänger unbekannt, und die
    /// Zustimmung wäre zudem nicht an den konkreten Host gebunden – ein
    /// späterer Wechsel der Adresse würde eine einmal erteilte Freigabe
    /// stillschweigend mitnehmen. Vor einer Freischaltung muss der
    /// Zustimmungsdatensatz auf "custom|<host>" umgestellt, ein Name des
    /// Betreibers abgefragt und das Schema auf https begrenzt werden.
    /// Reihenfolge mit Absicht: OpenRouter zuerst, weil er als einziger
    /// Preise mitliefert; danach Mistral, weil er als einziger dokumentiert
    /// in der EU verarbeitet. Der Rest alphabetisch.
    ///
    /// Nicht dabei ist Fireworks AI: dort führen die Modellkennungen einen
    /// Pfad (`accounts/fireworks/models/…`) und es gibt keine Modell-Liste im
    /// OpenAI-Format. Beides liesse sich nachrüsten, wäre aber ein Sonderfall
    /// im sonst einheitlichen Ablauf.
    static let all: [any AIProviderProtocol] = [
        OpenRouterProvider(),
        OpenAICompatibleProvider.mistral,
        OpenAICompatibleProvider.openAI,
        OpenAICompatibleProvider.cerebras,
        OpenAICompatibleProvider.deepSeek,
        OpenAICompatibleProvider.gemini,
        OpenAICompatibleProvider.groq,
        OpenAICompatibleProvider.together,
        OpenAICompatibleProvider.xai
    ]

    static func provider(id: String) -> (any AIProviderProtocol)? {
        all.first { $0.id == id }
    }

    static func providerOrDefault(id: String) -> any AIProviderProtocol {
        provider(id: id) ?? OpenRouterProvider()
    }
}
