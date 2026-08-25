//
//  KeychainStore.swift
//  ByoKey
//
//  API-Schlüssel gehören nicht in UserDefaults. Sie liegen in der System-Keychain
//  mit kSecAttrAccessibleWhenUnlockedThisDeviceOnly:
//    • verschlüsselt durch das Betriebssystem,
//    • nur bei entsperrtem Gerät lesbar,
//    • KEIN iCloud-Keychain-Sync -> der Schlüssel verlässt das Gerät nie.
//
//  Relevanz für die App-Review: Richtlinie 5.1.1 (Datensicherheit) und die
//  Zusage in der Datenschutzerklärung, dass Schlüssel ausschließlich lokal
//  gespeichert und nur an die offizielle Anbieter-API gesendet werden.
//

import Foundation
import Security

enum KeychainStore {

    private static var service: String {
        Bundle.main.bundleIdentifier ?? "de.byokey.app"
    }

    /// Speichert einen Wert. Leerer oder nil-Wert löscht den Eintrag.
    ///
    /// Erst aktualisieren, nur bei "gibt es noch nicht" anlegen.
    /// Ein vorheriges SecItemDelete wäre gefährlich: schlägt das
    /// anschließende Schreiben fehl (gesperrtes Gerät, fehlende
    /// Entitlements), wäre der bisherige Schlüssel bereits vernichtet und
    /// der Nutzer stünde ohne Zugang da.
    /// `label` wird als `kSecAttrLabel` mitgeschrieben.
    ///
    /// Das ist kein Beiwerk: der Eintrag heisst `apikey.entry.<uuid>`, und
    /// diese UUID steht sonst **nur** in der Zustandsdatei. Ginge die verloren,
    /// wären alle Schlüssel zwar noch da, aber nicht mehr zuzuordnen. Mit dem
    /// Etikett – „anbieter|name" – lässt sich die Liste aus der Keychain
    /// wiederherstellen. Ein Geheimnis steht nicht darin.
    @discardableResult
    static func set(_ value: String?, for account: String, label: String? = nil) -> Bool {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return remove(account)
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        var attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        if let label { attributes[kSecAttrLabel as String] = label }

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        // Alles außer "nicht vorhanden" ist ein echter Fehler – dann NICHT
        // löschen und NICHT Erfolg melden.
        guard updateStatus == errSecItemNotFound else { return false }

        var insert = query
        insert.merge(attributes) { current, _ in current }
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8),
              !string.isEmpty else {
            return nil
        }
        return string
    }

    static func has(_ account: String) -> Bool {
        get(account) != nil
    }

    @discardableResult
    static func remove(_ account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Löscht alle von dieser App abgelegten Schlüssel – Teil von
    /// "Alle Daten löschen" in den Einstellungen.
    /// Der Rückgabewert wird ausgewertet: die App darf nicht behaupten,
    /// Schlüssel entfernt zu haben, wenn das fehlgeschlagen ist.
    @discardableResult
    static func removeAll() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Ändert nur das Etikett eines vorhandenen Eintrags.
    ///
    /// Nach einer Umbenennung: der Schlüssel selbst wird dabei nicht angefasst,
    /// es geht allein um die Zuordnung im Rettungsfall.
    @discardableResult
    static func setLabel(_ label: String, for account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecAttrLabel as String: label]
        return SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess
    }

    /// Alle Konten dieser App, deren Name mit `prefix` beginnt – samt Etikett.
    ///
    /// Der Rettungsweg, wenn die Zustandsdatei fehlt oder beschädigt ist.
    /// Ohne ihn wäre ein Schlüssel unter `apikey.entry.<uuid>` für immer
    /// unerreichbar, sobald die Liste, die auf ihn zeigt, verloren geht.
    static func accounts(withPrefix prefix: String) -> [(account: String, label: String?)] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let entries = item as? [[String: Any]] else {
            return []
        }
        return entries.compactMap { entry in
            guard let account = entry[kSecAttrAccount as String] as? String,
                  account.hasPrefix(prefix) else { return nil }
            return (account, entry[kSecAttrLabel as String] as? String)
        }
    }

    /// Schwärzt alles, was wie ein API-Schlüssel aussieht.
    ///
    /// Für Texte, die vom Anbieter kommen und im Verlauf **gespeichert**
    /// werden: mehrere Dienste antworten auf HTTP 401 mit „Incorrect API key
    /// provided: sk-…abcd". Genau diese Form soll die Zustandsdatei nicht
    /// enthalten – sie ist gewöhnliches JSON im App-Container, während der
    /// Schlüssel selbst in der Keychain liegt.
    static func redactingSecrets(in text: String) -> String {
        // Die gängigen Präfixe: OpenAI/OpenRouter/DeepSeek (sk-), Groq (gsk_),
        // Cerebras (csk-), xAI (xai-), Google (AIza).
        //
        // Der Rückblick nach links ist keine Feinheit, sondern nötig: ohne ihn
        // trifft `sk-` mitten in gewöhnlichen Wörtern („task-specific",
        // „disk-storage", „risk-management") und zerstört die Fehlermeldung an
        // genau der Stelle, die dem Nutzer sagt, was zu tun ist.
        //
        // `Bearer` steht bewusst **nicht** in der Liste: „Expected Bearer
        // authorization header" wäre sonst geschwärzt worden. Ein echter
        // Schlüssel trägt eines der Präfixe.
        let pattern = "(?<![A-Za-z0-9_.-])(sk-|gsk_|csk-|xai-|AIza)[A-Za-z0-9._-]{6,}"
        return text.replacingOccurrences(of: pattern, with: "•••", options: .regularExpression)
    }

    /// Gekürzte Darstellung für die Oberfläche: "sk-or-v1-…4f2a".
    static func masked(_ value: String) -> String {
        guard value.count > 12 else { return String(repeating: "•", count: max(value.count, 4)) }
        let head = value.prefix(8)
        let tail = value.suffix(4)
        return "\(head)…\(tail)"
    }
}
