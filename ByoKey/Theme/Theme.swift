//
//  Theme.swift
//  ByoKey
//
//  Farb- und Maßangaben an einer Stelle. Alle Farben sind als dynamische
//  UIColor definiert und schalten automatisch zwischen Hell und Dunkel um –
//  die App erzwingt kein Erscheinungsbild, sondern folgt der Systemeinstellung.
//

import SwiftUI
import UIKit

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light)
        })
    }

    /// Für vom Nutzer gewählte Projektfarben (Hex aus dem Datenmodell).
    init(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        // Schlägt das Einlesen fehl, bleibt `value` 0 und die Farbe wird
        // schwarz – ein sichtbarer, aber harmloser Ausfall.
        //
        // `scanUInt64(representation:)` statt `scanHexInt64(&value)`: die
        // Zeigervariante ist die alte ObjC-Übersetzung und seit Swift 5 als
        // veraltet markiert – Xcode 26 warnt darüber.
        let value = Scanner(string: cleaned).scanUInt64(representation: .hexadecimal) ?? 0
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

enum Theme {

    // MARK: - Farben

    static let background = Color.adaptive(light: 0xFAF9F7, dark: 0x161617)
    static let surface = Color.adaptive(light: 0xFFFFFF, dark: 0x1F1F21)
    static let surfaceAlt = Color.adaptive(light: 0xF2EFEB, dark: 0x27272A)
    static let border = Color.adaptive(light: 0xE6E1DA, dark: 0x35353A)
    static let textPrimary = Color.adaptive(light: 0x1E1C1A, dark: 0xECEAE6)
    static let textSecondary = Color.adaptive(light: 0x6E6862, dark: 0x9C978F)
    static let accent = Color.adaptive(light: 0x5B3E9A, dark: 0x9C7BD4)
    static let accentSoft = Color.adaptive(light: 0xEDE7F8, dark: 0x2E2545)
    static let userBubble = Color.adaptive(light: 0xEFEAF9, dark: 0x2C2542)
    static let codeBackground = Color.adaptive(light: 0x1C1B22, dark: 0x101014)
    // Etwas dunkler als das ursprüngliche 0xB4541A: die Warnfarbe steht
    // auch als Text auf `warning.opacity(0.10)` (Warnkarte bei markiertem
    // Inhalt), und dort lag der Kontrast mit 4,13:1 unter den 4,5:1, die WCAG
    // AA für Fliesstext verlangt. Mit 0xA34A16 sind es 4,6:1, und optisch ist
    // der Unterschied nicht zu sehen.
    static let warning = Color.adaptive(light: 0xA34A16, dark: 0xE59450)
    static let danger = Color.adaptive(light: 0xB3261E, dark: 0xF2837C)
    static let success = Color.adaptive(light: 0x1F7A4D, dark: 0x62C79A)

    // MARK: - Farben für Code-Hervorhebung

    enum Code {
        static let plain = Color(red: 0.90, green: 0.90, blue: 0.93)
        static let keyword = Color(red: 0.78, green: 0.57, blue: 0.95)
        static let string = Color(red: 0.55, green: 0.85, blue: 0.62)
        static let number = Color(red: 0.95, green: 0.73, blue: 0.45)
        static let comment = Color(red: 0.50, green: 0.52, blue: 0.58)
        static let type = Color(red: 0.45, green: 0.78, blue: 0.94)
    }

    // MARK: - Maße

    static let corner: CGFloat = 14
    static let bubbleCorner: CGFloat = 18
    static let gutter: CGFloat = 16

    // MARK: - Projektfarben zur Auswahl

    static let projectColors: [String] = [
        "#5B3E9A", "#2F6C9A", "#1F7A4D", "#B4541A", "#B3261E", "#7A5C1F", "#4A4A55"
    ]
}

// MARK: - Wiederverwendbare Bausteine

/// Fläche mit Rahmen, wie sie in Einstellungen und Hinweiskarten genutzt wird.
struct CardBackground: ViewModifier {
    var tint: Color = Theme.surface

    func body(content: Content) -> some View {
        content
            .background(tint, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            }
    }
}

extension View {
    func card(tint: Color = Theme.surface) -> some View {
        modifier(CardBackground(tint: tint))
    }
}
