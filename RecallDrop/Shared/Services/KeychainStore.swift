//
//  KeychainStore.swift
//  RecallDrop
//
//  API keys live in the system Keychain – never in UserDefaults, the
//  database or exports. On iOS the items are written to the App Group's
//  access group so the share extension can analyze captures too.
//  Items are not synchronized through iCloud Keychain.
//

import Foundation
import Security
import RecallDropKit

enum KeychainStore {
    static let service = "RecallDrop.AIProviderKeys"

    static func apiKey(for provider: AIProviderKind) -> String? {
        var query = baseQuery(account: account(for: provider))
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            return nil
        }
        return key
    }

    static func hasAPIKey(for provider: AIProviderKind) -> Bool {
        apiKey(for: provider) != nil
    }

    /// Stores `key`; an empty or nil key removes the entry.
    ///
    /// Updates in place first and only adds when nothing exists yet, so a
    /// failed write can never destroy a working key.
    @discardableResult
    static func setAPIKey(_ key: String?, for provider: AIProviderKind) -> Bool {
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return removeAPIKey(for: provider)
        }
        let account = account(for: provider)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(baseQuery(account: account) as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var insert = baseQuery(account: account)
        insert.merge(attributes) { current, _ in current }
        insert[kSecAttrLabel as String] = "RecallDrop – \(provider.displayName) API key"
        if let accessGroup = sharedAccessGroup {
            insert[kSecAttrAccessGroup as String] = accessGroup
            let status = SecItemAdd(insert as CFDictionary, nil)
            if status != errSecMissingEntitlement { return status == errSecSuccess }
            // Unsigned development builds lack the group entitlement: keep the key app-private.
            insert.removeValue(forKey: kSecAttrAccessGroup as String)
        }
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func removeAPIKey(for provider: AIProviderKind) -> Bool {
        let status = SecItemDelete(baseQuery(account: account(for: provider)) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    @discardableResult
    static func removeAll() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// "sk-or-v1-…4f2a" for display.
    static func masked(_ key: String) -> String {
        guard key.count > 12 else { return String(repeating: "•", count: max(key.count, 4)) }
        return "\(key.prefix(8))…\(key.suffix(4))"
    }

    // MARK: Private

    private static func account(for provider: AIProviderKind) -> String {
        "apikey.\(provider.rawValue)"
    }

    /// Lookups deliberately omit the access group: the Keychain then searches
    /// every group this process may read, which covers both storage variants.
    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static var sharedAccessGroup: String? {
        #if os(iOS)
        return AppGroup.identifier
        #else
        return nil
        #endif
    }
}
