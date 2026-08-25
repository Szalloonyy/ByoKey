//
//  OpenRouterProvider.swift
//  ByoKey
//
//  Primärer Anbieter. OpenRouter liefert Modell-Liste inklusive Preisen und
//  meldet den tatsächlichen Verbrauch im letzten Stream-Chunk zurück – damit
//  ist die Kostenanzeige exakt und nicht geschätzt.
//
//  Datenfluss: Gerät -> https://openrouter.ai. Kein Zwischenserver von ByoKey.
//

import Foundation

struct OpenRouterProvider: AIProviderProtocol {

    static let identifier = "openrouter"

    let id = OpenRouterProvider.identifier
    let displayName = "OpenRouter"
    let legalEntity = "OpenRouter, Inc. (USA)"
    let apiHost = "openrouter.ai"
    let keyPlaceholder = "sk-or-v1-…"
    let providesPricing = true

    var dataCategories: [String] {
        [
            "Der Text deiner Nachrichten",
            "Der Inhalt von Dateien, die du anhängst – als ausgelesener Text",
            "Bilder, die du anhängst – verkleinert und als JPEG",
            "Der System-Prompt des jeweiligen Projekts",
            "Der bisherige Verlauf des offenen Chats",
            "Die Kennung des gewählten Modells sowie Temperatur und maximale Antwortlänge",
            "Dein API-Schlüssel – ausschließlich zur Anmeldung bei diesem Anbieter",
            "Deine IP-Adresse – technisch bedingt bei jeder Internetverbindung"
        ]
    }

    var privacySummary: String {
        """
        Deine Nachrichten werden direkt von deinem iPhone an OpenRouter, Inc. (USA) \
        gesendet und dort an den Betreiber des gewählten Modells weitergeleitet \
        (z. B. Anthropic, Google, Meta oder OpenAI). Die Verarbeitung findet auf \
        Servern dieser Unternehmen statt, also außerhalb deines Geräts und \
        möglicherweise außerhalb der EU. ByoKey betreibt keinen eigenen Server \
        und erhält keine Kopie deiner Daten.
        """
    }

    var privacyPolicyURL: URL? {
        URL(string: "https://openrouter.ai/privacy")
    }

    private let baseURL = "https://openrouter.ai/api/v1"

    /// OpenRouter hat seit 2026 OpenAI-kompatible Audio-Endpunkte
    /// (`/audio/speech`, `/audio/transcriptions`). Sie funktionieren aber nur
    /// mit Modellen, die Audio können – ein Chat-Modell wie Claude bleibt
    /// stumm. Die Auswahl passender Modelle übernimmt die Oberfläche.
    var audioBaseURL: String? { baseURL }

    // Ausreisser: bei OpenRouter heisst der Pfad `/images`, nicht
    // `/images/generations`. Base64 kommt hier ohne Zutun, und als einziger
    // Anbieter meldet OpenRouter die Kosten des Bildes mit zurück.
    var imageEndpoint: String? { "\(baseURL)/images" }

    /// Als einziger angebundener Anbieter nimmt OpenRouter Vorlagebilder für
    /// die Bilderzeugung entgegen – über `input_references`. Genau das braucht
    /// man, wenn ein eigenes Foto als Vorlage dienen soll, statt es in Worten
    /// zu beschreiben.
    var supportsImageReferences: Bool { true }

    // MARK: - Modelle

    private struct ModelsResponse: Decodable {
        struct Pricing: Decodable {
            let prompt: String?
            let completion: String?
            // Sprachmodelle rechnen hierüber ab, nicht über Tokens. Fehlten
            // diese Felder, meldete die Liste sie als kostenlos.
            let audio: String?
            let request: String?
            let image: String?
        }
        struct Architecture: Decodable {
            let inputModalities: [String]?
            let outputModalities: [String]?
        }
        struct Entry: Decodable {
            let id: String
            let name: String?
            let description: String?
            let contextLength: Int?
            let pricing: Pricing?
            let architecture: Architecture?
        }
        let data: [Entry]
    }

