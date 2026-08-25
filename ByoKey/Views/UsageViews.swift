//
//  UsageViews.swift
//  ByoKey
//
//  Kleine Anzeigen für Tokens und Kosten. Sie tauchen an drei Stellen auf:
//  unter jeder Antwort, im Kopf des Chats und in der Seitenleiste.
//  Geschätzte Werte werden immer mit "ca." gekennzeichnet.
//

import SwiftUI

/// Monatsbudget als schmaler Balken. Wird ab 80 % orange, ab 100 % rot.
struct BudgetBar: View {
    let spentUSD: Double
    let budgetUSD: Double

    private var fraction: Double {
        guard budgetUSD > 0 else { return 0 }
        return min(1, spentUSD / budgetUSD)
    }

    private var tint: Color {
        if fraction >= 1 { return Theme.danger }
        if fraction >= 0.8 { return Theme.warning }
        return Theme.accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Beide Texte haben dieselbe Schriftgröße, deshalb reicht die
            // mittige Ausrichtung – und sie bleibt auch dann ruhig, wenn der
            // Betrag rechts kleiner skaliert wird.
            HStack(alignment: .center, spacing: 8) {
                Text("Diesen Monat")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(CostFormat.usd(spentUSD)) / \(CostFormat.usd(budgetUSD))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(fraction >= 0.8 ? tint : Theme.textSecondary)
                    // Lieber ein wenig kleiner als umgebrochen: ein Umbruch
                    // schiebt den Balken darunter nach unten.
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(1)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.border)
                    Capsule()
                        .fill(tint)
                        .frame(width: max(2, geometry.size.width * fraction))
                }
            }
            .frame(height: 5)
        }
        // Etwas Luft nach oben: direkt unter dem Regler klebte die Zeile
        // am Bedienelement darüber.
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Ausgaben diesen Monat: \(CostFormat.usd(spentUSD)) von \(CostFormat.usd(budgetUSD))")
    }
}

/// Kompakte Anzeige im Chat-Kopf: Sitzung und aktueller Chat.
struct UsagePill: View {
    let tokens: Int
    let costUSD: Double
    let label: LocalizedStringKey

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.caption2)
            Text(label)
                .font(.caption2)
            Text("·")
                .font(.caption2)
            Text(CostFormat.tokens(tokens))
                .font(.caption2.monospacedDigit())
            Text(CostFormat.usd(costUSD))
                .font(.caption2.monospacedDigit().weight(.semibold))
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.surfaceAlt, in: Capsule())
        .accessibilityElement(children: .combine)
        // `label` ist ein Übersetzungsschlüssel und lässt sich nicht in eine
        // Zeichenkette einsetzen. Zwei Text-Bausteine addieren geht dagegen.
        .accessibilityLabel(Text(label) + Text(": \(tokens) Tokens, \(CostFormat.usd(costUSD))"))
    }
}

/// Fußzeile unter einer Antwort.
struct MessageCostFooter: View {
    let message: ChatMessage

    var body: some View {
        // Ohne Tokens und ohne Preis wäre die Zeile leer und würde nur eine
        // Lücke erzeugen – etwa bei den Hinweisen des Inhaltsfilters.
        if message.totalTokens == 0 && message.costUSD == nil {
            EmptyView()
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 8) {
            if message.totalTokens > 0 {
                Label {
                    Text("\(message.promptTokens ?? 0) ein · \(message.completionTokens ?? 0) aus")
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "arrow.left.arrow.right")
                }
            }
            if let cost = message.costUSD {
                // Als Ternär hätte der Else-Zweig den Typ `String` und
                // zöge den ganzen Ausdruck auf die Überladung, die nichts
                // nachschlägt – „ca." bliebe dann in jeder Sprache deutsch.
                Group {
                    if message.isEstimate {
                        Text("ca. \(CostFormat.usd(cost))")
                    } else {
                        Text(verbatim: CostFormat.usd(cost))
                    }
                }
                    .monospacedDigit()
                    .fontWeight(.semibold)
            } else if message.totalTokens > 0 {
                Text("Preis unbekannt")
            }
            if let modelID = message.modelID, !modelID.isEmpty {
                Text("·")
                Text(modelID)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.caption2)
        .foregroundStyle(Theme.textSecondary)
    }
}

/// Preisangabe pro 1 Mio. Tokens als `Text`.
///
/// „kostenlos“ und „Preis unbekannt“ sind Worte. Kämen sie als `String` aus
/// `CostFormat`, träfen sie die Überladung von `Text`, die keinen Schlüssel
/// nachschlägt – die Angabe bliebe dann auch in der englischen und polnischen
/// Oberfläche deutsch. Als Literal hier greift der Katalog.
@MainActor
func priceText(perMillion value: Double?) -> Text {
    guard let value, value.isFinite else { return Text("Preis unbekannt") }
    if value == 0 { return Text("kostenlos") }
    return Text(verbatim: CostFormat.perMillionAmount(value))
}
