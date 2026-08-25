//
//  SettingsView.swift
//  ByoKey
//
//  Einstellungen und zugleich die Stelle, an der die Store-Anforderungen
//  für den Nutzer sichtbar werden:
//    • Datenfreigabe je Anbieter widerrufbar   (Richtlinie 5.1.2(i))
//    • Inhaltsfilter, gesperrte Modelle, Meldungen (Richtlinie 1.2)
//    • Veröffentlichte Kontaktdaten            (Richtlinie 1.2)
//    • Vollständige Datenlöschung             (Richtlinie 5.1.1)
//

import SwiftUI
import AVFoundation

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var keyInput = ""
    /// Diese drei standen vorher direkt im Body.
    ///
    /// `Form` ist **ein** Body: jede Änderung an `app.settings` – jeder
    /// Tastendruck im Schlüsselfeld, jede Bewegung am Budget- oder
    /// Temperaturregler – wertete ihn neu aus. Dabei liefen
    /// `AVSpeechSynthesisVoice.speechVoices()` (auf einem Gerät mit
    /// nachgeladenen Stimmen mehrere hundert Objekte, dazu drei Sortier- und
    /// Filterdurchläufe) und zwei Filter über die gesamte Modell-Liste. Beim
    /// Ziehen eines Reglers waren das rund sechzig Durchläufe pro Sekunde –
    /// der auffälligste Ruckler der App.
    @State private var deviceVoices: [AVSpeechSynthesisVoice] = []
    @State private var transcriptionModels: [AIModel] = []
    @State private var speechModels: [AIModel] = []
    /// Steht das Eingabefeld für einen **weiteren** Schlüssel offen?
    @State private var isAddingKey = false
    /// Der Eintrag, für den gerade ein Name abgefragt wird.
    @State private var naming: NamingRequest?
    @State private var nameDraft = ""
    @State private var isTesting = false
    @State private var testResult: String?
    /// Ergebnis der Schlüsselprüfung. Der Zwischenwert ist wichtig: „Freigabe
    /// fehlt noch" ist **kein** Fehler, wurde aber mit rotem Warndreieck
    /// angezeigt – der Prüfer im App Review folgt der Anleitung, sieht Rot und
    /// liest das als „Schlüssel abgelehnt".
    enum TestOutcome { case success, pending, failure }
    @State private var testOutcome: TestOutcome = .failure
    @State private var showDeleteConfirm = false

    /// Der Anbieter, dessen Zustimmungsblatt gerade offen ist.
    ///
    /// **Eigener** Zustand und ein eigenes `.sheet` an dieser Ansicht – nicht
    /// `app.consentRequest`. Das hängt in `RootView` an derselben Ansicht, die
    /// auch dieses Blatt zeigt, und ein zweites Blatt vom selben Präsentierer
    /// erscheint nicht. Es käme also gar nichts.
    @State private var consentSheet: AppState.ConsentRequest?
    @State private var keyInfo: OpenRouterProvider.KeyInfo?
    @State private var keyInfoError: String?
    @State private var isLoadingKeyInfo = false
    /// Anlass für den Benennen-Dialog. `isNew` unterscheidet nur den Titel:
    /// direkt nach dem Prüfen „benennen", später „umbenennen".
    struct NamingRequest: Identifiable {
        let credentialID: UUID
        let isNew: Bool
        var id: UUID { credentialID }
    }

    private var provider: any AIProviderProtocol { app.activeProvider }

    var body: some View {
        @Bindable var app = app

        return NavigationStack {
            Form {
                Group {
                    languageSection
                    appearanceSection
                }
                providerSection
                // Zusammengefasst: ein Form nimmt höchstens zehn direkte
                // Kinder auf.
                Group {
                    keySection
                    storedKeysSection
                }
                // Zusammengefasst wie unten: ein Form nimmt höchstens zehn
                // direkte Kinder auf.
                Group {
                    consentSection
                    otherConsentSection
                }
                modelSection
                voiceSection
                costSection
                safetySection
                // Zusammengefasst, weil ein Form höchstens zehn direkte
                // Kinder aufnimmt – die elfte Section wäre ein Übersetzungs-
                // fehler, kein Laufzeitproblem.
                Group {
                    legalSection
                    dataSection
                    aboutSection
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            // Einmal beim Öffnen die Keychain befragen, nicht bei jedem
            // Bildaufbau. Das heilt zugleich den Fall, dass die App bei
            // gesperrtem Gerät gestartet ist: dann liess sich beim Start
            // kein Schlüssel lesen, und die Liste sähe leer aus.
            .task { app.refreshKeyPresence() }
            // Neu berechnen, wenn sich die Grundlage ändert – nicht bei jedem
            // Bildaufbau.
            .task(id: app.settings.voiceLanguage) {
                deviceVoices = SpeechService.deviceVoices(language: app.settings.voiceLanguage)
            }
            .task(id: app.models.map(\.id)) {
                transcriptionModels = app.models.filter(\.isTranscriptionModel)
                speechModels = app.models.filter(\.isSpeechModel)
            }
            // Beide Literale: bei gemischten Typen fiele der Ausdruck auf
            // `String` zurück und der Titel bliebe in jeder Sprache deutsch.
            .alert(naming?.isNew == true ? "Schlüssel benennen" : "Schlüssel umbenennen",
                   isPresented: namingBinding) {
                TextField("Name", text: $nameDraft)
                    .textInputAutocapitalization(.words)
                Button("Sichern") {
                    if let request = naming {
                        app.renameCredential(request.credentialID, to: nameDraft)
                    }
                    naming = nil
                }
                Button("Abbrechen", role: .cancel) { naming = nil }
            } message: {
                Text("Ein eigener Name hilft, wenn du mehrere Schlüssel desselben Anbieters benutzt – etwa „Arbeit“ und „Privat“.")
            }
            .sheet(item: $consentSheet) { request in
                ConsentView(providerID: request.providerID, scope: request.scope)
            }
            // Auch beim Wegwischen sichern.
            //
            // Bisher schrieb nur „Fertig". Alles über `$app.settings.…`
            // Gebundene – Temperatur, maximale Antwortlänge, Budget, Währung,
            // strenger Filter, sämtliche Sprachmodus-Einstellungen – blieb
            // beim Herunterwischen nur im Speicher stehen.
            .onDisappear { app.saveNow() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") {
                        app.saveNow()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .confirmationDialog("Wirklich alle Daten löschen?",
                                isPresented: $showDeleteConfirm,
                                titleVisibility: .visible) {
                Button("Alles unwiderruflich löschen", role: .destructive) {
                    app.deleteAllData()
                    keyInput = ""
                    isAddingKey = false
                    testResult = nil
                    keyInfo = nil
                    keyInfoError = nil
                }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text("Chats, Projekte, Meldungen, Einstellungen, erteilte Freigaben und alle API-Schlüssel werden von diesem Gerät entfernt.")
            }
        }
    }

    // MARK: - Sprache der Oberfläche

    private var languageSection: some View {
        @Bindable var app = app

        return Section {
            Picker("Sprache", selection: $app.settings.language) {
                // „Systemsprache" wird übersetzt, die anderen bewusst nicht:
                // „Deutsch" muss auch auf einer polnischen Oberfläche als
                // „Deutsch" dastehen, sonst findet es niemand zurück.
                Text("Systemsprache").tag(AppLanguage.system)
                ForEach(AppLanguage.allCases.filter { $0 != .system }) { language in
                    Text(verbatim: language.nativeName).tag(language)
                }
            }
            .onChange(of: app.settings.language) { _, new in
                Loc.language = new
                app.saveNow()
            }
        } header: {
            Text("Sprache")
        } footer: {
            Text("Gilt sofort und nur für ByoKey. Die Sprache, in der die KI antwortet, steuerst du im Chat oder über den Projekt-Prompt – sie hat mit dieser Einstellung nichts zu tun.")
        }
    }

    // MARK: - Darstellung

    private var appearanceSection: some View {
        @Bindable var app = app

        return Section {
            Picker("Pfeil nach unten", selection: $app.settings.scrollButtonPosition) {
                ForEach(ScrollButtonPosition.allCases) { position in
                    Text(LocalizedStringKey(position.label)).tag(position)
                }
            }
            .onChange(of: app.settings.scrollButtonPosition) { _, _ in
                app.scheduleSave()
            }
        } header: {
            Text("Darstellung")
        } footer: {
            Text("Der Knopf, der im Verlauf ans Ende springt. Er erscheint nur, wenn du weiter oben liest. Wer das Gerät links hält, erreicht ihn links bequemer.")
        }
    }

    // MARK: - Anbieter

    private var providerSection: some View {
        @Bindable var app = app

        return Section {
            Picker("Anbieter", selection: $app.settings.activeProviderID) {
                ForEach(ProviderRegistry.all, id: \.id) { item in
                    Text(item.displayName).tag(item.id)
                }
            }
            .onChange(of: app.settings.activeProviderID) { _, _ in
                keyInput = ""
                // Ohne dieses Zurücksetzen zeigt der Abschnitt ein leeres
                // Eingabefeld, obwohl für den neuen Anbieter ein Schlüssel
                // hinterlegt ist.
                isAddingKey = false
                testResult = nil
                testOutcome = .failure
                keyInfo = nil
                keyInfoError = nil
                app.models = []
                // Modellkennungen unterscheiden sich je Anbieter: OpenRouter
                // führt das Präfix, die direkte OpenAI-Schnittstelle nicht.
                let audio = AppSettings.defaultAudioModels(for: app.settings.activeProviderID)
                app.settings.sttModelID = audio.stt
                app.settings.ttsModelID = audio.tts
                Task { await app.refreshModels(force: true) }
            }
        } header: {
            Text("KI-Anbieter")
        } footer: {
            Text("ByoKey spricht die offizielle Schnittstelle des Anbieters direkt an. Es gibt keinen Zwischenserver von ByoKey.")
        }
    }

    // MARK: - Schlüssel

    /// Die Schlüssel des **aktiven** Anbieters.
    ///
    /// Mehrere sind ausdrücklich vorgesehen: einer für die Arbeit, einer
    /// privat, einer mit Ausgabengrenze zum Ausprobieren. Angetippt wird der
    /// benutzte gewechselt; welcher das ist, zeigt der Haken.
    private var keySection: some View {
        let mine = app.credentials(for: provider.id)

        return Section {
            ForEach(mine) { credential in
                credentialRow(credential)
            }

            if mine.isEmpty || isAddingKey {
                SecureField(LocalizedStringKey(provider.keyPlaceholder), text: $keyInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote.monospaced())

                Button("Sichern und prüfen") {
                    saveAndTest()
                }
                .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTesting)

                if !mine.isEmpty {
                    Button("Abbrechen", role: .cancel) {
                        isAddingKey = false
                        keyInput = ""
                    }
                }
            } else {
                Button {
                    keyInput = ""
                    testResult = nil
                    isAddingKey = true
                } label: {
                    Label("Weiteren Schlüssel hinzufügen", systemImage: "plus.circle")
                }
            }

            if isTesting {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Verbindung wird geprüft …")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            if let testResult {
                // `Text(verbatim:)`: der Text ist an jeder Zuweisungsstelle
                // schon übersetzt. Ein zweites Nachschlagen fände nichts und
                // könnte im schlimmsten Fall auf einen gleichlautenden
                // deutschen Schlüssel treffen.
                Label {
                    Text(verbatim: testResult)
                } icon: {
                    Image(systemName: testIcon)
                }
                .font(.footnote)
                .foregroundStyle(testTint)
            }

        } header: {
            Text("API-Schlüssel")
        } footer: {
            Text("Schlüssel liegen in der iOS-Keychain (nur dieses Gerät, kein iCloud-Abgleich) und werden ausschließlich zur Anmeldung an \(provider.apiHost) verwendet. ByoKey sendet sie an keinen anderen Empfänger. Mehrere Schlüssel je Anbieter sind möglich – benutzt wird der mit dem Haken.")
        }
    }

    /// Eine Zeile der Schlüsselliste.
    ///
    /// Der Schlüssel selbst steht nie hier: gezeigt wird die verkürzte Form
    /// aus `AppState.credentialMasks`, die einmal beim Auffrischen aus der
    /// Keychain gebildet wurde. Fehlt sie, liess sich der Eintrag nicht lesen –
    /// das sagt die Zeile dann auch, statt einen Schlüssel vorzutäuschen.
    @ViewBuilder
    private func credentialRow(_ credential: APICredential) -> some View {
        let isActive = app.activeCredential(for: credential.providerID)?.id == credential.id

        Button {
            guard !isActive else { return }
            app.activateCredential(credential.id)
            testResult = nil
            keyInfo = nil
            keyInfoError = nil
            Task { await app.refreshModels(force: true) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(isActive ? Theme.accent : Theme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: credential.name)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                    Group {
                        if let mask = app.credentialMasks[credential.id] {
                            Text(verbatim: mask)
                                .font(.caption.monospaced())
                        } else {
                            Text("Nicht auffindbar – Gerät entsperren oder Schlüssel neu eintragen")
                                .font(.caption)
                        }
                    }
                    .foregroundStyle(Theme.textSecondary)
                    if let verified = credential.lastVerifiedAt {
                        Text(verbatim: Loc.tr("Verbindung geprüft am %@",
                                              verified.formatted(date: .abbreviated, time: .shortened)))
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Loc.tr("Schlüssel %@", credential.name))
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                removeCredential(credential)
            } label: {
                Label("Entfernen", systemImage: "trash")
            }
            Button {
                startNaming(credential, isNew: false)
            } label: {
                Label("Umbenennen", systemImage: "pencil")
            }
            .tint(Theme.accent)
        }
        .contextMenu {
            Button {
                startNaming(credential, isNew: false)
            } label: {
                Label("Umbenennen", systemImage: "pencil")
            }
            Button {
                // Ohne Benennen-Dialog: wer hier prüft, hat den Eintrag schon.
                Task { await test(credential) }
            } label: {
                Label("Verbindung prüfen", systemImage: "antenna.radiowaves.left.and.right")
            }
            // Sonst verschluckt der Riegel in `test` den zweiten Auftrag
            // wortlos, und der Nutzer hält das Ergebnis des ersten für seines.
            .disabled(isTesting)
            Button(role: .destructive) {
                removeCredential(credential)
            } label: {
                Label("Entfernen", systemImage: "trash")
            }
        }
    }

    /// Übersicht über die Schlüssel **anderer** Anbieter.
    ///
    /// Wer nur einen Anbieter benutzt, bekommt diesen Abschnitt nie zu sehen –
    /// dort stünde bloss noch einmal, was oben schon steht. Wer mehrere
    /// benutzt, sieht auf einen Blick, was schon hinterlegt ist, und wechselt
    /// mit einem Tippen dorthin.
    @ViewBuilder
    private var storedKeysSection: some View {
        let others = app.providersWithStoredKey.filter { $0.id != provider.id }
        if !others.isEmpty {
            Section {
                ForEach(others, id: \.id) { item in
                    Button {
                        app.settings.activeProviderID = item.id
                        app.scheduleSave()
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: item.displayName)
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textPrimary)
                                Text(verbatim: app.credentials(for: item.id)
                                        .map(\.name)
                                        .joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Weitere hinterlegte Schlüssel")
            } footer: {
                Text("Tippe auf einen Anbieter, um zu ihm zu wechseln. Seine Schlüssel stehen dann oben und lassen sich dort benennen, prüfen oder entfernen.")
            }
        }
    }

    // MARK: - Datenfreigabe (Richtlinie 5.1.2(i))

    /// Nur der **aktive** Anbieter.
    ///
    /// Vorher standen hier alle neun untereinander. Wer OpenRouter eingerichtet
    /// hatte, sah darunter Mistral, DeepSeek, xAI und den Rest – und musste
    /// raten, ob er die auch freigeben soll. Das ist nicht nur unübersichtlich,
    /// es ist irreführend: an einen Anbieter, den man nicht benutzt, geht
    /// ohnehin nichts.
    private var consentSection: some View {
        Section {
            consentRow(for: provider)
        } header: {
            Text("Datenfreigabe an KI-Anbieter")
        } footer: {
            Text("Ohne Freigabe sendet ByoKey nichts an \(provider.displayName) – weder Nachrichten noch die Modell-Liste. Ein Widerruf wirkt sofort. Wechselst du oben den Anbieter, erscheint hier dessen Freigabe.")
        }
    }

    /// Anbieter, die nicht der aktive sind, aber eine erteilte Freigabe oder
    /// einen hinterlegten Schlüssel haben.
    ///
    /// Sie **müssen** sichtbar bleiben: eine erteilte Zustimmung muss jederzeit
    /// widerrufbar sein (Richtlinie 5.1.2(i)), und wer einen Schlüssel
    /// hinterlegt hat, soll das auch sehen. Wer nur einen Anbieter benutzt,
    /// bekommt diesen Abschnitt nie zu Gesicht.
    private var otherProviders: [any AIProviderProtocol] {
        ProviderRegistry.all.filter { item in
            guard item.id != provider.id else { return false }
            return app.consent.hasConsent(for: item.id)
                || app.consent.hasConsent(for: item.id, scope: .audio)
                || app.providersWithKey.contains(item.id)
        }
    }

    @ViewBuilder
    private var otherConsentSection: some View {
        let others = otherProviders
        if !others.isEmpty {
            Section {
                ForEach(others, id: \.id) { item in
                    consentRow(for: item)
                }
            } header: {
                Text("Weitere Anbieter")
            } footer: {
                Text("Diese Anbieter hast du bereits eingerichtet oder freigegeben. Sie stehen hier, damit du die Freigabe jederzeit zurücknehmen kannst – auch ohne den Anbieter zu wechseln.")
            }
        }
    }

    private func consentRow(for item: any AIProviderProtocol) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: consentBinding(for: item.id)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: item.displayName)
                        .font(.subheadline.weight(.medium))
                    Text("Empfänger: \(Loc.tr(item.legalEntity))")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            // Die Sprachfreigabe hat ihren eigenen Schalter im Sprachmodus –
            // aber der steht hinter drei Bedingungen: Sprachmodus an, Modus
            // „Über den Anbieter", und der Anbieter muss der aktive sein.
            // Wer eine Sprachfreigabe erteilt und danach eine dieser drei
            // Bedingungen ändert, käme sonst nicht mehr an sie heran, während
            // sie im Hintergrund weiter gilt. Deshalb hier ein zweiter Weg,
            // und zwar genau dann, wenn es etwas zurückzunehmen gibt.
            if app.consent.hasConsent(for: item.id, scope: .audio) {
                Toggle(isOn: audioConsentBinding(for: item.id)) {
                    Text("Sprachaufnahmen an \(item.displayName) senden")
                        .font(.footnote)
                }
            }

            if let date = consentDate(for: item.id) {
                // `Date.FormatStyle(...)` und nicht `formatted(date:time:)`: die
                // Kurzform kennt kein `locale:`-Argument, und ohne eines folgt
                // das Datum der **System**sprache statt der in ByoKey
                // eingestellten.
                Text("Freigegeben am \(date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: app.settings.language.locale)))")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }

            // Auch **nach** der Freigabe erreichbar. Die Aufzählung dessen,
            // was das Gerät verlässt, ist keine einmalige Hürde beim
            // Einschalten, sondern eine Auskunft, die jederzeit nachlesbar
            // sein muss – so steht es auch in den Notizen für die Prüfung.
            Button("Was gesendet wird ansehen") {
                consentSheet = AppState.ConsentRequest(providerID: item.id)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Theme.accent)
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    /// Frühester Zeitpunkt einer erteilten Freigabe – Text oder Sprache.
    /// Nur den Text-Datensatz zu prüfen hiesse: ein Anbieter, der allein wegen
    /// der Sprachfreigabe hier steht, sähe aus wie ein leerer Eintrag.
    private func consentDate(for providerID: String) -> Date? {
        [ConsentScope.text, .audio]
            .compactMap { scope -> Date? in
                guard let record = app.consent.record(for: providerID, scope: scope),
                      record.granted else { return nil }
                return record.grantedAt
            }
            .min()
    }

    /// Der Schalter **erteilt** die Freigabe nicht – er führt zu ihr.
    ///
    /// Richtlinie 5.1.2(i) verlangt eine Zustimmung, die weiss, wozu sie
    /// gegeben wird: Empfänger namentlich, Datenarten einzeln, Zweck, Link auf
    /// die Datenschutzerklärung des Anbieters. Das alles steht in
    /// `ConsentView`. Ein Schalter, der die Freigabe im Vorbeigehen setzt,
    /// führt daran vorbei – und genau diesen Weg beschreiben die Notizen für
    /// die Prüfung: Freigabe einschalten, Schlüssel eintragen, senden. Der
    /// Prüfer bekäme den Bildschirm nie zu sehen, an dem die ganze Zusage
    /// hängt.
    ///
    /// **Ausschalten** geht weiterhin sofort. Ein Widerruf braucht keine
    /// Belehrung, und ihn zu verzögern wäre das Gegenteil von dem, was die
    /// Richtlinie will.
    private func consentBinding(for providerID: String) -> Binding<Bool> {
        Binding(
            get: { app.consent.hasConsent(for: providerID) },
            set: { granted in
                if granted {
                    consentSheet = AppState.ConsentRequest(providerID: providerID)
                } else {
                    // Über setConsent: der Widerruf muss einen laufenden
                    // Stream stoppen und die Modell-Liste leeren.
                    app.setConsent(false, for: providerID)
                }
            }
        )
    }

    // MARK: - Modell

    private var modelSection: some View {
        @Bindable var app = app

        return Section {
            LabeledContent("Standardmodell") {
                Text(app.settings.defaultModelID.map { app.model(id: $0)?.name ?? $0 } ?? "–")
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            VStack(alignment: .leading) {
                HStack {
                    Text("Temperatur")
                    Spacer()
                    Text(String(format: "%.1f", app.settings.temperature))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                }
                Slider(value: $app.settings.temperature, in: 0...2, step: 0.1)
            }

            Stepper(value: $app.settings.maxTokens, in: 256...16_384, step: 256) {
                HStack {
                    Text("Max. Antwortlänge")
                    Spacer()
                    Text("\(app.settings.maxTokens) Tokens")
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        } header: {
            Text("Modell und Antworten")
        } footer: {
            Text("Eine kürzere Antwortlänge begrenzt die Kosten pro Anfrage zuverlässiger als jede Schätzung.")
        }
    }


    // MARK: - Sprachmodus

    private var voiceSection: some View {
        @Bindable var app = app

        return Section {
            Toggle("Sprachmodus", isOn: $app.settings.voiceEnabled)

            if app.settings.voiceEnabled {
                Picker("Sprache und Stimme über", selection: $app.settings.voiceEngine) {
                    ForEach(VoiceEngine.allCases) { engine in
                        Text(LocalizedStringKey(engine.label)).tag(engine)
                    }
                }

                Picker("Sprache", selection: $app.settings.voiceLanguage) {
                    ForEach(Self.voiceLanguages) { language in
                        Text(LocalizedStringKey(language.label)).tag(language.id)
                    }
                }

                if app.settings.voiceEngine == .device {
                    deviceVoiceRows
                } else {
                    providerVoiceRows
                }

                Toggle("Antworten vorlesen", isOn: $app.settings.speakAnswers)
                Toggle("Gesprächsmodus", isOn: $app.settings.handsFree)

                NavigationLink {
                    VoiceInfoView()
                } label: {
                    Label("Welche Modelle können sprechen?", systemImage: "info.circle")
                }
            }
        } header: {
            Text("Sprachmodus")
        } footer: {
            Text(app.settings.voiceEngine == .device
                 ? "Auf dem Gerät: funktioniert mit jedem Chat-Modell, kostet nichts zusätzlich, und die Aufnahme verlässt dein iPhone nicht."
                 : "Über den Anbieter: bessere Stimmen, aber die Aufnahme wird übertragen und kostet nach Anbieterpreis. Es braucht Modelle, die Audio können – ein Chat-Modell allein genügt nicht.")
        }
    }

    @ViewBuilder
    private var deviceVoiceRows: some View {
        @Bindable var app = app

        let onDevice = app.speech.supportsOnDeviceRecognition(language: app.settings.voiceLanguage)

        NavigationLink {
            VoicePickerView(language: app.settings.voiceLanguage,
                            selection: $app.settings.deviceVoiceID)
        } label: {
            LabeledContent("Stimme") {
                Text(Self.voiceName(for: app.settings.deviceVoiceID, in: deviceVoices))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }

        HStack(spacing: 8) {
            Image(systemName: onDevice ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(onDevice ? Theme.success : Theme.warning)
            Text(onDevice
                 ? "Erkennung läuft vollständig auf dem Gerät."
                 : "Für diese Sprache gibt es keine Erkennung auf dem Gerät.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if !onDevice {
            // Ohne Erkennung auf dem Gerät ginge die Aufnahme an Apple.
            // Das ist eine Weitergabe an Dritte und braucht eine bewusste
            // Entscheidung (Richtlinie 5.1.2(i)).
            Toggle(isOn: $app.settings.allowServerSpeechRecognition) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apples Server-Erkennung erlauben")
                    Text("Die Aufnahme wird dann zur Erkennung an Apple übertragen.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    /// Beschriftung der Zeile: der gespeicherte Wert ist eine Kennung wie
    /// „com.apple.voice.premium.de-DE.Anna" – die will niemand lesen.
    @MainActor
    private static func voiceName(for identifier: String,
                                  in voices: [AVSpeechSynthesisVoice]) -> String {
        guard !identifier.isEmpty else { return Loc.tr("Systemstandard") }
        guard let voice = voices.first(where: { $0.identifier == identifier }) else {
            // Stimme wurde in den iOS-Einstellungen wieder entfernt.
            return Loc.tr("Nicht mehr vorhanden")
        }
        // Der Stimmenname ist ein Eigenname und bleibt; nur der Zusatz
        // dahinter ist ein Wort und wird übersetzt.
        switch voice.quality {
        case .premium:  return "\(voice.name) · \(Loc.tr("Premium"))"
        case .enhanced: return "\(voice.name) · \(Loc.tr("Erweitert"))"
        default:        return voice.name
        }
    }

    @ViewBuilder
    private var providerVoiceRows: some View {
        @Bindable var app = app

        if !provider.supportsAudio {
            Label("\(provider.displayName) bietet keine Sprach-Endpunkte. Stelle auf „Auf dem Gerät“ um.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(Theme.warning)
        } else {
            Toggle(isOn: audioConsentBinding(for: provider.id)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sprachaufnahmen an \(provider.displayName) senden")
                    Text("Eigene Freigabe – unabhängig von der für Text.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            modelRow(title: "Erkennungsmodell",
                     placeholder: "openai/whisper-1",
                     candidates: transcriptionModels,
                     selection: $app.settings.sttModelID)

            modelRow(title: "Vorlesemodell",
                     placeholder: "openai/gpt-4o-mini-tts",
                     candidates: speechModels,
                     selection: $app.settings.ttsModelID)

            HStack {
                Text("Stimme")
                Spacer()
                TextField("alloy", text: $app.settings.ttsVoice)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(maxWidth: 160)
            }

            Text("Die Kosten für das Vorlesen meldet der Anbieter nicht zurück; sie erscheinen nur auf seiner Abrechnung. Die Erkennung wird mitgerechnet, sofern der Anbieter sie ausweist.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    /// Auswahl aus der geladenen Liste, mit Eingabefeld als Rückfallebene.
    /// Nicht jeder Anbieter meldet die Modalitäten seiner Modelle – dann
    /// bleibt nur die Kennung von Hand.
    @ViewBuilder
    private func modelRow(title: LocalizedStringKey,
                          placeholder: String,
                          candidates: [AIModel],
                          selection: Binding<String>) -> some View {
        if candidates.isEmpty {
            HStack {
                Text(title)
                Spacer()
                TextField(placeholder, text: selection)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote.monospaced())
                    .frame(maxWidth: 200)
            }
        } else {
            Picker(title, selection: selection) {
                // Eine von Hand eingetragene Kennung steht nicht in der Liste.
                // Ohne diesen Eintrag träfe die Auswahl auf kein `tag`, der
                // Picker stünde leer – und der Wert wäre nicht mehr sichtbar,
                // würde aber weiter für Anfragen benutzt.
                if !selection.wrappedValue.isEmpty,
                   !candidates.contains(where: { $0.id == selection.wrappedValue }) {
                    Text(verbatim: selection.wrappedValue).tag(selection.wrappedValue)
                }
                ForEach(candidates) { model in
                    Text(model.name).tag(model.id)
                }
            }
        }
    }

    /// Wie beim Text: Einschalten führt ins Zustimmungsblatt, Ausschalten
    /// wirkt sofort. Für die Sprachaufnahme gilt Richtlinie 5.1.2(i) genauso –
    /// und die Aufnahme der eigenen Stimme ist eine eigene Datenart mit einer
    /// eigenen Aufzählung.
    private func audioConsentBinding(for providerID: String) -> Binding<Bool> {
        Binding(
            get: { app.consent.hasConsent(for: providerID, scope: .audio) },
            set: { granted in
                if granted {
                    consentSheet = AppState.ConsentRequest(providerID: providerID, scope: .audio)
                } else {
                    app.setConsent(false, for: providerID, scope: .audio)
                }
            }
        )
    }

    /// Kein Tupel-Array. `ForEach(..., id: \.0)` übersetzt zwar – KeyPaths auf
    /// Tupelelemente gibt es seit Swift 5 –, aber ein benannter Typ macht an der
    /// Verwendungsstelle sofort klar, was Kennung und was Beschriftung ist.
    private struct VoiceLanguage: Identifiable, Hashable {
        /// BCP-47-Kennung, zugleich der gespeicherte Wert.
        let id: String
        let label: String
    }

    private static let voiceLanguages: [VoiceLanguage] = [
        VoiceLanguage(id: "de-DE", label: "Deutsch"),
        VoiceLanguage(id: "en-US", label: "Englisch (USA)"),
        VoiceLanguage(id: "en-GB", label: "Englisch (UK)"),
        VoiceLanguage(id: "fr-FR", label: "Französisch"),
        VoiceLanguage(id: "es-ES", label: "Spanisch"),
        VoiceLanguage(id: "it-IT", label: "Italienisch"),
        VoiceLanguage(id: "nl-NL", label: "Niederländisch"),
        VoiceLanguage(id: "pl-PL", label: "Polnisch"),
        VoiceLanguage(id: "pt-BR", label: "Portugiesisch (BR)"),
        VoiceLanguage(id: "tr-TR", label: "Türkisch")
    ]

    // MARK: - Kosten

    private var costSection: some View {
        @Bindable var app = app

        return Section {
            Toggle("Kosten unter jeder Antwort", isOn: $app.settings.showCostPerMessage)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Monatsbudget")
                    Spacer()
                    Text(CostFormat.usd(app.settings.monthlyBudgetUSD))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                }
                Slider(value: $app.settings.monthlyBudgetUSD, in: 1...200, step: 1)
                BudgetBar(spentUSD: app.monthCostUSD, budgetUSD: app.settings.monthlyBudgetUSD)
            }
            .padding(.vertical, 2)

            LabeledContent("Diese Sitzung") {
                amount(Loc.tr("%@ Tokens · %@",
                              CostFormat.tokens(app.sessionTokens),
                              CostFormat.usd(app.sessionCostUSD)))
            }

            if provider.id == OpenRouterProvider.identifier {
                Button {
                    Task { await loadKeyInfo() }
                } label: {
                    HStack {
                        Text("Verbrauch beim Anbieter abfragen")
                        Spacer()
                        if isLoadingKeyInfo { ProgressView() }
                    }
                }
                .disabled(!app.hasAPIKey || !app.hasConsentForActiveProvider || isLoadingKeyInfo)

                // Das Ergebnis stand früher im Abschnitt „API-Schlüssel"
                // weiter oben – auf dem iPhone also außerhalb des Bildes.
                // Der Knopf wirkte dadurch wirkungslos. Antwort und Auslöser
                // gehören zusammen.
                // Jede Zeile ist ein eigenes Kind der Section, nicht in einen
                // VStack gepackt. In einem Form richtet nur die oberste Ebene
                // Beschriftung und Wert am selben Raster aus – verschachtelt
                // stand der Block sichtbar schief neben „Diese Sitzung“.
                if let keyInfo {
                    if let balance = keyInfo.accountBalanceUSD {
                        LabeledContent("Guthaben auf dem Konto") {
                            amount(CostFormat.usd(balance),
                                   tint: balance <= 0 ? Theme.danger : Theme.success)
                        }
                    }
                    LabeledContent("Mit diesem Schlüssel verbraucht") {
                        amount(CostFormat.usd(keyInfo.usageUSD))
                    }
                    if let remaining = keyInfo.remainingUSD {
                        LabeledContent("Rest bis zur Schlüsselgrenze") {
                            amount(CostFormat.usd(remaining))
                        }
                    }
                    Text(LocalizedStringKey(keyInfoHint(for: keyInfo)))
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let keyInfoError {
                    Label(LocalizedStringKey(keyInfoError), systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !app.hasAPIKey || !app.hasConsentForActiveProvider {
                    Text(app.hasAPIKey
                         ? "Dafür fehlt noch die Datenfreigabe für \(provider.displayName)."
                         : "Dafür muss zuerst ein API-Schlüssel hinterlegt sein.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        } header: {
            Text("Kosten")
        } footer: {
            Text("Die Anzeige beruht auf den Angaben des Anbieters. Maßgeblich ist immer dessen Abrechnung. Beträge mit „ca.“ sind lokal geschätzt, weil der Anbieter keinen Verbrauch gemeldet hat.")
        }
    }

    /// Betrag am rechten Rand: gleiche Zeichenbreite wie in allen anderen
    /// Zeilen, einzeilig, und bei Bedarf lieber etwas kleiner als umgebrochen.
    /// Ein Umbruch schiebt die Zeile in der Höhe und lässt den ganzen Block
    /// verrutscht aussehen.
    private func amount(_ text: String, tint: Color = Theme.textSecondary) -> some View {
        Text(text)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundStyle(tint)
    }

    /// Erklärt die Zahlen, statt den Nutzer raten zu lassen, warum bei einem
    /// frisch aufgeladenen Konto „kein Limit" steht.
    private func keyInfoHint(for info: OpenRouterProvider.KeyInfo) -> String {
        if info.accountBalanceUSD == nil {
            return info.limitUSD == nil
                ? "Für diesen Schlüssel ist keine eigene Ausgabengrenze gesetzt; das Kontoguthaben konnte der Schlüssel nicht abfragen."
                : "Das Kontoguthaben konnte dieser Schlüssel nicht abfragen – nur seine eigene Grenze."
        }
        if info.limitUSD == nil {
            return "Für diesen Schlüssel ist keine eigene Ausgabengrenze gesetzt – er kann das gesamte Kontoguthaben verbrauchen."
        }
        return "Die Schlüsselgrenze wirkt zusätzlich zum Kontoguthaben; maßgeblich ist der kleinere der beiden Werte."
    }

    // MARK: - Sicherheit und Inhalte (Richtlinie 1.2)

    private var safetySection: some View {
        @Bindable var app = app

        return Section {
            Toggle("Strenger Inhaltsfilter", isOn: $app.settings.strictFilter)

            NavigationLink {
                ReportsListView()
            } label: {
                HStack {
                    Text("Meldungen")
                    Spacer()
                    Text("\(app.reports.count)")
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            NavigationLink {
                BlockedModelsView()
            } label: {
                HStack {
                    Text("Gesperrte Modelle")
                    Spacer()
                    Text("\(app.blockedModelIDs.count)")
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        } header: {
            Text("Sicherheit und Inhalte")
        } footer: {
            Text("Der Grundschutz gegen klar unzulässige Inhalte lässt sich nicht abschalten. Der strenge Modus markiert zusätzlich Grenzfälle und blendet sie erst nach Nachfrage ein.")
        }
    }

    // MARK: - Rechtliches und Kontakt (Richtlinie 1.2)

    private var legalSection: some View {
        Section {
            if let url = AppInfo.privacyPolicyURL {
                Link("Datenschutzerklärung", destination: url)
            }
            if let url = AppInfo.termsURL {
                Link("Nutzungsbedingungen", destination: url)
            }
            if let url = AppInfo.appleEULAURL {
                Link("Lizenzvereinbarung (EULA)", destination: url)
            }
            Button {
                if let url = AppInfo.reportMailURL(
                    subject: "ByoKey – Anfrage",
                    body: "\n\n---\nApp-Version: \(AppInfo.version)"
                ) {
                    openURL(url)
                }
            } label: {
                LabeledContent("Support", value: AppInfo.supportEmail)
            }
        } header: {
            Text("Rechtliches und Kontakt")
        } footer: {
            Text("Meldungen und Anfragen beantworten wir unter der angegebenen Adresse.")
        }
    }

    // MARK: - Daten

    private var dataSection: some View {
        Section {
            Button("Alle Daten löschen", role: .destructive) {
                showDeleteConfirm = true
            }
        } header: {
            Text("Daten")
        } footer: {
            Text("Es gibt kein Nutzerkonto und keinen Server: Alles liegt auf diesem Gerät und ist mit einem Tippen restlos entfernt.")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: AppInfo.version)
            LabeledContent("Gespeicherte Chats", value: "\(app.conversations.count)")
            LabeledContent("Projekte", value: "\(app.projects.count)")
        }
    }

    // MARK: - Aktionen

    private var testIcon: String {
        switch testOutcome {
        case .success: return "checkmark.circle.fill"
        case .pending: return "info.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        }
    }

    private var testTint: Color {
        switch testOutcome {
        case .success: return Theme.success
        case .pending: return Theme.textSecondary
        case .failure: return Theme.danger
        }
    }

    private func saveAndTest() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        // Anbieter EINMAL festhalten: `provider` wird aus dem aktiven Anbieter
        // berechnet. Ändert der sich zwischen Speichern und Prüfen, ginge der
        // Schlüssel von Anbieter A an den Endpunkt von Anbieter B.
        let target = app.activeProvider

        switch app.addCredential(key: key, providerID: target.id) {
        case .failed:
            testOutcome = .failure
            testResult = Loc.tr("Der Schlüssel konnte nicht gesichert werden. Bitte erneut versuchen.")

        case .duplicate(let existing):
            // Kein Fehler, aber auch kein zweiter Zugang: zwei Zeilen mit
            // demselben Schlüssel wären nicht auseinanderzuhalten.
            testOutcome = .pending
            testResult = Loc.tr("Diesen Schlüssel gibt es schon – hinterlegt als „%@“.", existing.name)
            keyInput = ""
            isAddingKey = false

        case .added(let credential):
            keyInput = ""
            isAddingKey = false
            Task { await test(credential, isNew: true) }
        }
    }

    /// Prüft die Verbindung mit einem bestimmten Eintrag.
    ///
    /// Nach dem Prüfen fragt die App nach einem Namen. Genau hier ist der
    /// richtige Zeitpunkt: der Nutzer weiss jetzt, ob der Schlüssel taugt, und
    /// die Zuordnung „welcher Schlüssel war das noch gleich" ist ihm gerade
    /// präsent. Kommt der Dialog früher, benennt er etwas, das vielleicht gar
    /// nicht funktioniert.
    private func test(_ credential: APICredential, isNew: Bool = false) async {
        // Zwei Prüfungen gleichzeitig würden sich die Anzeige überschreiben:
        // der schnellere Lauf beendet den Fortschrittsbalken, das langsamere
        // Ergebnis überschreibt danach das des schnelleren.
        guard !isTesting else { return }

        // Anbieter aus dem **Eintrag**, nicht aus dem gerade aktiven: sonst
        // ginge der Schlüssel von Anbieter A an den Endpunkt von Anbieter B,
        // sollte sich die Auswahl zwischendurch ändern.
        guard let target = ProviderRegistry.provider(id: credential.providerID) else {
            testOutcome = .failure
            testResult = Loc.tr("Der Anbieter dieses Schlüssels ist unbekannt. Bitte entferne den Eintrag.")
            return
        }
        isTesting = true
        testResult = nil
        defer { isTesting = false }

        guard app.consent.hasConsent(for: target.id) else {
            testOutcome = .pending
            testResult = Loc.tr("Schlüssel gespeichert. Zum Prüfen fehlt noch die Datenfreigabe für %@.",
                                target.displayName)
            if isNew { startNaming(credential, isNew: true) }
            return
        }
        guard let key = app.apiKey(forCredential: credential.id) else {
            testOutcome = .failure
            testResult = Loc.tr("Der Schlüssel lässt sich nicht aus der Keychain lesen. Bitte entsperre das Gerät.")
            return
        }
        do {
            let models = try await target.fetchModels(apiKey: key)
            testOutcome = .success
            testResult = Loc.tr("Verbindung steht – %lld Modelle verfügbar.", models.count)
            app.markCredentialVerified(credential.id)
            // Erst jetzt wird ein frisch eingetragener Schlüssel auch benutzt.
            // Vorher nicht: ein Tippfehler hätte sonst den funktionierenden
            // verdrängt, und zwar unbemerkt.
            if isNew { app.activateCredential(credential.id) }
            // Die Liste liegt schon vor – ein zweiter Abruf über
            // `refreshModels` wäre bei OpenRouter rund ein Megabyte für nichts.
            if app.activeCredential(for: target.id)?.id == credential.id {
                app.adoptModels(models, for: target.id)
            }
            if isNew { startNaming(credential, isNew: true) }
        } catch {
            testOutcome = .failure
            testResult = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func startNaming(_ credential: APICredential, isNew: Bool) {
        nameDraft = credential.name
        naming = NamingRequest(credentialID: credential.id, isNew: isNew)
    }

    private func removeCredential(_ credential: APICredential) {
        keyInfo = nil
        keyInfoError = nil
        guard app.removeCredential(credential.id) else {
            // Die Keychain hat abgelehnt. Der Eintrag steht weiterhin in der
            // Liste – eine Zeile verschwinden zu lassen, während das Geheimnis
            // liegen bleibt, wäre die falsche Auskunft.
            testOutcome = .failure
            testResult = Loc.tr("Der Schlüssel konnte nicht aus der Keychain entfernt werden. Bitte entsperre das Gerät und versuche es erneut.")
            return
        }
        testResult = nil
        if app.credentials(for: credential.providerID).isEmpty {
            isAddingKey = false
            keyInput = ""
        } else if app.models.isEmpty {
            // Ein anderer Schlüssel hat übernommen: dessen Modell-Liste kann
            // eine andere sein. Ohne dieses Nachladen bliebe die Auswahl leer,
            // ohne dass eine Meldung erklärte, warum.
            Task { await app.refreshModels(force: true) }
        }
    }

    private var namingBinding: Binding<Bool> {
        Binding(
            get: { naming != nil },
            set: { if !$0 { naming = nil } }
        )
    }

    private func loadKeyInfo() async {
        // An OpenRouter gebunden, weil genau dorthin gesendet wird. Würde hier
        // der "aktive Anbieter" stehen, könnte bei einem Wechsel zwischen Tipp
        // und Ausführung der OpenAI-Schlüssel an OpenRouter gehen.
        let target = OpenRouterProvider()
        keyInfo = nil
        keyInfoError = nil

        guard app.consent.hasConsent(for: target.id) else {
            keyInfoError = Loc.tr("Datenfreigabe für %@ fehlt.", target.displayName)
            return
        }
        guard let key = app.apiKey(for: target.id) else {
            // Früher endete der Ablauf hier kommentarlos: kein Schlüssel,
            // keine Meldung, nichts passiert.
            keyInfoError = Loc.tr("Für %@ ist kein Schlüssel hinterlegt.", target.displayName)
            return
        }

        isLoadingKeyInfo = true
        defer { isLoadingKeyInfo = false }

        do {
            keyInfo = try await target.fetchKeyInfo(apiKey: key)
        } catch {
            keyInfoError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - Meldungen

struct ReportsListView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        List {
            if app.reports.isEmpty {
                ContentUnavailableView("Keine Meldungen",
                                       systemImage: "flag",
                                       description: Text("Gemeldete Antworten erscheinen hier, damit du nachvollziehen kannst, was du gemeldet hast."))
            } else {
                ForEach(app.reports) { report in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizedStringKey(report.reason.displayName))
                            .font(.subheadline.weight(.medium))
                        Text(report.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                        Text(report.excerpt)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(3)
                    }
                    .padding(.vertical, 2)
                }
                .onDelete { offsets in
                    // Erst die IDs einsammeln, dann löschen: während des
                    // Löschens verschieben sich die Indizes.
                    let ids = offsets.map { app.reports[$0].id }
                    for id in ids { app.deleteReport(id) }
                }
            }
        }
        .navigationTitle("Meldungen")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Gesperrte Modelle

struct BlockedModelsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        List {
            if app.blockedModelIDs.isEmpty {
                ContentUnavailableView("Keine Sperren",
                                       systemImage: "nosign",
                                       description: Text("Modelle, die wiederholt unangemessene Antworten liefern, kannst du hier sperren. Gesperrte Modelle lassen sich nicht mehr auswählen."))
            } else {
                ForEach(Array(app.blockedModelIDs).sorted(), id: \.self) { modelID in
                    HStack {
                        Text(modelID)
                            .font(.footnote)
                        Spacer()
                        Button("Freigeben") { app.unblockModel(modelID) }
                            .font(.caption.weight(.semibold))
                    }
                }
            }
        }
        .navigationTitle("Gesperrte Modelle")
        .navigationBarTitleDisplayMode(.inline)
    }
}
