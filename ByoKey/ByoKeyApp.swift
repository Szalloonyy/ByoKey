//
//  ByoKeyApp.swift
//  ByoKey
//
//  Einstiegspunkt. Ein einziger Zustand (AppState) wird über die Umgebung
//  verteilt; beim Wechsel in den Hintergrund wird sofort gesichert, damit bei
//  einem Beenden durch das System nichts verloren geht.
//

import SwiftUI

@main
struct ByoKeyApp: App {

    @State private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                // Hieran hängt die Sprachumschaltung: SwiftUI schlägt jeden
                // Text gegen diese Sprache nach. Ändert sie sich, wird die
                // Oberfläche neu gezeichnet – ohne Neustart der App.
                .environment(\.locale, appState.settings.language.locale)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // Startet die App bei gesperrtem Gerät, lässt sich die
                // Keychain nicht lesen – die App hielte sich die ganze
                // Sitzung für nicht eingerichtet. Ein Blick beim
                // Zurückkehren kostet nichts und behebt genau das.
                appState.refreshKeyPresence()
                // Aus demselben Grund ein zweiter Anlauf auf die
                // Zustandsdatei. Scheitert das Lesen einmal – Start vor der
                // ersten Entsperrung, kurzer E/A-Fehler –, schreibt die App
                // aus Vorsicht **gar nichts** mehr, damit sie nichts
                // überschreibt, das sie nicht gelesen hat. Ohne diesen
                // Anlauf bliebe die ganze Sitzung ungesichert, ohne dass es
                // jemand merkt.
                appState.retryLoadIfNeeded()
            } else {
                appState.saveBeforeSuspend()
            }
        }
    }
}
