//
//  RootView.swift
//  ByoKey
//
//  Adaptives Grundgerüst: auf dem iPad zwei Spalten nebeneinander,
//  auf dem iPhone die Seitenleiste als überlagerte Spalte.
//
//  Die Nutzungsbedingungen sind ein harter Riegel davor: solange sie nicht
//  akzeptiert sind, existiert die Chat-Oberfläche nicht (Richtlinie 1.2).
//

import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var app
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var showSettings = false

    var body: some View {
        Group {
            if app.consent.hasAcceptedTerms {
                main
            } else {
                OnboardingView()
            }
        }
        .tint(Theme.accent)
        // Bewusst hier und nicht in `main`: nach "Alle Daten löschen" fällt
        // die App ins Onboarding, und eine Meldung an `main` wäre mit der
        // Ansicht verschwunden – etwa der Hinweis, dass ein Schlüssel nicht
        // aus der Keychain entfernt werden konnte.
        .alert("Hinweis", isPresented: alertBinding) {
            Button("OK", role: .cancel) { app.alertMessage = nil }
        } message: {
            // Die Meldungen entstehen im Modell-Layer als String. Ohne
            // `LocalizedStringKey` würde die `StringProtocol`-Überladung
            // greifen und der Text bliebe deutsch.
            Text(LocalizedStringKey(app.alertMessage ?? ""))
        }
        .onChange(of: app.consent.hasAcceptedTerms) { _, accepted in
            // Nach "Alle Daten löschen" fällt die App ins Onboarding zurück.
            // `showSettings` überlebt das, weil RootView selbst bestehen
            // bleibt – ohne dieses Zurücksetzen springt das Einstellungsblatt
            // direkt nach dem erneuten Zustimmen wieder auf.
            if !accepted {
                showSettings = false
                app.consentRequest = nil
                app.supportNotice = nil
                // `alertMessage` bleibt stehen: deleteAllData() meldet darüber
                // einen fehlgeschlagenen Keychain-Zugriff.
            }
        }
    }

    private var main: some View {
        @Bindable var app = app

        return NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(showSettings: $showSettings)
        } detail: {
            // Kein eigener NavigationStack: auf dem iPhone klappt der
            // SplitView zu einem Stack zusammen und würde sonst zwei
            // Navigationsleisten übereinander zeigen.
            if let conversationID = app.selectedConversationID, app.selectedConversation != nil {
                ChatView(showSettings: $showSettings)
                    // Eigener Zustand pro Chat: sonst wandert ein nicht
                    // gesendeter Entwurf beim Wechsel in den nächsten Chat.
                    .id(conversationID)
            } else {
                ContentUnavailableView("Kein Chat ausgewählt",
                                       systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Wähle links einen Chat oder lege einen neuen an."))
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        // `.sheet(item:)` statt `isPresented` plus `if let`: der Wert wird beim
        // Präsentieren festgehalten und kann während des Schließens nicht
        // auf nil fallen, was den Dialog kurz leer zeigen würde.
        .sheet(item: $app.consentRequest) { request in
            ConsentView(providerID: request.providerID, scope: request.scope)
        }
        .alert(Text(LocalizedStringKey(ContentModeration.selfHarmSupportTitle)),
               isPresented: supportBinding) {
            Button("Verstanden", role: .cancel) { app.supportNotice = nil }
        } message: {
            Text(LocalizedStringKey(app.supportNotice ?? ""))
        }
        .task {
            await app.refreshModels()
        }
        // Die Auswahl bestimmt, wo die App beim nächsten Start aufsetzt –
        // also gehört jede Änderung zeitnah auf die Platte, nicht erst beim
        // nächsten Speichern aus einem anderen Anlass. Wer aus der Übersicht
        // heraus die App wegwischt, soll dort wieder landen.
        .onChange(of: app.selectedConversationID) { _, _ in
            app.scheduleSave()
        }
        .onChange(of: app.selectedProjectID) { _, _ in
            app.scheduleSave()
        }
    }

    // MARK: - Bindings für optionale Zustände

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { app.alertMessage != nil },
            set: { if !$0 { app.alertMessage = nil } }
        )
    }

    private var supportBinding: Binding<Bool> {
        Binding(
            get: { app.supportNotice != nil },
            set: { if !$0 { app.supportNotice = nil } }
        )
    }
}
