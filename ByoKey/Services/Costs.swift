//
//  Costs.swift
//  ByoKey
//
//  Token-Schätzung, Kostenberechnung und Formatierung.
//
//  Grundregel der App: Ein Kostenwert wird nur dann ohne Kennzeichnung
//  angezeigt, wenn er nachweislich exakt ist. Dafür meldet der Rechner
//  zurück, WOHER der Wert stammt – ein aus der offiziellen Preisliste und
//  gemeldeten Tokens berechneter Betrag ist exakt und darf kein "ca." tragen.
//

import Foundation

enum TokenEstimator {

    /// Schätzung für Anbieter, die keinen Verbrauch zurückmelden.
    ///
    /// Gezählt werden UTF-8-Bytes, nicht Zeichen: "👨‍👩‍👧‍👦" ist EIN Character,
    /// aber 25 Bytes und rund 10 Tokens. Mit `text.count` würde der Verlauf
    /// beim Kürzen um ein Vielfaches unterschätzt – die Anfrage wird dann
    /// vom Anbieter wegen Kontextüberlauf abgelehnt. Aufgerundet, damit die
    /// Schätzung im Zweifel zu hoch statt zu niedrig ausfällt.
    static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return max(1, Int((Double(text.utf8.count) / 4.0).rounded(.up)))
    }

    static func estimate(turns: [ChatTurn]) -> Int {
        // Pro Nachricht kommen ein paar Struktur-Tokens hinzu.
        //
        // `imageTokens` gehört dazu: bei den Anbietern, die keinen Verbrauch
        // zurückmelden, ist dieser Wert die Kostenanzeige. Ohne ihn kostete
        // ein angehängtes Bild in der Abrechnung nichts, während dieselbe App
        // an anderer Stelle rund 1 600 Tokens dafür ausweist.
        turns.reduce(0) { $0 + estimate($1.content) + $1.imageTokens + 4 }
    }
}

struct CostBreakdown: Hashable {
    var promptTokens: Int
    var completionTokens: Int
    var costUSD: Double?
    var isEstimate: Bool

    var totalTokens: Int { promptTokens + completionTokens }
}

/// Woher ein Kostenwert stammt. Entscheidet über die Kennzeichnung.
enum CostSource {
    /// Der Anbieter hat den Betrag selbst genannt.
    case providerReported
    /// Aus der Preisliste des Anbieters berechnet – exakt, sofern die Tokens
    /// gemeldet wurden.
    case providerPriceTable
    /// Aus einem vom Nutzer hinterlegten Preis berechnet.
    case userPricing
    /// Kein Preis bekannt.
    case unknown
}

enum CostCalculator {

    static func cost(promptTokens: Int,
                     completionTokens: Int,
                     model: AIModel?,
                     customPricing: PersistedState.PricePair?,
                     reportedCostUSD: Double?) -> (usd: Double?, source: CostSource) {

        if let reportedCostUSD, reportedCostUSD.isFinite, reportedCostUSD >= 0 {
            return (reportedCostUSD, .providerReported)
        }

        if let model,
           let inPrice = model.promptPricePerToken, inPrice.isFinite,
           let outPrice = model.completionPricePerToken, outPrice.isFinite {
            let value = Double(promptTokens) * inPrice + Double(completionTokens) * outPrice
            if value.isFinite { return (value, .providerPriceTable) }
        }

        if let customPricing, customPricing.prompt.isFinite, customPricing.completion.isFinite {
            // Nutzerangabe erfolgt in USD pro 1 Mio. Tokens.
            let value = Double(promptTokens) * customPricing.prompt / 1_000_000
                      + Double(completionTokens) * customPricing.completion / 1_000_000
            if value.isFinite { return (value, .userPricing) }
        }

        return (nil, .unknown)
    }
}

enum CostFormat {

    /// Kleine Beträge brauchen mehr Nachkommastellen, sonst steht überall
    /// "$0.00" und die Kostenkontrolle ist wertlos.
    static func usd(_ value: Double?) -> String {
        // Nicht-endliche Werte sind ein Datenfehler und dürfen nicht als
        // Betrag ausgegeben werden ("$nan" / "$inf").
        guard let value, value.isFinite else { return "–" }
        let sign = value < 0 ? "-" : ""
        let magnitude = abs(value)
        if magnitude == 0 { return "$0" }
        if magnitude < 0.01 { return sign + String(format: "$%.5f", magnitude) }
        if magnitude < 1 { return sign + String(format: "$%.4f", magnitude) }
        return sign + String(format: "$%.2f", magnitude)
    }

    /// Preisangabe pro 1 Mio. Tokens, wie im Markt üblich – **nur die Zahl**.
    ///
    /// „kostenlos“ und „Preis unbekannt“ sind Worte und keine Zahlen. Kämen
    /// sie von hier, träfen sie als `String` die Überladung von `Text`, die
    /// nichts nachschlägt, und blieben in jeder Sprache deutsch. Sie
    /// entstehen deshalb in der Ansicht (`priceText(perMillion:)`).
    static func perMillionAmount(_ value: Double) -> String {
        // Ohne diesen Zweig läse sich ein sehr günstiges Modell als
        // "$0.000 / 1M" – also fälschlich als kostenlos.
        if value < 0.001 { return String(format: "$%.5f / 1M", value) }
        if value < 1 { return String(format: "$%.3f / 1M", value) }
        return String(format: "$%.2f / 1M", value)
    }

    static func tokens(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        return "\(value)"
    }

    /// Kontextfenster als reine Grössenangabe, ohne das Wort „Kontext" –
    /// das setzt die Ansicht, damit es übersetzt wird. `nil` heisst: der
    /// Anbieter hat nichts gemeldet.
    static func contextTokens(_ value: Int) -> String? {
        guard value > 0 else { return nil }
        if value >= 1000 { return "\(value / 1000)k" }
        return "\(value)"
    }
}
