//
//  SpeechService.swift
//  ByoKey
//
//  Sprechen und Zuhören. Zwei Wege, die sich bewusst unterscheiden:
//
//  ┌───────────────┬──────────────────────────┬───────────────────────────────┐
//  │               │ Auf dem Gerät           │ Über den Anbieter            │
//  ├───────────────┼──────────────────────────┼───────────────────────────────┤
//  │ Erkennung     │ SFSpeechRecognizer,      │ Aufnahme als m4a an           │
//  │               │ möglichst on-device     │ /audio/transcriptions         │
//  │ Ausgabe       │ AVSpeechSynthesizer      │ /audio/speech, MP3 abspielen  │
//  │ Kosten        │ keine                    │ nach Anbieterpreis            │
//  │ Aufnahme      │ verlässt das Gerät nie │ wird übertragen              │
//  │ Modelle       │ jedes Chat-Modell        │ nur Modelle mit Audio         │
//  └───────────────┴──────────────────────────┴───────────────────────────────┘
//
//  WICHTIG für die Erwartungshaltung: Ein Chat-Modell wie Claude oder
//  Gemini kann selbst weder hören noch sprechen. Der Sprachmodus setzt
//  Erkennung und Ausgabe DAVOR und DAHINTER – das Modell bekommt weiterhin
//  nur Text. Für den Weg über den Anbieter braucht es deshalb zwei
//  zusätzliche, eigene Modelle, und nicht jeder Anbieter hat sie.
//
//  Datenschutz: Im Geräte-Modus wird `requiresOnDeviceRecognition` gesetzt,
//  solange die Sprache das hergibt. Ist sie es nicht, würde Apple die Aufnahme
//  auf eigene Server schicken – das passiert nur nach ausdrücklicher Freigabe
//  in den Einstellungen (Richtlinie 5.1.2(i)).
//

import Foundation
import AVFoundation
import Speech
import Observation

@MainActor
@Observable
final class SpeechService {

    enum Phase: Equatable {
        case idle
        case preparing
        case listening
        case transcribing
        case speaking
    }

    enum PermissionState: Equatable {
        case unknown
        case granted
        case deniedMicrophone
        case deniedRecognition
    }

    // MARK: - Zustand

    private(set) var phase: Phase = .idle
    /// Was gerade erkannt wurde. Im Geräte-Modus wächst der Text live mit.
    private(set) var transcript = ""
    /// 0…1 für die Pegelanzeige.
    private(set) var level: Double = 0
    private(set) var errorMessage: String?
    private(set) var permission: PermissionState = .unknown
    /// Summe der Anbieterkosten für Spracherkennung in dieser Sitzung.
    private(set) var speechCostUSD: Double = 0

    /// Zählt Aufnahme- und Ausgabevorgänge. Bricht der Nutzer ab, während eine
    /// Anfrage beim Anbieter läuft, kommt die Antwort trotzdem an – ohne diesen
    /// Zähler würde sie danach abgespielt bzw. weiterverarbeitet, obwohl der
    /// Nutzer „Stopp" gedrückt hat.
    private var runGeneration = 0

    /// Wird von „Alle Daten löschen" gerufen. Ohne diesen Rücksetzer stünde im
    /// Sprachmodus weiterhin ein Betrag, obwohl es nichts mehr gibt, wozu er
    /// gehört.
    func resetCosts() {
        speechCostUSD = 0
    }

    var isBusy: Bool { phase != .idle }

    // MARK: - Innereien

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var silenceTimer: Timer?
    private var lastTranscriptChange = Date()

    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private let delegates = SpeechDelegates()
    /// Welche Ausgabe gerade läuft. Ein Abbruch stellt seinen Rückruf
    /// verzögert zu – ohne diesen Vergleich würde er die bereits gestartete
    /// NAECHSTE Ausgabe beenden.
    private var currentUtterance: AVSpeechUtterance?

