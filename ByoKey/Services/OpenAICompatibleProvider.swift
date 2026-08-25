//
//  OpenAICompatibleProvider.swift
//  ByoKey
//
//  Zweite Implementierung des AIProviderProtocol – sie zeigt, dass die
//  Architektur modular ist: jeder Dienst mit OpenAI-kompatibler /chat/completions
//  Schnittstelle lässt sich ohne Änderung am Rest der App anbinden
//  (OpenAI, Groq, Together, Mistral, DeepSeek, lokale Server …).
//
//  Diese Anbieter liefern keine Preise mit der Modell-Liste. Die Kostenanzeige
//  fällt deshalb auf vom Nutzer hinterlegte Preise zurück und kennzeichnet
//  Werte klar als Schätzung, statt falsche Sicherheit vorzutäuschen.
//

import Foundation

struct OpenAICompatibleProvider: AIProviderProtocol {

    static let customBaseURLKey = "provider.custom.baseURL"
    static let customNameKey = "provider.custom.name"

    let id: String
    let displayName: String
    let legalEntity: String
    let keyPlaceholder: String
    let privacyPolicyURL: URL?
    let dataCategories: [String]
    let providesPricing: Bool
    let defaultBaseURL: String
    let allowsCustomBaseURL: Bool
    /// Ob dieser Endpunkt die Audio-Routen anbietet. Bei OpenAI ja, bei einem
    /// beliebigen kompatiblen Server nicht zwingend.
    let hasAudioEndpoints: Bool
    /// Sendet `stream_options: {include_usage: true}`? Nur vier der
    /// angebundenen Dienste führen das Feld in ihrer Dokumentation. Wer es
    /// nicht kennt, antwortet darauf mit HTTP 400 – dann käme gar keine
    /// Antwort, nur weil die App die Tokenzahl mitgeliefert haben wollte.
    let sendsStreamOptions: Bool
    /// Pfad des Bild-Endpunkts unterhalb der Basis-Adresse, oder nil.
    let imagePath: String?
    /// Zusatzfelder für Base64. Die drei Schreibweisen sind Anbietersache.
    let imageExtras: [String: String]
    private let privacyText: String

    init(id: String,
         displayName: String,
         legalEntity: String,
         keyPlaceholder: String,
         privacyPolicyURL: URL?,
         dataCategories: [String],
         defaultBaseURL: String,
         allowsCustomBaseURL: Bool,
         hasAudioEndpoints: Bool = false,
         sendsStreamOptions: Bool = false,
         imagePath: String? = nil,
         imageExtras: [String: String] = [:],
         privacyText: String) {
        self.id = id
        self.displayName = displayName
        self.legalEntity = legalEntity
        self.keyPlaceholder = keyPlaceholder
        self.privacyPolicyURL = privacyPolicyURL
        self.dataCategories = dataCategories
        self.providesPricing = false
        self.defaultBaseURL = defaultBaseURL
        self.allowsCustomBaseURL = allowsCustomBaseURL
        self.hasAudioEndpoints = hasAudioEndpoints
        self.sendsStreamOptions = sendsStreamOptions
        self.imagePath = imagePath
        self.imageExtras = imageExtras
        self.privacyText = privacyText
    }

    var audioBaseURL: String? { hasAudioEndpoints ? baseURL : nil }

    var imageEndpoint: String? { imagePath.map { "\(baseURL)\($0)" } }
    var imageRequestExtras: [String: String] { imageExtras }

    var privacySummary: String { privacyText }

