//
//  AppLanguage.swift
//  ByoKey
//
//  Sprache der Oberfläche – umschaltbar in der App, ohne Neustart.
//
//  Warum überhaupt ein eigener Schalter, wo iOS doch seit Version 13 eine
//  App-Sprache in den Systemeinstellungen anbietet? Weil dieser Weg drei
//  Bildschirme entfernt liegt und kaum jemand ihn kennt. Wer eine App in
//  einer anderen Sprache haben will, sucht in der App danach.
//
//  Technisch hängt alles an zwei Dingen:
//
//  1. `Text("Einstellungen")` ist in SwiftUI keine Zeichenkette, sondern ein
//     Nachschlage-Schlüssel. Der deutsche Text **ist** der Schlüssel; die
//     Übersetzungen stehen in `Localizable.xcstrings`. Deshalb musste an den
//     Aufrufstellen nichts geändert werden.
//  2. Nachgeschlagen wird gegen `\.locale` aus der Umgebung. Wird dort eine
//     andere Sprache gesetzt, zeichnet SwiftUI die Oberfläche sofort neu –
//     kein Neustart, kein Wechsel in die Systemeinstellungen.
//
//  Für Text ausserhalb von SwiftUI – Fehlermeldungen aus dem Netzwerk-Layer
//  etwa – gibt es `Loc.tr`, das dasselbe Bündel benutzt.
//

import Foundation

enum AppLanguage: String, Codable, CaseIterable, Identifiable, Hashable {
    case system
    case de
    case en
    case pl

    var id: String { rawValue }

    /// `nil` heisst: der Systemsprache folgen.
    var code: String? { self == .system ? nil : rawValue }

    /// Der Name steht bewusst **in** der jeweiligen Sprache. Wer die App
    /// versehentlich auf Polnisch gestellt hat, findet „Deutsch" auch dann
    /// wieder, wenn er sonst kein Wort versteht.
    var nativeName: String {
        switch self {
        case .system: return ""      // wird in der Ansicht übersetzt
        case .de:     return "Deutsch"
        case .en:     return "English"
        case .pl:     return "Polski"
        }
    }

    var locale: Locale {
        guard let code else { return Locale.autoupdatingCurrent }
        return Locale(identifier: code)
    }

    /// Das Bündel mit den Texten dieser Sprache. Fällt auf das Hauptbündel
    /// zurück, wenn die Sprache nicht mitgeliefert wurde – dann greifen die
    /// deutschen Schlüssel, und nichts bleibt leer.
    var bundle: Bundle {
        guard let code,
              let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return .main }
        return bundle
    }
}

/// Übersetzung ausserhalb von SwiftUI.
///
/// `Text(...)` braucht das nicht – dort erledigt die Umgebung die Arbeit.
/// Gebraucht wird es dort, wo ein `String` entsteht, der später angezeigt
/// wird: Fehlermeldungen, aufbereitete Aufzählungen, Zeichenketten, die durch
/// den Markdown-Parser laufen.
enum Loc {
    /// Wird von `AppState` gesetzt, sobald die Einstellung geladen oder
    /// geändert wird.
    ///
    /// Warum nicht `@MainActor`: Anzeigetexte entstehen auch dort, wo keine
    /// Isolation möglich ist – `LocalizedError.errorDescription` etwa ist eine
    /// Protokollanforderung ohne Aktor. Wäre `Loc` an den Hauptaktor gebunden,
    /// bliebe jede Fehlermeldung des Netzwerk-Layers unübersetzt.
    ///
    /// Geschrieben wird der Wert an genau einer Stelle (`AppState`), und zwar
    /// auf dem Hauptaktor; gelesen wird er sonst nur. Ein Wechsel mitten in
    /// einer laufenden Anfrage kann höchstens dazu führen, dass eine einzelne
    /// Meldung noch in der alten Sprache erscheint.
    nonisolated(unsafe) static var language: AppLanguage = .system {
        didSet {
            guard oldValue != language else { return }
            lock.lock()
            cachedBundle = nil
            lock.unlock()
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedBundle: Bundle?

    /// Ohne diesen Puffer läuft bei **jedem** Aufruf ein
    /// `Bundle.main.path(forResource:ofType:)` samt `Bundle(path:)` – also zwei
    /// Dateisystemzugriffe. `Loc.tr` steht unter anderem in Ansichten, die
    /// während einer Antwort zwanzigmal pro Sekunde neu ausgewertet werden.
    private static var bundle: Bundle {
        lock.lock()
        defer { lock.unlock() }
        if let cachedBundle { return cachedBundle }
        let resolved = language.bundle
        cachedBundle = resolved
        return resolved
    }

    static func tr(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func tr(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: tr(key), arguments: arguments)
    }
}
