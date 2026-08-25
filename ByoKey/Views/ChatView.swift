//
//  ChatView.swift
//  ByoKey
//
//  Der eigentliche Arbeitsbereich: Modellauswahl, Verlauf, Kostenanzeige
//  und Eingabefeld.
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers
import PhotosUI

/// Die beiden Höhen, auf die der Verlauf beim Nachziehen hört.
///
/// Zwei Werte und nicht einer, weil sie zwei verschiedene Dinge bedeuten:
/// ändert sich `content`, ist im Verlauf selbst etwas gewachsen oder
/// geschrumpft – eine Antwort ist eingetroffen, ein Bild fertig geladen, ein
/// Code-Block aufgeklappt. Ändert sich `window`, hat sich nicht der
/// Verlauf verändert, sondern das Sichtfenster: die Tastatur kommt hoch oder
/// geht weg. iOS rückt die Ansicht dabei selbst nach, und ein eigener Sprung
/// mitten in diese Bewegung hinein ist genau das Aufschaukeln, das sich als
/// rasend auf- und abfahrender Chat zeigt.
///
/// `visibleRect.height` statt `containerSize.height`: das Sichtfenster
/// schrumpft je nach Lage über die Rahmenhöhe **oder** über die Innenabstände,
/// und diese eine Zahl fängt beides. Beim Scrollen ändert sie sich nicht – nur
/// der Ursprung wandert.
private struct TranscriptExtent: Equatable {
    var content: CGFloat
    var window: CGFloat
    /// Steht das Inhaltsende am unteren Rand?
    ///
    /// Bewusst ein `Bool` und keine Zahl: der Abstand zum Ende ändert sich bei
    /// jedem Bild einer Bildlaufbewegung, dieser Wert nur beim Verlassen und
    /// beim Erreichen des Endes. Als Zahl feuerte der Beobachter sechzigmal
    /// pro Sekunde.
    ///
    /// Er ist die eigentliche Bremse der Nachzieh-Kette: ein gelungener Sprung
    /// setzt ihn, und damit hebt die Kette ihre eigene Bedingung auf. Das ist
    /// gemessen statt geraten – anders als jede Zahl, die man sich ausdenkt.
    var atEnd: Bool

    /// Liegt der sichtbare Bereich **hinter** dem Inhaltsende?
    ///
    /// Das ist kein Randfall, sondern der leere Bildschirm: schrumpft der
    /// Inhalt schlagartig – ein aufgeklappter Code-Block wird wieder
    /// zugeklappt, zweitausend Punkte fallen weg –, kann die Ansicht kurz
    /// unterhalb von allem stehen, was es noch gibt. Seit dem `VStack` ist das
    /// nur noch ein Übergangszustand von einem Bild Dauer; die Rettung bleibt
    /// als billige Versicherung stehen.
    ///
    /// Vierzig Punkte Spiel, damit das Nachfedern am Ende einer
    /// Bildlaufbewegung nicht als Fehler zählt.
    var beyondEnd: Bool
}