    func fetchModels(apiKey: String) async throws -> [AIModel] {
        try requireConsent()
        guard let url = URL(string: "\(baseURL)/models") else { throw ProviderError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        applyIdentityHeaders(to: &request)

        let (data, response) = try await ProviderHTTP.sharedSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.http(status: http.statusCode, message: ProviderHTTP.errorMessage(from: data))
        }

        let decoded = try ProviderHTTP.jsonDecoder.decode(ModelsResponse.self, from: data)

        return decoded.data.map { entry in
            AIModel(
                id: entry.id,
                name: entry.name ?? entry.id,
                providerID: id,
                contextLength: entry.contextLength ?? 0,
                promptPricePerToken: Self.price(entry.pricing?.prompt),
                completionPricePerToken: Self.price(entry.pricing?.completion),
                summary: entry.description,
                inputModalities: entry.architecture?.inputModalities,
                outputModalities: entry.architecture?.outputModalities,
                audioPricePerUnit: Self.price(entry.pricing?.audio),
                requestPrice: Self.price(entry.pricing?.request),
                imagePrice: Self.price(entry.pricing?.image)
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// OpenRouter liefert Preise als Zeichenkette in USD pro Token.
    /// Negative Werte bedeuten "variabel" und werden als unbekannt behandelt.
    private static func price(_ raw: String?) -> Double? {
        // `Double("1e400")` liefert +unendlich statt nil. Ein solcher Wert
        // würde die Sitzungskosten dauerhaft vergiften.
        guard let raw, let value = Double(raw), value.isFinite, value >= 0 else { return nil }
        return value
    }

    // MARK: - Guthaben (nur Anzeige)

    struct KeyInfo {
        /// Verbrauch **dieses** Schlüssels.
        var usageUSD: Double
        /// Ausgabegrenze dieses Schlüssels. `nil`, wenn keine gesetzt ist –
        /// das ist bei OpenRouter der Normalfall und kein Fehler.
        var limitUSD: Double?
        var isFreeTier: Bool
        /// Auf das Konto eingezahltes Guthaben, über alle Schlüssel.
        var accountCreditsUSD: Double?
        /// Gesamtverbrauch des Kontos, über alle Schlüssel.
        var accountUsageUSD: Double?

        /// Rest bis zur Grenze **dieses** Schlüssels.
        var remainingUSD: Double? {
            guard let limitUSD else { return nil }
            return max(0, limitUSD - usageUSD)
        }

        /// Verbleibendes Kontoguthaben – die Zahl, die die meisten suchen.
        var accountBalanceUSD: Double? {
            guard let accountCreditsUSD, let accountUsageUSD else { return nil }
            return accountCreditsUSD - accountUsageUSD
        }
    }

    private struct KeyResponse: Decodable {
        struct Payload: Decodable {
            let usage: Double?
            let limit: Double?
            let isFreeTier: Bool?
        }
        let data: Payload
    }

    private struct CreditsResponse: Decodable {
        struct Payload: Decodable {
            let totalCredits: Double?
            let totalUsage: Double?
        }
        let data: Payload
    }

    /// Reine Anzeige des beim Anbieter verbrauchten Guthabens.
    /// Bewusst OHNE Kauf-Link oder Aufforderung zum Aufladen
    /// (App Store Richtlinie 3.1.1 / 3.1.3 – keine externen Kaufwege bewerben).
    ///
    /// Zwei Abfragen, weil OpenRouter die Angaben trennt: `/key` kennt nur
    /// diesen einen Schlüssel, das Kontoguthaben steht unter `/credits`.
    /// Früher zeigte die App nur den Schlüsselverbrauch – bei einem Schlüssel
    /// ohne gesetzte Grenze also „kein Limit gesetzt" und sonst nichts, was
    /// wie ein Fehler aussah.
    func fetchKeyInfo(apiKey: String) async throws -> KeyInfo {
        try requireConsent()
        guard let url = URL(string: "\(baseURL)/key") else { throw ProviderError.badURL }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        applyIdentityHeaders(to: &request)

        let (data, response) = try await ProviderHTTP.sharedSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.http(status: http.statusCode, message: ProviderHTTP.errorMessage(from: data))
        }

        let decoded = try ProviderHTTP.jsonDecoder.decode(KeyResponse.self, from: data)
        let credits = await fetchCredits(apiKey: apiKey)

        return KeyInfo(
            usageUSD: decoded.data.usage ?? 0,
            limitUSD: decoded.data.limit,
            isFreeTier: decoded.data.isFreeTier ?? false,
            accountCreditsUSD: credits?.credits,
            accountUsageUSD: credits?.usage
        )
    }

    /// Kontoguthaben. Schlägt bewusst leise fehl: manche Schlüssel dürfen
    /// diesen Endpunkt nicht lesen, und dann soll trotzdem der Schlüssel-
    /// verbrauch erscheinen statt einer Fehlermeldung.
    private func fetchCredits(apiKey: String) async -> (credits: Double, usage: Double)? {
        // Diese Abfrage liefert `nil` statt zu werfen; die Freigabe wird
        // trotzdem verlangt.
        do { try requireConsent() } catch { return nil }
        guard let url = URL(string: "\(baseURL)/credits") else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        applyIdentityHeaders(to: &request)

        guard let (data, response) = try? await ProviderHTTP.sharedSession.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let decoded = try? ProviderHTTP.jsonDecoder.decode(CreditsResponse.self, from: data),
              let credits = decoded.data.totalCredits,
              let usage = decoded.data.totalUsage,
              credits.isFinite, usage.isFinite else { return nil }

        return (credits, usage)
    }

    // MARK: - Streaming

    private struct Chunk: Decodable {
        struct Delta: Decodable {
            let content: String?
        }
        struct Choice: Decodable {
            let delta: Delta?
        }
        struct Usage: Decodable {
            let promptTokens: Int?
            let completionTokens: Int?
            let cost: Double?
        }
        struct APIError: Decodable {
            let message: String?
            let code: Int?

            enum CodingKeys: String, CodingKey { case message, code }

            // Nie werfen: `code` kommt je nach Upstream als Zahl ODER als Text
            // ("insufficient_quota"). Ein Wurf hier würde den ganzen Chunk –
            // und damit die Fehlermeldung – verschlucken.
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                message = (try? c.decodeIfPresent(String.self, forKey: .message)) ?? nil
                code = (try? c.decodeIfPresent(Int.self, forKey: .code)) ?? nil
            }
        }
        let choices: [Choice]?
        let usage: Usage?
        let error: APIError?
    }

    func streamCompletion(_ request: ChatCompletionRequest, apiKey: String) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try requireConsent()
                    guard let url = URL(string: "\(baseURL)/chat/completions") else {
                        throw ProviderError.badURL
                    }

                    var urlRequest = URLRequest(url: url)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    applyIdentityHeaders(to: &urlRequest)

                    var body: [String: Any] = [
                        "model": request.modelID,
                        "messages": request.turns.map(\.messagePayload),
                        "stream": true,
                        "temperature": request.temperature,
                        // Bittet OpenRouter, den echten Verbrauch mitzuliefern.
                        "usage": ["include": true]
                    ]
                    if let maxTokens = request.maxTokens, maxTokens > 0 {
                        body["max_tokens"] = maxTokens
                    }
                    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await ProviderHTTP.sharedSession.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else {
                        throw ProviderError.invalidResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        let data = await ProviderHTTP.drain(bytes)
                        throw ProviderError.http(status: http.statusCode,
                                                 message: ProviderHTTP.errorMessage(from: data))
                    }

                    let decoder = ProviderHTTP.jsonDecoder
                    var sawSSEData = false
                    var strayBody = Data()

                    for try await line in bytes.lines {
                        if Task.isCancelled { throw ProviderError.cancelled }

                        // Server-Sent-Events: Kommentarzeilen (": …") ignorieren.
                        guard line.hasPrefix("data:") else {
                            // Kein SSE-Rumpf: mitschneiden, um ihn später als
                            // Fehler melden zu können statt still zu enden.
                            if !sawSSEData, strayBody.count < 8_192 {
                                strayBody.append(contentsOf: Array(line.utf8))
                            }
                            continue
                        }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload.isEmpty { continue }
                        if payload == "[DONE]" { sawSSEData = true; break }
                        guard let data = payload.data(using: .utf8) else { continue }
                        sawSSEData = true

                        let chunk: Chunk
                        do {
                            chunk = try decoder.decode(Chunk.self, from: data)
                        } catch {
                            // Nicht dekodierbar heißt oft: es ist eine
                            // Fehlermeldung in unerwarteter Form.
                            let message = ProviderHTTP.errorMessage(from: data)
                            if !message.isEmpty {
                                throw ProviderError.http(status: -1, message: message)
                            }
                            continue
                        }

                        if let apiError = chunk.error, let message = apiError.message {
                            throw ProviderError.http(status: apiError.code ?? -1, message: message)
                        }
                        if let text = chunk.choices?.first?.delta?.content, !text.isEmpty {
                            continuation.yield(.token(text))
                        }
                        if let usage = chunk.usage {
                            continuation.yield(.usage(prompt: usage.promptTokens,
                                                      completion: usage.completionTokens,
                                                      costUSD: usage.cost))
                        }
                    }

                    // HTTP 200 mit einem Rumpf, der kein Event-Stream ist –
                    // z. B. ein JSON-Fehler oder eine Proxy-Seite. Ohne diese
                    // Prüfung endet der Stream still und der Nutzer sieht eine
                    // leere Antwort ohne jeden Hinweis.
                    guard sawSSEData else {
                        let message = ProviderHTTP.errorMessage(from: strayBody)
                        throw ProviderError.http(status: http.statusCode,
                                                 message: message.isEmpty
                                                     ? Loc.tr("Die Antwort war kein Event-Stream.")
                                                     : message)
                    }

                    continuation.yield(.finished)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Header

    /// OpenRouter empfiehlt diese optionalen Header zur App-Identifikation.
    /// Sie enthalten keine Nutzerdaten.
    private func applyIdentityHeaders(to request: inout URLRequest) {
        request.setValue("https://byokey.app", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("ByoKey", forHTTPHeaderField: "X-Title")
    }
}