    /// Bei "Eigener Endpunkt" darf der Nutzer die Basis-URL selbst setzen.
    var baseURL: String {
        if allowsCustomBaseURL,
           let stored = UserDefaults.standard.string(forKey: Self.customBaseURLKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty {
            return stored.hasSuffix("/") ? String(stored.dropLast()) : stored
        }
        return defaultBaseURL
    }

    var apiHost: String {
        URL(string: baseURL)?.host ?? baseURL
    }

    /// Für alle Anbieter identisch – es geht immer dasselbe raus.
    /// Einmal formuliert statt achtmal kopiert: so kann keine Aufzählung
    /// veralten, während die anderen aktuell bleiben.
    static let standardDataCategories = [
        "Der Text deiner Nachrichten",
        "Der Inhalt von Dateien, die du anhängst – als ausgelesener Text",
        "Bilder, die du anhängst – verkleinert und als JPEG",
        "Der System-Prompt des jeweiligen Projekts",
        "Der bisherige Verlauf des offenen Chats",
        "Die Kennung des gewählten Modells sowie Temperatur und maximale Antwortlänge",
        "Dein API-Schlüssel – ausschließlich zur Anmeldung bei diesem Anbieter",
        "Deine IP-Adresse – technisch bedingt bei jeder Internetverbindung"
    ]

    // MARK: - Vordefinierte Anbieter

    static let openAI = OpenAICompatibleProvider(
        id: "openai",
        displayName: "OpenAI",
        legalEntity: "OpenAI, L.L.C. (USA)",
        keyPlaceholder: "sk-…",
        privacyPolicyURL: URL(string: "https://openai.com/policies/privacy-policy"),
        dataCategories: standardDataCategories,
        defaultBaseURL: "https://api.openai.com/v1",
        allowsCustomBaseURL: false,
        hasAudioEndpoints: true,
        sendsStreamOptions: true,
        // Die gpt-image-Modelle liefern immer Base64; `response_format` gilt
        // nur für die alten DALL·E-Modelle und würde hier abgelehnt.
        imagePath: "/images/generations",
        privacyText: """
        Deine Nachrichten werden direkt von deinem iPhone an OpenAI, L.L.C. (USA) \
        gesendet und dort verarbeitet, also außerhalb deines Geräts und außerhalb \
        der EU. ByoKey betreibt keinen eigenen Server und erhält keine Kopie deiner Daten.
        """
    )

    static let mistral = OpenAICompatibleProvider(
        id: "mistral",
        displayName: "Mistral AI",
        legalEntity: "Mistral AI SAS (Frankreich)",
        keyPlaceholder: "API-Schlüssel",
        privacyPolicyURL: URL(string: "https://legal.mistral.ai/terms/privacy-policy"),
        dataCategories: standardDataCategories,
        defaultBaseURL: "https://api.mistral.ai/v1",
        allowsCustomBaseURL: false,
        hasAudioEndpoints: true,
        privacyText: """
        Deine Nachrichten werden direkt von deinem iPhone an Mistral AI SAS in Frankreich \
        gesendet. Der Anbieter gibt an, seine Server in der EU (Schweden) zu betreiben – \
        von den hier angebundenen Diensten der einzige mit dokumentierter Verarbeitung \
        in der EU. Zur Frage, ob Eingaben zum Training verwendet werden, widersprechen \
        sich Datenschutzerklärung und Hilfeseite des Anbieters; lies beides, bevor du \
        Vertrauliches eingibst. ByoKey betreibt keinen eigenen Server.
        """
    )

    static let deepSeek = OpenAICompatibleProvider(
        id: "deepseek",
        displayName: "DeepSeek",
        legalEntity: "Hangzhou DeepSeek Artificial Intelligence Co., Ltd. (China)",
        keyPlaceholder: "API-Schlüssel",
        privacyPolicyURL: URL(string: "https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html"),
        dataCategories: standardDataCategories,
        // Ohne "/v1": die Dokumentation nennt api.deepseek.com als Basis,
        // der Pfad lautet /chat/completions.
        defaultBaseURL: "https://api.deepseek.com",
        allowsCustomBaseURL: false,
        sendsStreamOptions: true,
        privacyText: """
        Achtung: Deine Nachrichten werden direkt von deinem iPhone an ein Unternehmen \
        in der Volksrepublik China gesendet. Der Anbieter schreibt in seiner \
        Datenschutzerklärung ausdrücklich, dass er personenbezogene Daten in China \
        erhebt, verarbeitet und speichert – auch in der Fassung für den EWR. Ausserdem \
        werden Eingaben zum Training der Modelle verwendet, solange du dem nicht \
        widersprichst. Für vertrauliche oder personenbezogene Inhalte ist das die \
        ungeeignetste Wahl in dieser Liste. ByoKey betreibt keinen eigenen Server.
        """
    )

    static let groq = OpenAICompatibleProvider(
        id: "groq",
        displayName: "Groq",
        legalEntity: "Groq LLC (USA) bzw. Groq UK Limited für Europa",
        keyPlaceholder: "gsk_…",
        privacyPolicyURL: URL(string: "https://groq.com/privacy-policy/"),
        dataCategories: standardDataCategories,
        defaultBaseURL: "https://api.groq.com/openai/v1",
        allowsCustomBaseURL: false,
        hasAudioEndpoints: true,
        sendsStreamOptions: true,
        privacyText: """
        Deine Nachrichten werden direkt von deinem iPhone an Groq gesendet. \
        Vertragspartner ist je nach Region Groq LLC (USA) oder Groq UK Limited; \
        gespeichert wird laut Anbieterdokumentation in den USA, also ausserhalb der EU. \
        Der Anbieter sagt zu, Eingaben nicht zum Training zu verwenden. \
        ByoKey betreibt keinen eigenen Server.
        """
    )

    static let xai = OpenAICompatibleProvider(
        id: "xai",
        displayName: "xAI (Grok)",
        legalEntity: "X.AI LLC (USA)",
        keyPlaceholder: "xai-…",
        privacyPolicyURL: URL(string: "https://x.ai/legal/privacy-policy"),
        dataCategories: standardDataCategories,
        defaultBaseURL: "https://api.x.ai/v1",
        allowsCustomBaseURL: false,
        // Ohne diese Angabe liefert xAI nur eine kurzlebige Adresse.
        imagePath: "/images/generations",
        imageExtras: ["response_format": "b64_json"],
        privacyText: """
        Deine Nachrichten werden direkt von deinem iPhone an X.AI LLC (USA) gesendet, \
        also ausserhalb der EU. Ob Eingaben über die Schnittstelle zum Training \
        verwendet werden, sagen die Unterlagen des Anbieters nicht eindeutig: die \
        Geschäftsbedingungen schliessen es aus, die Datenschutzerklärung für \
        Verbraucher nicht. ByoKey betreibt keinen eigenen Server.
        """
    )

    static let together = OpenAICompatibleProvider(
        id: "together",
        displayName: "Together AI",
        legalEntity: "Together Computer, Inc. (USA)",
        keyPlaceholder: "API-Schlüssel",
        privacyPolicyURL: URL(string: "https://www.together.ai/privacy"),
        dataCategories: standardDataCategories,
        defaultBaseURL: "https://api.together.ai/v1",
        allowsCustomBaseURL: false,
        hasAudioEndpoints: true,
        // Together schreibt „base64“, nicht „b64_json“ wie alle anderen.
        imagePath: "/images/generations",
        imageExtras: ["response_format": "base64", "output_format": "png"],
        privacyText: """
        Deine Nachrichten werden direkt von deinem iPhone an Together Computer, Inc. \
        (USA) gesendet, also ausserhalb der EU. Der Anbieter sagt zu, Daten ohne \
        ausdrückliche Einwilligung nicht zum Training zu verwenden. \
        ByoKey betreibt keinen eigenen Server.
        """
    )

    static let cerebras = OpenAICompatibleProvider(
        id: "cerebras",
        displayName: "Cerebras",
        legalEntity: "Cerebras Systems Inc. (USA)",
        keyPlaceholder: "API-Schlüssel",
        privacyPolicyURL: URL(string: "https://www.cerebras.ai/privacy-policy"),
        dataCategories: standardDataCategories,
        defaultBaseURL: "https://api.cerebras.ai/v1",
        allowsCustomBaseURL: false,
        privacyText: """
        Deine Nachrichten werden direkt von deinem iPhone an Cerebras Systems Inc. \
        (USA) gesendet, also ausserhalb der EU. Der Anbieter gibt an, Ein- und \
        Ausgaben nicht aufzubewahren. ByoKey betreibt keinen eigenen Server.
        """
    )

    static let gemini = OpenAICompatibleProvider(
        id: "gemini",
        displayName: "Google Gemini",
        legalEntity: "Google LLC (USA), in der EU Google Ireland Limited",
        keyPlaceholder: "AIza…",
        // Die Datenschutzerklärung, nicht die Nutzungsbedingungen: hier stand
        // vorher `ai.google.dev/gemini-api/terms`, während die Zeile daneben
        // „Datenschutzerklärung von Google Gemini" beschriftet ist. Wer darauf
        // tippt, muss auch eine finden – Richtlinie 5.1.2(i) hängt daran.
        privacyPolicyURL: URL(string: "https://policies.google.com/privacy"),
        dataCategories: standardDataCategories,
        // Googles OpenAI-kompatible Ebene liegt unter diesem Pfad.
        defaultBaseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
        allowsCustomBaseURL: false,
        sendsStreamOptions: true,
        imagePath: "/images/generations",
        imageExtras: ["response_format": "b64_json"],
        privacyText: """
        Deine Nachrichten werden direkt von deinem iPhone an Google gesendet und können \
        laut Google in jedem Land verarbeitet werden, in dem Google Rechenzentren \
        betreibt – also auch ausserhalb der EU. Wichtig: Bei einem Schlüssel aus dem \
        kostenlosen Kontingent nutzt Google Eingaben und Antworten zur Verbesserung \
        seiner Dienste und lässt sie teilweise von Menschen prüfen. Nur im \
        kostenpflichtigen Tarif ist das ausgeschlossen. ByoKey betreibt keinen \
        eigenen Server.
        """
    )

    static let custom = OpenAICompatibleProvider(
        id: "custom",
        displayName: "Eigener Endpunkt",
        legalEntity: "der von dir eingetragene Betreiber",
        keyPlaceholder: "API-Schlüssel",
        privacyPolicyURL: nil,
        dataCategories: standardDataCategories,
        defaultBaseURL: "https://api.openai.com/v1",
        allowsCustomBaseURL: true,
        privacyText: """
        Deine Nachrichten werden direkt von deinem iPhone an die von dir eingetragene \
        Adresse gesendet. Wer diesen Dienst betreibt und wie er die Daten verarbeitet, \
        bestimmst du selbst – ByoKey kann das nicht prüfen. Trage hier nur Endpunkte ein, \
        deren Betreiber du kennst und vertraust.
        """
    )

    // MARK: - Modelle

    private struct ModelEntry: Decodable {
        let id: String
    }

    /// Manche Dienste liefern `{"data":[…]}`, andere ein nacktes Array.
    /// Together AI ist so ein Fall – mit nur einer der beiden Formen bliebe
    /// die Modell-Liste dort leer.
    private struct ModelsResponse: Decodable {
        let data: [ModelEntry]

        init(from decoder: Decoder) throws {
            if let container = try? decoder.container(keyedBy: CodingKeys.self),
               let entries = try? container.decode([ModelEntry].self, forKey: .data) {
                data = entries
                return
            }
            data = try decoder.singleValueContainer().decode([ModelEntry].self)
        }

        private enum CodingKeys: String, CodingKey { case data }
    }

    func fetchModels(apiKey: String) async throws -> [AIModel] {
        try requireConsent()
        guard let url = URL(string: "\(baseURL)/models") else { throw ProviderError.badURL }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await ProviderHTTP.sharedSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.http(status: http.statusCode, message: ProviderHTTP.errorMessage(from: data))
        }

        let decoded = try ProviderHTTP.jsonDecoder.decode(ModelsResponse.self, from: data)
        return decoded.data
            .map { AIModel(id: $0.id,
                           name: $0.id,
                           providerID: id,
                           contextLength: 0,
                           promptPricePerToken: nil,
                           completionPricePerToken: nil,
                           summary: nil) }
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
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
        }
        struct APIError: Decodable {
            let message: String?

            enum CodingKeys: String, CodingKey { case message }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                message = (try? c.decodeIfPresent(String.self, forKey: .message)) ?? nil
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

                    var body: [String: Any] = [
                        "model": request.modelID,
                        "messages": request.turns.map(\.messagePayload),
                        "stream": true,
                        "temperature": request.temperature
                    ]
                    if sendsStreamOptions {
                        body["stream_options"] = ["include_usage": true]
                    }
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
                        guard line.hasPrefix("data:") else {
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
                            let message = ProviderHTTP.errorMessage(from: data)
                            if !message.isEmpty {
                                throw ProviderError.http(status: -1, message: message)
                            }
                            continue
                        }

                        if let message = chunk.error?.message {
                            throw ProviderError.http(status: -1, message: message)
                        }
                        if let text = chunk.choices?.first?.delta?.content, !text.isEmpty {
                            continuation.yield(.token(text))
                        }
                        if let usage = chunk.usage {
                            continuation.yield(.usage(prompt: usage.promptTokens,
                                                      completion: usage.completionTokens,
                                                      costUSD: nil))
                        }
                    }

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
}
