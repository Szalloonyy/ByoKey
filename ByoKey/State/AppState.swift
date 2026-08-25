//
//  AppState.swift
//  ByoKey
//
//  Einziger Zustandsspeicher der App. Hält Projekte, Chats, Einstellungen und
//  den laufenden Stream. Persistiert als eine JSON-Datei im App-Container;
//  API-Schlüssel liegen ausschließlich in der Keychain.
//

import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class AppState {

    /// Träger für `.sheet(item:)`. Mit `.sheet(isPresented:)` plus `if let`
    /// im Inhalt würde der Dialog beim Schließen kurz leer dargestellt.
    struct ConsentRequest: Identifiable, Equatable {
        let providerID: String
        /// Text oder Sprachaufnahme – beides wird getrennt freigegeben.
        var scope: ConsentScope = .text
        var id: String { providerID + "." + scope.rawValue }
    }

    // MARK: - Persistierter Zustand

    var projects: [AIProject] = []
    var conversations: [Conversation] = []
    var settings: AppSettings = .default
    var blockedModelIDs: Set<String> = []
    var reports: [ContentReport] = []
    var customPricing: [String: PersistedState.PricePair] = [:]
    /// Die hinterlegten Schlüssel – **ohne** den Schlüssel selbst.
    var credentials: [APICredential] = []

    // MARK: - Laufzeit

    var models: [AIModel] = []
    var isLoadingModels = false
    var modelsError: String?

    var selectedConversationID: UUID?
    /// nil bedeutet "Alle Chats", sonst wird nach Projekt gefiltert.
    var selectedProjectID: UUID?

    private(set) var isStreaming = false
    private(set) var streamingConversationID: UUID?
    private(set) var streamingProviderID: String?

    /// Kosten und Tokens seit App-Start.
    var sessionCostUSD: Double = 0
    var sessionTokens: Int = 0

    /// Zwischengespeichert statt berechnet: die Seitenleiste liest den Wert,
    /// und während eines Streams wird sie sehr oft neu ausgewertet. Eine
    /// Kalenderprüfung pro Nachricht wäre dabei ein Hauptthread-Fresser.
    private(set) var monthCostUSD: Double = 0
    /// Gespiegelter Keychain-Zustand. Ein SecItemCopyMatching pro
    /// Body-Auswertung wäre ein XPC-Aufruf im Zeichentakt – und @Observable
    /// kann die Keychain ohnehin nicht beobachten.
    private(set) var providersWithKey: Set<String> = []

    /// Verkürzte Darstellung je Schlüssel („sk-or-v1-…4f2a").
    ///
    /// Wird beim Auffrischen **einmal** aus der Keychain gebildet und hier
    /// gehalten. Jeder Zugriff auf die Keychain ist ein XPC-Aufruf; im
    /// Bildaufbau einer Liste wäre das je Zeile einer. Fehlt ein Eintrag,
    /// liess sich der Schlüssel nicht lesen – die Einstellungen sagen das
    /// dann auch, statt einen Schlüssel vorzutäuschen.
    private(set) var credentialMasks: [UUID: String] = [:]

    /// Aufgedeckte, vom Filter markierte Antworten. Bewusst nicht persistiert.
    var revealedMessageIDs: Set<UUID> = []
    /// Welche Antwort gerade vorgelesen wird.
    private(set) var speakingMessageID: UUID?

    /// Wird gesetzt, wenn der Zustimmungsdialog nötig ist (Richtlinie 5.1.2(i)).
    var consentRequest: ConsentRequest?
    /// Hinweis auf Hilfsangebote bei Selbstgefährdung.
    var supportNotice: String?
    /// Allgemeine Fehlermeldung für einen Alert.
    var alertMessage: String?

    let consent = ConsentStore()
    /// Zuhören und Vorlesen. Bewusst EINE Instanz für die ganze App: zwei
    /// würden sich um die Audio-Sitzung streiten.
    let speech = SpeechService()

    private var streamTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var modelsTask: Task<[AIModel], Error>?

    /// Zählt Stream-Läufe. Nur der aktuelle Lauf darf den Zustand zurücksetzen.
    private var streamGeneration = 0
    private var modelsGeneration = 0
    private var loadedModelsProviderID: String?

    /// true, wenn beim Start eine vorhandene Datei nicht gelesen werden konnte.
    /// Solange das steht, wird nichts geschrieben – sonst würde ein leerer
    /// Zustand die noch intakten Daten überschreiben.
    /// Die Zustandsdatei war da, liess sich aber nicht lesen. Dann darf
    /// **nichts** geschrieben werden – der leere Zustand überschriebe sonst
    /// die noch intakten Daten.
    private var loadFailed = false
    /// Die Datei war beschädigt und wurde in Quarantäne verschoben. Schreiben
    /// ist wieder erlaubt (die alte Datei ist in Sicherheit), aber das
    /// Aufräumen verwaister Bilder muss aussetzen: `conversations` ist leer.
    private var skipOrphanCleanup = false
    /// Zählt die Schnappschüsse. `StateWriter` verwirft alles, was älter ist
    /// als der zuletzt geschriebene Stand.
    private var writeGeneration = 0
    /// Enthielt die gelesene Datei überhaupt eine Auswahl? Siehe
    /// `PersistedState.hasStoredSelection`.
    private var hasStoredSelection = false

    // MARK: - Start

    init() {
        load()

        // Leere, nie benannte Chats aus früheren Sitzungen wegräumen.
        //
        // Bis hierher hat jedes Tippen auf „Neuer Chat“ eine Zeile
        // hinterlassen, auch wenn nie etwas darin stand. Wer die App eine
        // Weile benutzt hat, findet deshalb eine Reihe leerer Einträge vor.
        // Verloren geht dabei nichts: ein Chat ohne Nachricht **und** ohne
        // eigenen Namen enthält keine Angabe des Nutzers.
        //
        // Der zuletzt geöffnete Chat bleibt in jedem Fall stehen – dort
        // setzt die App gleich wieder auf.
        discardEmptyDrafts(keeping: selectedConversationID)

        // Zeigt die gelesene Auswahl noch auf einen vorhandenen Chat? Sie
        // kann in einer früheren Sitzung gelöscht worden sein, und eine
        // Auswahl ins Leere hiesse dauerhaft „Kein Chat ausgewählt“.
        //
        // Das Aufräumen darüber deckt denselben Fall bereits ab; hier steht
        // die Prüfung trotzdem, weil sie zum Vertrag dieses Starts gehört und
        // nicht von einem Seiteneffekt einer privaten Hilfsfunktion abhängen
        // soll. Und sie steht **vor** der Verzweigung: ist am Ende kein Chat
        // übrig, kommt der Zweig darunter gar nicht mehr dazu.
        if let id = selectedConversationID,
           !conversations.contains(where: { $0.id == id }) {
            selectedConversationID = nil
        }

        if conversations.isEmpty {
            // Erststart oder frisch geleert: direkt in den leeren Chat, das
            // ist der freundlichere Einstieg als eine leere Übersicht.
            //
            // **Nicht** aber, wenn die App zuletzt in der Übersicht stand und
            // nur leere Entwürfe übrig waren: dann käme der Nutzer trotz der
            // gespeicherten Auswahl wieder in einem Chat heraus – genau das
            // Verhalten, das vorher schon abgestellt wurde.
            if !hasStoredSelection {
                let conversation = Conversation(modelID: settings.defaultModelID ?? "")
                conversations = [conversation]
                selectedConversationID = conversation.id
            }
            selectedProjectID = nil
        } else {
            // Datei aus einer Fassung vor dieser Änderung: dort gab es die
            // Auswahl noch nicht. Einmalig wie bisher den jüngsten Chat
            // öffnen, danach greift die gespeicherte Auswahl.
            if !hasStoredSelection {
                selectedConversationID = conversations
                    .sorted { $0.updatedAt > $1.updatedAt }
                    .first?.id
            }
            // Ansonsten bleibt die geladene Auswahl stehen – auch wenn sie
            // `nil` ist. Vorher stand hier fest der jüngste Chat, weshalb die
            // App ihn selbst dann öffnete, wenn man sie aus der Übersicht
            // heraus geschlossen hatte.

            if let id = selectedProjectID,
               !projects.contains(where: { $0.id == id }) {
                selectedProjectID = nil
            }
            // Beides kann für sich gültig sein und trotzdem nicht
            // zusammenpassen: die Seitenleiste zeigte dann Projekt P, das
            // Detail aber einen Chat, der dort gar nicht steht.
            if let cid = selectedConversationID,
               !conversationList(inProject: selectedProjectID).contains(where: { $0.id == cid }) {
                selectedProjectID = nil
            }
        }
        recomputeMonthCost()
        // Muss vor `refreshKeyPresence` laufen: sonst stünde beim ersten Start
        // nach dem Update „kein Schlüssel hinterlegt", obwohl einer da ist.
        recoverKeys()
        refreshKeyPresence()
        // Texte ausserhalb von SwiftUI schlagen über `Loc` nach und brauchen
        // die gewählte Sprache, bevor die erste Fehlermeldung entstehen kann.
        Loc.language = settings.language
        // Bilder gelöschter Chats bleiben sonst für immer im Container liegen.
        // Aber nur, wenn der Zustand wirklich gelesen wurde: nach einem
        // Lesefehler ist `conversations` leer, und ohne diese Bedingung
        // würde das Aufräumen sämtliche Bilder löschen, während die intakte
        // Zustandsdatei sie weiter referenziert.
        if !loadFailed && !skipOrphanCleanup {
            ImageStore.removeOrphans(keeping: Set(
                conversations.flatMap(\.messages).compactMap(\.imageFileName)
            ))
            // Dasselbe für angehängte Dateien. Fängt zusätzlich den Fall, dass
            // eine Datei angehängt, die Nachricht aber nie abgeschickt wurde.
            AttachmentStore.removeOrphans(keeping: Set(
                conversations.flatMap(\.attachmentFileNames)
            ))
        }

        speech.onSpeechFinished = { [weak self] in
            self?.speakingMessageID = nil
        }
    }

    // MARK: - Vorlesen

    /// Liest eine Antwort vor oder bricht das Vorlesen ab.
    ///
    /// Der Weg über den Anbieter braucht eine eigene Freigabe: der Text geht
    /// dann an einen Sprach-Endpunkt, nicht an das Chat-Modell
    /// (Richtlinie 5.1.2(i)).
    func toggleSpeak(_ message: ChatMessage) async {
        // Zweiter Riegel im Modell-Layer, nicht nur in der Ansicht: ein vom
        // Filter markierter Text darf nicht vorgelesen und im Anbieter-Modus
        // erst recht nicht hochgeladen werden, solange der Nutzer ihn nicht
        // ausdrücklich aufgedeckt hat (Richtlinie 1.2).
        guard !message.isFlagged || revealedMessageIDs.contains(message.id) else { return }

        if speech.phase == .speaking, speakingMessageID == message.id {
            speech.stopSpeaking()
            speakingMessageID = nil
            return
        }
        speech.stopSpeaking()

        let provider = activeProvider
        if settings.voiceEngine == .provider {
            guard provider.supportsAudio else {
                alertMessage = ProviderError.audioUnsupported(provider: provider.displayName).errorDescription
                return
            }
            guard consent.hasConsent(for: provider.id, scope: .audio) else {
                consentRequest = ConsentRequest(providerID: provider.id, scope: .audio)
                return
            }
            // Ohne Modellkennung käme nur der rohe Fehler des Anbieters zurück.
            guard !settings.ttsModelID.trimmingCharacters(in: .whitespaces).isEmpty else {
                alertMessage = Loc.tr("Für diesen Anbieter ist noch kein Vorlesemodell eingetragen. Du findest das Feld unter Einstellungen › Sprachmodus.")
                return
            }
        }

        speakingMessageID = message.id
        await speech.speak(text: message.text,
                           engine: settings.voiceEngine,
                           language: settings.voiceLanguage,
                           voiceIdentifier: settings.activeVoiceIdentifier,
                           provider: provider,
                           apiKey: apiKey(for: provider.id),
                           modelID: settings.ttsModelID)
    }

    // MARK: - Abgeleitete Werte

    var activeProvider: any AIProviderProtocol {
        ProviderRegistry.providerOrDefault(id: settings.activeProviderID)
    }

    /// Ist der Schlüssel, mit dem gerade gearbeitet wird, wirklich lesbar?
    ///
    /// Nicht „hat dieser Anbieter irgendeinen Schlüssel": beides fiel früher
    /// zusammen, seit es mehrere je Anbieter gibt aber nicht mehr. Wer einen
    /// Eintrag auswählt, dessen Keychain-Element fehlt – etwa nach einer
    /// Wiederherstellung auf einem neuen Gerät –, bekäme sonst ein grünes
    /// Siegel und ein freies Eingabefeld, und jedes Senden liefe in
    /// „Kein API-Schlüssel hinterlegt".
    var hasAPIKey: Bool {
        guard let credential = activeCredential else { return false }
        return credentialMasks[credential.id] != nil
    }

    var hasConsentForActiveProvider: Bool {
        consent.hasConsent(for: activeProvider.id)
    }

    var isReadyToSend: Bool {
        hasAPIKey && hasConsentForActiveProvider
    }

    var selectedConversation: Conversation? {
        guard let selectedConversationID else { return nil }
        return conversations.first { $0.id == selectedConversationID }
    }

    var selectedProject: AIProject? {
        guard let selectedProjectID else { return nil }
        return projects.first { $0.id == selectedProjectID }
    }

    /// Modelle des aktiven Anbieters ohne die vom Nutzer gesperrten.
    var availableModels: [AIModel] {
        models.filter { !blockedModelIDs.contains($0.id) }
    }

    /// Läuft in genau diesem Chat gerade ein Stream? Das globale Flag allein
    /// würde in einem anderen Chat eine Tippanzeige und einen Stopp-Knopf
    /// zeigen, der den fremden Stream abbricht.
    func isStreaming(conversationID: UUID?) -> Bool {
        guard isStreaming, let conversationID, let streamingConversationID else { return false }
        return streamingConversationID == conversationID
    }

    func model(id: String?) -> AIModel? {
        guard let id else { return nil }
        return models.first { $0.id == id }
    }

    func project(id: UUID?) -> AIProject? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    func conversationList(inProject projectID: UUID?) -> [Conversation] {
        let filtered: [Conversation]
        if let projectID {
            filtered = conversations.filter { $0.projectID == projectID }
        } else {
            filtered = conversations
        }
        return filtered.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Gesamtkosten und Tokens je Projekt – **gepuffert**.
    ///
    /// Die Seitenleiste liest `app.conversations` und wird deshalb während
    /// einer Antwort zwanzigmal pro Sekunde neu ausgewertet. Ohne diesen Puffer
    /// summierte sie dabei je Projektzeile über alle Chats und deren
    /// sämtliche Nachrichten – bei 10 000 Nachrichten rund 400 000 Durchläufe
    /// pro Sekunde. Berechnet wird jetzt zusammen mit den Monatskosten, also
    /// einmal pro fertiger Antwort.
    struct ProjectTotals {
        var costUSD: Double = 0
        var tokens: Int = 0
    }

    private(set) var projectTotals: [UUID: ProjectTotals] = [:]

    func costUSD(forProject projectID: UUID) -> Double {
        projectTotals[projectID]?.costUSD ?? 0
    }

    func tokens(forProject projectID: UUID) -> Int {
        projectTotals[projectID]?.tokens ?? 0
    }

    var budgetFraction: Double {
        guard settings.monthlyBudgetUSD > 0 else { return 0 }
        return min(1, monthCostUSD / settings.monthlyBudgetUSD)
    }

    /// Der Monatsbereich wird EINMAL bestimmt; ein Kalendervergleich pro
    /// Nachricht ist bei mehreren tausend Nachrichten zu teuer.
    private func recomputeProjectTotals() {
        var totals: [UUID: ProjectTotals] = [:]
        for conversation in conversations {
            guard let projectID = conversation.projectID else { continue }
            var entry = totals[projectID] ?? ProjectTotals()
            entry.costUSD += conversation.totalCostUSD
            entry.tokens += conversation.totalTokens
            totals[projectID] = entry
        }
        projectTotals = totals
    }

    private func recomputeMonthCost() {
        recomputeProjectTotals()
        guard let month = Calendar.current.dateInterval(of: .month, for: Date()) else {
            monthCostUSD = 0
            return
        }
        var sum = 0.0
        for conversation in conversations {
            // Ein Chat, der seit Monatsbeginn nicht angefasst wurde, kann
            // keine Nachricht aus diesem Monat enthalten.
            guard conversation.updatedAt >= month.start else { continue }
            for message in conversation.messages where month.contains(message.createdAt) {
                sum += message.costUSD ?? 0
            }
        }
        monthCostUSD = sum.isFinite ? sum : 0
    }

    func refreshKeyPresence() {
        var masks: [UUID: String] = [:]
        var providers: Set<String> = []
        for credential in credentials {
            guard let value = KeychainStore.get(credential.keychainAccount) else { continue }
            masks[credential.id] = KeychainStore.masked(value)
            providers.insert(credential.providerID)
        }
        credentialMasks = masks
        providersWithKey = providers
    }

    // MARK: - Hinterlegte Schlüssel

    /// Alle Schlüssel eines Anbieters, ältester zuerst.
    func credentials(for providerID: String) -> [APICredential] {
        credentials
            .filter { $0.providerID == providerID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Der Schlüssel, mit dem gerade gearbeitet wird.
    ///
    /// Zeigt die gemerkte Wahl auf einen gelöschten Eintrag, gilt der erste
    /// des Anbieters – sonst stünde die App ohne Schlüssel da, obwohl einer
    /// hinterlegt ist.
    func activeCredential(for providerID: String) -> APICredential? {
        let mine = credentials(for: providerID)
        if let id = settings.activeCredentialByProvider[providerID],
           let match = mine.first(where: { $0.id == id }) {
            return match
        }
        return mine.first
    }

    var activeCredential: APICredential? {
        // Die **aufgelöste** Kennung, wie `activeProvider` sie liefert. Stünde
        // in der Datei eine Kennung, die es nicht (mehr) gibt, fiele
        // `activeProvider` auf OpenRouter zurück, `activeCredential` aber ins
        // Leere – die App meldete „nicht startklar", obwohl der Schlüssel da
        // ist und jeder Sendepfad ihn fände.
        activeCredential(for: activeProvider.id)
    }

    /// Alle Anbieter, für die mindestens ein Schlüssel hinterlegt ist – in der
    /// Reihenfolge der Anbieterliste.
    var providersWithStoredKey: [any AIProviderProtocol] {
        ProviderRegistry.all.filter { provider in
            credentials.contains { $0.providerID == provider.id }
        }
    }

    enum AddKeyOutcome {
        case added(APICredential)
        /// Derselbe Schlüssel liegt schon unter diesem Namen.
        case duplicate(APICredential)
        case failed
    }

    /// Legt einen weiteren Schlüssel für einen Anbieter an.
    ///
    /// Benutzt wird er nur, wenn es der **erste** dieses Anbieters ist; sonst
    /// schaltet ihn erst die bestandene Prüfung frei. Die Reihenfolge ist
    /// ebenfalls Absicht: erst in die Keychain schreiben, dann in die Liste
    /// aufnehmen. Scheitert das Schreiben (gesperrtes Gerät), gibt es keinen
    /// Eintrag ohne Schlüssel.
    func addCredential(key: String, providerID: String) -> AddKeyOutcome {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed }

        // Denselben Schlüssel zweimal einzutragen ist ein Versehen, kein
        // zweiter Zugang – und zwei gleich aussehende Zeilen in der Liste
        // wären für den Nutzer nicht auseinanderzuhalten.
        for existing in credentials(for: providerID)
        where KeychainStore.get(existing.keychainAccount) == trimmed {
            return .duplicate(existing)
        }

        let hadCredential = !credentials(for: providerID).isEmpty
        let credential = APICredential(providerID: providerID,
                                       name: defaultCredentialName(for: providerID))
        // Keine Meldung über `alertMessage`: die hängt an der Grundansicht und
        // erschiene erst nach dem Schliessen der Einstellungen, aus dem
        // Zusammenhang gerissen. Die Einstellungen sagen es selbst, an Ort und
        // Stelle.
        guard KeychainStore.set(trimmed,
                                for: credential.keychainAccount,
                                label: credential.keychainLabel) else {
            return .failed
        }
        credentials.append(credential)
        // **Nicht** sofort benutzen, wenn schon einer da ist: ein Schlüssel mit
        // Tippfehler verdrängte sonst den funktionierenden, und zwar bevor
        // überhaupt geprüft wurde. Die Prüfung schaltet ihn danach frei.
        //
        // Ausnahme: der bisher aktive Eintrag hat gar keinen lesbaren
        // Schlüssel mehr. Genau das ist die Lage nach einer Wiederherstellung
        // des Geräts – die Chats kommen aus dem Backup zurück, die Keychain
        // nicht, weil sie „nur dieses Gerät" ist. Die Liste zeigt dann Zeilen
        // ohne Geheimnis, und ohne diese Zeile bliebe der frisch eingetragene,
        // funktionierende Schlüssel unbenutzt: jedes Senden meldete weiterhin
        // „Kein API-Schlüssel hinterlegt".
        let activeIsUnusable = activeCredential(for: providerID)
            .map { credentialMasks[$0.id] == nil } ?? true
        if !hadCredential || activeIsUnusable {
            settings.activeCredentialByProvider[providerID] = credential.id
        }
        refreshKeyPresence()
        scheduleSave()
        return .added(credential)
    }

    /// Ein freier Name: der Anbietername, bei Bedarf durchnummeriert.
    func defaultCredentialName(for providerID: String) -> String {
        let base = ProviderRegistry.providerOrDefault(id: providerID).displayName
        let taken = Set(credentials(for: providerID).map(\.name))
        guard taken.contains(base) else { return base }
        var index = 2
        while taken.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    func renameCredential(_ id: UUID, to name: String) {
        guard let index = credentials.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Ein namenloser Eintrag wäre in der Liste nicht zu unterscheiden.
        guard !trimmed.isEmpty else { return }
        credentials[index].name = String(trimmed.prefix(40))
        // Bestmöglich nachziehen. Scheitert es, stimmt allein der Name in der
        // Keychain nicht mehr – sichtbar würde das erst, wenn die Liste je aus
        // ihr wiederhergestellt werden müsste.
        KeychainStore.setLabel(credentials[index].keychainLabel,
                               for: credentials[index].keychainAccount)
        scheduleSave()
    }

    /// Merkt sich, dass die Verbindung mit diesem Schlüssel gerade stand.
    func markCredentialVerified(_ id: UUID) {
        guard let index = credentials.firstIndex(where: { $0.id == id }) else { return }
        credentials[index].lastVerifiedAt = Date()
        scheduleSave()
    }

    /// Entfernt einen Schlüssel – aus der Keychain **und** aus der Liste.
    ///
    /// `false` heisst: die Keychain hat das Löschen abgelehnt. Dann bleibt der
    /// Eintrag auch in der Liste stehen. Andernfalls verschwände die Zeile,
    /// während das Geheimnis liegen bleibt – und wäre danach über keinen
    /// einzelnen Weg mehr zu entfernen. Die App sagt zu, Daten restlos zu
    /// löschen; „sieht gelöscht aus" genügt dafür nicht.
    @discardableResult
    func removeCredential(_ id: UUID) -> Bool {
        guard let index = credentials.firstIndex(where: { $0.id == id }) else { return true }
        let removed = credentials[index]
        guard KeychainStore.remove(removed.keychainAccount) else { return false }

        let wasActive = activeCredential(for: removed.providerID)?.id == id
        credentials.remove(at: index)
        if settings.activeCredentialByProvider[removed.providerID] == id {
            settings.activeCredentialByProvider[removed.providerID] = nil
        }
        refreshKeyPresence()
        // Die Modell-Liste hängt am Schlüssel: zwei Schlüssel desselben
        // Anbieters können unterschiedliche Modelle freigeschaltet haben.
        // Nur verwerfen, wenn wirklich ein anderer Schlüssel übernimmt.
        if wasActive, removed.providerID == activeProvider.id {
            models = []
            loadedModelsProviderID = nil
        }
        scheduleSave()
        return true
    }

    /// Wechselt den benutzten Schlüssel eines Anbieters.
    ///
    /// Die Modell-Liste wird dabei verworfen – sie gehört zum vorherigen
    /// Schlüssel. Das Nachladen stösst die Ansicht an, damit hier kein
    /// Nebenläufigkeitszustand entsteht.
    func activateCredential(_ id: UUID) {
        guard let credential = credentials.first(where: { $0.id == id }) else { return }
        guard settings.activeCredentialByProvider[credential.providerID] != id else { return }
        settings.activeCredentialByProvider[credential.providerID] = id
        if credential.providerID == activeProvider.id {
            models = []
            loadedModelsProviderID = nil
            modelsError = nil
        }
        scheduleSave()
    }

    /// Übernimmt Schlüssel aus der Ablage vor dieser Fassung.
    ///
    /// Dort lag je Anbieter genau einer, unter dem festen Konto
    /// `apikey.<anbieter>`. Er wird zu einem benannten Eintrag – erst
    /// schreiben, dann prüfen, erst danach das alte Konto räumen. Scheitert
    /// das Schreiben, bleibt alles wie es war und der nächste Start versucht
    /// es erneut; verloren geht der Schlüssel in keinem Fall.
    private func recoverKeys() {
        // Nach einem **Lesefehler** nichts anfassen. `credentials` ist dann
        // leer, obwohl die Datei voller Einträge sein kann – und geschrieben
        // werden darf ohnehin nicht (`pendingWrite` verweigert bei
        // `loadFailed`). Ohne diesen Riegel räumte die Übernahme unten das
        // alte Konto und könnte den neuen Stand nicht sichern: der Schlüssel
        // wäre dauerhaft verloren. Der nächste gelungene Start holt es nach.
        guard !loadFailed else { return }

        var changed = false
        var legacyAccounts: [String] = []

        // A) Ablage vor dieser Fassung: je Anbieter genau ein Schlüssel unter
        //    dem festen Konto `apikey.<anbieter>`.
        for provider in ProviderRegistry.all {
            guard !credentials.contains(where: { $0.providerID == provider.id }) else { continue }
            guard let key = KeychainStore.get(provider.keychainAccount) else { continue }
            let credential = APICredential(providerID: provider.id, name: provider.displayName)
            guard KeychainStore.set(key,
                                    for: credential.keychainAccount,
                                    label: credential.keychainLabel) else { continue }
            // Erst nachlesen, dann erst darf das alte Konto überhaupt in die
            // Räumliste. Ohne diese Probe stünde der Schlüssel am neuen Ort
            // womöglich gar nicht.
            guard KeychainStore.get(credential.keychainAccount) == key else {
                // Geschrieben, aber nicht nachlesbar: das neue Konto wieder
                // räumen. Sonst fände Weg B es beim nächsten Start und legte
                // eine zweite Zeile mit demselben Schlüssel an – nicht von
                // der ersten zu unterscheiden.
                KeychainStore.remove(credential.keychainAccount)
                continue
            }
            credentials.append(credential)
            settings.activeCredentialByProvider[provider.id] = credential.id
            legacyAccounts.append(provider.keychainAccount)
            changed = true
        }

        // B) Einträge, die in der Keychain liegen, auf die aber nichts mehr
        //    zeigt. Das passiert, wenn die Zustandsdatei beschädigt war und in
        //    Quarantäne wandern musste: der Kontoname ist eine nackte UUID,
        //    und ohne diesen Weg wären die Schlüssel für immer unerreichbar.
        //    Anbieter und Name stehen im Etikett des Keychain-Eintrags.
        let known = Set(credentials.map(\.keychainAccount))
        for entry in KeychainStore.accounts(withPrefix: APICredential.accountPrefix)
        where !known.contains(entry.account) {
            guard let credential = APICredential(recoveredAccount: entry.account,
                                                 label: entry.label) else { continue }
            credentials.append(credential)
            changed = true
        }

        guard changed else { return }

        // Reihenfolge mit Absicht: **erst** die Liste auf die Platte, dann die
        // alten Konten räumen. `saveNow()` setzt nur einen Auftrag ab, der
        // nebenläufig und mit niedriger Priorität läuft – ein Absturz im
        // Startfenster hinterliesse sonst einen Schlüssel, den es zwar noch
        // gibt, auf den aber nichts mehr zeigt.
        writeSynchronously()
        for account in legacyAccounts {
            KeychainStore.remove(account)
        }
    }

    /// Schreibt den aktuellen Stand **auf diesem Thread**.
    ///
    /// Nur für den einen Fall, in dem das Ergebnis feststehen muss, bevor die
    /// nächste Zeile läuft. Sonst gilt der Weg über `StateWriter`: der hält
    /// die Reihenfolge nebenläufiger Schreibvorgänge ein.
    ///
    /// **Darf nur laufen, bevor der erste Auftrag beim Aktor liegt** – also
    /// aus dem `init()` heraus. Danach kennt der Aktor diesen Schreibvorgang
    /// nicht, und ein älterer Schnappschuss aus der Warteschlange könnte ihn
    /// überholen.
    private func writeSynchronously() {
        guard let (snapshot, url, _) = pendingWrite() else { return }
        Self.write(snapshot, to: url)
    }

    // MARK: - Chats verwalten

    @discardableResult
    func newConversation(inProject projectID: UUID? = nil) -> Conversation {
        let modelID = defaultModelID(inProject: projectID)

        // Liegt im selben Projekt schon ein leerer, unbenannter Entwurf, wird
        // **der** geöffnet, statt einen zweiten daneben zu legen. Sonst
        // entstünde bei jedem Tippen auf „Neuer Chat“ eine weitere leere
        // Zeile in der Seitenleiste, ohne dass je etwas darin stünde.
        if let index = conversations.firstIndex(where: { $0.projectID == projectID && $0.isEmptyDraft }) {
            // Das Standardmodell kann sich seit dem Anlegen geändert haben –
            // etwa weil erst danach ein Schlüssel hinterlegt wurde.
            if conversations[index].modelID.isEmpty || blockedModelIDs.contains(conversations[index].modelID) {
                conversations[index].modelID = modelID
            }
            // Nach oben holen: sonst liegt der wiederverwendete Entwurf in
            // der nach Datum sortierten Liste unter Chats, in denen seither
            // gesendet wurde – „Neuer Chat“ sähe dann wie ein Fehlgriff aus.
            conversations[index].updatedAt = Date()
            let existing = conversations[index]
            selectedConversationID = existing.id
            discardEmptyDrafts(keeping: existing.id)
            scheduleSave()
            return existing
        }

        let conversation = Conversation(projectID: projectID, modelID: modelID)
        conversations.insert(conversation, at: 0)
        selectedConversationID = conversation.id
        // Entwürfe in **anderen** Projekten bleiben sonst stehen.
        discardEmptyDrafts(keeping: conversation.id)
        scheduleSave()
        return conversation
    }

    /// Das Modell, mit dem ein neuer Chat startet: erst die Projektvorgabe,
    /// dann die App-Vorgabe, sonst das erste verfügbare.
    private func defaultModelID(inProject projectID: UUID?) -> String {
        let project = self.project(id: projectID)
        // Gesperrte Modelle nie als Vorgabe übernehmen – der Chat wäre sonst
        // von Anfang an nicht benutzbar.
        let candidates = [project?.defaultModelID, settings.defaultModelID, availableModels.first?.id]
        return candidates
            .compactMap { $0 }
            .first { !$0.isEmpty && !blockedModelIDs.contains($0) } ?? ""
    }

    /// Auswahl wechseln – und dabei aufräumen.
    ///
    /// Der einzige Weg, über den die Seitenleiste die Auswahl setzt. Ein
    /// leerer, unbenannter Chat verschwindet in dem Moment, in dem man ihn
    /// verlässt; er hat nichts zu verlieren. Wer einen leeren Chat behalten
    /// will, gibt ihm einen Namen – dann bleibt er.
    func selectConversation(_ id: UUID?) {
        guard selectedConversationID != id else { return }
        selectedConversationID = id
        discardEmptyDrafts(keeping: id)
    }

    /// Entfernt alle leeren, unbenannten Chats bis auf einen.
    ///
    /// `keeping` ist der gerade offene Chat: den darf es nicht unter den
    /// Fingern wegziehen, sonst stünde man mitten im Tippen vor „Kein Chat
    /// ausgewählt“.
    private func discardEmptyDrafts(keeping id: UUID?) {
        let before = conversations.count
        conversations.removeAll { $0.id != id && $0.isEmptyDraft }
        var changed = conversations.count != before

        // Zeigt die Auswahl auf einen Chat, den es nicht mehr gibt, muss sie
        // mit. Das steht **vor** jeder Abkürzung und nicht hinter einem
        // `guard` auf „es wurde etwas entfernt“: die Seitenleiste kann noch
        // eine Zeile zeigen, die es im Zustand schon nicht mehr gibt (die
        // gefilterte Liste wird verzögert nachgezogen). Ein Tippen darauf
        // setzte sonst eine Auswahl ins Leere, und die Detailspalte bliebe
        // dauerhaft auf „Kein Chat ausgewählt“ stehen – gespeichert wird
        // dieser Zustand obendrein.
        if let selected = selectedConversationID,
           !conversations.contains(where: { $0.id == selected }) {
            selectedConversationID = nil
            changed = true
        }

        if changed { scheduleSave() }
    }

    func deleteConversation(_ id: UUID) {
        defer { recomputeProjectTotals() }
        // Läuft dort ein Stream, muss er mit dem Chat verschwinden – sonst
        // bleibt isStreaming bis zum Timeout hängen und die App kann nicht
        // mehr senden.
        if streamingConversationID == id { stopStreaming() }

        let deleted = conversations.first { $0.id == id }
        conversations.removeAll { $0.id == id }
        // Meldungen zu diesem Chat enthalten einen Auszug des gelöschten
        // Textes. Sie müssen mit weg, sonst überlebt der Inhalt die Löschung.
        reports.removeAll { $0.conversationID == id }
        // **Erst** die Löschung auf die Platte, dann die Dateien.
        //
        // Umgekehrt lag ein Verlust: `scheduleSave` entprellt 600 ms. Wer den
        // Chat wegwischt und die App sofort danach beendet oder abstürzt, hat
        // beim nächsten Start den Chat wieder – aber ohne seine Anhänge, weil
        // die Dateien längst weg waren.
        //
        // `writeSynchronously` und nicht `saveNow`: letzteres setzt nur einen
        // Auftrag ab, der nebenläufig läuft und durchaus **nach** dem Löschen
        // der Dateien auf der Platte landen kann. Das Fenster wäre dann zwar
        // klein, aber es wäre noch da.
        writeSynchronously()
        // Der ausgelesene Text angehängter Dateien und erzeugte Bilder. Das
        // Aufräumen beim Start fängt beides zwar ohnehin ein – aber „gelöscht"
        // soll gelöscht heissen und nicht „beim übernächsten Start".
        for name in deleted?.attachmentFileNames ?? [] {
            AttachmentStore.delete(name)
        }
        for message in deleted?.messages ?? [] {
            if let name = message.imageFileName { ImageStore.delete(name) }
        }

        let visible = conversationList(inProject: selectedProjectID)
        if selectedConversationID == id {
            selectedConversationID = visible.first?.id
        }
        if conversations.isEmpty || visible.isEmpty {
            newConversation(inProject: deleted?.projectID ?? selectedProjectID)
        } else {
            scheduleSave()
        }
        recomputeMonthCost()
    }

    func renameConversation(_ id: UUID, to title: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Ein leerer Titel ist keine Benennung – sonst liesse sich ein
        // Entwurf durch Umbenennen auf Leerzeichen dauerhaft festnageln.
        guard !trimmed.isEmpty else { return }
        // Ein unverändert bestätigter Vorgabetitel ist keine Benennung: sonst
        // bliebe ein leerer Chat namens „Neuer Chat“ für immer stehen, nur
        // weil das Umbenennen einmal geöffnet und abgenickt wurde.
        //
        // Das Merkmal kennt dabei nur **eine** Richtung. Würde es beim
        // Zurückbenennen wieder fallen, entstünde genau das, was hier
        // abgestellt werden soll: ein zweiter leerer Chat namens „Neuer Chat“
        // neben dem gerade offenen.
        let wasUnnamed = !conversations[index].titleWasEdited
            && conversations[index].title == Conversation.untitled
        conversations[index].title = trimmed
        if !(wasUnnamed && trimmed == Conversation.untitled) {
            conversations[index].titleWasEdited = true
        }
        scheduleSave()
    }

    func setModel(_ modelID: String, for conversationID: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].modelID = modelID
        scheduleSave()
    }

    func move(conversationID: UUID, toProject projectID: UUID?) {
        defer { recomputeProjectTotals() }
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].projectID = projectID
        scheduleSave()
    }

    // MARK: - Projekte verwalten

    func upsert(project: AIProject) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
        } else {
            projects.append(project)
        }
        scheduleSave()
    }

    func deleteProject(_ id: UUID) {
        defer { recomputeProjectTotals() }
        projects.removeAll { $0.id == id }
        for index in conversations.indices where conversations[index].projectID == id {
            conversations[index].projectID = nil
        }
        if selectedProjectID == id { selectedProjectID = nil }
        scheduleSave()
    }

    // MARK: - Modelle laden

    func refreshModels(force: Bool = false) async {
        let provider = activeProvider
        let providerID = provider.id

        guard let key = apiKey(for: providerID) else {
            models = []
            loadedModelsProviderID = nil
            modelsError = Loc.tr("Kein API-Schlüssel hinterlegt.")
            return
        }
        // Die Modell-Liste enthält keine Nutzerdaten, aber wir respektieren
        // die Zustimmung trotzdem: ohne Freigabe kein Kontakt zum Anbieter.
        // Bewusst OHNE Dialog – der erscheint erst beim Senden.
        guard consent.hasConsent(for: providerID) else {
            models = []
            loadedModelsProviderID = nil
            modelsError = Loc.tr("Datenfreigabe für %@ fehlt.", provider.displayName)
            return
        }
        if !force, !models.isEmpty, loadedModelsProviderID == providerID { return }

        // Laufende Abfrage abbrechen statt die neue zu verwerfen: sonst gewinnt
        // beim Anbieterwechsel die Antwort des vorherigen Anbieters.
        modelsGeneration &+= 1
        let generation = modelsGeneration
        modelsTask?.cancel()

        isLoadingModels = true
        modelsError = nil
        defer { if generation == modelsGeneration { isLoadingModels = false } }

        let task = Task { try await provider.fetchModels(apiKey: key) }
        modelsTask = task

        do {
            let loaded = try await task.value
            // Veraltet oder Anbieter inzwischen gewechselt: Ergebnis verwerfen.
            guard generation == modelsGeneration,
                  providerID == activeProvider.id else { return }

            adoptModels(loaded, for: providerID)
        } catch {
            guard generation == modelsGeneration else { return }
            if error is CancellationError { return }
            if let urlError = error as? URLError, urlError.code == URLError.Code.cancelled { return }
            modelsError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private static func preferredDefaultModel(in models: [AIModel]) -> AIModel? {
        // Ein günstiges, breit verfügbares Modell als Startpunkt.
        let candidates = ["openai/gpt-4o-mini", "anthropic/claude-3-5-haiku", "google/gemini-flash-1.5"]
        for candidate in candidates {
            if let match = models.first(where: { $0.id.hasPrefix(candidate) }) { return match }
        }
        return models.first { ($0.promptPricePerToken ?? 0) > 0 } ?? models.first
    }

    /// Übernimmt eine frisch geladene Modell-Liste.
    ///
    /// Eigene Methode, weil die Einstellungen beim Prüfen einer Verbindung
    /// ohnehin schon eine vollständige Liste in der Hand haben. Ohne diesen
    /// Weg würde dieselbe Abfrage unmittelbar danach ein zweites Mal laufen –
    /// bei OpenRouter sind das rund ein Megabyte für nichts.
    func adoptModels(_ loaded: [AIModel], for providerID: String) {
        guard providerID == activeProvider.id else { return }
        models = loaded
        loadedModelsProviderID = providerID
        modelsError = nil

        let usable = loaded.filter { !blockedModelIDs.contains($0.id) }
        if settings.defaultModelID == nil
            || !usable.contains(where: { $0.id == settings.defaultModelID }) {
            settings.defaultModelID = Self.preferredDefaultModel(in: usable)?.id
        }
        // Nur Chats **ohne** Modell bekommen eines gesetzt.
        //
        // Vorher wurde hier jeder Chat angeglichen, dessen Modell nicht in der
        // frisch geladenen Liste steht – und das ist nach einem Anbieterwechsel
        // jeder einzelne. Vierzig Chats mit sorgfältig gewählten Modellen
        // trugen danach alle dasselbe Standardmodell, ohne Rückweg. Ein
        // fremdes Modell stehen zu lassen ist dagegen harmlos: `send` weist
        // eine Kennung, die der aktive Anbieter nicht kennt, mit einer
        // verständlichen Meldung ab, statt sie hinauszuschicken.
        if !loaded.isEmpty, let fallback = settings.defaultModelID {
            for index in conversations.indices where conversations[index].modelID.isEmpty {
                conversations[index].modelID = fallback
            }
        }
        scheduleSave()
    }

    // MARK: - Schlüssel lesen

    /// Der Schlüssel, mit dem gerade gearbeitet wird – aus der Keychain.
    ///
    /// Der einzige Weg an das Geheimnis. Bewusst keine gepufferte Kopie im
    /// Arbeitsspeicher: was nicht dauerhaft herumliegt, kann auch nicht
    /// versehentlich in einem Protokoll oder einem Absturzbericht landen.
    func apiKey(for providerID: String) -> String? {
        guard let credential = activeCredential(for: providerID) else { return nil }
        return KeychainStore.get(credential.keychainAccount)
    }

    /// Der Schlüssel eines bestimmten Eintrags – für das Prüfen der Verbindung
    /// in den Einstellungen, das auch einen gerade nicht aktiven Eintrag
    /// prüfen können muss.
    func apiKey(forCredential id: UUID) -> String? {
        guard let credential = credentials.first(where: { $0.id == id }) else { return nil }
        return KeychainStore.get(credential.keychainAccount)
    }

    // MARK: - Zustimmung

    /// Zentraler Weg, eine Freigabe zu setzen. Ein Widerruf muss sofort
    /// wirken – auch mitten in einem laufenden Stream.
    func setConsent(_ granted: Bool, for providerID: String, scope: ConsentScope = .text) {
        consent.toggle(providerID: providerID, scope: scope, granted: granted)
        if scope == .audio {
            if !granted {
                // Sofort wirksam: auch eine laufende Aufnahme muss enden,
                // sonst würde sie nach dem Widerruf noch hochgeladen.
                speech.stopSpeaking()
                Task { await speech.cancelListening() }
            }
            return
        }
        if granted {
            if providerID == activeProvider.id {
                Task { await refreshModels(force: true) }
            }
            return
        }
        if isStreaming, streamingProviderID == providerID { stopStreaming() }
        if providerID == activeProvider.id { speech.stopSpeaking() }
        if providerID == activeProvider.id {
            models = []
            loadedModelsProviderID = nil
            modelsError = Loc.tr("Datenfreigabe für %@ fehlt.", activeProvider.displayName)
        }
    }

    // MARK: - Senden

    /// Liefert `true`, wenn die Eingabe verarbeitet wurde – also gesendet oder
    /// bewusst vom Inhaltsfilter abgewiesen. Bei `false` fehlt noch etwas
    /// (Schlüssel, Freigabe, Modell); die Oberfläche behält den Entwurf dann
    /// im Eingabefeld, statt ihn stillschweigend zu verwerfen.
    @discardableResult
    func send(_ rawText: String, attachments: [Attachment] = []) -> Bool {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Wer nur eine Datei anhängt und nichts dazu schreibt, meint fast
        // immer dasselbe. Der Satz wird **in die Nachricht geschrieben** und
        // nicht heimlich untergeschoben: der Nutzer sieht in seiner eigenen
        // Blase, was tatsächlich gefragt wurde.
        if text.isEmpty, !attachments.isEmpty {
            // Bei einem Bild heisst „nichts dazu geschrieben" etwas anderes
            // als bei einem PDF. „Fasse das angehängte Bild zusammen" wäre
            // eine Aufforderung, die niemand so stellt.
            if attachments.allSatisfy({ $0.kind.isImage }) {
                text = attachments.count == 1
                    ? Loc.tr("Beschreibe das angehängte Bild.")
                    : Loc.tr("Beschreibe die angehängten Bilder.")
            } else {
                text = attachments.count == 1
                    ? Loc.tr("Fasse die angehängte Datei zusammen.")
                    : Loc.tr("Fasse die angehängten Dateien zusammen.")
            }
        }
        guard !text.isEmpty else { return false }
        if isStreaming {
            alertMessage = streamingConversationID == selectedConversationID
                ? Loc.tr("Es läuft noch eine Antwort. Bitte warte, bis sie fertig ist, oder stoppe sie.")
                : Loc.tr("In einem anderen Chat läuft noch eine Antwort. Bitte warte kurz oder stoppe sie dort.")
            return false
        }
        guard let conversationID = selectedConversationID,
              let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return false }

        // 1) Inhaltsfilter auf die Eingabe (Richtlinie 1.2)
        let verdict = ContentModeration.screenInput(text, strict: settings.strictFilter)
        if verdict.isBlocked {
            // Die schon ausgelesenen Dateien gehören mit weg. Die Nachricht
            // wird nie angelegt, also zeigt gleich gar nichts mehr auf sie –
            // und ausgelesener Dokumententext, der eine abgewiesene Nachricht
            // überlebt, widerspräche der Zusage, Daten restlos zu entfernen.
            for attachment in attachments {
                AttachmentStore.delete(attachment.storedFileName)
            }
            appendBlockedExchange(explanation: verdict.explanation, at: index)
            return true
        }

        // 2) Zustimmung zur Datenweitergabe (Richtlinie 5.1.2(i))
        let provider = activeProvider
        guard consent.hasConsent(for: provider.id) else {
            consentRequest = ConsentRequest(providerID: provider.id)
            return false
        }

        // 3) Schlüssel
        guard let apiKey = apiKey(for: provider.id) else {
            alertMessage = ProviderError.missingKey(provider: provider.displayName).errorDescription
            refreshKeyPresence()
            return false
        }

        // 4) Modell
        let modelID = conversations[index].modelID.isEmpty
            ? (settings.defaultModelID ?? "")
            : conversations[index].modelID
        guard !modelID.isEmpty else {
            alertMessage = Loc.tr("Bitte wähle zuerst ein Modell aus.")
            return false
        }
        guard !blockedModelIDs.contains(modelID) else {
            alertMessage = ProviderError.modelBlocked.errorDescription
            return false
        }
        // Kennt der aktive Anbieter dieses Modell nicht, hier abbrechen –
        // nicht erst beim Anbieter.
        //
        // Nach einem Anbieterwechsel behalten bestehende Chats ihre
        // Modellkennung (sie wieder einzusammeln kostete den Nutzer seine
        // Auswahl in allen Chats). Ohne diese Prüfung ginge die Anfrage
        // hinaus und käme als kryptischer HTTP-Fehler des Anbieters zurück.
        // `models.isEmpty` lässt die Prüfung aus, solange die Liste noch gar
        // nicht geladen ist – dort wäre jede Aussage geraten.
        guard models.isEmpty || model(id: modelID) != nil else {
            alertMessage = Loc.tr("„%@“ gehört nicht zu %@. Wähle oben im Chat ein Modell dieses Anbieters – oder wechsle zurück zu dem Anbieter, bei dem dieses Modell liegt.",
                                  modelID, provider.displayName)
            return false
        }
        // Bildmodelle sprechen einen anderen Endpunkt. Kann der Anbieter das
        // nicht, wird hier abgebrochen – **vor** dem Anlegen der Nachrichten.
        // Vorher wurden sie erst angelegt und wieder entfernt, Chattitel und
        // Änderungsdatum blieben dabei aber stehen: der Chat trug danach den
        // Titel einer Nachricht, die es nicht gab, und rutschte in der
        // Seitenleiste nach oben.
        guard model(id: modelID)?.isImageModel != true || provider.canGenerateImages else {
            alertMessage = ProviderError.imageUnsupported(provider: provider.displayName).errorDescription
            return false
        }

        // 4a) Der Ersatzsatz für eine Nachricht ohne eigenen Text hängt vom
        //     Modell ab – und das steht erst hier fest. „Beschreibe das
        //     angehängte Bild." wäre bei einem Bildmodell keine Frage, sondern
        //     ein Malauftrag: es zeichnete die Aufforderung.
        if rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !attachments.isEmpty,
           model(id: modelID)?.isImageModel == true {
            let images = attachments.filter { $0.kind.isImage }
            guard !images.isEmpty else {
                // Bildmodell, nur Dokumente angehängt, kein Wort dazu: es gibt
                // nichts, woraus sich ein Bild machen liesse. Der Dateitext
                // geht an den Bild-Endpunkt ohnehin nicht mit, und
                // „Fasse die angehängte Datei zusammen." als Malauftrag wäre
                // bezahlter Unsinn. Lieber gar nicht senden und es sagen.
                alertMessage = Loc.tr("Ein Bildmodell braucht eine Beschreibung. Schreib dazu, was auf dem Bild zu sehen sein soll – der Text angehängter Dokumente geht an ein Bildmodell nicht mit.")
                return false
            }
            text = images.count == 1
                ? Loc.tr("Erzeuge ein neues Bild auf Grundlage der angehängten Vorlage.")
                : Loc.tr("Erzeuge ein neues Bild auf Grundlage der angehängten Vorlagen.")
        }

        // 5) Nachricht anlegen und den Kontext bauen
        let userMessage = ChatMessage(role: .user, text: text, modelID: modelID,
                                      attachments: attachments)
        conversations[index].messages.append(userMessage)

        // 6) Filter auf das, was tatsächlich das Gerät verlässt. Ohne diese
        //    Prüfung genügen zwei Nachrichten zum Umgehen: harmlose erste,
        //    dann "mach weiter" – der Verlauf ginge ungeprüft mit.
        // Der Filter läuft über den Verlauf **ohne** die Dateiinhalte.
        //
        // Nicht aus Nachlässigkeit: der Inhalt einer angehängten Datei wird
        // beim Anhängen geprüft, einmal und abseits des Hauptthreads. Ihn hier
        // erneut mitzuschleifen hiesse, bei **jeder** Nachricht ein paar
        // hunderttausend Zeichen durch Normalisierung und 216 Suchbegriffe zu
        // schicken – auf dem Hauptaktor, mit einer sichtbar stehenden
        // Oberfläche. Geprüft wird hier, was der Nutzer schreibt; der Verlauf
        // ist damit weiterhin lückenlos abgedeckt.
        //
        // Immer die anhanglose Fassung, auch wenn gar nichts angehängt ist:
        // dort ist sie ohnehin Wort für Wort dieselbe, und der Sonderfall
        // hätte nur eine zweite Stelle geschaffen, die man beim nächsten
        // Umbau vergisst.
        let screened = buildTurns(for: conversations[index], modelID: modelID,
                                  includeAttachments: false)
        let contextVerdict = ContentModeration.screenOutgoingContext(screened, strict: settings.strictFilter)
        if contextVerdict.isBlocked {
            // Die Anhänge dieser Nachricht verschwinden mit ihr – ihr Text
            // liegt sonst für immer im Anhangsordner, ohne dass etwas darauf
            // zeigt.
            for attachment in conversations[index].messages.last?.attachments ?? [] {
                AttachmentStore.delete(attachment.storedFileName)
            }
            conversations[index].messages.removeLast()
            // Den auslösenden Verlauf markieren, damit er künftig aus dem
            // Kontext fällt. Ohne das würde derselbe Verlauf JEDE weitere
            // Nachricht blockieren und der Chat wäre nicht mehr benutzbar.
            for messageIndex in conversations[index].messages.indices {
                let existing = conversations[index].messages[messageIndex]
                guard !existing.isFlagged, !existing.isError, !existing.text.isEmpty else { continue }
                if ContentModeration.screenInput(existing.text, strict: settings.strictFilter).isBlocked {
                    conversations[index].messages[messageIndex].isFlagged = true
                }
            }
            appendBlockedExchange(explanation: contextVerdict.explanation, at: index)
            return true
        }

        if !conversations[index].titleWasEdited,
           conversations[index].title == Conversation.untitled {
            conversations[index].title = Self.title(from: text)
        }
        let assistantMessage = ChatMessage(role: .assistant, text: "", modelID: modelID)
        conversations[index].messages.append(assistantMessage)
        conversations[index].updatedAt = Date()
        // **Jetzt** sichern, nicht erst wenn die Antwort fertig ist.
        //
        // Zwischen dem Absenden und dem Ende einer langen Antwort liegen
        // schnell zwei Minuten, und in dieser Zeit stand bisher weder die
        // Frage noch der Titel des Chats auf der Platte: `append` schreibt
        // bewusst nicht mit, sonst liefe die Zustandsdatei bei jedem Token
        // neu durch den Kodierer. Beendet iOS die App wegen Speicherdrucks
        // oder stürzt sie ab, war die getippte Frage weg. Ein
        // entprellter Schreibvorgang hier kostet einmal, rettet aber alles,
        // was der Nutzer selbst geschrieben hat.
        scheduleSave()

        // Krisen-Hinweis erst hier: vorher könnte er mit dem
        // Zustimmungsdialog kollidieren, und SwiftUI zeigt nur eines von beiden.
        if verdict.needsSupportNotice {
            supportNotice = ContentModeration.selfHarmSupportBody
        }

        // Bildmodelle sprechen einen anderen Endpunkt. Ohne diese Weiche
        // ginge die Anfrage an /chat/completions, das Modell antwortete mit
        // Text – und behauptete womöglich, es habe ein Bild erzeugt, obwohl
        // nie eines übertragen wurde. Genau das war der Fehler vorher.
        if model(id: modelID)?.isImageModel == true, provider.canGenerateImages {
            streamGeneration &+= 1
            let generation = streamGeneration
            isStreaming = true
            streamingConversationID = conversationID
            streamingProviderID = provider.id

            // Vorlagebilder aus der gerade abgeschickten Nachricht. Genau
            // dafür ist das Anhängen bei einem Bildmodell da: ein eigenes Foto
            // sagt mehr als drei Absätze Beschreibung.
            let references = imageDataURLs(for: userMessage)

            streamTask?.cancel()
            streamTask = Task { [weak self] in
                await self?.produceImage(provider: provider,
                                         apiKey: apiKey,
                                         prompt: text,
                                         modelID: modelID,
                                         references: references,
                                         conversationID: conversationID,
                                         assistantID: assistantMessage.id,
                                         generation: generation)
            }
            return true
        }

        // Erst **hier** bauen, nicht vor der Bildmodell-Weiche: `buildTurns`
        // liest jede zugeschaltete Bilddatei des Verlaufs von der Platte und
        // kodiert sie Base64 – auf dem Hauptaktor. Im Bildmodell-Zweig wird
        // das Ergebnis nie benutzt; bei vier Anhangsbildern wären das rund
        // anderthalb Megabyte Zeichenkette für nichts.
        let turns = buildTurns(for: conversations[index], modelID: modelID)

        // Die Schätzung **hier** bilden und als Zahl weiterreichen.
        //
        // Gebraucht wird sie nur als Rückfall, wenn der Anbieter keinen
        // Verbrauch zurückmeldet. Die Turns selbst in die Antwort-Aufgabe zu
        // geben hiesse, die Base64-Fassung sämtlicher Bilder des Verlaufs über
        // die ganze Antwortdauer im Speicher zu halten – bei zwanzig Bildern
        // acht Megabyte, zusätzlich zu der Kopie, die in der Anfrage ohnehin
        // steckt.
        let estimatedPromptTokens = TokenEstimator.estimate(turns: turns)

        let request = ChatCompletionRequest(modelID: modelID,
                                            turns: turns,
                                            temperature: settings.temperature,
                                            maxTokens: settings.maxTokens)
        // Preise zur Sendezeit festhalten: `models` kann während des Streams
        // geleert werden (Anbieterwechsel), die Kosten wären dann verloren.
        let pricingModel = model(id: modelID)

        streamGeneration &+= 1
        let generation = streamGeneration
        isStreaming = true
        streamingConversationID = conversationID
        streamingProviderID = provider.id

        streamTask?.cancel()
        streamTask = Task { [weak self] in
            await self?.consume(provider: provider,
                                apiKey: apiKey,
                                request: request,
                                pricingModel: pricingModel,
                                conversationID: conversationID,
                                assistantID: assistantMessage.id,
                                estimatedPromptTokens: estimatedPromptTokens,
                                generation: generation)
        }
        return true
    }

    // MARK: - Bilderzeugung

    /// Holt ein Bild und hängt es an die bereits angelegte Antwort.
    ///
    /// Bewusst ohne Stream: die Bild-Endpunkte liefern das fertige Bild in
    /// einer Antwort. Die Wartezeit ist trotzdem sichtbar, weil `isStreaming`
    /// gesetzt bleibt und die Tippanzeige läuft.
    private func produceImage(provider: any AIProviderProtocol,
                              apiKey: String,
                              prompt: String,
                              modelID: String,
                              references: [String],
                              conversationID: UUID,
                              assistantID: UUID,
                              generation: Int) async {
        defer {
            if generation == streamGeneration {
                isStreaming = false
                streamingConversationID = nil
                streamingProviderID = nil
            }
        }

        do {
            let image = try await provider.generateImage(prompt: prompt,
                                                         modelID: modelID,
                                                         apiKey: apiKey,
                                                         references: references)
            guard !Task.isCancelled else {
                // Sonst bliebe die Antwortnachricht leer stehen.
                finishImage(text: Loc.tr("Abgebrochen."), fileName: nil, costUSD: nil,
                            isError: true,
                            conversationID: conversationID, assistantID: assistantID)
                return
            }
            guard let name = ImageStore.save(image.data, mimeType: image.mimeType) else {
                finishImage(text: Loc.tr("Das Bild konnte nicht gespeichert werden."),
                            fileName: nil, costUSD: nil, isError: true,
                            conversationID: conversationID, assistantID: assistantID)
                return
            }
            // Reihenfolge zählt: `recomputeMonthCost` summiert über die
            // Nachrichten. Vor `finishImage` stünde dort noch kein Betrag,
            // und das Bild fehlte in der Monats- und Budgetanzeige, obwohl
            // die Sitzungssumme es schon enthielte.
            finishImage(text: "", fileName: name, costUSD: image.costUSD,
                        isError: false,
                        // Aus den Daten, die ohnehin im Speicher liegen – nur
                        // der Dateikopf, kein Entpacken. Der Wert wandert in
                        // die Nachricht, damit die Ansicht die Höhe der Blase
                        // auch nach einem Neustart sofort kennt.
                        aspectRatio: ImageFileLoader.aspectRatio(of: image.data),
                        conversationID: conversationID, assistantID: assistantID)
            // Nur, wenn die Nachricht die Antwort auch bekommen hat.
            // Löscht der Nutzer den Chat, während das Bild entsteht, steigt
            // `finishImage` oben aus – die Sitzungssumme zeigte dann einen
            // Betrag, den weder Chat noch Projekt noch Monat kennen.
            if let cost = image.costUSD, cost.isFinite, cost > 0,
               conversations.contains(where: { $0.id == conversationID }) {
                sessionCostUSD += cost
                recomputeMonthCost()
            }
        } catch {
            // Beim Abbruch bliebe die Antwortnachricht sonst leer und die
            // Ansicht zeigte „Keine Antwort erhalten." – der Textpfad schreibt
            // an derselben Stelle „Abgebrochen.".
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                finishImage(text: Loc.tr("Abgebrochen."), fileName: nil, costUSD: nil,
                            isError: true,
                            conversationID: conversationID, assistantID: assistantID)
                return
            }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            finishImage(text: message, fileName: nil, costUSD: nil, isError: true,
                        conversationID: conversationID, assistantID: assistantID)
        }
    }

    private func finishImage(text: String,
                             fileName: String?,
                             costUSD: Double?,
                             isError: Bool,
                             aspectRatio: Double? = nil,
                             conversationID: UUID,
                             assistantID: UUID) {
        guard let ci = conversations.firstIndex(where: { $0.id == conversationID }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == assistantID })
        else { return }
        conversations[ci].messages[mi].text = text
        conversations[ci].messages[mi].imageFileName = fileName
        conversations[ci].messages[mi].imageAspectRatio = aspectRatio
        conversations[ci].messages[mi].costUSD = costUSD
        conversations[ci].messages[mi].isError = isError
        conversations[ci].updatedAt = Date()
        if fileName != nil {
            // Nicht erst in 600 Millisekunden: stirbt der Prozess vorher,
            // kennt niemand mehr den Dateinamen, und der nächste Start
            // räumt die Bilddatei als Waise weg. Der Nutzer sähe ein Bild,
            // das nach dem Neustart spurlos verschwunden ist.
            saveNow()
        } else {
            scheduleSave()
        }
    }

    /// Der blockierte Text wird bewusst NICHT gespeichert. Sonst stünde er im
    /// Verlauf und ginge mit der nächsten Nachricht doch an den Anbieter –
    /// und die Zusage "ByoKey sendet sie nicht und speichert sie nicht" wäre
    /// nachweislich falsch.
    private func appendBlockedExchange(explanation: String, at index: Int) {
        conversations[index].messages.append(
            ChatMessage(role: .user,
                        text: Loc.tr("Eingabe vom Inhaltsfilter blockiert."),
                        isError: true,
                        isFlagged: true)
        )
        // `isError` genügt zur Ausgrenzung aus dem Kontext. Zusätzliches
        // `isFlagged` würde den eigenen Hinweistext der App hinter der
        // Markierung verstecken – samt "Trotzdem anzeigen" und "Melden".
        conversations[index].messages.append(
            // Nicht hier übersetzen: der deutsche Text ist der Schlüssel und
            // wird beim Anzeigen nachgeschlagen. So wechselt auch ein alter
            // Hinweis die Sprache mit, wenn der Nutzer sie umstellt.
            ChatMessage(role: .assistant,
                        text: explanation,
                        isError: true)
        )
        conversations[index].updatedAt = Date()
        scheduleSave()
    }

    func stopStreaming() {
        streamGeneration &+= 1
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        streamingConversationID = nil
        streamingProviderID = nil
    }

    /// Beendet den Lauf nur, wenn ihn nicht längst ein neuer abgelöst hat.
    private func endStream(generation: Int) {
        guard generation == streamGeneration else { return }
        isStreaming = false
        streamingConversationID = nil
        streamingProviderID = nil
    }

    private func consume(provider: any AIProviderProtocol,
                         apiKey: String,
                         request: ChatCompletionRequest,
                         pricingModel: AIModel?,
                         conversationID: UUID,
                         assistantID: UUID,
                         estimatedPromptTokens: Int,
                         generation: Int) async {

        var reportedPrompt: Int?
        var reportedCompletion: Int?
        var reportedCost: Double?
        var accumulated = ""
        var pending = ""
        var lastFlush = Date()
        /// Bytes statt `accumulated.count`: Graphem-Zählen ist O(n) und wäre
        /// pro Token genau die quadratische Falle, die `append` vermeidet.
        var accumulatedLength = 0
        var lastScreenedLength = 0
        var flaggedDuringStream = false
        var failure: Error?

        func flush() {
            guard !pending.isEmpty else { return }
            append(pending, to: assistantID, in: conversationID)
            pending.removeAll(keepingCapacity: true)
        }

        do {
            for try await event in provider.streamCompletion(request, apiKey: apiKey) {
                switch event {
                case .token(let piece):
                    accumulated += piece
                    pending += piece
                    accumulatedLength += piece.utf8.count

                    // Zwischenprüfung: markierter Inhalt darf nicht während
                    // des Streams offen sichtbar sein. Ein Filter, der den Text
                    // erst nach dem Lesen verdeckt, filtert nichts.
                    //
                    // Geprüft wird nur das Ende des bisherigen Textes – die
                    // vollständige Prüfung macht `finish()`. Den ganzen Text
                    // alle 120 Zeichen neu zu normalisieren wäre quadratisch.
                    if !flaggedDuringStream, accumulatedLength - lastScreenedLength >= 120 {
                        lastScreenedLength = accumulatedLength
                        // `accumulatedLength` steht in Bytes und ist bereits
                        // mitgeführt. `accumulated.count` zählt dagegen
                        // Grapheme über den **gesamten** bisherigen Text –
                        // alle 120 Bytes erneut, also quadratisch. Bei einer
                        // langen Antwort war das der spürbarste Bremsklotz.
                        let window = accumulatedLength > 800
                            ? String(accumulated.suffix(800))
                            : accumulated
                        if ContentModeration.screenStreamingChunk(window).isFlagged {
                            flaggedDuringStream = true
                            setFlag(true, on: assistantID, in: conversationID)
                        }
                    }

                    // Nur getaktet in den Zustand schreiben. Jede Zuweisung
                    // lässt die halbe Oberfläche neu rechnen – und der Takt
                    // hängt an der Länge.
                    //
                    // Bei jeder Ausgabe wird die laufende Antwort neu
                    // ausgezeichnet – Markdown, Code-Hervorhebung, Layout –,
                    // und das über den **ganzen** bis dahin angesammelten
                    // Text. Bei zwanzig Ausgaben pro Sekunde wächst dieser
                    // Aufwand quadratisch mit der Antwortlänge. Ab ein paar
                    // Kilobyte fällt der Unterschied zwischen 50 und 150
                    // Millisekunden niemandem auf; das Ruckeln bei langen
                    // Antworten sehr wohl.
                    let interval: TimeInterval = accumulatedLength > 20_000 ? 0.15
                        : (accumulatedLength > 4_000 ? 0.1 : 0.05)
                    if Date().timeIntervalSince(lastFlush) >= interval {
                        flush()
                        lastFlush = Date()
                    }

                case .usage(let prompt, let completion, let cost):
                    // Monoton: ein späterer Null-Chunk darf echte Werte nicht
                    // überschreiben.
                    if let prompt { reportedPrompt = max(reportedPrompt ?? 0, prompt) }
                    if let completion { reportedCompletion = max(reportedCompletion ?? 0, completion) }
                    if let cost, cost > 0 { reportedCost = cost }

                case .finished:
                    break
                }
            }
        } catch {
            failure = error
        }

        // Ein abgebrochener AsyncThrowingStream wirft nicht zwingend – der
        // Abbruch ist zuverlässig nur am Task-Zustand erkennbar.
        var wasCancelled = Task.isCancelled
        if let failure {
            if failure is CancellationError { wasCancelled = true }
            if let providerError = failure as? ProviderError, providerError == .cancelled {
                wasCancelled = true
            }
            if let urlError = failure as? URLError, urlError.code == URLError.Code.cancelled {
                wasCancelled = true
            }
        }

        // Der Chat kann während des Streams gelöscht worden sein (auch durch
        // "Alle Daten löschen"). Dann gibt es nichts abzurechnen, und die
        // Sitzungszähler bleiben unberührt.
        guard conversations.contains(where: { $0.id == conversationID }) else {
            endStream(generation: generation)
            return
        }

        flush()

        let tokensReported = reportedPrompt != nil && reportedCompletion != nil
        let promptTokens = reportedPrompt ?? estimatedPromptTokens
        let completionTokens = reportedCompletion ?? TokenEstimator.estimate(accumulated)

        let priced = CostCalculator.cost(promptTokens: promptTokens,
                                         completionTokens: completionTokens,
                                         model: pricingModel,
                                         customPricing: customPricing[request.modelID],
                                         reportedCostUSD: reportedCost)

        let isExact: Bool
        switch priced.source {
        case .providerReported:
            isExact = true
        case .providerPriceTable:
            // Preisliste ist exakt, sobald die Tokens vom Anbieter stammen.
            isExact = tokensReported
        case .userPricing, .unknown:
            isExact = false
        }

        // Ohne Antworttext und ohne gemeldeten Verbrauch ist nichts
        // abzurechnen – sonst wächst das Budget ohne sichtbare Ursache.
        let hasBilling = !accumulated.isEmpty || tokensReported || reportedCost != nil
        let breakdown = hasBilling
            ? CostBreakdown(promptTokens: promptTokens,
                            completionTokens: completionTokens,
                            costUSD: priced.usd,
                            isEstimate: !isExact)
            : nil

        if let failure, !wasCancelled {
            let message = (failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription
            finish(assistantID: assistantID,
                   in: conversationID,
                   text: accumulated.isEmpty ? message : accumulated + "\n\n⚠️ " + message,
                   isError: true,
                   forceFlagged: flaggedDuringStream,
                   breakdown: breakdown,
                   modelID: request.modelID)
        } else if accumulated.isEmpty {
            finish(assistantID: assistantID,
                   in: conversationID,
                   text: wasCancelled ? Loc.tr("Abgebrochen.")
                                      : Loc.tr("Der Anbieter hat keine Antwort geliefert."),
                   isError: true,
                   forceFlagged: false,
                   breakdown: breakdown,
                   modelID: request.modelID)
        } else {
            finish(assistantID: assistantID,
                   in: conversationID,
                   text: accumulated,
                   isError: false,
                   forceFlagged: flaggedDuringStream,
                   breakdown: breakdown,
                   modelID: request.modelID)
        }

        // Bewusst ohne Generations-Prüfung: `consume` läuft genau einmal pro
        // Stream, es kann also nichts doppelt gezählt werden. Mit Prüfung
        // fehlten nach einem Stopp die Kosten in "Diese Sitzung", während sie
        // in Chat- und Monatssumme auftauchen – ein sichtbarer Widerspruch.
        if let breakdown {
            sessionTokens += breakdown.totalTokens
            sessionCostUSD += breakdown.costUSD ?? 0
        }

        recomputeMonthCost()
        endStream(generation: generation)
        scheduleSave()
    }

    /// Hängt nur das neue Stück an. Den kompletten Text zuzuweisen würde den
    /// String-Puffer bei jedem Token vollständig kopieren (O(n²)).
    private func append(_ piece: String, to messageID: UUID, in conversationID: UUID) {
        guard !piece.isEmpty,
              let ci = conversations.firstIndex(where: { $0.id == conversationID }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == messageID }) else { return }
        conversations[ci].messages[mi].text.append(piece)
    }

    private func setFlag(_ value: Bool, on messageID: UUID, in conversationID: UUID) {
        guard let ci = conversations.firstIndex(where: { $0.id == conversationID }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == messageID }) else { return }
        conversations[ci].messages[mi].isFlagged = value
    }

    private func finish(assistantID: UUID,
                        in conversationID: UUID,
                        text: String,
                        isError: Bool,
                        forceFlagged: Bool,
                        breakdown: CostBreakdown?,
                        modelID: String) {
        guard let ci = conversations.firstIndex(where: { $0.id == conversationID }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == assistantID }) else { return }

        // Auch Fehlertexte enthalten den bis dahin gestreamten Modelltext.
        // Ohne Prüfung wäre der Ausgabefilter mit einem abgebrochenen Stream
        // aushebelbar.
        let verdict = ContentModeration.screenOutput(text, strict: settings.strictFilter)

        conversations[ci].messages[mi].text = text
        conversations[ci].messages[mi].isError = isError
        conversations[ci].messages[mi].isFlagged = verdict.isFlagged || forceFlagged
        conversations[ci].messages[mi].modelID = modelID
        if let breakdown {
            conversations[ci].messages[mi].promptTokens = breakdown.promptTokens
            conversations[ci].messages[mi].completionTokens = breakdown.completionTokens
            conversations[ci].messages[mi].costUSD = breakdown.costUSD
            conversations[ci].messages[mi].isEstimate = breakdown.isEstimate
        }
        conversations[ci].updatedAt = Date()
    }

    /// Was von einer Nachricht wirklich hinausgeht: erst die Anhänge, dann der
    /// Text des Nutzers.
    ///
    /// Die Trennlinien sind kein Schmuck. Ohne sie verschwimmt der Dateiinhalt
    /// mit der Frage, und ein Dokument, das selbst wie eine Anweisung klingt
    /// („Ignoriere alle vorherigen Anweisungen"), liest sich für das Modell wie
    /// eine solche. Mit klarer Kennzeichnung bleibt erkennbar, was Zitat ist
    /// und was Auftrag.
    private func outgoingContent(for message: ChatMessage) -> String {
        // Bilder gehen als Bild hinaus, nicht als Text – sie stehen in
        // `ChatTurn.images`.
        let active = message.attachments.filter { $0.isActive && !$0.kind.isImage }
        guard !active.isEmpty else { return message.text }

        var blocks: [String] = []
        for attachment in active {
            guard let body = AttachmentStore.text(for: attachment.storedFileName) else {
                // Die Textdatei fehlt – etwa nach einer Wiederherstellung, bei
                // der nur die Zustandsdatei zurückkam. Ehrlich benennen statt
                // stillschweigend weglassen: sonst antwortet das Modell auf
                // ein Dokument, das es nie gesehen hat.
                blocks.append(Loc.tr("[Der Anhang „%@“ ist auf diesem Gerät nicht mehr vorhanden.]",
                                     attachment.fileName))
                continue
            }
            var header = Loc.tr("--- Angehängte Datei: %@ ---", attachment.fileName)
            if attachment.isTruncated {
                let share = Int((attachment.transferredShare * 100).rounded())
                header = Loc.tr("--- Angehängte Datei: %@ (gekürzt, nur die ersten %lld %% des Textes) ---",
                                attachment.fileName, share)
            }
            blocks.append(header + "\n" + body + "\n"
                          + Loc.tr("--- Ende der Datei: %@ ---", attachment.fileName))
        }

        blocks.append(message.text)
        return blocks.joined(separator: "\n\n")
    }

    /// Die angehängten Bilder einer Nachricht als Data-URLs.
    ///
    /// Gelesen und kodiert wird bei **jedem** Senden neu. Das ist Absicht: die
    /// Base64-Fassung eines Bildes ist ein Drittel grösser als die Datei, und
    /// sie dauerhaft im Arbeitsspeicher zu halten hiesse, bei einem Verlauf mit
    /// mehreren Bildern zweistellige Megabyte mitzuschleppen – für einen
    /// Vorgang, der ohnehin auf eine Netzantwort wartet.
    private func imageDataURLs(for message: ChatMessage) -> [String] {
        message.attachments
            .filter { $0.isActive && $0.kind.isImage }
            .compactMap { attachment in
                AttachmentStore.imageData(for: attachment.storedFileName)
                    .map(ImageAttachmentCoder.dataURL)
            }
    }

    /// Was die Bilder einer Nachricht im Kontextfenster belegen.
    private func imageTokens(of message: ChatMessage) -> Int {
        message.attachments
            .filter { $0.isActive && $0.kind.isImage }
            .reduce(0) { $0 + $1.tokenEstimate }
    }

    /// Baut die Nachrichtenliste für den Anbieter zusammen und kürzt den
    /// Verlauf so, dass er in das Kontextfenster des Modells passt.
    private func buildTurns(for conversation: Conversation,
                           modelID: String,
                           includeAttachments: Bool = true) -> [ChatTurn] {
        var systemTurns: [ChatTurn] = []

        // Projekt-Prompt ZUERST, verbindliche Regeln danach: stünde der
        // Projekt-Prompt hinten, könnte er die Regeln allein durch seine
        // spätere Position aushebeln.
        if let project = project(id: conversation.projectID),
           !project.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            systemTurns.append(ChatTurn(role: "system", content: project.systemPrompt))
        }
        systemTurns.append(ChatTurn(role: "system", content: ContentModeration.safetySystemPrompt))

        // Markierte Inhalte verlassen das Gerät auch später nicht – weder
        // blockierte Eingaben noch markierte Antworten.
        let history = conversation.messages.filter {
            $0.role != .system && !$0.isError && !$0.isFlagged && !$0.text.isEmpty
        }

        let contextLimit = model(id: modelID)?.contextLength ?? 0
        // Rund 60 % des Fensters für den Verlauf, der Rest für die Antwort.
        let budget = contextLimit > 0 ? Int(Double(contextLimit) * 0.6) : 12_000

        // Der ausgehende Text einer Nachricht ist **nicht** dasselbe wie der
        // angezeigte: bei einem Anhang kommt dessen Inhalt davor. Einmal
        // gebaut und gemerkt – sonst würde jede Anhangsdatei zweimal gelesen,
        // einmal fürs Rechnen und einmal fürs Senden, und die beiden Werte
        // könnten auseinanderlaufen.
        var rendered: [UUID: String] = [:]
        func content(of message: ChatMessage) -> String {
            guard includeAttachments else { return message.text }
            if let cached = rendered[message.id] { return cached }
            let built = outgoingContent(for: message)
            rendered[message.id] = built
            return built
        }

        var selected: [ChatMessage] = []
        var used = systemTurns.reduce(0) { $0 + TokenEstimator.estimate($1.content) + 4 }
        for message in history.reversed() {
            let cost = TokenEstimator.estimate(content(of: message))
                + (includeAttachments ? imageTokens(of: message) : 0) + 4
            // `selected.isEmpty` ist der Grund, warum ein grosser Anhang
            // überhaupt durchkommt: die **neueste** Nachricht wird immer
            // aufgenommen, koste sie was sie wolle, und der ältere Verlauf
            // weicht ihr. Andernfalls hinge man mit einem angehängten Buch
            // fest, ohne je eine Antwort zu bekommen.
            if used + cost > budget && !selected.isEmpty { break }
            used += cost
            selected.append(message)
        }
        selected.reverse()

        var turns = systemTurns
        turns.append(contentsOf: selected.map { message in
            ChatTurn(role: message.role.rawValue,
                     content: content(of: message),
                     // Beim Prüflauf für den Inhaltsfilter bleiben die Bilder
                     // weg: der Filter arbeitet auf Text, und die Base64-Form
                     // umsonst zu bauen kostet nur Speicher.
                     images: includeAttachments ? imageDataURLs(for: message) : [],
                     imageTokens: includeAttachments ? imageTokens(of: message) : 0)
        })
        // Letzte Instanz unmittelbar vor der Antwort.
        turns.append(ChatTurn(role: "system", content: ContentModeration.safetyReminder))
        return turns
    }

    private static func title(from text: String) -> String {
        let clean = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.count <= 42 { return clean }
        return String(clean.prefix(42)) + "…"
    }

    // MARK: - Anhänge

    /// Wie viele Tokens Anhänge bei diesem Modell höchstens belegen dürfen.
    ///
    /// Die Hälfte des Kontextfensters. Der Rest wird gebraucht: `buildTurns`
    /// gibt dem Verlauf 60 %, und die Antwort selbst braucht auch Platz. Wer
    /// ein Modell ohne gemeldete Kontextlänge benutzt, bekommt einen
    /// vorsichtigen Festwert.
    func attachmentTokenLimit(forModel modelID: String) -> Int {
        let contextLimit = model(id: modelID)?.contextLength ?? 0
        return contextLimit > 0 ? Int(Double(contextLimit) * 0.5) : 6_000
    }

    /// Summe der Anhänge, die im Chat gerade mitgeschickt werden.
    func activeAttachmentTokens(in conversation: Conversation) -> Int {
        // Von Hand geschleift statt `flatMap` + `filter`: diese Zahl wird bei
        // **jedem** Bildaufbau der Chat-Ansicht gebraucht, während einer
        // laufenden Antwort also rund zwanzigmal pro Sekunde. Die
        // Kettenschreibweise legte dabei jedes Mal zwei neue Arrays über
        // sämtliche Nachrichten an.
        var sum = 0
        for message in conversation.messages {
            for attachment in message.attachments where attachment.isActive {
                sum += attachment.tokenEstimate
            }
        }
        return sum
    }

    /// Schaltet einen Anhang für Folgefragen zu oder ab.
    func setAttachment(_ attachmentID: UUID, active: Bool) {
        for conversationIndex in conversations.indices {
            for messageIndex in conversations[conversationIndex].messages.indices {
                guard let attachmentIndex = conversations[conversationIndex]
                    .messages[messageIndex].attachments
                    .firstIndex(where: { $0.id == attachmentID }) else { continue }
                conversations[conversationIndex]
                    .messages[messageIndex]
                    .attachments[attachmentIndex].isActive = active
                scheduleSave()
                return
            }
        }
    }

    /// Der ausgelesene Text eines Anhangs – für die Vorschau in der Ansicht.
    func attachmentText(_ attachment: Attachment) -> String? {
        AttachmentStore.text(for: attachment.storedFileName)
    }

    // MARK: - Melden und Sperren (Richtlinie 1.2)

    func report(message: ChatMessage,
                in conversationID: UUID,
                reason: ContentReport.Reason,
                note: String) {
        let report = ContentReport(messageID: message.id,
                                   conversationID: conversationID,
                                   modelID: message.modelID,
                                   reason: reason,
                                   note: note,
                                   excerpt: String(message.text.prefix(500)))
        reports.insert(report, at: 0)

        if let ci = conversations.firstIndex(where: { $0.id == conversationID }),
           let mi = conversations[ci].messages.firstIndex(where: { $0.id == message.id }) {
            conversations[ci].messages[mi].isReported = true
        }
        // Meldungen sofort sichern, nicht erst nach der Entprellung: sie sind
        // der Nachweis, den Richtlinie 1.2 verlangt.
        saveNow()
    }

    func blockModel(_ modelID: String) {
        blockedModelIDs.insert(modelID)
        let replacement = availableModels.first?.id
        for index in conversations.indices where conversations[index].modelID == modelID {
            conversations[index].modelID = replacement ?? ""
        }
        // Auch die Vorgaben räumen, sonst bekommt jeder NEUE Chat wieder
        // genau das Modell, das der Nutzer gerade gesperrt hat.
        if settings.defaultModelID == modelID {
            settings.defaultModelID = replacement
        }
        for index in projects.indices where projects[index].defaultModelID == modelID {
            projects[index].defaultModelID = nil
        }
        scheduleSave()
    }

    func unblockModel(_ modelID: String) {
        blockedModelIDs.remove(modelID)
        scheduleSave()
    }

    func deleteReport(_ id: UUID) {
        reports.removeAll { $0.id == id }
        scheduleSave()
    }

    // MARK: - Datenlöschung

    /// Entfernt restlos alles: Chats, Projekte, Meldungen, Einstellungen,
    /// Zustimmungen und sämtliche Schlüssel aus der Keychain.
    func deleteAllData() {
        stopStreaming()
        saveTask?.cancel()
        saveTask = nil
        modelsTask?.cancel()
        modelsTask = nil

        projects = []
        conversations = []
        reports = []
        blockedModelIDs = []
        customPricing = [:]
        // Die Schlüssel selbst räumt `KeychainStore.removeAll()` weiter unten;
        // hier fällt die Liste weg, die auf sie zeigt.
        credentials = []
        credentialMasks = [:]
        settings = .default
        // `Loc` hängt nicht an SwiftUI und wird deshalb nicht automatisch
        // mit zurückgesetzt. Ohne diese Zeile spräche die Oberfläche wieder
        // Systemsprache, während Fehlermeldungen bis zum Neustart in der
        // vorherigen Sprache herauskämen – die Meldung direkt danach zuerst.
        Loc.language = settings.language

        models = []
        loadedModelsProviderID = nil
        isLoadingModels = false
        modelsError = nil
        consentRequest = nil
        supportNotice = nil
        alertMessage = nil
        revealedMessageIDs = []
        sessionCostUSD = 0
        sessionTokens = 0
        monthCostUSD = 0

        ImageStore.deleteAll()
        AttachmentStore.deleteAll()
        ImageMemory.shared.removeAll()
        ImageFileLoader.releaseFullSize()
        consent.reset()
        speech.stopSpeaking()
        speech.resetCosts()
        SpeechService.clearRecordings()
        ZipArchive.clearExports()
        let keychainCleared = KeychainStore.removeAll()
        UserDefaults.standard.removeObject(forKey: OpenAICompatibleProvider.customBaseURLKey)
        UserDefaults.standard.removeObject(forKey: OpenAICompatibleProvider.customNameKey)
        refreshKeyPresence()

        loadFailed = false
        skipOrphanCleanup = false
        projectTotals = [:]
        try? FileManager.default.removeItem(at: Self.fileURL)
        // Eine früher in Quarantäne gelegte Zustandsdatei enthält den
        // vollständigen Verlauf. Sie hier stehen zu lassen widerspräche der
        // Zusage „restlos entfernt" – und einer Auskunft nach DSGVO.
        let folder = Self.fileURL.deletingLastPathComponent()
        if let leftovers = try? FileManager.default.contentsOfDirectory(atPath: folder.path) {
            for name in leftovers where name.hasPrefix("byokey-state-defekt-") {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
        }

        let conversation = Conversation(modelID: "")
        conversations = [conversation]
        selectedConversationID = conversation.id
        selectedProjectID = nil
        // Der Aktor verwirft jeden älteren Schnappschuss, der noch unterwegs
        // ist – ohne diese Reihenfolge könnten gelöschte Chats zurückkehren.
        //
        // `discard` schliesst das letzte enge Fenster: ein bereits abgesetzter
        // Schreibvorgang mit dem vollen Nutzerzustand könnte sonst zwischen
        // dem Löschen der Datei und dem neuen, leeren Stand durchlaufen. Der
        // Endzustand wäre zwar richtig, aber ein Absturz genau dazwischen
        // hinterliesse Daten, die als restlos entfernt zugesagt sind.
        let barrier = writeGeneration
        // Höhere Priorität als die `.utility`-Schreibaufträge, damit dieser
        // Riegel eine Chance hat, vor ihnen beim Aktor anzukommen.
        Task.detached(priority: .high) { await StateWriter.shared.discard(upTo: barrier) }
        saveNow()

        // Nur behaupten, was auch passiert ist (Richtlinie 5.1.1).
        if !keychainCleared {
            alertMessage = Loc.tr("Chats, Projekte und Einstellungen wurden gelöscht. Mindestens ein API-Schlüssel ließ sich nicht aus der Keychain entfernen – bitte entsperre das Gerät und wiederhole den Vorgang.")
        }
    }

    // MARK: - Persistenz

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base.appendingPathComponent("byokey-state.json")
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Schreibt den aktuellen Stand.
    ///
    /// Alles läuft über `StateWriter`, einen Aktor. Der Grund ist nicht die
    /// Geschwindigkeit, sondern die **Reihenfolge**: zwei nebenläufige
    /// `Task.detached` haben keine, und der ältere Schnappschuss konnte den
    /// neueren überschreiben. Beim Löschen aller Daten war das der ernste Fall –
    /// ein noch laufender Schreibvorgang hätte gelöschte Chats zurückgebracht.
    func saveNow() {
        enqueueWrite()
    }

    /// Beim Wechsel in den Hintergrund.
    ///
    /// Vorher lief hier ein **synchroner** Schreibvorgang auf dem Hauptthread.
    /// Bei einem langen Verlauf sind das mehrere Megabyte Kodierarbeit plus
    /// ein atomarer Schreibvorgang – und `.inactive` feuert nicht nur beim
    /// echten Wechsel in den Hintergrund, sondern auch beim Kontrollzentrum,
    /// beim App-Umschalter und bei einem eingehenden Anruf. Jetzt schreibt der
    /// Aktor, und `beginBackgroundTask` hält den Prozess so lange am Leben.
    func saveBeforeSuspend() {
        guard let (snapshot, url, generation) = pendingWrite() else { return }
        // Der Ablauf-Handler ist Pflicht, nicht Zierde: läuft das Zeitfenster
        // ab, ohne dass die Aufgabe beendet wurde, beendet iOS die App hart.
        let box = BackgroundTaskBox()
        box.id = UIApplication.shared.beginBackgroundTask(withName: "byokey-zustand-sichern") {
            box.end()
        }
        Task.detached(priority: .userInitiated) {
            await StateWriter.shared.write(snapshot, to: url, generation: generation)
            await MainActor.run { box.end() }
        }
    }

    private func enqueueWrite() {
        guard let (snapshot, url, generation) = pendingWrite() else { return }
        Task.detached(priority: .utility) {
            await StateWriter.shared.write(snapshot, to: url, generation: generation)
        }
    }

    /// Der Schnappschuss entsteht auf dem MainActor: nie ein halb mutierter
    /// Zustand auf der Platte.
    private func pendingWrite() -> (PersistedState, URL, Int)? {
        // Nach einem gescheiterten **Lesen** nichts schreiben: der leere
        // Zustand würde die noch intakten Daten überschreiben.
        guard !loadFailed else { return nil }
        let snapshot = PersistedState(version: PersistedState.currentVersion,
                                      projects: projects,
                                      conversations: conversations,
                                      settings: settings,
                                      blockedModelIDs: Array(blockedModelIDs).sorted(),
                                      reports: reports,
                                      customPricing: customPricing,
                                      credentials: credentials,
                                      selectedConversationID: selectedConversationID,
                                      selectedProjectID: selectedProjectID)
        writeGeneration &+= 1
        return (snapshot, Self.fileURL, writeGeneration)
    }

    fileprivate nonisolated static func write(_ snapshot: PersistedState, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        // .completeUntilFirstUserAuthentication: weiterhin verschlüsselt auf
        // der Platte, aber nach dem ersten Entsperren lesbar. Mit
        // .completeFileProtection scheitert jeder Start im gesperrten Zustand.
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Zweiter Anlauf, wenn das Lesen beim Start scheiterte.
    ///
    /// Nach einem Lesefehler steht `loadFailed`, und `pendingWrite` verweigert
    /// daraufhin **jedes** Schreiben – zu Recht: die App darf nicht über
    /// Daten schreiben, die sie nicht gelesen hat. Ohne einen zweiten Anlauf
    /// bliebe damit aber die ganze Sitzung ungesichert, ohne dass der Nutzer
    /// es merkt. Der häufigste Grund ist ein Start vor der ersten Entsperrung;
    /// beim Zurückkehren in den Vordergrund ist das Gerät entsperrt.
    ///
    /// Läuft nur, solange **nichts** angelegt wurde: gäbe es schon Chats aus
    /// dieser Sitzung, überschriebe das Einlesen sie.
    func retryLoadIfNeeded() {
        guard loadFailed else { return }
        // `credentials` mit im Riegel: wer in der gescheiterten Sitzung einen
        // Schlüssel eingetragen hat, hat ihn in der Keychain – die Liste dazu
        // steht aber nur im Speicher, weil nichts geschrieben werden durfte.
        // Ein Einlesen überschriebe sie, und der Schlüssel bliebe als Waise
        // in der Keychain zurück.
        guard conversations.allSatisfy(\.isEmptyDraft), projects.isEmpty,
              reports.isEmpty, credentials.isEmpty else { return }
        loadFailed = false
        alertMessage = nil
        load()
        guard !loadFailed else { return }
        discardEmptyDrafts(keeping: selectedConversationID)
        if conversations.isEmpty { newConversation(inProject: nil) }
        refreshKeyPresence()
        recomputeMonthCost()
    }

    private func load() {
        let url = Self.fileURL
        // Erststart: keine Datei -> regulär leer weitermachen.
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // Datei da, aber nicht lesbar (Dateischutz bei gesperrtem Gerät,
            // I/O-Fehler). NICHT mit leerem Zustand weiterlaufen und
            // anschließend darüber schreiben.
            loadFailed = true
            alertMessage = Loc.tr("Die gespeicherten Daten konnten nicht gelesen werden. Bitte entsperre das Gerät und starte ByoKey neu. Es wurde nichts überschrieben.")
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let state = try decoder.decode(PersistedState.self, from: data)
            projects = state.projects
            conversations = state.conversations
            settings = state.settings
            blockedModelIDs = Set(state.blockedModelIDs)
            reports = state.reports
            customPricing = state.customPricing
            credentials = state.credentials
            // Genau dort weitermachen, wo der Nutzer aufgehört hat. `nil`
            // heisst Übersicht und wird deshalb ausdrücklich übernommen.
            selectedConversationID = state.selectedConversationID
            selectedProjectID = state.selectedProjectID
            hasStoredSelection = state.hasStoredSelection
        } catch {
            // Defekte Datei aufheben statt überschreiben – sie ist die
            // einzige Kopie der Nutzerdaten.
            let stamp = Int(Date().timeIntervalSince1970)
            let quarantine = url.deletingLastPathComponent()
                .appendingPathComponent("byokey-state-defekt-\(stamp).json")
            let rescued = (try? FileManager.default.moveItem(at: url, to: quarantine)) != nil
            // **Nicht** `loadFailed` setzen. Das sperrt jedes Speichern, und
            // hier ist die alte Datei bereits in Sicherheit – die App startet
            // leer und darf ab jetzt wieder schreiben. Täte sie es nicht,
            // wäre alles verloren, was der Nutzer nach diesem Start anlegt.
            //
            // Das Aufräumen der Bilder muss aber trotzdem aussetzen:
            // `conversations` ist leer, und `removeOrphans` löschte sonst
            // genau die Dateien, auf die die gerettete Zustandsdatei zeigt.
            skipOrphanCleanup = true
            loadFailed = !rescued
            alertMessage = rescued
                ? Loc.tr("Die gespeicherten Daten waren beschädigt. Eine Sicherung der defekten Datei wurde behalten; ByoKey startet leer.")
                : Loc.tr("Die gespeicherten Daten konnten nicht gelesen werden. Bitte entsperre das Gerät und starte ByoKey neu. Es wurde nichts überschrieben.")
        }
    }
}

/// Schreibt die Zustandsdatei – einer nach dem anderen, und niemals einen
/// veralteten Stand über einen neueren.
///
/// Ein Aktor statt einer Warteschlange, weil das Kodieren mehrerer Megabyte
/// nichts auf dem Hauptaktor zu suchen hat und die Reihenfolge trotzdem
/// garantiert sein muss.
actor StateWriter {
    static let shared = StateWriter()

    private var lastWritten = 0

    func write(_ snapshot: PersistedState, to url: URL, generation: Int) {
        guard generation > lastWritten else { return }
        lastWritten = generation
        AppState.write(snapshot, to: url)
    }

    /// Verwirft alles bis einschliesslich dieser Generation, ohne zu schreiben.
    /// Für „Alle Daten löschen": ein noch wartender Schnappschuss mit dem
    /// vollen Verlauf darf danach nicht mehr auf die Platte.
    func discard(upTo generation: Int) {
        lastWritten = max(lastWritten, generation)
    }
}

/// Hält die Kennung der Hintergrundaufgabe, damit Ablauf-Handler und
/// regulärer Abschluss dieselbe meinen und sie genau einmal beenden.
@MainActor
private final class BackgroundTaskBox {
    var id: UIBackgroundTaskIdentifier = .invalid

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
