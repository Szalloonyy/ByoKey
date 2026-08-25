//
//  VoiceModeView.swift
//  ByoKey
//
//  Vollbild-Sprachmodus. Der Ablauf ist der von Gemini oder dem
//  Sprachmodus in ChatGPT: zuhören, senden, vorlesen – und im
//  Gesprächsmodus von selbst wieder zuhören.
//
//  Der Text bleibt trotzdem sichtbar. Sprache ist praktisch beim Kochen oder
//  im Auto, aber eine reine Audio-Ausgabe wäre für einen Chat, in dem es um
//  Code und Kosten geht, die falsche Entscheidung.
//

import SwiftUI

struct VoiceModeView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var pendingText = ""
    @State private var didStartAnswer = false
    @State private var setupError: String?
    @State private var showInfo = false

    private var speech: SpeechService { app.speech }
    private var settings: AppSettings { app.settings }

    private var lastAnswer: String {
        app.selectedConversation?.messages.last { $0.role == .assistant }?.text ?? ""
    }

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                header
                Spacer(minLength: 12)
                orb
                statusLine
                Spacer(minLength: 12)
                transcriptArea
                controls
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .task {
            await begin()
        }
        .onDisappear {
            Task {
                await speech.cancelListening()
                speech.stopSpeaking()
                speech.endSilenceDetection()
                SpeechService.clearRecordings()
            }
        }
        .onChange(of: app.isStreaming) { wasStreaming, isStreaming in
            // Antwort ist fertig: vorlesen, sofern gewünscht.
            guard wasStreaming, !isStreaming, didStartAnswer else { return }
            didStartAnswer = false
            Task { await speakAnswerIfWanted() }
        }
        .onChange(of: speech.phase) { previous, current in
            // Im Gesprächsmodus nach dem Vorlesen von selbst weiterhören.
            // Über die beobachtbare Phase statt über einen Rückruf: den
            // hat bereits AppState belegt, zwei Empfänger wären einer zu viel.
            guard previous == .speaking, current == .idle,
                  settings.handsFree, !app.isStreaming else { return }
            Task { await listen() }
        }
        // Die Erklärung steht auch in den Einstellungen. Sie hier zu
        // wiederholen ist Absicht: die Frage „warum spricht mein Modell
        // nicht?" stellt sich genau an dieser Stelle, nicht zwei Menüs weiter.
        .sheet(isPresented: $showInfo) {
            NavigationStack {
                VoiceInfoView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Fertig") { showInfo = false }
                        }
                    }
            }
        }
    }

    // MARK: - Bausteine

    private var background: some View {
        LinearGradient(colors: [Theme.background, Theme.accentSoft.opacity(0.55)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }

    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Theme.surface, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Sprachmodus schließen")

            Spacer()

            Button {
                showInfo = true
            } label: {
                VStack(spacing: 2) {
                    HStack(spacing: 4) {
                        Text(LocalizedStringKey(settings.voiceEngine.label))
                            .font(.caption.weight(.medium))
                        Image(systemName: "info.circle")
                            .font(.caption2)
                    }
                    .foregroundStyle(Theme.textSecondary)

                    if let model = app.model(id: app.selectedConversation?.modelID) {
                        Text(model.name)
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Erklärung zu Sprache und Modellen")

            Spacer()

            Button {
                app.settings.handsFree.toggle()
                app.scheduleSave()
            } label: {
                Image(systemName: settings.handsFree ? "infinity.circle.fill" : "infinity.circle")
                    .font(.body)
                    .foregroundStyle(settings.handsFree ? Theme.accent : Theme.textSecondary)
                    .frame(width: 44, height: 44)
                    .background(Theme.surface, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(settings.handsFree
                                ? "Gesprächsmodus ausschalten"
                                : "Gesprächsmodus einschalten")
        }
        .padding(.top, 8)
    }

    private var orb: some View {
        let scale = reduceMotion ? 1.0 : 1.0 + speech.level * 0.35
        return ZStack {
            Circle()
                .fill(Theme.accent.opacity(0.16))
                .frame(width: 210, height: 210)
                .scaleEffect(scale)
                .blur(radius: 18)

            Circle()
                .fill(Theme.accent.opacity(0.28))
                .frame(width: 150, height: 150)
                .scaleEffect(reduceMotion ? 1.0 : 1.0 + speech.level * 0.2)

            Circle()
                .fill(Theme.accent)
                .frame(width: 96, height: 96)
                .overlay {
                    Image(systemName: orbSymbol)
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: speech.level)
        .accessibilityHidden(true)
    }

    private var orbSymbol: String {
        switch speech.phase {
        case .listening:              return "waveform"
        case .transcribing, .preparing: return "hourglass"
        case .speaking:               return "speaker.wave.3.fill"
        case .idle:                   return app.isStreaming ? "ellipsis" : "mic.fill"
        }
    }

    private var statusLine: some View {
        // `statusText` liefert den deutschen Schlüssel; hier wird daraus
        // der übersetzte Text. Meldungen mit eingesetztem Anbieternamen
        // kommen bereits übersetzt aus `Loc.tr` – der Schlüssel greift dann
        // ins Leere und der fertige Satz bleibt unverändert stehen, was
        // genau richtig ist.
        Text(LocalizedStringKey(statusText))
            .font(.headline)
            .foregroundStyle(Theme.textPrimary)
            .multilineTextAlignment(.center)
            .padding(.top, 22)
            .accessibilityLabel(Text(LocalizedStringKey(statusText)))
    }

    private var statusText: String {
        if let setupError { return setupError }
        if let error = speech.errorMessage { return error }
        if app.isStreaming { return "Antwort kommt …" }
        switch speech.phase {
        case .listening:    return "Ich höre zu"
        case .preparing:    return "Einen Moment …"
        case .transcribing: return "Wird erkannt …"
        case .speaking:     return "Antwort wird vorgelesen"
        case .idle:         return "Tippe auf Sprechen"
        }
    }

    private var transcriptArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !speech.transcript.isEmpty || !pendingText.isEmpty {
                    Text(speech.transcript.isEmpty ? pendingText : speech.transcript)
                        .font(.title3)
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !lastAnswer.isEmpty {
                    Text(lastAnswer)
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 8)
        }
        .frame(maxHeight: 210)
        .scrollIndicators(.hidden)
    }

    private var controls: some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                if speech.phase == .listening {
                    Button {
                        Task { await finishTurn() }
                    } label: {
                        Label("Fertig", systemImage: "checkmark")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                    }
                    .buttonStyle(.borderedProminent)

                } else if speech.phase == .speaking {
                    Button {
                        speech.stopSpeaking()
                    } label: {
                        Label("Stopp", systemImage: "stop.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                    }
                    .buttonStyle(.bordered)

                } else if app.isStreaming {
                    Button {
                        app.stopStreaming()
                    } label: {
                        Label("Antwort stoppen", systemImage: "stop.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                    }
                    .buttonStyle(.bordered)

                } else {
                    Button {
                        Task { await listen() }
                    } label: {
                        Label("Sprechen", systemImage: "mic.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if setupError != nil {
                Button {
                    showInfo = true
                } label: {
                    Label("Warum geht das nicht?", systemImage: "questionmark.circle")
                        .font(.footnote.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }

            HStack(spacing: 8) {
                Text("Chat: \(CostFormat.usd(app.selectedConversation?.totalCostUSD ?? 0))")
                if speech.speechCostUSD > 0 {
                    Text("·")
                    Text("Sprache: \(CostFormat.usd(speech.speechCostUSD))")
                }
                if settings.voiceEngine == .device {
                    Text("·")
                    Text("Sprache kostenlos")
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: - Ablauf

    /// Anbieterfähigkeit und Sprach-Freigabe. Muss VOR jeder Aufnahme laufen,
    /// nicht nur beim Öffnen: der Knopf „Sprechen“ ist auch dann erreichbar,
    /// wenn `begin()` bereits abgebrochen hat – sonst ließe sich die
    /// Zustimmung mit zwei Tippern umgehen (Richtlinie 5.1.2(i)).
    /// Welcher Baustein gebraucht wird – davon hängt ab, welche
    /// Modellkennung gesetzt sein muss.
    private enum VoiceStep { case listening, speaking }

    private func voiceGateOK(_ step: VoiceStep = .listening) -> Bool {
        guard app.isReadyToSend else {
            setupError = "Erst API-Schlüssel hinterlegen und Datenweitergabe freigeben."
            return false
        }
        guard settings.voiceEngine == .provider else { return true }
        guard app.activeProvider.supportsAudio else {
            setupError = Loc.tr("%@ bietet keine Sprach-Endpunkte. Stelle in den Einstellungen auf „Auf dem Gerät“ um.",
                                app.activeProvider.displayName)
            return false
        }
        guard app.consent.hasConsent(for: app.activeProvider.id, scope: .audio) else {
            setupError = Loc.tr("Die Freigabe für Sprachaufnahmen an %@ fehlt. Du kannst sie in den Einstellungen erteilen.",
                                app.activeProvider.displayName)
            return false
        }
        // Die Sprachmodelle heißen bei jedem Anbieter anders; für die meisten
        // steht deshalb keine Vorbelegung fest. Ohne diese Prüfung ginge eine
        // Anfrage mit leerer Modellkennung raus und der Nutzer sähe nur den
        // rohen HTTP-400 des Anbieters.
        let missing = step == .listening ? settings.sttModelID : settings.ttsModelID
        guard !missing.trimmingCharacters(in: .whitespaces).isEmpty else {
            setupError = step == .listening
                ? Loc.tr("Für %@ ist noch kein Erkennungsmodell eingetragen. Du findest das Feld unter Einstellungen › Sprachmodus.",
                         app.activeProvider.displayName)
                : Loc.tr("Für %@ ist noch kein Vorlesemodell eingetragen. Du findest das Feld unter Einstellungen › Sprachmodus.",
                         app.activeProvider.displayName)
            return false
        }
        return true
    }

    private func begin() async {
        guard voiceGateOK() else { return }
        await listen()
    }

    private func listen() async {
        guard voiceGateOK() else { return }
        setupError = nil
        await speech.startListening(engine: settings.voiceEngine,
                                    language: settings.voiceLanguage,
                                    allowServerRecognition: settings.allowServerSpeechRecognition)

        // Im Gesprächsmodus endet das Zuhören von selbst nach einer Pause.
        if settings.handsFree, settings.voiceEngine == .device {
            speech.beginSilenceDetection(after: 1.8) {
                Task { await finishTurn() }
            }
        }
    }

    private func finishTurn() async {
        speech.endSilenceDetection()

        let key = app.apiKey(for: app.activeProvider.id)
        let text = await speech.stopListening(engine: settings.voiceEngine,
                                              language: settings.voiceLanguage,
                                              provider: app.activeProvider,
                                              apiKey: key,
                                              modelID: settings.sttModelID)

        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pendingText = text
        didStartAnswer = app.send(text)
        if !didStartAnswer {
            // Die Meldung von AppState hängt an RootView – die liegt hinter
            // diesem Vollbild. Ohne diese Zeile verschwände der gesprochene
            // Satz kommentarlos.
            setupError = app.alertMessage ?? "Die Nachricht konnte nicht gesendet werden."
            app.alertMessage = nil
        }
    }

    private func speakAnswerIfWanted() async {
        guard settings.speakAnswers || settings.handsFree, voiceGateOK(.speaking) else { return }
        let answer = lastAnswer
        guard !answer.isEmpty else { return }

        await speech.speak(text: answer,
                           engine: settings.voiceEngine,
                           language: settings.voiceLanguage,
                           voiceIdentifier: settings.activeVoiceIdentifier,
                           provider: app.activeProvider,
                           apiKey: app.apiKey(for: app.activeProvider.id),
                           modelID: settings.ttsModelID)
    }
}
