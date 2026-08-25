//
//  ConsentStore.swift
//  ByoKey
//
//  Umsetzung von App Store Richtlinie 5.1.2(i):
//  "You must clearly disclose where personal data will be shared with third
//   parties, including with third-party AI, and obtain explicit permission
//   before doing so."
//
//  Die vier Anforderungen, an denen Apple Apps ablehnt, sind hier hart verdrahtet:
//   1. Anbieter wird namentlich genannt      -> AIProviderProtocol.legalEntity
//   2. Zweck ist konkret beschrieben         -> AIProviderProtocol.privacySummary
//   3. Datenarten sind einzeln aufgelistet   -> AIProviderProtocol.dataCategories
//   4. Zustimmung ist aktiv und widerrufbar  -> grant() / revoke(), Standard = aus
//
//  Zusätzlich gilt: Ohne Datensatz mit granted == true wird kein einziger
//  Netzwerkaufruf an den Anbieter ausgelöst (siehe AppState.requireConsent).
//

import Foundation
import Observation

/// Wofür die Zustimmung gilt. Audio ist bewusst getrennt: eine Sprachaufnahme
/// ist etwas anderes als getippter Text, und wer nur schreibt, soll nicht
/// nebenbei sein Mikrofon freigeben (Richtlinie 5.1.2(i)).
enum ConsentScope: String, Codable, CaseIterable {
    case text
    case audio

    /// Anhang am Schlüssel des Datensatzes.
    var keySuffix: String { self == .audio ? "#audio" : "" }
}

struct ConsentRecord: Codable, Hashable {
    var granted: Bool
    var grantedAt: Date?
    var policyVersion: Int
}


/// Spiegel der erteilten Freigaben, lesbar aus **jedem** Kontext.
///
/// Warum es das gibt: Der Torwächter für Richtlinie 5.1.2(i) muss dort stehen,
/// wo die Anfrage tatsächlich entsteht – im Netz-Layer. `ConsentStore` ist
/// `@Observable` und lebt am Hauptaktor, ein Provider dagegen läuft irgendwo.
/// Lagen die Prüfungen wie früher nur in `AppState` und in zwei Ansichten, war
/// das zwar lückenlos, aber nur solange niemand einen neuen Aufrufpfad
/// einbaut. Hier kann keiner mehr daran vorbei.
enum ConsentGate {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var granted: Set<String> = []

    static func replace(with keys: Set<String>) {
        lock.lock()
        granted = keys
        lock.unlock()
    }

    static func isGranted(_ providerID: String, scope: ConsentScope) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return granted.contains(providerID + scope.keySuffix)
    }
}

@Observable
final class ConsentStore {

    /// Erhöhen, sobald sich Umfang oder Empfänger der Datenweitergabe ändert.
    /// Alte Zustimmungen werden dadurch ungültig und neu eingeholt.
    static let policyVersion = 1
    /// Version der Nutzungsbedingungen inkl. Null-Toleranz-Klausel (Richtlinie 1.2).
    static let termsVersion = 1

    private let defaults = UserDefaults.standard
    private let recordsKey = "consent.records"
    private let termsKey = "terms.acceptedVersion"

    private(set) var records: [String: ConsentRecord] = [:]
    private(set) var acceptedTermsVersion: Int = 0

    init() {
        load()
        syncGate()
    }

    /// Hält `ConsentGate` auf demselben Stand. Muss nach **jeder** Änderung
    /// laufen – ein vergessener Aufruf hiesse, dass eine widerrufene Freigabe
    /// im Netz-Layer weiter als erteilt gilt.
    private func syncGate() {
        let keys = records.filter { $0.value.granted && $0.value.policyVersion >= Self.policyVersion }
            .keys
        ConsentGate.replace(with: Set(keys))
    }

    // MARK: - Nutzungsbedingungen

    var hasAcceptedTerms: Bool {
        acceptedTermsVersion >= Self.termsVersion
    }

    func acceptTerms() {
        acceptedTermsVersion = Self.termsVersion
        defaults.set(acceptedTermsVersion, forKey: termsKey)
    }

    // MARK: - Datenfreigabe je Anbieter

    private func key(_ providerID: String, _ scope: ConsentScope) -> String {
        providerID + scope.keySuffix
    }

    func hasConsent(for providerID: String, scope: ConsentScope = .text) -> Bool {
        guard let record = records[key(providerID, scope)] else { return false }
        return record.granted && record.policyVersion >= Self.policyVersion
    }

    func record(for providerID: String, scope: ConsentScope = .text) -> ConsentRecord? {
        records[key(providerID, scope)]
    }

    func grant(providerID: String, scope: ConsentScope = .text) {
        records[key(providerID, scope)] = ConsentRecord(granted: true,
                                                        grantedAt: Date(),
                                                        policyVersion: Self.policyVersion)
        syncGate()
        persist()
    }

    /// Widerruf. Ab sofort wird an diesen Anbieter nichts mehr gesendet.
    func revoke(providerID: String, scope: ConsentScope = .text) {
        records[key(providerID, scope)] = ConsentRecord(granted: false,
                                                        grantedAt: nil,
                                                        policyVersion: Self.policyVersion)
        syncGate()
        persist()
    }

    func toggle(providerID: String, scope: ConsentScope = .text, granted: Bool) {
        granted ? grant(providerID: providerID, scope: scope)
                : revoke(providerID: providerID, scope: scope)
    }

    /// Teil von "Alle Daten löschen".
    func reset() {
        records = [:]
        acceptedTermsVersion = 0
        syncGate()
        defaults.removeObject(forKey: recordsKey)
        defaults.removeObject(forKey: termsKey)
    }

    // MARK: - Persistenz

    private func load() {
        acceptedTermsVersion = defaults.integer(forKey: termsKey)
        guard let data = defaults.data(forKey: recordsKey),
              let decoded = try? JSONDecoder().decode([String: ConsentRecord].self, from: data) else {
            return
        }
        records = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: recordsKey)
    }
}