struct ChatView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var showSettings: Bool

    @State private var draft = ""
    /// Wird nur bei einer Änderung des Entwurfs neu bestimmt.
    @State private var draftLooksLikeImageRequest = false
    @State private var showModelPicker = false
    @State private var showVoiceMode = false
    @State private var reportTarget: ChatMessage?
    @State private var exportTarget: ChatMessage?
    /// Zählt die Export-Blätter, damit ein verzögerter Aufräum-Auftrag
    /// nicht die Dateien eines inzwischen neu geöffneten Blattes löscht.
    @State private var exportGeneration = 0
    /// Steht der Verlauf am Ende? Steuert den Knopf „nach unten“.
    @State private var isAtBottom = true
    @State private var showFeedback = false
    /// Läuft die Ansicht dem wachsenden Text hinterher? Wird nur durch eine
    /// echte Fingerbewegung ausgeschaltet – nicht dadurch, dass der Text
    /// wächst und das Ende deshalb kurz aus dem Bild rutscht.
    @State private var followsBottom = true
    @State private var isDragging = false

    /// Wie oft der Verlauf nach einer Höhenänderung noch von selbst ans Ende
    /// nachrücken darf.
    ///
    /// Historisch die Bremse gegen ein Aufschaukeln: solange der Verlauf eine
    /// faule Liste war, erzeugte jeder Sprung ans Ende die Höhenänderung, auf
    /// die er selbst hörte. Seit dem `VStack` sind die Höhen exakt und die
    /// Kette bricht nach einer Runde von selbst ab.
    ///
    /// Der Vorrat bleibt als Notbremse: er wird nur dort gefüllt, wo es einen
    /// **Grund** gibt, ans Ende zu rücken – beim Öffnen, beim Absenden, beim
    /// Sprung-Knopf –, und begrenzt damit jeden denkbaren Rückfall auf eine
    /// endliche Zahl von Versuchen.
    @State private var repinBudget = 0

    /// Wie viele der neuesten Nachrichten der Verlauf zeichnet.
    ///
    /// Der Verlauf baut **jede** dieser Zeilen wirklich (kein `LazyVStack`
    /// mehr), damit seine Gesamthöhe zu jedem Zeitpunkt exakt bekannt ist –
    /// siehe `transcript`. Das kostet beim Öffnen einmal Rechenzeit, und diese
    /// Zahl ist die Obergrenze dafür. Ältere Nachrichten holt ein Knopf am
    /// oberen Rand nach.
    ///
    /// Wird nicht zurückgesetzt: `RootView` hängt `.id(conversationID)` an
    /// diese Ansicht, ein Chatwechsel baut sie also ohnehin neu auf.
    @State private var visibleCount = 30

    // MARK: Anhänge

    /// Angehängt, aber noch nicht abgeschickt.
    @State private var pendingAttachments: [Attachment] = []
    @State private var showFileImporter = false
    @State private var showPhotoPicker = false
    /// Auswahl aus der Fotomediathek. Der Auswähler läuft ausserhalb der App –
    /// deshalb braucht er **keine** Berechtigung und stellt auch keine Frage.
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var isAttaching = false
    @State private var attachmentError: String?
    /// Eine Datei, die nicht in das Kontextfenster des gewählten Modells
    /// passt. Der Nutzer entscheidet, was damit geschehen soll.
    @State private var oversized: OversizedFile?
    /// Meldungen, die warten müssen: solange ein Dialog offen ist, verschluckt
    /// SwiftUI eine gleichzeitig angeforderte Meldung.
    @State private var deferredError: String?
    /// Eine ausgelesene Datei, die auf ein grösseres Modell wartet. Ohne sie
    /// müsste der Nutzer nach „Anderes Modell wählen" dieselbe Datei erneut
    /// aussuchen und erneut auslesen lassen.
    @State private var heldFile: FileTextExtractor.Extraction?
    @State private var previewAttachment: Attachment?

    /// Eine zu grosse Datei samt der Zahlen, die für die Entscheidung nötig sind.
    struct OversizedFile: Identifiable {
        let id = UUID()
        let extraction: FileTextExtractor.Extraction
        let tokens: Int
        let limit: Int
    }

    private var conversation: Conversation? {
        app.selectedConversation
    }

    /// Die Bilddateien dieses Chats. Eigene Eigenschaft, damit `.task(id:)`
    /// darauf reagieren kann – und Taktgeber für das Mitlaufen, wenn ein
    /// erzeugtes Bild fertig wird.
    private var imageFileNames: [String] {
        conversation?.messages.compactMap(\.imageFileName) ?? []
    }

    /// Zeichenzahl der letzten Nachricht. Ändert sich, während die Antwort
    /// eintrifft – und ist damit der Auslöser für das Mitlaufen. Die Zahl
    /// selbst wird nirgends angezeigt; sie ist nur ein Taktgeber.
    private var streamingTick: Int {
        // `utf8.count` liest die Speichergrösse direkt. `count` würde
        // Grapheme zählen – O(n) bei jedem Bildaufbau, über einen Text, der
        // gerade wächst: genau die quadratische Falle, die `AppState.consume`
        // an anderer Stelle schon umgeht.
        conversation?.messages.last?.text.utf8.count ?? 0
    }

    private var activeModel: AIModel? {
        app.model(id: conversation?.modelID)
    }

    /// Nur dieser Chat. Das globale Flag würde in einem anderen Chat eine
    /// Tippanzeige und einen Stopp-Knopf zeigen, der den fremden Stream
    /// abbricht.
    private var isStreamingHere: Bool {
        app.isStreaming(conversationID: conversation?.id)
    }

    /// Anzeigename des Modells; `nil`, solange die Modell-Liste noch nicht
    /// geladen ist. Der Rückfalltext bleibt bewusst in der Ansicht: dort ist
    /// er ein Literal und wird übersetzt, als `String` wäre er es nicht.
    private var modelLabel: String? {
        if let name = activeModel?.name { return name }
        if let rawID = conversation?.modelID, !rawID.isEmpty { return rawID }
        return nil
    }

    var body: some View {
        core
        .background { Theme.background.ignoresSafeArea() }
        .navigationTitle(titleText)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showModelPicker, onDismiss: {
            // Ohne dieses Zurücksetzen bliebe eine ausgelesene Datei liegen,
            // wenn der Wähler ohne Auswahl geschlossen wird – und tauchte beim
            // nächsten, ganz anders gemeinten Modellwechsel wieder auf.
            heldFile = nil
        }) {
            ModelPickerView(selectedModelID: conversation?.modelID) { modelID in
                if let id = conversation?.id {
                    app.setModel(modelID, for: id)
                }
                if let held = heldFile {
                    heldFile = nil
                    evaluate(held, limit: remainingAttachmentBudget(forModel: modelID))
                }
            }
        }
        .sheet(item: $reportTarget) { message in
            if let conversationID = conversation?.id {
                ReportSheet(message: message, conversationID: conversationID)
            }
        }
        .onChange(of: draft) { _, value in
            draftLooksLikeImageRequest = Self.looksLikeImageRequest(value)
        }
        // Die Bilder dieses Chats bleiben im Speicher, solange er offen ist.
        // Ohne diesen Riegel entscheidet die Reihenfolge der Zugriffe, was
        // überlebt – und die läuft beim Hochscrollen genau gegen das unterste
        // Bild, also gegen das, was man beim nächsten Betreten zuerst sieht.
        //
        // Ausgelöst wird das an der **Bildliste**, nicht an der Chat-Kennung:
        // ein währenddessen erzeugtes Bild wäre sonst das einzige ungesteckte
        // und damit das erste, das verdrängt wird – genau verkehrt herum.
        .task(id: imageFileNames) {
            ImageFileLoader.pinPreviews(fileNames: imageFileNames)
        }
        .onDisappear {
            // **Nur** beim echten Verlassen. `onDisappear` feuert auch, wenn
            // sich ein Vollbild darüberlegt – die Bildansicht und der
            // Sprachmodus tun das –, und dort das Festgesteckte zu lösen
            // hiesse, die Vorschauen genau in dem Moment freizugeben, in dem
            // die Vollbildansicht 36 MB entpackt.
            if app.selectedConversationID == nil {
                ImageFileLoader.pinPreviews(fileNames: [])
            }
        }
        .sheet(item: $exportTarget, onDismiss: {
            // Quelltext nicht länger als nötig im temporären Ordner lassen.
            // Kurze Verzögerung, damit ein noch offenes Teilen-Blatt die
            // Datei fertig lesen kann.
            //
            // Der Zähler ist nicht Kosmetik: öffnet der Nutzer das Blatt
            // innerhalb dieser fünf Sekunden erneut, löschte der Auftrag des
            // ersten Blattes die gerade neu geschriebenen Dateien – das
            // Teilen-Blatt zeigte dann auf nichts mehr.
            exportGeneration &+= 1
            let generation = exportGeneration
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard generation == exportGeneration else { return }
                ZipArchive.clearExports()
            }
        }) { message in
            ArtifactExportView(sourceText: message.text,
                               suggestedName: conversation?.title ?? "projekt")
        }
        .sheet(isPresented: $showFeedback) {
            FeedbackSheet()
        }
        .fullScreenCover(isPresented: $showVoiceMode) {
            VoiceModeView()
        }
    }

    /// Aufbau der Ansicht – **mit** den Blättern rund um Anhänge.
    ///
    /// Getrennt vom `body` und nicht aus Ordnungsliebe: dort hingen sonst
    /// fünfzehn Modifikatoren in einem einzigen Ausdruck, darunter vier mit
    /// je zwei nachgestellten Abschlüssen und mehreren herzuleitenden
    /// Typen. Genau daran scheitert der Typprüfer mit „unable to type-check
    /// this expression in reasonable time" – einem Fehler, der nichts über den
    /// Code aussagt und sich nur durch Zerlegen beheben lässt.
    private var core: some View {
        VStack(spacing: 0) {
            subheader
            Divider().overlay(Theme.border)
            transcript
            if showsImageHint { imageHint }
            if let overflow = attachmentOverflow { attachmentWarning(overflow) }
            attachmentProblemHint
            ComposerView(
                draft: $draft,
                isStreaming: isStreamingHere,
                isReady: app.isReadyToSend,
                placeholder: placeholder,
                showsVoiceButton: app.settings.voiceEnabled,
                attachments: pendingAttachments,
                isAttaching: isAttaching,
                onAttachPhoto: { showPhotoPicker = true },
                onAttachFile: { showFileImporter = true },
                onRemoveAttachment: { removePending($0) },
                onSend: {
                    // Entwurf nur leeren, wenn die Nachricht wirklich
                    // angenommen wurde. Fehlt noch die Freigabe oder der
                    // Schlüssel, bleibt der Text stehen – und die Anhänge
                    // bleiben es auch, sonst wären sie verloren.
                    if app.send(draft, attachments: pendingAttachments) {
                        draft = ""
                        pendingAttachments = []
                    }
                },
                onStop: { app.stopStreaming() },
                onVoice: { showVoiceMode = true },
                onFeedback: { showFeedback = true }
            )
        }
        .photosPicker(isPresented: $showPhotoPicker,
                      selection: $photoItems,
                      maxSelectionCount: 4,
                      matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            // Sofort leeren: sonst meldet der Auswähler dieselbe Auswahl beim
            // nächsten Öffnen erneut und hängt das Bild ein zweites Mal an.
            photoItems = []
            importPhotos(items)
        }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: FileTextExtractor.readableTypes
                        + ImageAttachmentCoder.readableTypes,
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): importFiles(urls)
            case .failure(let error):
                attachmentError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
        .alert("Anhang nicht möglich", isPresented: attachmentErrorBinding) {
            Button("OK", role: .cancel) { attachmentError = nil }
        } message: {
            // Der Text entsteht ausserhalb von SwiftUI und ist bereits
            // übersetzt – deshalb `verbatim`, sonst würde er ein zweites Mal
            // nachgeschlagen.
            Text(verbatim: attachmentError ?? "")
        }
        .confirmationDialog("Datei ist zu groß für dieses Modell",
                            isPresented: oversizedBinding,
                            titleVisibility: .visible,
                            presenting: oversized) { file in
            // Kein Kürzen anbieten, wenn ohnehin nichts mehr hineinpasst –
            // „gekürzt auf null" wäre kein Angebot, sondern eine Falle.
            if file.limit > 0 {
                Button("Gekürzt anhängen") { attachTruncated(file) }
            }
            Button("Anderes Modell wählen") {
                // Die Datei bleibt ausgelesen liegen und wird nach der Wahl
                // gegen das neue Fenster erneut geprüft.
                heldFile = file.extraction
                showModelPicker = true
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { file in
            // Bewusst **ohne** Prozentangabe: sie liesse sich hier nur als
            // Verhältnis von Tokens bilden, während der Anhang danach ein
            // Verhältnis von Zeichen anzeigt. Bei japanischem Text oder Emoji
            // liegen die beiden Zahlen um Dutzende Prozentpunkte auseinander –
            // und zwei verschiedene Angaben zur selben Sache sind schlimmer
            // als gar keine. Wie viel wirklich übertragen wurde, steht danach
            // an der Datei.
            Text(verbatim: Loc.tr("„%@“ ergibt rund %@ Tokens. In %@ passen an dieser Stelle höchstens %@. Gekürzt wird auf das, was hineinpasst – die KI erfährt dabei, dass ihr der Rest fehlt, und der Anhang zeigt anschließend genau an, wie viel übertragen wurde.",
                                  file.extraction.fileName,
                                  CostFormat.tokens(file.tokens),
                                  modelLabel ?? Loc.tr("dieses Modell"),
                                  CostFormat.tokens(file.limit)))
        }
        .sheet(item: $previewAttachment) { attachment in
            // Bei einem Bild gar nicht erst lesen: `attachmentText` zöge die
            // ganze JPEG-Datei auf dem Hauptaktor durch eine
            // UTF-8-Prüfung, die zwangsläufig scheitert.
            AttachmentPreviewView(attachment: attachment,
                                  text: attachment.kind.isImage ? nil
                                        : app.attachmentText(attachment))
        }
        .onChange(of: canShowNotice) { _, free in
            guard free, let waiting = deferredError else { return }
            deferredError = nil
            attachmentError = waiting
        }
    }

    /// Der Titel in der Navigationsleiste.
    ///
    /// `??` auf Zeichenketten ergäbe einen `String` und damit die Überladung,
    /// die nichts nachschlägt – der Rückfalltext bliebe in jeder Sprache
    /// deutsch. Und der Vorgabetitel eines frischen Chats liegt als deutscher
    /// Text im Datenmodell; er muss über den Katalog laufen, sonst steht in
    /// der englischen Oberfläche „Neuer Chat“ über dem Verlauf.
    private var titleText: Text {
        guard let title = conversation?.title else { return Text("Chat") }
        return title == Conversation.untitled ? Text("Neuer Chat") : Text(verbatim: title)
    }

    // MARK: - Kopfzeile mit Modell und Verbrauch

    private var subheader: some View {
        HStack(spacing: 10) {
            Button {
                showModelPicker = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "cpu")
                        .font(.caption)
                    Group {
                        if let modelLabel { Text(modelLabel) } else { Text("Modell wählen") }
                    }
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Theme.surface, in: Capsule())
                .overlay { Capsule().strokeBorder(Theme.border, lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Loc.tr("Modell auswählen. Aktuell: %@",
                                       modelLabel ?? Loc.tr("Modell wählen")))

            Spacer(minLength: 8)

            // Bei sehr großer Schrift würde die Pille den Modellnamen auf
            // zwei Zeichen zusammenschrumpfen.
            if let conversation, !dynamicTypeSize.isAccessibilitySize {
                UsagePill(tokens: conversation.totalTokens,
                          costUSD: conversation.totalCostUSD,
                          label: "Chat")
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 8)
        // Gleiche Breitenbegrenzung wie Verlauf und Eingabefeld, sonst klebt
        // die Kopfzeile auf dem iPad am Fensterrand.
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .background(Theme.background)
    }

    // MARK: - Verlauf

    private var transcript: some View {
        // Einmal auflösen statt in jeder ForEach-Runde: `selectedConversation`
        // sucht linear durch alle Chats.
        let conversation = self.conversation
        let messages = conversation?.visibleMessages ?? []
        // Das Fenster: die neuesten `visibleCount` Nachrichten.
        let shown = messages.count > visibleCount
            ? Array(messages.suffix(visibleCount))
            : messages
        let hiddenCount = messages.count - shown.count
        let lastMessageID = conversation?.messages.last?.id
        let streamingHere = isStreamingHere
        let startAnchor: UnitPoint = messages.isEmpty ? .top : .bottom
        // Der Anker für Höhenänderungen wird getrennt gesetzt – siehe unten.
        let sizeAnchor: UnitPoint = (streamingHere && followsBottom) ? .bottom : .top

        return ScrollViewReader { proxy in
            // In zwei Ausdrücke geteilt. Nicht der Ordnung wegen: an dieser
            // Ansicht hängen fünfzehn Modifikatoren, die meisten mit
            // Abschlüssen, und genau daran scheitert der Typprüfer irgendwann
            // mit „unable to type-check this expression in reasonable time" –
            // einem Fehler, der nichts über den Code aussagt.
            let area = ScrollView {
                // **`VStack`, nicht `LazyVStack`** – das ist die Behebung von
                // sechs Fehlerrunden, und sie ist eine einzige Zeile.
                //
                // Eine faule Liste **schätzt** die Höhe jeder Zeile, die sie
                // noch nie gebaut hat. Bei einem Verlauf mit Code-Blöcken und
                // Bildern liegt diese Schätzung um Tausende von Punkten
                // daneben, und `scrollTo` löst sein Ziel gegen genau diese
                // Schätzung auf. Daraus folgte alles: der Sprung, der zu kurz
                // kam; die Kette, die nachzog; das Aufschaukeln, weil jeder
                // Sprung die Schätzung änderte, auf die er hörte; und
                // schliesslich der leere Bildschirm, wenn die Ansicht in einem
                // Bereich stand, in dem nichts gebaut war.
                //
                // Ein `VStack` baut jede Zeile. Die Gesamthöhe ist damit zu
                // jedem Zeitpunkt exakt, jeder Sprung landet beim ersten Mal,
                // und ein leerer Bereich kann gar nicht entstehen.
                //
                // Bezahlt wird das mit Rechenzeit beim Öffnen – deshalb das
                // Fenster über `visibleCount`. Dreissig Nachrichten sind rund
                // zehn Bildschirme Rückschau und kosten beim Öffnen ein paar
                // Dutzend Millisekunden für Markdown und Code-Hervorhebung.
                // Der Speicher bindet nicht mehr: Bilder geben ihre entpackte
                // Fassung frei, sobald ihre Zeile aus dem Bild scrollt (siehe
                // `GeneratedImageView`).
                VStack(alignment: .leading, spacing: 22) {

                    if !app.isReadyToSend {
                        setupCard
                    }

                    if messages.isEmpty {
                        emptyState
                    }

                    if hiddenCount > 0 {
                        olderMessagesButton(hiddenCount,
                                            anchorID: shown.first?.id,
                                            proxy: proxy)
                    }

                    ForEach(shown) { message in
                        MessageRow(
                            message: message,
                            showCost: app.settings.showCostPerMessage,
                            isStreaming: streamingHere
                                && message.role == .assistant
                                && message.id == lastMessageID,
                            isRevealed: app.revealedMessageIDs.contains(message.id),
                            isSpeaking: app.speech.phase == .speaking
                                && app.speakingMessageID == message.id,
                            voiceEnabled: app.settings.voiceEnabled,
                            onReveal: { app.revealedMessageIDs.insert(message.id) },
                            onReport: { reportTarget = message },
                            onBlockModel: {
                                if let modelID = message.modelID { app.blockModel(modelID) }
                            },
                            // Zähler auch beim **Öffnen** erhöhen: sonst
                            // sieht der Aufräum-Auftrag des vorigen Blattes
                            // seine eigene Generation wieder und löscht die
                            // Dateien des jetzt offenen.
                            onExportFiles: {
                                exportGeneration &+= 1
                                exportTarget = message
                            },
                            onSpeak: { Task { await app.toggleSpeak(message) } },
                            onPreviewAttachment: { previewAttachment = $0 },
                            onToggleAttachment: { attachment in
                                app.setAttachment(attachment.id, active: !attachment.isActive)
                            }
                        )
                        .equatable()
                        .id(message.id)
                    }

                    // Die Endmarke trägt den unteren Abstand selbst, statt
                    // ihn als `padding` **unter** sich zu haben. Sonst richtet
                    // `scrollTo("bottom", anchor: .bottom)` die Marke am
                    // unteren Rand aus und lässt die zwölf Punkte darunter
                    // stehen – das Ende wäre dann nie ganz erreicht.
                    Color.clear
                        .frame(height: 12)
                        .id("bottom")
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.top, 16)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            // Einstiegsposition und Ausrichtung bei kurzem Inhalt: unverändert
            // am Ende. Getrennt gesetzt, damit die dritte Rolle darunter sich
            // ändern darf, ohne den Einstieg erneut auszulösen.
            .defaultScrollAnchor(startAnchor, for: .initialOffset)
            .defaultScrollAnchor(startAnchor, for: .alignment)
            // Die Rolle, auf die es ankommt – und die einzige, die sich je
            // nach Lage unterscheidet.
            //
            // **In aller Regel `.top`**: was oberhalb des Sichtfensters steht,
            // bleibt stehen. Genau das erwartet man, wenn sich mitten im
            // Verlauf eine Höhe ändert – ein Code-Block wird aufgeklappt, ein
            // Bild ist fertig geladen. Der Block wächst nach unten, die
            // Leseposition bleibt.
            //
            // Vorher stand hier `.bottom`, also „halte den Abstand zum
            // **Inhaltsende** fest". Beim Aufklappen eines Code-Blocks um
            // zweitausend Punkte heisst das: die Ansicht schiebt sich um
            // zweitausend Punkte weiter – am Inhalt vorbei, in einen Bereich,
            // in dem die faule Liste nichts gebaut hat. Klappte man den Block
            // gleich wieder zu, fielen dieselben zweitausend Punkte weg und
            // die Ansicht stand vollends hinter dem Ende: leerer Bildschirm.
            // Das war der gemeldete Fehler, und die Tastatur hatte nie etwas
            // damit zu tun.
            //
            // **`.bottom` nur beim Mitlaufen im Stream**: dort wächst der
            // Inhalt am Ende, und der feste Abstand dazu ist genau richtig.
            // Sobald der Nutzer hochscrollt (`followsBottom == false`) oder
            // die Antwort fertig ist, gilt wieder `.top`.
            .defaultScrollAnchor(sizeAnchor, for: .sizeChanges)
            // Der Balken sprang früher, weil `contentSize` bei jeder
            // Höhenkorrektur der faulen Liste eine andere Zahl war. Seit dem
            // `VStack` stimmt sie vom ersten Bild an – **der Balken könnte
            // zurück**, indem man diese Zeile löscht. Bis der `VStack` als
            // stabil gilt, bleibt sie: zur Orientierung gibt es den
            // Sprung-Knopf.
            .scrollIndicators(.hidden)
            // `.immediately` statt `.interactively`.
            //
            // Apple hat unter der Kennung FB20979569 einen Fehler in iOS 26
            // bestätigt und nachgestellt: eine `ScrollView` mit `LazyVStack`,
            // Zeilen **veränderlicher** Höhe, `defaultScrollAnchor(.bottom)`
            // **und** `scrollDismissesKeyboard(.interactively)` verliert ihre
            // Bildlaufposition auf unvorhersehbare Weise – am deutlichsten
            // beim Erscheinen und Verschwinden der Tastatur. Auf iOS 18 tritt
            // es nicht auf, einen Umweg gibt es nicht.
            //
            // Seit dem Wechsel auf `VStack` fehlt der Ansicht die erste der
            // vier Zutaten, der Fehler kann sie also gar nicht mehr treffen –
            // und die eigentliche Ursache des leeren Bildschirms lag ohnehin
            // woanders. **Diese Zeile darf auf `.interactively` zurück**,
            // sobald der `VStack` als stabil gilt; dann kommt das
            // Herunterziehen der Tastatur mit dem Finger wieder. Sie steht
            // nur deshalb noch hier, weil zwei Änderungen auf einmal kein
            // sauberes Urteil erlauben.
            .scrollDismissesKeyboard(.immediately)

            let observed = area
            // Ist das Ende in Sicht? 60 pt Toleranz, damit der Knopf nicht
            // schon beim letzten Fingerbreit Rest erscheint.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // Über `visibleRect` und nicht über `contentOffset` plus
                // `containerSize`: letzteres rechnet die Innenabstände falsch
                // mit, sobald welche da sind – etwa wenn die Tastatur
                // hochkommt. Der Knopf erschien dann zur falschen Zeit und
                // wirkte deshalb wie ein Knopf ohne Funktion.
                let rest = geometry.contentSize.height - geometry.visibleRect.maxY
                return rest <= 60
            } action: { _, atBottom in
                // **Ohne** `withAnimation`. Das galt nicht nur dieser einen
                // Zuweisung, sondern der ganzen Transaktion – und fiel in
                // dieselbe Transaktion die Rahmenänderung des Verlaufs
                // (Tastatur, Hinweisstreifen, wachsendes Eingabefeld), legte
                // sich eine zweite, 0,18 Sekunden lange Kurve über die
                // Tastaturbewegung von iOS. Jede animierte Zwischengrösse
                // meldete wieder Geometrie, und die Ansicht schaukelte sich
                // auf. Die Einblendung des Knopfes steht jetzt am Overlay
                // selbst und betrifft nur ihn.
                guard isAtBottom != atBottom else { return }
                isAtBottom = atBottom
            }
            // **Hier** wird nachgezogen, und nur hier.
            //
            // Seit dem Wechsel auf `VStack` ist das eine Rückfallebene und
            // nicht mehr der Normalfall: die Höhen sind exakt, ein Sprung ans
            // Ende trifft beim ersten Mal. Was bleibt, sind Höhen, die sich
            // **nach** dem Sprung noch ändern – ein Bild ist fertig geladen,
            // die Fusszeile einer Antwort erscheint. Dann rückt die Ansicht
            // nach, bis nichts mehr nachkommt.
            //
            // Die drei Wächter unten stehen in dieser Reihenfolge, weil sie
            // unterschiedlich teuer sind. `atEnd` beendet die Kette, sobald
            // sie ihr Ziel hat – ein Sprung, der nichts bewegt, wird gar
            // nicht erst versucht und kostet deshalb auch nichts. Erst danach
            // greift `repinBudget`, und der zählt damit **Fehlversuche**, nicht
            // Höhenänderungen: die paar Dutzend Korrekturen beim Öffnen
            // verbrauchen ihn nicht, ein echtes Pendeln schon.
            //
            // Nur wenn die Ansicht dem Ende überhaupt folgen soll. Wer
            // hochgescrollt hat, um etwas nachzulesen, wird nicht gezogen.
            //
            // Der Auslöser ist die **Höhe**, nicht der Versatz: die Höhe
            // ändert sich ein paar Mal, der Versatz bei jedem Bild einer
            // Bildlaufbewegung. Auf den Versatz zu hören hiesse, sechzigmal
            // pro Sekunde Zustand zu schreiben.
            .onScrollGeometryChange(for: TranscriptExtent.self) { geometry in
                // Ein halber Bildpunkt Spiel: die Endmarke ist die letzte
                // Zeile, „angekommen" heisst Abstand null – exakt vergleichen
                // wäre bei Fliesskomma eine Wette.
                let rest = geometry.contentSize.height - geometry.visibleRect.maxY
                return TranscriptExtent(content: geometry.contentSize.height,
                                        window: geometry.visibleRect.height,
                                        atEnd: rest <= 0.5,
                                        beyondEnd: rest < -40)
            } action: { old, new in
                // 0) Die Rettung, und sie steht **vor** allem anderen.
                //
                //    Liegt der sichtbare Bereich hinter dem Inhaltsende, ist
                //    der Bildschirm leer – und zwar unabhängig davon, ob die
                //    Ansicht dem Ende folgen soll oder wie viel Vorrat noch da
                //    ist. Das ist keine Feinheit der Bildlaufposition, das ist
                //    ein kaputter Zustand, und er gehört immer repariert.
                //
                //    `isDragging` schliesst das Nachfedern unter dem Finger
                //    aus: dort ist „hinter dem Ende" gewollt und geht von
                //    selbst zurück.
                if new.beyondEnd, !isDragging, !messages.isEmpty {
                    proxy.scrollTo("bottom", anchor: .bottom)
                    return
                }

                // `messages.isEmpty` mit: bei leerem Chat steht der Anker
                // bewusst oben, und der Sprung ans Ende widerspräche dem.
                guard followsBottom, !messages.isEmpty else { return }

                // 1) Bewegt sich das **Sichtfenster**, hat sich nicht der
                //    Verlauf geändert: die Tastatur kommt oder geht, das
                //    Eingabefeld wächst um eine Zeile, ein Hinweisstreifen
                //    darüber schaltet um.
                //
                //    Währenddessen wird nicht gesprungen. Jeder Sprung in eine
                //    laufende Bewegung hinein hat dort nichts zu suchen: iOS
                //    rückt selbst nach, und zwei Bewegungen auf derselben
                //    Achse ergaben früher das Aufschaukeln beim Antippen des
                //    Eingabefelds.
                //
                //    Nachgezogen wird trotzdem – aber nicht hier, sondern
                //    wenn iOS meldet, dass die Tastatur **fertig** gefahren
                //    ist (siehe `keyboardDidShowNotification` weiter unten).
                //    Ohne dieses Nachziehen bliebe die Ansicht nach dem Öffnen
                //    der Tastatur mitten im Verlauf stehen und richtete sich
                //    erst beim Schliessen wieder ein.
                //
                //    Toleranz statt exaktem Vergleich: eine Wackelei von einem
                //    Drittelpunkt (Rundung bei dreifacher Auflösung, sich noch
                //    setzende Sicherheitsabstände) darf nicht als Bewegung
                //    zählen, sonst käme die Kette nie zum Zug.
                guard abs(new.window - old.window) < 0.5 else { return }

                // 2) Der Fixpunkt: steht das Ende schon unten, ist nichts zu
                //    tun. Vor dem Vorrat geprüft, damit ein Null-Sprung nichts
                //    kostet – beim Streaming wären das sonst zwanzig Punkte
                //    pro Sekunde für Sprünge, die nirgendwo hin führen.
                guard !new.atEnd else { return }

                // 3) Letzte Rückfallsicherung. Seit dem `VStack` sollte sie
                //    nie greifen; sie begrenzt jeden Rückfall auf eine
                //    endliche Zahl von Versuchen.
                guard repinBudget > 0 else { return }
                repinBudget -= 1
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .overlay(alignment: .bottom) {
                Group {
                    if !isAtBottom && !messages.isEmpty {
                        // Erste Begrenzung: Seite innerhalb der
                        // Nachrichtenspalte (einstellbar). Zweite: die Spalte
                        // selbst mittig halten – auf dem iPad stünde der Knopf
                        // sonst weit draussen im Rand statt neben den
                        // Nachrichten.
                        scrollToBottomButton {
                            jumpToBottom(proxy, animated: true)
                        }
                        .frame(maxWidth: 820, alignment: scrollButtonAlignment)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                // Die Animation gehört hierher und nicht in den
                // Geometrie-Rückruf: so betrifft sie den Knopf und sonst
                // nichts.
                .animation(.easeOut(duration: 0.18), value: isAtBottom)
            }
            // Wenn die Tastatur **fertig** gefahren ist, einmal nachziehen.
            //
            // `didShow`/`didHide` und nicht `willShow`/`willHide`: iOS
            // verschickt sie genau am Ende der Bewegung. Damit braucht es
            // keine Wartezeit, die man sich ausdenkt und die auf dem einen
            // Gerät passt und auf dem nächsten nicht – die Dauer bestimmt
            // ohnehin das System.
            //
            // Warum überhaupt: die Tastatur verkleinert das Sichtfenster um
            // gut die halbe Bildschirmhöhe. Während dieser Viertelsekunde
            // springt die Ansicht bewusst nicht mit (sonst schaukelt sie sich
            // auf, siehe oben) – dafür kann sie danach an der falschen Stelle
            // stehen.
            //
            // **Nur wenn wirklich etwas nachzuziehen ist.** `isAtBottom` gilt
            // ab sechzig Punkten Abstand zum Ende; steht das Ende schon im
            // Bild, hat `defaultScrollAnchor(.bottom, for: .sizeChanges)`
            // seine Arbeit getan und hier ist nichts zu tun.
            //
            // Der Wächter bleibt auch nach dem Wechsel auf `VStack`: ein
            // Sprung, der nichts zu korrigieren hat, ist kein Dienst am
            // Nutzer, sondern nur eine Bewegung, die niemand bestellt hat.
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardDidShowNotification)) { _ in
                guard followsBottom, !messages.isEmpty, !isAtBottom else { return }
                settleAtBottom(proxy)
            }

            // Zweite Teilung, gleicher Grund wie oben: sonst hingen hier
            // elf Modifikatoren mit Abschlüssen an einem einzigen Ausdruck.
            observed
            // Der eigentliche Gleichlauf: die Antwort trifft Stück für Stück
            // in DERSELBEN Nachricht ein, `messages.count` ändert sich dabei
            // nicht. Ohne diesen Auslöser wächst der Text unten aus dem Bild
            // heraus und man muss von Hand nachscrollen.
            .onChange(of: streamingTick) { _, _ in
                guard followsBottom else { return }
                // Ein kleiner Vorrat je Textstück. `onChange` feuert in der
                // Aktualisierung, in der sich der Text ändert – also **bevor**
                // die neue Höhe gemessen ist. Der Sprung löst deshalb gegen
                // die alte Höhe auf und kommt ein Stück zu kurz; die Kette
                // gleicht das im nächsten Bild aus und hört von selbst auf,
                // sobald das Ende unten steht.
                // `if` statt `max`: SwiftUI vergleicht bei `@State` **nicht**
                // auf Gleichheit – eine Zuweisung desselben Werts baut die
                // Ansicht trotzdem neu auf. Da der Vorrat während des
                // Mitlaufens ohnehin fast immer über 4 liegt, kostete diese
                // eine Zeile bei **jedem** Textstück einen zweiten,
                // vollständigen Bildaufbau.
                if repinBudget < 4 { repinBudget = 4 }
                // Ohne Animation: bei jedem Textstück eine zu starten ruckelt
                // und überholt sich selbst.
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            // Nur eine echte Fingerbewegung beendet das Mitlaufen. Endet sie
            // wieder unten, läuft die Ansicht von selbst weiter mit.
            .onScrollPhaseChange { _, phase in
                // Nur `.interacting`: `.tracking` meldet bereits das Auflegen
                // des Fingers, also auch jeden Tipp auf den Verlauf. Damit
                // hätte ein Tipp zum Schliessen der Tastatur das Mitlaufen
                // mitten in der Antwort abgeschaltet.
                if phase == .interacting {
                    isDragging = true
                    followsBottom = false
                    // Ein Restvorrat aus einem früheren Sprung lebte sonst
                    // wieder auf, sobald die Bewegung unten endet.
                    repinBudget = 0
                } else if phase == .idle, isDragging {
                    isDragging = false
                    followsBottom = isAtBottom
                }
            }
            // Beim Öffnen ans Ende.
            //
            // `.defaultScrollAnchor(.bottom, for: .initialOffset)` allein
            // genügte nicht, solange der Verlauf eine faule Liste war: die
            // Anfangsposition wurde aus einer Schätzung berechnet, die fast
            // immer zu niedrig ausfiel, und der Verlauf setzte irgendwo in der
            // Mitte auf. Seit dem `VStack` trifft der Anker – dieser Sprung
            // ist die Absicherung, nicht mehr die Bedingung.
            //
            // Dieser erste Sprung bringt die Ansicht in die Nähe; genau
            // getroffen wird über die Höhenänderungen weiter oben.
            .task {
                guard !messages.isEmpty else { return }
                // Dreimal über gut zwei Zehntelsekunden. Seit dem `VStack`
                // wäre einmal genug; die beiden Nachläufer kosten nichts und
                // fangen Höhen ab, die erst asynchron feststehen (Bilder).
                //
                // `onScrollGeometryChange` meldet nur **Änderungen** – der
                // erste beobachtete Wert löst nichts aus. Die Nachzieh-Kette
                // oben hätte damit keinen garantierten ersten Takt, und beim
                // Öffnen ist genau der entscheidend. Diese drei Anläufe geben
                // ihn: der erste bringt die Ansicht in die Nähe, die beiden
                // folgenden greifen die Höhenkorrekturen der ersten Bilder ab.
                // Danach übernimmt die Kette.
                for _ in 0..<3 {
                    guard followsBottom else { return }
                    jumpToBottom(proxy, animated: false)
                    try? await Task.sleep(nanoseconds: 80_000_000)
                }
            }
            // Ohne `followsBottom`-Wächter, anders als die vier Auslöser
            // darunter – und das ist Absicht: die Zahl der Nachrichten wächst
            // ausschliesslich dadurch, dass der Nutzer selbst sendet. Wer
            // gerade weiter oben liest und dann abschickt, will seine eigene
            // Nachricht sehen. Käme je ein Auslöser hinzu, der **nicht** vom
            // Nutzer kommt, gehört hier ein Wächter hin.
            .onChange(of: messages.count) { _, _ in
                jumpToBottom(proxy, animated: true)
            }
            // Ein fertiges Bild ändert weder den Text noch die Anzahl der
            // Nachrichten – ohne diesen Auslöser bliebe die Ansicht stehen,
            // wo sie war. Vorher fing das der Anker auf.
            .onChange(of: imageFileNames.count) { _, _ in
                guard followsBottom else { return }
                settleAtBottom(proxy)
            }
            // Am Ende einer Antwort verschwindet die Tippanzeige und die
            // Fusszeile mit Tokens und Kosten erscheint. Das ist die letzte
            // Höhenänderung, und auch sie fing vorher der Anker auf.
            .onChange(of: streamingHere) { _, nowStreaming in
                guard !nowStreaming, followsBottom else { return }
                settleAtBottom(proxy)
            }
            // Kein `onChange` auf die Chat-Kennung: `RootView` hängt
            // `.id(conversationID)` an diese Ansicht, ein Wechsel baut sie
            // also komplett neu auf – die Kennung ändert sich innerhalb einer
            // Instanz nie, der Auslöser feuerte nie. Den Einstieg ans Ende
            // erledigt `.defaultScrollAnchor`; die Zustände beginnen über
            // ihre Vorgabewerte ohnehin bei „unten".
            //
            // Die Einrichtungskarte steht **über** allem anderen. Verschwindet
            // sie – Schlüssel hinterlegt, Freigabe erteilt –, verkürzt sich
            // der Inhalt oberhalb des Sichtfensters.
            .onChange(of: app.isReadyToSend) { _, _ in
                guard followsBottom else { return }
                settleAtBottom(proxy)
            }
            // Tippen auf den Verlauf schliesst die Tastatur. Knöpfe und
            // Textauswahl in den Nachrichten behalten Vorrang – SwiftUI
            // reicht den Tipp nur weiter, wenn ihn dort niemand annimmt.
            .onTapGesture {
                dismissKeyboard()
            }
        }
    }

    // MARK: - Hinweis auf Bildmodelle

    /// Sieht der Entwurf nach einer Bildbitte aus, während das gewählte
    /// Modell nur Text kann?
    ///
    /// Der Hintergrund: ein Textmodell lehnt so eine Bitte nicht ab. Es
    /// antwortet – manchmal sogar mit „hier ist dein Bild", obwohl nie eines
    /// entstanden ist. Die Schnittstelle meldet dabei keinen Fehler, also
    /// muss die App selbst warnen.
    /// Gepuffert, nicht berechnet: der Body von `ChatView` läuft während einer
    /// Antwort zwanzigmal pro Sekunde, `draft` ändert sich dabei nicht.
    private var showsImageHint: Bool {
        draftLooksLikeImageRequest && activeModel?.isImageModel != true
    }

    /// Wortweise statt über Teilzeichenketten.
    ///
    /// `contains` fand „bild" in „Bildschirm" und „male" in „normale" – der
    /// Satz „Wie sieht der normale Bildschirm aus?" blendete damit den Hinweis
    /// ein. Geprüft wird deshalb Wort für Wort, mit Präfixen dort, wo deutsche
    /// Beugung es verlangt („erstelle", „erstellst", „erstellen").
    private static func looksLikeImageRequest(_ text: String) -> Bool {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return false }

        let subjectPrefixes = ["bild", "grafik", "foto", "illustration", "logo",
                               "poster", "image", "picture", "artwork",
                               "obraz", "zdjęcie", "zdjecie"]
        let subjectStopWords: Set<String> = ["bildschirm", "bildschirme", "bildung",
                                             "bildlich", "fotograf", "fotografie",
                                             "logout", "login"]
        let verbPrefixes = ["erstell", "generier", "zeichne", "entwirf", "entwerfe",
                            "create", "generate", "draw", "design", "render",
                            "stwórz", "stworz", "wygeneruj", "narysuj"]
        let verbExact: Set<String> = ["mach", "mache", "machst", "male", "malen",
                                      "malst", "make", "makes"]

        let hasSubject = words.contains { word in
            !subjectStopWords.contains(word) && subjectPrefixes.contains { word.hasPrefix($0) }
        }
        guard hasSubject else { return false }
        return words.contains { word in
            verbExact.contains(word) || verbPrefixes.contains { word.hasPrefix($0) }
        }
    }

    /// Ans Ende rücken, wenn sich gleich noch eine Höhe ändert.
    ///
    /// Für die drei Fälle, in denen unmittelbar nach dem Sprung noch etwas
    /// nachwächst: ein fertig geladenes Bild, die Fusszeile mit Tokens und
    /// Kosten am Ende einer Antwort, die verschwundene Einrichtungskarte.
    /// Der kleine Vorrat lässt die Nachzieh-Kette genau dafür anlaufen.
    ///
    /// Anders als `jumpToBottom` schaltet er das Mitlaufen **nicht** ein –
    /// alle drei Aufrufer prüfen `followsBottom` selbst, und wer hochgescrollt
    /// hat, um etwas nachzulesen, soll oben bleiben.
    private func settleAtBottom(_ proxy: ScrollViewProxy) {
        // `if` statt `max` – siehe `streamingTick`: eine Zuweisung ohne
        // Änderung baut die Ansicht trotzdem neu auf.
        if repinBudget < 8 { repinBudget = 8 }
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    /// Der Knopf, der ältere Nachrichten nachholt.
    ///
    /// Er springt danach genau auf die Nachricht zurück, die vorher die
    /// oberste war – so bleibt die Leseposition erhalten, statt dass der
    /// Verlauf um dreissig Nachrichten wegrutscht. Dass das auf den Punkt
    /// genau geht, ist erst seit dem Wechsel auf `VStack` möglich: die Höhen
    /// sind exakt, `scrollTo` trifft beim ersten Mal.
    ///
    /// `Task { @MainActor … }` und nicht direkt: gesprungen werden kann erst,
    /// wenn die neuen Zeilen gebaut sind, und das geschieht im nächsten
    /// Durchlauf.
    private func olderMessagesButton(_ hidden: Int,
                                     anchorID: UUID?,
                                     proxy: ScrollViewProxy) -> some View {
        Button {
            visibleCount += 30
            guard let anchorID else { return }
            Task { @MainActor in
                proxy.scrollTo(anchorID, anchor: .top)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.up")
                    .font(.caption2.weight(.semibold))
                Text(verbatim: Loc.tr("Ältere Nachrichten anzeigen (%lld)", hidden))
                    .font(.footnote.weight(.medium))
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Theme.surfaceAlt, in: Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Springt ans Ende des Verlaufs.
    ///
    /// Seit der Verlauf ein `VStack` ist, trifft dieser Sprung beim ersten
    /// Mal: alle Zeilen sind gebaut, die Gesamthöhe ist exakt, es gibt nichts
    /// mehr zu schätzen. Die Nachzieh-Kette in `transcript` (siehe
    /// `onScrollGeometryChange`) ist damit von der Notwendigkeit zur
    /// Rückfallebene geworden – sie greift noch, wenn sich unmittelbar nach
    /// dem Sprung eine Höhe ändert, etwa weil ein Bild fertig geladen ist.
    ///
    /// `followsBottom = true` ist der zweite Teil und wirkt unabhängig vom
    /// Scrollen: der Knopf ist nur sichtbar, wenn der Nutzer selbst gescrollt
    /// hat – und dann ist das Mitlaufen abgeschaltet. Ohne diese Zeile springt
    /// die Ansicht ans Ende und wird beim nächsten Textstück sofort wieder
    /// abgehängt.
    private func jumpToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        followsBottom = true
        // Vorrat für die Nachzieh-Kette. Die eigentliche Bremse ist der
        // gemessene Fixpunkt `atEnd`; diese Zahl fängt nur den Fall ab, dass
        // ein Sprung wider Erwarten nicht ankommt. Grosszügig, weil ein
        // Null-Sprung nichts kostet.
        repinBudget = 30
        if animated {
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    /// Wie viele Tokens die zugeschalteten Anhänge über dem liegen, was in
    /// das gewählte Modell passt. `nil` heisst: alles in Ordnung.
    private var attachmentOverflow: Int? {
        guard let conversation else { return nil }
        let modelID = effectiveModelID
        guard !modelID.isEmpty else { return nil }
        // Die noch nicht abgeschickten Anhänge zählen mit. Ohne sie erschiene
        // die Warnung erst **nach** dem Senden – also genau dann, wenn sie
        // nichts mehr verhindern kann.
        let used = app.activeAttachmentTokens(in: conversation)
            + pendingAttachments.reduce(0) { $0 + $1.tokenEstimate }
        let limit = app.attachmentTokenLimit(forModel: modelID)
        return used > limit ? used - limit : nil
    }

    /// Erscheint vor allem **nach einem Modellwechsel**: derselbe Anhang, der
    /// bei einem grossen Modell mühelos passte, sprengt ein kleines. Statt
    /// beim Senden stillschweigend abzuschneiden, sagt die App es vorher und
    /// überlässt dem Nutzer, welchen Anhang er abschaltet.
    private func attachmentWarning(_ overflow: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc.badge.ellipsis")
                .foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 4) {
                Text("Die Anhänge sind für dieses Modell zu umfangreich.")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(verbatim: Loc.tr("Rund %@ Tokens zu viel. Beim Senden fällt der ältere Verlauf weg. Du kannst einzelne Anhänge abschalten – tippe dazu auf die Datei in der Nachricht – oder ein Modell mit größerem Kontext wählen.",
                                      CostFormat.tokens(overflow)))
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Größeres Modell wählen") { showModelPicker = true }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .background(Theme.surfaceAlt)
    }

    // MARK: - Dateien anhängen

    /// Das Modell, gegen dessen Kontextfenster gerechnet wird.
    private var effectiveModelID: String {
        let id = conversation?.modelID ?? ""
        return id.isEmpty ? (app.settings.defaultModelID ?? "") : id
    }

    /// Ergebnis eines Auslesevorgangs. Der Fehler wird gleich zu Text gemacht:
    /// so muss kein `Error` die Grenze zwischen den Ausführungsumgebungen
    /// überqueren.
    private enum ImportResult {
        case ok(Attachment)
        case tooBig(FileTextExtractor.Extraction, tokens: Int, budget: Int)
        case failed(String)
    }

    /// Was an Tokens noch für Anhänge übrig ist.
    ///
    /// Rechnet mit: was in diesem Chat schon zugeschaltet ist **und** was
    /// gerade unabgeschickt über dem Eingabefeld liegt. Ohne das Zweite
    /// bestünde jede Datei einzeln die Prüfung, und fünf Dateien à 90 % des
    /// Fensters ergäben zusammen 450 %.
    private func remainingAttachmentBudget(forModel modelID: String) -> Int {
        let limit = app.attachmentTokenLimit(forModel: modelID)
        let inChat = conversation.map { app.activeAttachmentTokens(in: $0) } ?? 0
        let pending = pendingAttachments.reduce(0) { $0 + $1.tokenEstimate }
        return max(0, limit - inChat - pending)
    }

    private func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let modelID = effectiveModelID
        isAttaching = true

        Task {
            var problems: [String] = []
            var pendingDialog: OversizedFile?

            for url in urls {
                // Alles Schwere in **einem** nebenläufigen Abschnitt: Auslesen,
                // Kürzen und Ablegen. Ein 20-MB-PDF zu zerlegen dauert
                // Sekunden, und `count` über zwanzig Millionen Bytes ist eine
                // vollständige Unicode-Segmentierung – beides gehört nicht auf
                // den Hauptthread.
                let budget = remainingAttachmentBudget(forModel: modelID)
                let strict = app.settings.strictFilter
                let outcome = await Task.detached(priority: .userInitiated) { () -> ImportResult in
                    // Bilder gehen einen eigenen Weg: sie werden verkleinert
                    // statt ausgelesen, und gekürzt werden können sie nicht.
                    if ImageAttachmentCoder.isImage(url) {
                        return Self.importImage(budget: budget) {
                            try ImageAttachmentCoder.prepare(url: url)
                        }
                    }
                    do {
                        let extraction = try FileTextExtractor.extract(from: url)

                        // Der Inhaltsfilter, **hier** und nicht beim Senden.
                        //
                        // Was in einer Datei steht, geht genauso an den
                        // Anbieter wie Getipptes und muss deshalb durch
                        // dieselbe Prüfung (Richtlinie 1.2). Der richtige
                        // Zeitpunkt ist dieser: einmal je Datei, abseits des
                        // Hauptthreads, mit einer Meldung, die den Dateinamen
                        // nennt. Bei jedem Senden erneut über
                        // hunderttausende Zeichen zu laufen, hiesse die
                        // Oberfläche jedes Mal für eine Sekunde anzuhalten.
                        let verdict = ContentModeration.screenInput(extraction.text, strict: strict)
                        if verdict.isBlocked {
                            return .failed(verdict.explanation)
                        }

                        let tokens = TokenEstimator.estimate(extraction.text)
                        if tokens > budget {
                            return .tooBig(extraction, tokens: tokens, budget: budget)
                        }
                        guard let attachment = AttachmentStore.make(from: extraction,
                                                                    byteLimit: nil) else {
                            return .failed(Loc.tr("Der Text der Datei konnte nicht gespeichert werden. Bitte entsperre das Gerät und versuche es erneut."))
                        }
                        return .ok(attachment)
                    } catch {
                        return .failed((error as? LocalizedError)?.errorDescription
                                       ?? error.localizedDescription)
                    }
                }.value

                switch outcome {
                case .ok(let attachment):
                    pendingAttachments.append(attachment)
                case .failed(let message):
                    problems.append(Loc.tr("%@: %@", url.lastPathComponent, message))
                case .tooBig(let extraction, let tokens, let budget):
                    // Die **erste** zu grosse Datei bekommt den Dialog. Alles
                    // Weitere geht in die Sammelmeldung – sonst stapelten sich
                    // Dialoge, und SwiftUI zeigte am Ende nur einen davon.
                    if pendingDialog == nil {
                        pendingDialog = OversizedFile(extraction: extraction,
                                                      tokens: tokens,
                                                      limit: budget)
                    } else {
                        problems.append(Loc.tr("%@: zu groß für dieses Modell – nicht angehängt.",
                                               extraction.fileName))
                    }
                }
            }

            isAttaching = false

            // Reihenfolge: erst der Dialog, der eine Entscheidung braucht;
            // die Sammelmeldung wartet, bis er weg ist.
            if let pendingDialog {
                deferredError = problems.isEmpty ? nil : problems.joined(separator: "\n\n")
                oversized = pendingDialog
            } else if !problems.isEmpty {
                attachmentError = problems.joined(separator: "\n\n")
            }
        }
    }

    /// Bilder aus der Fotomediathek anhängen.
    ///
    /// `PhotosPicker` läuft ausserhalb der App: die Auswahl trifft der Nutzer
    /// in einem eigenen Prozess, herüber kommt nur das Ergebnis. Deshalb
    /// braucht dieser Weg **keine** Fotoberechtigung – die App sieht nichts
    /// ausser dem, was der Nutzer ihr ausdrücklich gibt. Genau darum fragt
    /// ByoKey nie nach Zugriff auf die Mediathek.
    private func importPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        let modelID = effectiveModelID
        isAttaching = true

        Task {
            var problems: [String] = []
            // Fortlaufend nummerieren: die Mediathek liefert keinen
            // Dateinamen mit, und drei Anhänge namens „Bild.jpg" wären in der
            // Kachelleiste nicht auseinanderzuhalten.
            var number = pendingAttachments.filter { $0.kind.isImage }.count

            for item in items {
                number += 1
                let name = Loc.tr("Foto %lld", number)
                // Frisch je Bild: das vorige hat gerade selbst Platz belegt.
                let budget = remainingAttachmentBudget(forModel: modelID)

                let data = try? await item.loadTransferable(type: Data.self)
                guard let data else {
                    problems.append(Loc.tr("%@: %@", name,
                                           Loc.tr("Dieses Bild ließ sich nicht laden. Liegt es in iCloud, warte, bis es geladen ist.")))
                    continue
                }

                let outcome = await Task.detached(priority: .userInitiated) { () -> ImportResult in
                    Self.importImage(budget: budget) {
                        try ImageAttachmentCoder.prepare(data: data, fileName: name)
                    }
                }.value

                switch outcome {
                case .ok(let attachment):
                    pendingAttachments.append(attachment)
                case .failed(let message):
                    problems.append(Loc.tr("%@: %@", name, message))
                case .tooBig:
                    // Kommt hier nicht vor: `importImage` meldet ein zu
                    // grosses Bild als Fehlschlag, weil es nichts zu kürzen
                    // gibt. Der Fall steht trotzdem da, damit ein späteres
                    // Umbauen von `ImportResult` hier auffällt.
                    problems.append(Loc.tr("%@: %@", name,
                                           Loc.tr("Für dieses Bild ist im Kontextfenster kein Platz mehr.")))
                }
            }

            isAttaching = false
            if !problems.isEmpty {
                attachmentError = problems.joined(separator: "\n\n")
            }
        }
    }

    /// Aus einem Bild einen Anhang machen – oder sagen, warum nicht.
    ///
    /// Ausdrücklich **ohne** `ContentModeration`: der Filter dieser App liest
    /// Text. Was auf einem Bild zu sehen ist, kann er nicht beurteilen. So zu
    /// tun, als prüfe er es, wäre schlimmer, als es offen zu sagen – deshalb
    /// steht es auch in den Hinweisen zur Prüfung und in der
    /// Datenschutzerklärung. Für Bildinhalte greifen die Prüfung des
    /// Anbieters und die Melde- und Sperrfunktion in der App.
    ///
    /// Der Abschluss statt zweier fast gleicher Funktionen: Fotomediathek und
    /// Dateien-App unterscheiden sich nur darin, woher die Bytes kommen.
    private nonisolated static func importImage(
        budget: Int,
        prepare: () throws -> ImageAttachmentCoder.Prepared
    ) -> ImportResult {
        do {
            let prepared = try prepare()
            let tokens = ImageAttachmentCoder.tokenEstimate(width: prepared.width,
                                                            height: prepared.height)
            // Ein Bild lässt sich nicht kürzen – ein halbes Bild ist kein
            // Bild. Passt es nicht, hilft nur ein anderes Modell oder ein
            // abgeschalteter Anhang. Deshalb hier kein Dialog mit Angebot,
            // sondern eine klare Auskunft.
            guard tokens <= budget else {
                return .failed(Loc.tr("Das Bild braucht rund %@ Tokens, frei sind noch %@. Schalte einen Anhang ab oder wähle ein Modell mit größerem Kontext.",
                                      CostFormat.tokens(tokens),
                                      CostFormat.tokens(budget)))
            }
            guard let attachment = AttachmentStore.make(from: prepared) else {
                return .failed(Loc.tr("Das Bild konnte nicht gespeichert werden. Bitte entsperre das Gerät und versuche es erneut."))
            }
            return .ok(attachment)
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription
                           ?? error.localizedDescription)
        }
    }

    private func attachTruncated(_ file: OversizedFile) {
        // Das Budget **frisch** holen und nicht `file.limit` benutzen: seit
        // dem Öffnen des Dialogs können weitere Dateien desselben
        // Auswahlvorgangs angehängt worden sein.
        let budget = remainingAttachmentBudget(forModel: effectiveModelID)
        guard budget > 0 else {
            attachmentError = Loc.tr("Für diesen Anhang ist im Kontextfenster kein Platz mehr. Schalte einen anderen Anhang ab oder wähle ein Modell mit größerem Kontext.")
            return
        }
        // Vier **Bytes** je Token – genau die Faustregel, mit der
        // `TokenEstimator` rechnet. Nach Zeichen zu kürzen ginge bei
        // japanischem Text oder Emoji um ein Vielfaches daneben.
        appendMade(from: file.extraction, byteLimit: budget * 4)
    }

    /// Prüft eine bereits ausgelesene Datei gegen ein (neues) Budget.
    private func evaluate(_ extraction: FileTextExtractor.Extraction, limit: Int) {
        let tokens = TokenEstimator.estimate(extraction.text)
        if tokens > limit {
            oversized = OversizedFile(extraction: extraction, tokens: tokens, limit: limit)
        } else {
            appendMade(from: extraction, byteLimit: nil)
        }
    }

    private func appendMade(from extraction: FileTextExtractor.Extraction, byteLimit: Int?) {
        // Auch dieser Weg sperrt das Senden, solange gekürzt und geschrieben
        // wird. Ohne das liesse sich in genau dieser Sekunde eine Nachricht
        // abschicken – ohne den Anhang, den der Nutzer gerade bestätigt hat,
        // und mit einer Datei, die als Waise liegen bliebe.
        isAttaching = true
        Task {
            let made = await Task.detached(priority: .userInitiated) {
                AttachmentStore.make(from: extraction, byteLimit: byteLimit)
            }.value
            isAttaching = false
            guard let made else {
                attachmentError = Loc.tr("Der Text der Datei konnte nicht gespeichert werden. Bitte entsperre das Gerät und versuche es erneut.")
                return
            }
            pendingAttachments.append(made)
        }
    }

    private func removePending(_ id: UUID) {
        guard let index = pendingAttachments.firstIndex(where: { $0.id == id }) else { return }
        // Der ausgelesene Text gehört mit weg – sonst bliebe er im
        // Anhangsordner liegen, bis der nächste Start ihn aufräumt.
        AttachmentStore.delete(pendingAttachments[index].storedFileName)
        pendingAttachments.remove(at: index)
    }

    private var attachmentErrorBinding: Binding<Bool> {
        Binding(get: { attachmentError != nil },
                set: { if !$0 { attachmentError = nil } })
    }

    private var oversizedBinding: Binding<Bool> {
        Binding(get: { oversized != nil },
                set: { if !$0 { oversized = nil } })
    }

    /// Ist der Weg für eine Meldung frei?
    ///
    /// Alert, Dialog und Blatt hängen an derselben Ansicht und schliessen
    /// einander aus: zeigt SwiftUI eines davon, fällt ein gleichzeitig
    /// angefordertes zweites ersatzlos aus. Deshalb wird die zurückgestellte
    /// Meldung nicht nach einer abgewarteten Zeitspanne gezeigt – das wäre
    /// eine Wette –, sondern genau dann, wenn dieser Wert wahr wird.
    private var canShowNotice: Bool {
        oversized == nil && !showModelPicker && attachmentError == nil
    }

    private var imageHint: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "photo.badge.exclamationmark")
                .foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 4) {
                Text("Dieses Modell erzeugt keine Bilder.")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Es antwortet mit Text – und behauptet dabei manchmal, ein Bild erstellt zu haben. Wähle ein Modell mit der Kennzeichnung „Bild“.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Bildmodell wählen") { showModelPicker = true }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .background(Theme.surfaceAlt)
    }

    // MARK: - Hinweis auf Anhänge, die das Modell nicht verwerten kann

    /// Was an den Anhängen zum gewählten Modell nicht passt. `nil` heisst: passt.
    private enum AttachmentProblem {
        /// Das Modell nimmt laut Anbieterliste ausdrücklich keine Bilder an.
        case modelRejectsImages
        /// Bildmodell gewählt, aber der Anbieter kennt keine Vorlagen.
        case providerIgnoresReferences(String)
        /// Bildmodell gewählt, während Dokumente angehängt sind: an den
        /// Bild-Endpunkt geht nur der Prompt, kein Dateitext.
        case documentsIgnored
    }

    /// Bei `acceptsImages == nil` wird **nicht** gewarnt: nur OpenRouter
    /// liefert die Modalitäten mit der Modell-Liste. Bei den übrigen Anbietern
    /// hiesse eine Warnung raten – und eine geratene Warnung, die dreimal
    /// danebenliegt, wird beim vierten Mal überlesen.
    ///
    /// Zuerst das Modell nachschlagen, erst danach die Anhänge durchgehen –
    /// dieser Wert wird bei **jedem** Bildaufbau geholt, während einer
    /// laufenden Antwort also rund zwanzigmal pro Sekunde. Beide Schritte sind
    /// lineare Durchläufe; entscheidend ist, dass in aller Regel nur der erste
    /// stattfindet: bei einem Textmodell, das Bilder versteht oder über dessen
    /// Modalitäten nichts bekannt ist, endet die Prüfung sofort, und der
    /// Verlauf wird gar nicht angefasst.
    private var attachmentProblem: AttachmentProblem? {
        let model = app.model(id: effectiveModelID)
        if model?.isImageModel == true {
            // Nur der Entwurf, **nicht** der Verlauf: als Vorlage geht allein
            // mit, was an der gerade abgeschickten Nachricht hängt
            // (`AppState.send` → `imageDataURLs(for: userMessage)`). Ein Bild
            // von vor drei Nachrichten erreicht den Bild-Endpunkt nie – vor
            // dessen Ablehnung zu warnen hiesse, einen Fehlschlag anzukündigen,
            // der nicht eintritt.
            if !app.activeProvider.supportsImageReferences,
               pendingAttachments.contains(where: { $0.kind.isImage }) {
                return .providerIgnoresReferences(app.activeProvider.displayName)
            }
            return hasActiveAttachment(images: false) ? .documentsIgnored : nil
        }
        guard model?.acceptsImages == false, hasActiveAttachment(images: true) else { return nil }
        return .modelRejectsImages
    }

    /// Liegt ein zugeschalteter Anhang der gesuchten Art vor – im Entwurf oder
    /// im Verlauf?
    ///
    /// Der Verlauf gehört dazu: bei einer Folgefrage ist `pendingAttachments`
    /// leer, das Bild von vorhin geht aber weiter mit. Ohne diesen Teil wäre
    /// die Warnung genau dann verschwunden, wenn sie am nötigsten ist –
    /// nämlich nach einem Modellwechsel.
    private func hasActiveAttachment(images: Bool) -> Bool {
        if pendingAttachments.contains(where: { $0.kind.isImage == images }) { return true }
        guard let conversation else { return false }
        // Dieselbe Vorauswahl wie in `AppState.buildTurns`: markierte und
        // fehlerhafte Nachrichten fallen dort aus dem Kontext, ihre Anhänge
        // also auch. Vor einem Bild zu warnen, das das Modell nie zu sehen
        // bekommt, wäre eine Warnung ohne Anlass.
        for message in conversation.messages where !message.isFlagged && !message.isError {
            for attachment in message.attachments
            where attachment.isActive && attachment.kind.isImage == images {
                return true
            }
        }
        return false
    }

    @ViewBuilder
    private var attachmentProblemHint: some View {
        if let problem = attachmentProblem {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "photo.badge.exclamationmark")
                    .foregroundStyle(Theme.warning)
                VStack(alignment: .leading, spacing: 4) {
                    switch problem {
                    case .modelRejectsImages:
                        Text("Dieses Modell kann keine Bilder ansehen.")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Laut Modell-Liste des Anbieters nimmt es nur Text entgegen – die Anfrage würde mit einer Fehlermeldung abgelehnt. Wähle ein Modell, das Bilder versteht, oder entferne das Bild.")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Anderes Modell wählen") { showModelPicker = true }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.top, 2)
                    case .providerIgnoresReferences(let name):
                        Text("Dieser Anbieter nimmt keine Vorlagenbilder an.")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(verbatim: Loc.tr("%@ kennt beim Erzeugen von Bildern keine eigenen Vorlagen. Die Anfrage würde abgelehnt. Entferne das Bild – oder wechsle in den Einstellungen zu einem Anbieter, der Vorlagen unterstützt.", name))
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    case .documentsIgnored:
                        Text("Angehängte Dokumente gehen an ein Bildmodell nicht mit.")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Ein Bildmodell bekommt nur den Prompt und, wo möglich, Vorlagenbilder – der ausgelesene Text von PDF, Textdateien und Quelltext bleibt hier. Wähle ein Textmodell, wenn die KI die Datei lesen soll.")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Anderes Modell wählen") { showModelPicker = true }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
            .background(Theme.surfaceAlt)
        }
    }

    /// Schliesst die Tastatur, ohne dass der Fokus aus dem Eingabefeld
    /// heraus bekannt sein muss. `@FocusState` liegt in `ComposerView` und
    /// wäre von hier aus nur über eine zusätzliche Bindung erreichbar.
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }

    /// Seite, auf der der Sprung-Knopf sitzt. `Alignment` gehört zu SwiftUI,
    /// deshalb liegt die Zuordnung hier und nicht im Datenmodell.
    private var scrollButtonAlignment: Alignment {
        switch app.settings.scrollButtonPosition {
        case .leading:  return .leading
        case .center:   return .center
        case .trailing: return .trailing
        }
    }

    /// Springt ans Ende des Verlaufs. Erscheint nur, wenn dort etwas zu
    /// holen ist – ein Knopf, der immer sichtbar ist, verdeckt bloss die
    /// letzte Antwort.
    private func scrollToBottomButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 40, height: 40)
                .background(Theme.surface, in: Circle())
                .overlay { Circle().strokeBorder(Theme.border, lineWidth: 1) }
                .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
                // Sichtbar bleiben 40 Punkte, treffbar sind 44 – die
                // Mindestgrösse, die Apple für Bedienelemente nennt. Der
                // Unterschied fällt am Rand des Kreises auf, wo bisher jeder
                // zweite Tipp danebenging.
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // Beidseitig, damit derselbe Knopf links wie rechts denselben
        // Abstand zur Kante hat.
        .padding(.horizontal, Theme.gutter)
        .padding(.bottom, 14)
        .transition(.scale(scale: 0.8).combined(with: .opacity))
        .accessibilityLabel("Zum Ende springen")
    }

    // MARK: - Hinweiskarten

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Noch nicht startklar", systemImage: "wrench.and.screwdriver")
                .font(.subheadline.bold())
                .foregroundStyle(Theme.textPrimary)

            VStack(alignment: .leading, spacing: 8) {
                // Bewusst **ohne** Anbieternamen. Hier steht der Nutzer noch
                // ganz am Anfang und hat nichts eingerichtet – „API-Schlüssel
                // für OpenRouter hinterlegen" liest sich dann wie eine
                // Vorschrift, obwohl neun Anbieter zur Wahl stehen und
                // OpenRouter nur die Voreinstellung ist. Wer den Anbieter
                // gewählt hat, sieht seinen Namen an den Stellen, an denen es
                // darauf ankommt: im Zustimmungsdialog und in den
                // Einstellungen.
                checklistRow(done: app.hasAPIKey,
                             text: "API-Schlüssel für deinen Anbieter hinterlegen",
                             plain: Loc.tr("API-Schlüssel für deinen Anbieter hinterlegen"))
                checklistRow(done: app.hasConsentForActiveProvider,
                             text: "Datenweitergabe an deinen Anbieter freigeben",
                             plain: Loc.tr("Datenweitergabe an deinen Anbieter freigeben"))
            }

            Button {
                showSettings = true
            } label: {
                Text("Einstellungen öffnen")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .card(tint: Theme.accentSoft)
    }

    /// `text` ist ein `LocalizedStringKey`, damit die Interpolation an der
    /// Aufrufstelle als Platzhalter im Katalog landet. VoiceOver braucht
    /// daneben einen fertigen `String` – dafür `plain`.
    private func checklistRow(done: Bool,
                              text: LocalizedStringKey,
                              plain: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Theme.success : Theme.textSecondary)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.textPrimary)
                .strikethrough(done, color: Theme.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(done ? Loc.tr("Erledigt: %@", plain)
                                 : Loc.tr("Offen: %@", plain))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(greeting)
                .font(.title2.bold())
                .foregroundStyle(Theme.textPrimary)

            if let project = app.project(id: conversation?.projectID),
               !project.systemPrompt.isEmpty {
                Label("Projekt-Prompt aktiv: \(project.name)", systemImage: "text.badge.checkmark")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            if let model = activeModel {
                HStack(spacing: 8) {
                    // `String + String` ergäbe einen `String` und damit die
                    // Überladung, die nichts nachschlägt. Als Literal mit
                    // Interpolation greift der Katalog.
                    priceText(perMillion: model.promptPricePerMillion) + Text(" ein")
                    Text("·")
                    priceText(perMillion: model.completionPricePerMillion) + Text(" aus")
                    if let context = CostFormat.contextTokens(model.contextLength) {
                        Text("·")
                        Text("\(context) Kontext")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 20)
    }

    private var greeting: LocalizedStringKey {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<11: return "Guten Morgen. Womit fangen wir an?"
        case 11..<18: return "Womit kann ich helfen?"
        default: return "Guten Abend. Woran arbeitest du?"
        }
    }

    private var placeholder: LocalizedStringKey {
        if !app.hasAPIKey { return "Zuerst API-Schlüssel hinterlegen …" }
        if !app.hasConsentForActiveProvider { return "Zuerst Datenweitergabe freigeben …" }
        guard let name = activeModel?.name else { return "Nachricht an das Modell …" }
        return "Nachricht an \(name) …"
    }
}