    /// Wird aufgerufen, wenn eine Sprachausgabe regulär zu Ende ist.
    /// Der Gesprächsmodus hängt daran das erneute Zuhören.
    var onSpeechFinished: (() -> Void)?

    init() {
        synthesizer.delegate = delegates
        delegates.speechDidFinish = { [weak self] utterance in
            Task { @MainActor in self?.handleSpeechFinished(utterance: utterance) }
        }
        delegates.playbackDidFinish = { [weak self] in
            Task { @MainActor in self?.handleSpeechFinished(utterance: nil) }
        }
    }

    // MARK: - Verfügbarkeit

    /// Kann die Erkennung für diese Sprache ohne Server laufen?
    func supportsOnDeviceRecognition(language: String) -> Bool {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)) else {
            return false
        }
        return recognizer.supportsOnDeviceRecognition
    }

    func isRecognitionAvailable(language: String) -> Bool {
        SFSpeechRecognizer(locale: Locale(identifier: language))?.isAvailable ?? false
    }

    /// Stimmen, die das Gerät für diese Sprache anbietet.
    ///
    /// Bewusst ohne fest eingebaute Kennungen: die Liste kommt vom System und
    /// enthält genau das, was auf **diesem** Gerät installiert ist – je nach
    /// Nachladen in den iOS-Einstellungen auch Stimmen in Premium-Qualität.
    /// Siri-Stimmen gibt Apple Fremd-Apps nicht frei; taucht auf einem Gerät
    /// doch eine auf, steht sie hier ganz normal mit drin, ohne dass die App
    /// sich auf ihr Vorhandensein verlässt.
    static func deviceVoices(language: String) -> [AVSpeechSynthesisVoice] {
        let prefix = String(language.prefix(2)).lowercased()
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix(prefix) }
            .sorted { lhs, rhs in
                // Beste Qualität zuerst, danach alphabetisch.
                if lhs.quality.rawValue != rhs.quality.rawValue {
                    return lhs.quality.rawValue > rhs.quality.rawValue
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    /// Persönliche Stimme (iOS 17+): der Nutzer nimmt sie in den
    /// Bedienungshilfen auf, Fremd-Apps brauchen dafür eine eigene Freigabe.
    /// Ohne diesen Aufruf liefert `speechVoices()` sie nicht mit.
    static func requestPersonalVoiceAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVSpeechSynthesizer.requestPersonalVoiceAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    static var hasPersonalVoice: Bool {
        AVSpeechSynthesisVoice.speechVoices().contains { $0.voiceTraits.contains(.isPersonalVoice) }
    }

    /// Kurze Hörprobe für die Stimmenauswahl. Läuft nur über das Gerät –
    /// eine Probe beim Anbieter wäre kostenpflichtig, und niemand rechnet
    /// damit, dass Durchhören Geld kostet.
    func previewDeviceVoice(identifier: String, language: String) {
        stopSpeaking()
        do { try configureSession(forRecording: false) } catch { }

        let sample = Self.previewSentence(for: language)
        let utterance = AVSpeechUtterance(string: sample)
        utterance.voice = AVSpeechSynthesisVoice(identifier: identifier)
            ?? AVSpeechSynthesisVoice(language: language)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        phase = .speaking
        currentUtterance = utterance
        synthesizer.speak(utterance)
    }

    private static func previewSentence(for language: String) -> String {
        switch String(language.prefix(2)).lowercased() {
        case "en": return "Hello, this is how I sound. Ask me anything."
        case "fr": return "Bonjour, voici ma voix. Posez-moi une question."
        case "es": return "Hola, asi suena mi voz. Preguntame lo que quieras."
        case "it": return "Ciao, questa e la mia voce. Chiedimi pure."
        case "nl": return "Hallo, zo klink ik. Stel gerust een vraag."
        case "pl": return "Czesc, tak brzmi moj glos. Zapytaj mnie o cos."
        case "pt": return "Ola, esta e a minha voz. Pergunte o que quiser."
        case "tr": return "Merhaba, sesim boyle. Bana bir sey sor."
        default:   return "Hallo, so klinge ich. Frag mich einfach etwas."
        }
    }

    // MARK: - Berechtigungen

    /// Fragt Mikrofon und – nur im Geräte-Modus – Spracherkennung ab.
    /// Die Erkennung wird bewusst nicht angefragt, wenn sie nicht gebraucht
    /// wird: jede unnötige Abfrage ist eine Rücktrittsmöglichkeit für den
    /// Nutzer und eine Frage mehr bei der App-Prüfung.
    @discardableResult
    func requestPermissions(needsRecognition: Bool) async -> Bool {
        let micGranted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        guard micGranted else {
            permission = .deniedMicrophone
            errorMessage = "Ohne Mikrofonzugriff kann ByoKey nicht zuhören. Du kannst ihn in den Systemeinstellungen freigeben."
            return false
        }

        guard needsRecognition else {
            permission = .granted
            return true
        }

        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard status == .authorized else {
            permission = .deniedRecognition
            errorMessage = "Die Spracherkennung ist nicht freigegeben. Du kannst sie in den Systemeinstellungen erlauben."
            return false
        }

        permission = .granted
        return true
    }

    // MARK: - Zuhören

    func startListening(engine: VoiceEngine,
                        language: String,
                        allowServerRecognition: Bool) async {
        guard phase == .idle else { return }
        errorMessage = nil
        transcript = ""
        phase = .preparing

        guard await requestPermissions(needsRecognition: engine == .device) else {
            phase = .idle
            return
        }

        do {
            try configureSession(forRecording: true)
            switch engine {
            case .device:
                try startDeviceRecognition(language: language,
                                           allowServerRecognition: allowServerRecognition)
            case .provider:
                try startRecording()
            }
            lastTranscriptChange = Date()
            phase = .listening
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await teardownCapture()
            phase = .idle
        }
    }

    /// Beendet die Aufnahme und liefert den erkannten Text.
    /// Im Anbieter-Modus wird dafür die Aufnahme hochgeladen.
    func stopListening(engine: VoiceEngine,
                       language: String,
                       provider: (any AIProviderProtocol)?,
                       apiKey: String?,
                       modelID: String) async -> String? {
        guard phase == .listening || phase == .preparing else { return nil }

        switch engine {
        case .device:
            let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            await teardownCapture()
            phase = .idle
            return text.isEmpty ? nil : text

        case .provider:
            phase = .transcribing
            recorder?.stop()
            let url = recorder?.url
            recorder = nil
            stopTimers()

            // Sofort löschen, nicht verzögert: die Zustimmung sagt zu, dass
            // die Aufnahme nach dem Hochladen nicht mehr auf dem Gerät liegt.
            defer {
                if let url { try? FileManager.default.removeItem(at: url) }
            }

            guard let url, let provider, let apiKey else {
                phase = .idle
                errorMessage = "Für die Spracherkennung über den Anbieter fehlt der API-Schlüssel."
                return nil
            }
            guard let data = try? Data(contentsOf: url), data.count > 2_000 else {
                phase = .idle
                errorMessage = "Die Aufnahme war zu kurz."
                return nil
            }

            let generation = runGeneration
            do {
                let result = try await provider.transcribe(audio: data,
                                                           fileExtension: "m4a",
                                                           modelID: modelID,
                                                           language: language,
                                                           apiKey: apiKey)
                // Abbruch während des Hochladens: das Ergebnis wird verworfen,
                // damit der Widerruf der Freigabe hält, was er ankündigt.
                // **Nichts** am gemeinsamen Zustand anfassen: `phase` und die
                // Audio-Sitzung gehören inzwischen einem neueren Lauf. Wer hier
                // `deactivateSession()` ruft, legt dessen frische Aufnahme
                // still.
                // Die Kosten sind auch dann angefallen, wenn der Nutzer
                // inzwischen abgebrochen hat – der Anbieter hat die Anfrage
                // bereits abgerechnet. Sie gehören zur Sitzung, nicht zum Lauf.
                if let cost = result.costUSD, cost.isFinite { speechCostUSD += cost }
                guard generation == runGeneration else { return nil }
                transcript = result.text
                phase = .idle
                try? deactivateSession()
                return result.text
            } catch {
                // Auch ein **gescheiterter** veralteter Lauf darf nichts
                // anfassen: eine Zeitüberschreitung, die nach dem Neustart
                // eintrudelt, legte sonst die frische Aufnahme still.
                guard generation == runGeneration else { return nil }
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                phase = .idle
                try? deactivateSession()
                return nil
            }
        }
    }

    func cancelListening() async {
        runGeneration &+= 1
        await teardownCapture()
        transcript = ""
        phase = .idle
    }

    // MARK: - Sprechen

    func speak(text: String,
               engine: VoiceEngine,
               language: String,
               voiceIdentifier: String,
               provider: (any AIProviderProtocol)?,
               apiKey: String?,
               modelID: String) async {
        let clean = SpeechService.plainText(from: text)
        guard !clean.isEmpty else {
            onSpeechFinished?()
            return
        }

        stopSpeaking()
        phase = .speaking

        switch engine {
        case .device:
            do { try configureSession(forRecording: false) } catch { }
            let utterance = AVSpeechUtterance(string: clean)
            utterance.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)
                ?? AVSpeechSynthesisVoice(language: language)
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            utterance.postUtteranceDelay = 0.1
            currentUtterance = utterance
            synthesizer.speak(utterance)

        case .provider:
            guard let provider, let apiKey else {
                errorMessage = "Für die Sprachausgabe über den Anbieter fehlt der API-Schlüssel."
                phase = .idle
                return
            }
            let generation = runGeneration
            do {
                let audio = try await provider.synthesize(text: clean,
                                                          modelID: modelID,
                                                          voice: voiceIdentifier,
                                                          apiKey: apiKey)
                // Wurde inzwischen gestoppt oder die Freigabe widerrufen, darf
                // nichts mehr abgespielt werden – und schon gar nicht die
                // Audio-Sitzung mitten in einer neuen Aufnahme umgestellt.
                // Siehe oben: `phase` steht womöglich schon auf `.listening`
                // eines neuen Laufs. Sie hier auf `.idle` zu setzen liesse den
                // „Fertig"-Knopf verschwinden, während noch aufgenommen wird.
                guard generation == runGeneration else { return }
                try configureSession(forRecording: false)
                let player = try AVAudioPlayer(data: audio)
                player.delegate = delegates
                self.player = player
                player.play()
            } catch {
                // Siehe oben. `onSpeechFinished` würde zusätzlich die
                // Vorlese-Markierung des neuen Laufs löschen.
                guard generation == runGeneration else { return }
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                phase = .idle
                onSpeechFinished?()
            }
        }
    }

    func stopSpeaking() {
        runGeneration &+= 1
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        currentUtterance = nil
        player?.stop()
        player = nil
        if phase == .speaking { phase = .idle }
    }

    private func handleSpeechFinished(utterance: AVSpeechUtterance?) {
        // Gehört der Rückruf noch zur laufenden Ausgabe?
        if let utterance, let current = currentUtterance, utterance !== current { return }
        currentUtterance = nil
        player = nil
        if phase == .speaking {
            phase = .idle
            // Sonst bleiben andere Apps gedämpft, bis das nächste Mal
            // aufgenommen wird.
            try? deactivateSession()
        }
        onSpeechFinished?()
    }

    /// Markdown taugt nicht zum Vorlesen: Sternchen, Rauten und Code-Zäune
    /// würden mitgesprochen. Code-Blöcke werden ganz weggelassen und nur
    /// angekündigt.
    static func plainText(from markdown: String) -> String {
        var result: [String] = []
        var insideCode = false
        var codeBlocks = 0

        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if !insideCode { codeBlocks += 1 }
                insideCode.toggle()
                continue
            }
            guard !insideCode else { continue }

            var text = trimmed
            while text.hasPrefix("#") { text.removeFirst() }
            if text.hasPrefix("> ") { text.removeFirst(2) }
            if text.hasPrefix("- ") || text.hasPrefix("* ") { text.removeFirst(2) }
            text = text
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "`", with: "")
                .replacingOccurrences(of: "|", with: " ")
                .trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { result.append(text) }
        }

        var spoken = result.joined(separator: " ")
        if codeBlocks > 0 {
            let suffix = codeBlocks == 1
                ? " Dazu kommt ein Code-Block, den du am besten liest."
                : " Dazu kommen \(codeBlocks) Code-Blöcke, die du am besten liest."
            spoken += suffix
        }
        // Sehr lange Antworten nicht komplett vorlesen.
        return String(spoken.prefix(4000))
    }

    // MARK: - Aufnahme (Geräte-Modus)

    private func startDeviceRecognition(language: String, allowServerRecognition: Bool) throws {
        let locale = Locale(identifier: language)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw SpeechError.recognizerUnavailable(language)
        }
        self.recognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        if recognizer.supportsOnDeviceRecognition {
            // Die Aufnahme verlässt das Gerät nicht.
            request.requiresOnDeviceRecognition = true
        } else if !allowServerRecognition {
            throw SpeechError.onDeviceUnavailable(language)
        }
        recognitionRequest = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let value = SpeechService.level(from: buffer)
            Task { @MainActor in self?.level = value }
        }

        audioEngine.prepare()
        try audioEngine.start()

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    if text != self.transcript {
                        self.transcript = text
                        self.lastTranscriptChange = Date()
                    }
                }
                if error != nil, self.phase == .listening {
                    // Ein Abbruch beim Beenden ist normal und keine Meldung wert.
                    if self.transcript.isEmpty {
                        self.errorMessage = "Es wurde nichts erkannt."
                    }
                }
            }
        }
    }

    // MARK: - Aufnahme (Anbieter-Modus)

    private func startRecording() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("byokey-voice", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("aufnahme-\(UUID().uuidString).m4a")

        // 16 kHz Mono AAC: für Sprache völlig ausreichend und klein genug,
        // dass der Upload auch im Mobilfunknetz zügig geht.
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        // Harte Obergrenze: ohne sie kann im Gesprächsmodus eine unbegrenzt
        // lange Aufnahme entstehen, die dann komplett hochgeladen wird.
        guard recorder.record(forDuration: 60) else { throw SpeechError.recordingFailed }
        self.recorder = recorder

        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder else { return }
                recorder.updateMeters()
                let decibel = Double(recorder.averagePower(forChannel: 0))
                self.level = min(max((decibel + 50) / 50, 0), 1)
            }
        }
    }

    // MARK: - Stille erkennen

    /// Startet die Überwachung auf Sprechpausen. Wird nur im Gesprächsmodus
    /// genutzt: dort soll das Zuhören von selbst enden.
    func beginSilenceDetection(after seconds: TimeInterval, onSilence: @escaping () -> Void) {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .listening else { return }
                guard !self.transcript.isEmpty else { return }
                if Date().timeIntervalSince(self.lastTranscriptChange) >= seconds {
                    self.silenceTimer?.invalidate()
                    self.silenceTimer = nil
                    onSilence()
                }
            }
        }
    }

    func endSilenceDetection() {
        silenceTimer?.invalidate()
        silenceTimer = nil
    }

    // MARK: - Aufräumen

    private func teardownCapture() async {
        recognitionTask?.cancel()
        recognitionTask = nil

        // Reihenfolge: erst den Tap abhängen, dann die Engine anhalten, und
        // **erst danach** `endAudio()`. Andersherum kann ein bereits laufender
        // Tap-Block noch `append(buffer)` auf eine Anfrage rufen, die schon
        // beendet ist – das ist laut Apple unzulässig.
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        if let recorder {
            recorder.stop()
            try? FileManager.default.removeItem(at: recorder.url)
        }
        recorder = nil

        stopTimers()
        level = 0
        try? deactivateSession()
    }

    private func stopTimers() {
        meterTimer?.invalidate()
        meterTimer = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
    }

    /// Entfernt alle noch liegenden Aufnahmen. Wird beim Verlassen des
    /// Sprachmodus und beim Löschen aller Daten gerufen.
    static func clearRecordings() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("byokey-voice", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Audio-Sitzung

    /// Aufnahme über ein Bluetooth-Headset (Hands-Free-Profil).
    ///
    /// Im SDK von iOS 26 wurde `allowBluetooth` in `allowBluetoothHFP`
    /// umbenannt – gleicher Rohwert (0x4), gleiche Wirkung, laut
    /// Verfügbarkeitsangabe bis iOS 1.0 zurück nutzbar. Der alte Name ist
    /// dort als ersetzt markiert und erzeugt eine Warnung; der neue Name
    /// existiert in älteren SDKs noch nicht. Die Abfrage auf die
    /// Übersetzer-Version hält den Quelltext deshalb für beide Xcode-Stände
    /// übersetzbar und warnungsfrei – Xcode 26 bringt Swift 6.2.
    private static var bluetoothOption: AVAudioSession.CategoryOptions {
        #if compiler(>=6.2)
        return .allowBluetoothHFP
        #else
        return .allowBluetooth
        #endif
    }

    private func configureSession(forRecording: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        if forRecording {
            // `.default` statt `.spokenAudio`: Apple kombiniert `.spokenAudio`
            // mit `.playback`, nicht mit `.playAndRecord`.
            try session.setCategory(.playAndRecord,
                                    mode: .default,
                                    options: [.duckOthers,
                                              .defaultToSpeaker,
                                              Self.bluetoothOption])
        } else {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        }
        try session.setActive(true, options: [])
    }

    private func deactivateSession() throws {
        try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - Pegel

    private nonisolated static func level(from buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }

        var sum: Float = 0
        for index in 0..<count {
            let sample = channel[index]
            sum += sample * sample
        }
        let rms = sqrtf(sum / Float(count))
        let decibel = 20 * log10f(max(rms, 1e-7))
        return Double(min(max((decibel + 50) / 50, 0), 1))
    }
}

// MARK: - Fehler

enum SpeechError: LocalizedError {
    case recognizerUnavailable(String)
    case onDeviceUnavailable(String)
    case recordingFailed

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable(let language):
            return Loc.tr("Für %@ ist auf diesem Gerät keine Spracherkennung verfügbar.", language)
        case .onDeviceUnavailable(let language):
            return Loc.tr("Für %@ gibt es keine Erkennung direkt auf dem Gerät. Du kannst in den Einstellungen Apples Server-Erkennung erlauben oder die Erkennung über deinen API-Anbieter laufen lassen.", language)
        case .recordingFailed:
            return Loc.tr("Die Aufnahme konnte nicht gestartet werden.")
        }
    }
}

// MARK: - Delegierte

/// Getrennte Klasse, damit `SpeechService` eine reine @Observable-Klasse
/// bleiben kann und nicht von NSObject erben muss.
private final class SpeechDelegates: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    var speechDidFinish: ((AVSpeechUtterance) -> Void)?
    var playbackDidFinish: (() -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        speechDidFinish?(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didCancel utterance: AVSpeechUtterance) {
        speechDidFinish?(utterance)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playbackDidFinish?()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        playbackDidFinish?()
    }
}
