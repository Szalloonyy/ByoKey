# ByoKey

Native iOS-App (SwiftUI) als „Bring Your Own Key"-Oberfläche für KI-Modelle.
Der Nutzer hinterlegt seinen eigenen API-Schlüssel – primär OpenRouter – und sieht bei
jeder Antwort, was sie gekostet hat.

- **Ziel:** iPhone + iPad, iOS 18.0+
- **Sprachen:** Deutsch, Englisch, Polnisch – umschaltbar in der App, ohne Neustart
- **Stack:** SwiftUI, Swift 5, Observation, URLSession. **Keine Fremdbibliotheken.**
- **Zustand:** Chats und Projekte als JSON im App-Container, Schlüssel in der Keychain
- **Kostenlos**, keine In-App-Käufe, kein Konto, kein Server des Entwicklers

## Loslegen

1. `ByoKey.xcodeproj` in Xcode 16 oder neuer öffnen.
2. Target „ByoKey" → Signing & Capabilities → dein Team wählen und
   `PRODUCT_BUNDLE_IDENTIFIER` von `de.byokey.app` auf deine eigene ID ändern.
3. Bauen und starten. Onboarding durchklicken, dann in den Einstellungen den
   OpenRouter-Schlüssel eintragen und die Datenfreigabe aktivieren.

Das Projekt nutzt **file system synchronized groups** (Xcode 16+): neue Dateien im Ordner
`ByoKey/` landen automatisch im Target, ohne dass die `project.pbxproj` angefasst werden muss.

Es übersetzt mit Xcode 16 **und** Xcode 26. Die einzige Stelle, die beide SDKs
unterscheiden muss, ist `SpeechService.bluetoothOption`: Apple hat
`AVAudioSession.CategoryOptions.allowBluetooth` im iOS-26-SDK in `allowBluetoothHFP`
umbenannt. Gelöst über `#if compiler(>=6.2)` – kein Verhaltensunterschied, beide Namen
stehen für denselben Rohwert.

## Aufbau

```
ByoKey.xcodeproj
Support/Info.plist            Bundle-Konfiguration, Exportbestimmung
ByoKey/
├── ByoKeyApp.swift           Einstiegspunkt
├── AppInfo.swift             Support-Adresse und Rechts-URLs (byokey.app)
├── PrivacyInfo.xcprivacy     Privacy Manifest (ohne die Datei scheitert der Upload)
├── Localization/
│   ├── AppLanguage.swift            Sprachwahl, Umschaltung zur Laufzeit
│   └── Localizable.xcstrings        Textkatalog DE (Quelle) · EN · PL
├── Models/Models.swift       Projekt, Chat, Nachricht, Modell, Meldung, Einstellungen
├── Services/
│   ├── KeychainStore.swift          Schlüssel in der Keychain, kein iCloud-Sync
│   ├── AIProvider.swift             Protokoll + Registry: ein Anbieter = eine Zeile
│   ├── OpenRouterProvider.swift     Modelle mit Preisen, SSE-Streaming, echter Verbrauch
│   ├── OpenAICompatibleProvider.swift  Generischer OpenAI-kompatibler Anbieter
│   ├── Costs.swift                  Token-Schätzung, Kostenrechnung, Formatierung
│   ├── ContentModeration.swift      Inhaltsfilter (Richtlinie 1.2)
│   ├── FileTextExtractor.swift      PDF, Text und Quelltext auf dem Gerät auslesen
│   ├── ImageAttachmentCoder.swift   Angehängte Bilder verkleinern, kodieren, schätzen
│   ├── AttachmentStore.swift        Anhänge als eigene Dateien im App-Container
│   ├── SpeechService.swift          Aufnahme, Erkennung, Vorlesen – Gerät oder Anbieter
│   ├── CodeArtifactExtractor.swift  Dateien aus Code-Blöcken einer Antwort erkennen
│   └── ZipArchive.swift             ZIP-Schreiber, selbst geschrieben, ohne Fremdcode
├── State/
│   ├── ConsentStore.swift    Zustimmung je Anbieter (Richtlinie 5.1.2(i))
│   └── AppState.swift        Einziger Zustandsspeicher, Streaming, Persistenz
├── Theme/Theme.swift         Farben für Hell und Dunkel, Bausteine
└── Views/                    Sidebar, Chat, Markdown, Code, Einstellungen, Dialoge
    ├── ArtifactExportView.swift  Dateien prüfen, umbenennen, einzeln oder als ZIP sichern
    ├── AttachmentThumbnail.swift Vorschaubild eines angehängten Bildes
    ├── AttachmentPreviewView.swift  Zeigt, was von einem Anhang wirklich hinausgeht
    ├── HTMLPreviewView.swift     Lokale Seitenvorschau, nur file:// – kein Browser
    ├── VoiceModeView.swift       Vollbild-Sprachmodus
    ├── VoiceInfoView.swift       Erklärung: warum ein Chat-Modell nicht spricht
    └── VoicePickerView.swift     Stimmen nach Qualität, mit Hörprobe
Docs/
├── COMPLIANCE.md                    → hier anfangen vor der Einreichung
├── APP-REVIEW-NOTES.md              Text für App Store Connect, wörtlich einfügen
├── DATENSCHUTZ-VORLAGE.md           DE + EN
└── NUTZUNGSBEDINGUNGEN-VORLAGE.md   DE + EN
```

## Funktionen

**Chat.** Streaming Zeichen für Zeichen, Markdown mit Überschriften, Listen, Zitaten und
Inline-Code, Code-Blöcke mit Syntaxhervorhebung und Kopierknopf. Eingabefeld wächst von
einer auf acht Zeilen mit. Hell und Dunkel folgen dem System.

**Leere Chats bleiben nicht liegen.** „Neuer Chat" legt nur dann einen an, wenn nicht
schon ein leerer, unbenannter danebensteht – sonst wird der geöffnet. Und wer einen leeren
Chat wieder verlässt, findet ihn nicht in der Seitenleiste wieder: er verschwindet in dem
Moment, in dem man ihn verlässt. Bestehen bleibt ein Chat, sobald **eine Nachricht** darin
steht oder man ihm **einen Namen** gegeben hat – ein benannter leerer Chat ist eine
Absicht („hier kommt später der Umzug rein"), ein unbenannter ein Versehen. Beim Start
räumt die App Altbestände nach derselben Regel weg. Verloren geht dabei nichts: ein Chat
ohne Nachricht und ohne eigenen Namen enthält keine Angabe des Nutzers.

**Kosten.** Unter jeder Antwort Eingabe-/Ausgabe-Tokens und Kosten in USD. OpenRouter meldet
den tatsächlichen Verbrauch zurück – diese Werte sind exakt. Wo geschätzt wird, steht „ca."
davor. Summen pro Chat, pro Projekt und pro Monat, dazu ein Budgetbalken, der ab 80 %
orange und ab 100 % rot wird.

**Dateien anhängen.** Die Büroklammer im Eingabefeld öffnet ein Menü mit zwei Einträgen:
„Foto auswählen" und „Datei auswählen". Aus der Dateien-App gelesen werden **PDF**
(Textebene), **Textdateien** und **Quelltext** – Markdown, PHP, Swift, Python, JSON, CSV
und Dutzende weitere; was nicht lesbar ist, lässt sich gar nicht erst auswählen. Der Text
wird auf dem Gerät ausgelesen, nie in der Cloud.

Über dem Eingabefeld steht jede Datei als Kachel mit Namen und geschätzter Tokenzahl –
**bevor** gesendet wird. Wer nur eine Datei anhängt und nichts dazu schreibt, bekommt
sichtbar „Fasse die angehängte Datei zusammen." in die eigene Nachricht gesetzt.

Ein Anhang bleibt im Gespräch: die KI kann auch auf die zehnte Nachfrage noch aus dem
Dokument antworten. Das kostet jedes Mal erneut, deshalb lässt sich jeder Anhang über
sein Kontextmenü abschalten – die Kachel bleibt blass und durchgestrichen stehen und ist
mit einem Tippen wieder da. Passt die Summe nicht mehr in das gewählte Modell, sagt eine
Leiste über dem Eingabefeld, um wie viel.

Ist eine Datei zu groß für das Kontextfenster, **fragt** die App: gekürzt anhängen, ein
größeres Modell wählen oder abbrechen. Gekürzt wird nach UTF-8-Bytes, nicht nach Zeichen –
bei japanischem Text oder Emoji läge eine Zeichenzählung um das Drei- bis Sechsfache
daneben. Und die Kürzung steht anschliessend an drei Stellen: an der Kachel, in der
Vorschau **und** im Kontext, den das Modell sieht. Ohne das Letzte behauptet die KI, das
ganze Dokument gelesen zu haben.

Der ausgelesene Text geht durch denselben Inhaltsfilter wie getippter – einmal beim
Anhängen, abseits des Hauptthreads. Eine Datei, deren Inhalt der Filter blockiert, wird
gar nicht erst angehängt. Abgelegt wird der Text als eigene Datei im App-Container, nicht
in der Zustandsdatei: die wird bei jedem gestreamten Token neu geschrieben, und 400 000
Zeichen dabei mitzuschleifen brächte die App zum Stehen.

**Bilder anhängen.** „Foto auswählen" öffnet die Fotoauswahl von iOS. Sie läuft in einem
**eigenen Prozess**: ByoKey fragt deshalb nie nach Zugriff auf die Mediathek und liest
dort auch nichts – die App bekommt genau die Bilder, die du antippst. Aus der Dateien-App
lassen sich Bilder ebenso anhängen.

Wozu das gut ist: bei einem Bildmodell ist eine Vorlage jeder Beschreibung überlegen. Wer
einen Stil, ein Gesicht oder ein Produkt im Kopf hat, kommt mit einem angehängten Bild
weiter als mit drei Absätzen Text. Über `/chat/completions` geht das Bild als Bildteil der
Nachricht mit; wählst du ein Bildmodell, geht es an dessen eigenen Endpunkt als Vorlage
(`input_references`, derzeit nur über OpenRouter). Weggelassen wird es nie: was das
gewählte Modell kann, weiß am Ende nur der Anbieter, und ein stillschweigend
unterschlagenes Bild wäre die schlechtere Auskunft als seine Fehlermeldung.

Vor dem Senden wird auf dem Gerät auf höchstens 1536 Bildpunkte an der langen Kante
verkleinert und als JPEG kodiert – ein iPhone-Foto wäre sonst als Base64 rund vier
Megabyte, ohne dass ein Modell mehr darauf erkennen würde. Die Kachel über dem
Eingabefeld zeigt das Bild, seine Kantenlängen und die geschätzten Tokens. Kürzen lässt
sich ein Bild nicht: passt es nicht mehr in das Kontextfenster, sagt die App das, statt
etwas abzuschneiden.

Eine Leiste über dem Eingabefeld warnt **vor** dem Senden, wenn Anhang und Modell nicht
zusammenpassen – in drei Fällen: das Modell nimmt laut Modell-Liste des Anbieters nur Text
entgegen (das meldet nur OpenRouter); der Anbieter kennt beim Erzeugen von Bildern keine
Vorlagen; oder es ist ein Bildmodell gewählt, während Dokumente angehängt sind – deren
ausgelesener Text erreicht den Bild-Endpunkt nämlich nicht.

Wer gar nichts dazu schreibt, bekommt einen sichtbaren Ersatzsatz in die eigene Blase
gesetzt, passend zu Anhang und Modell: „Beschreibe das angehängte Bild." bei einem
Seh-Modell, „Erzeuge ein neues Bild auf Grundlage der angehängten Vorlage." bei einem
Bildmodell. Bildmodell ohne Text und ohne Vorlage sendet die App gar nicht erst – daraus
liesse sich kein Bild machen.

Eines sagt die App offen: der Inhaltsfilter auf dem Gerät liest Text und kann nicht
beurteilen, was auf einem Bild zu sehen ist. Dafür stehen die Prüfung des Anbieters und
die Melde- und Sperrfunktion in der App gerade.

**Mehrere Schlüssel je Anbieter.** Die Einstellungen zeigen unter „API-Schlüssel" alle
hinterlegten Schlüssel des gewählten Anbieters – Name, verkürzte Darstellung und der
Zeitpunkt der letzten geglückten Prüfung. Angetippt wird gewechselt, der Haken zeigt den
benutzten. Nach „Sichern und prüfen" fragt die App nach einem Namen: „Arbeit", „Privat",
„Kunde A". Wer mehrere Anbieter benutzt, sieht darunter eine Übersicht der übrigen und
wechselt mit einem Tippen dorthin.

Ein neuer Schlüssel wird **erst nach bestandener Prüfung** benutzt – ein Tippfehler
verdrängt also nicht den funktionierenden. Denselben Schlüssel zweimal einzutragen lehnt
die App ab und sagt, unter welchem Namen er schon liegt.

Gespeichert wird weiterhin ausschliesslich in der iOS-Keychain, ein Eintrag je Schlüssel
unter `apikey.entry.<uuid>`. In der Zustandsdatei stehen nur Kennung, Anbieter und Name –
**nicht** der Schlüssel und auch nicht seine verkürzte Darstellung. Anbieter und Name
liegen zusätzlich als `kSecAttrLabel` am Keychain-Eintrag: geht die Zustandsdatei verloren,
stellt die App die Liste beim nächsten Start daraus wieder her, statt die Schlüssel
unerreichbar zurückzulassen.

**Projekte.** Eigener System-Prompt, Standardmodell, Farbe und eigene Kostenübersicht.
Der Projekt-Prompt ergänzt die Sicherheitsregeln der App, ersetzt sie nie. „Neues Projekt"
steht als zweiter Knopf direkt unter „Neuer Chat" – nicht mehr nur im Menü oben rechts,
denn ein Projekt anzulegen ist ein Einstieg und keine Nebeneinstellung. Nach dem Sichern
wechselt die App in das neue Projekt und öffnet gleich einen Chat darin.

**Modelle.** Live von der Anbieter-API inklusive Preisen pro 1 Mio. Tokens und
Kontextlänge, durchsuchbar, nach Hersteller gruppiert, Filter für kostenlose Modelle.
Der Verlauf wird automatisch auf das Kontextfenster des gewählten Modells gekürzt.

Sprach- und Bildmodelle rechnen **nicht** nach Tokens ab. Die Modell-Liste meldet für sie
oft `prompt: 0` und `completion: 0` – daraus „kostenlos" zu schliessen wäre falsch.
`AIModel.isFree` prüft deshalb zusätzlich die Preisfelder `audio`, `request` und `image`
und schliesst audiofähige Modelle grundsätzlich aus; angezeigt wird dann
„Abrechnung nach Audiolänge" bzw. „nach Zeichen".

**Bilder.** Wählt man ein Bildmodell (in der Liste mit „Bild" gekennzeichnet), schickt die
App den Text nicht an `/chat/completions`, sondern an den Bild-Endpunkt des Anbieters –
`/images` bei OpenRouter, `/images/generations` bei OpenAI, Together und xAI. Das Ergebnis
erscheint direkt in der Antwort und lässt sich über das Teilen-Blatt sichern.

Der Unterschied ist kein Schönheitsfehler, sondern der Grund für ein Verhalten, das vorher
irritierte: ein Bildmodell am Chat-Endpunkt antwortet mit **Text** und behauptet dabei
gerne, es habe ein Bild erzeugt. Erzeugt wurde nie eines. Deshalb prüft die App jetzt
zusätzlich, ob ein reines Textmodell nach einem Bild gefragt wird, und weist darauf hin,
statt die Antwort kommentarlos stehen zu lassen. Kann der gewählte Anbieter überhaupt keine
Bilder liefern, bricht die App vor dem Senden ab und sagt das.

Angetippt öffnet sich das Bild formatfüllend, mit Zoom über Aufziehen und Doppeltippen.
Gesichert wird an drei Stellen, weil jeder Nutzer einen anderen Weg sucht: unten links in
der Vollbildansicht, über die Zeile unter dem Bild, oder indem man das Bild im Chat
gedrückt hält. Alle drei rufen `PHPhotoLibrary` mit `.addOnly` – die App fordert **keinen**
Lesezugriff auf die Mediathek an, `NSPhotoLibraryUsageDescription` steht bewusst nicht in
der `Info.plist`.

Angezeigt wird über `ImageFileLoader`, **nicht** über `AsyncImage`. Letzteres ist für
Netzadressen gedacht und geht durch `URLSession` samt Zwischenspeicher; für eine Datei im
eigenen Container war das die Ursache eines Fehlers, bei dem das Bild direkt nach dem
Erzeugen erschien und beim nächsten Öffnen desselben Chats nicht mehr. `ImageFileLoader`
liest die Datei mit `ImageIO` und verkleinert dabei gleich auf Anzeigegröße, statt ein
grosses PNG in voller Auflösung zu entpacken.

**Der Verlauf springt nicht.** Das ist bei Chat-Listen mit Bildern der klassische Fehler,
und er hat hier drei Zutaten, die alle drei nötig sind:

1. **Die Höhe steht fest, bevor das Bild geladen ist.** `ChatMessage.imageAspectRatio` wird
   beim Erzeugen aus dem Dateikopf mitgeschrieben und persistiert; für ältere Nachrichten
   liest `ImageFileLoader.reservedAspectRatio` denselben Wert aus dem Dateikopf nach, ohne
   das Bild zu entpacken. Die Blase reserviert damit ab dem ersten Bildaufbau exakt die
   Höhe, die sie am Ende hat – `Rectangle().aspectRatio(…, contentMode: .fit)` als Kasten,
   das Bild als `overlay` darin. Ein Overlay ändert die Grösse seines Elternteils nie.
2. **Der Wert kommt aus genau einer Quelle und wird festgeschrieben.** Mal aus der
   Nachricht, mal aus dem entpackten Bild zu lesen wäre subtil falsch: bei EXIF-Orientierung
   5–8 ist das entpackte Bild gedreht, das Verhältnis also der Kehrwert. Dieselbe Zeile
   bekäme beim Zurückscrollen eine andere Höhe – und genau dann springt es.
3. **Ein `LazyVStack` wirft den Zustand einer Zeile weg, sobald sie den Sichtbereich
   verlässt.** Ohne Gegenmassnahme beginnt jede zurückkehrende Zeile wieder bei der
   Ladeanzeige. `GeneratedImageView.init` holt sich das bereits entpackte Bild deshalb
   **synchron** aus einem `NSCache` – die Zeile ist beim ersten Zeichnen fertig.

Dazu Kleinigkeiten mit derselben Wirkung: die Knopfzeile unter dem Bild ist immer da (nur
abgeschaltet, solange nichts geladen ist), statt beim Erscheinen des Bildes zusätzliche
Höhe einzubringen. Und `ImageStore.directory` ist eine reine Pfadberechnung ohne
Dateizugriff – `url(for:)` läuft beim Scrollen für jede Bildzeile durch.

Die Liste selbst braucht dafür nichts Besonderes: `ForEach` über `Identifiable` mit der
Nachrichten-UUID, `.equatable()` auf der Zeile, `.defaultScrollAnchor(.bottom)`. Was in
React Native `getItemLayout` leistet, macht in SwiftUI der Platzhalter mit fester Höhe.

Bilder liegen als einzelne Dateien in `Application Support/byokey-bilder`, nicht im
Zustands-JSON – dieses wird bei jeder Änderung neu geschrieben, und ein PNG darin würde
jeden Tastendruck teuer machen. Verwaiste Dateien räumt die App beim Start auf, aber nur
wenn der Zustand sauber geladen wurde. Für das „Bild sichern" des Teilen-Blatts steht
`NSPhotoLibraryAddUsageDescription` in der `Info.plist`; gelesen wird die Mediathek nie.

**Dateien exportieren.** Enthält eine Antwort Quelltext, erkennt die App die einzelnen
Dateien samt Namen und Sprache – aus dem Fence (```` ```php index.php ````), aus einer
Überschrift davor oder aus dem ersten Kommentar. Geratene Namen sind als solche markiert
und lassen sich vor dem Export ändern. Ein Tipp auf „Dateien exportieren" öffnet das
Teilen-Blatt mit einem ZIP; über „In Dateien sichern" landet es auf dem iPhone oder iPad.
Gesichert wird wahlweise **einzeln** – dann liegen `index.php` und `style.css` unter ihrem
eigenen Namen im Zielordner – oder als **ZIP**, wenn Unterordner wie `inc/config.php`
erhalten bleiben sollen.

Enthält die Auswahl HTML, gibt es zusätzlich **„Seite ansehen"**: die Dateien werden lokal
gerendert, samt CSS und JavaScript, sodass sich ein Layout direkt auf dem iPhone prüfen
lässt. Das Fenster lässt ausschließlich lokale Dateien zu – jede Netzadresse wird
abgewiesen und angezeigt. **PHP läuft dort nicht**: dafür braucht es einen Server, ein
iPhone kann es nicht ausführen. Die Vorschau sagt das auch so.

Der ZIP-Schreiber ist eigener Code – keine Fremdbibliothek. Ausgeführt wird nichts, was
die App exportiert; die Vorschau rendert, sie startet kein Programm.

**Sprachmodus.** Vollbild wie bei Gemini: zuhören, senden, vorlesen, im Gesprächsmodus
von selbst weiterhören. Zwei Wege, und die App erklärt den Unterschied im Sprachmodus
selbst (Knopf in der Kopfzeile) und in den Einstellungen:

- **Auf dem Gerät** (Standard) – `SFSpeechRecognizer` und `AVSpeechSynthesizer`.
  Funktioniert mit **jedem** Chat-Modell, kostet nichts, die Aufnahme bleibt auf dem Gerät.
  Die Stimmenauswahl listet alles, was auf dem Gerät installiert ist – nach Qualität
  gruppiert, mit Hörprobe, inklusive der kostenlos nachladbaren Premium-Stimmen und einer
  persönlichen Stimme, falls vorhanden. Siri-Stimmen gibt Apple Fremd-Apps nicht frei.
- **Über den Anbieter** – dessen Audio-Endpunkte. Braucht **zwei zusätzliche,
  sprachfähige Modelle** (eines fürs Erkennen, eines fürs Vorlesen), eine eigene
  Datenfreigabe und wird vom Anbieter berechnet.

Der wichtige Punkt, den die App unmissverständlich sagt: **ein Chat-Modell hört und
spricht nicht.** Es nimmt Text und gibt Text. Sprache entsteht durch zwei zusätzliche
Bausteine davor und dahinter – nicht jeder Anbieter und nicht jedes Modell bietet sie an.

**Verlauf.** Während eine Antwort eintrifft, läuft die Ansicht mit – der Text wächst in
*derselben* Nachricht, `messages.count` ändert sich dabei nicht, deshalb hängt das
Mitlaufen an der Zeichenzahl der letzten Nachricht. Sobald man mit dem Finger nach oben
zieht, hört es auf; endet die Bewegung wieder unten, geht es von selbst weiter. Ein Tipp
auf den Verlauf schliesst die Tastatur.

**Darstellung.** Der Knopf, der im Verlauf ans Ende springt, sitzt standardmässig in der
Mitte und lässt sich in den Einstellungen nach links oder rechts legen. Er erscheint ohnehin nur,
solange man weiter oben liest – und wer das Gerät links hält, erreicht ihn links
bequemer.

**Sprachen.** Die Oberfläche gibt es auf Deutsch, Englisch und Polnisch. Umgestellt wird
in den Einstellungen ganz oben; die Änderung greift sofort, ohne Neustart und ohne Umweg
über die iOS-Einstellungen. „Systemsprache" folgt dem Gerät.

Technisch: die **deutschen Texte sind zugleich die Schlüssel**. `Text("Einstellungen")`
schlägt in `Localizable.xcstrings` nach; fehlt eine Übersetzung, erscheint der deutsche
Text. An den Aufrufstellen musste deshalb nichts umgebaut werden. Umgeschaltet wird über
`\.locale` in der Umgebung – daher der sofortige Wechsel.

Die Einstellung **Generate String Catalog Symbols** steht bewusst auf `NO`. Xcode 26
erzeugt sonst aus jedem Schlüssel ein Swift-Symbol – bei deutschen Sätzen als Schlüssel
kollidieren die früher oder später (zwei Sätze, die sich nur im Fragezeichen
unterscheiden, ergeben denselben Namen). Gebraucht werden die Symbole hier nicht:
nachgeschlagen wird über den deutschen Text.

*Eine Sprache ergänzen:* `Localizable.xcstrings` in Xcode öffnen, links die Sprache
hinzufügen, übersetzen. Zusätzlich die Kennung in `AppLanguage` und in `knownRegions`
der `project.pbxproj` eintragen. Texte ausserhalb von SwiftUI laufen über `Loc.tr`.

*Die Falle dabei:* `Text("Einstellungen")` ist ein Schlüssel, `Text(einStringWert)` ist
es **nicht** – Swift wählt dann die Überladung für `StringProtocol`, und die schlägt nichts
nach. Der Text bleibt in jeder Sprache deutsch, ohne Warnung, ohne Fehler. Dasselbe gilt
für `TextField`, `Button`, `Label`, `Section`, `.navigationTitle` und
`.accessibilityLabel`. Zwei Muster fallen besonders leicht durch:

- **Hilfs-Views mit `String`-Parameter.** `row(title: "Kosten")` sieht nach einem Literal
  aus, aber übersetzt wird es nur, wenn der Parameter `LocalizedStringKey` heißt.
- **Ternäre mit gemischtem Typ.** In `cond ? "Einrichtung nötig" : provider.displayName`
  hat ein Zweig den Typ `String`; damit bekommt der ganze Ausdruck diesen Typ, und auch
  das Literal im anderen Zweig wird nicht mehr nachgeschlagen. Deshalb stehen an solchen
  Stellen zwei getrennte `Text`-Zweige in einer `Group`.

Wo ein Satz mit einem Namen darin entsteht, gehört ein Platzhalter in den Katalog und
`Loc.tr("… %@ …", name)` in den Code – ein mit Swift-Interpolation fertig gebauter Satz
findet keinen Eintrag mehr. `Loc` ist bewusst **nicht** an den Hauptaktor gebunden:
`LocalizedError.errorDescription` ist eine Protokollanforderung ohne Isolation, und
genau dort entstehen die Fehlermeldungen des Netzwerk-Layers.

**Neun Anbieter.** OpenRouter, Mistral AI, OpenAI, Cerebras, DeepSeek, Google Gemini,
Groq, Together AI und xAI. Alle sprechen dieselbe OpenAI-kompatible Schnittstelle, aber
nicht identisch – die Unterschiede stecken in `OpenAICompatibleProvider`:

- **DeepSeek** hat kein `/v1` in der Basis-Adresse.
- **Together AI** liefert die Modell-Liste als nacktes Array statt als `{"data":[…]}`;
  der Decoder nimmt beide Formen.
- **Gemini** liegt unter `/v1beta/openai`.
- `stream_options: {include_usage: true}` senden nur die vier Dienste, die es
  dokumentieren (`sendsStreamOptions`). Die übrigen würden mit HTTP 400 antworten.

Preise liefert weiterhin nur OpenRouter mit der Modell-Liste. Bei den anderen bleibt es
bei der Schätzung, klar mit „ca." gekennzeichnet.

**Anbieter erweitern.** `AIProviderProtocol` implementieren und in `ProviderRegistry.all`
eintragen – fertig. Das Protokoll erzwingt dabei die Angaben, die der Zustimmungsdialog
für Richtlinie 5.1.2(i) braucht. Audio-Endpunkte sind optional: `supportsAudio = false`
genügt, dann bleibt für diesen Anbieter der Weg über das Gerät.

## Bauen

Ab **Xcode 26**. Seit dem 28.04.2026 nimmt App Store Connect nur noch Builds an, die
gegen das iOS-26-SDK erzeugt wurden; `SDKROOT = iphoneos` zieht automatisch das neueste
installierte SDK, eine eigene Einstellung dafür gibt es nicht. Das Bereitstellungsziel
bleibt davon unberührt und steht auf **iOS 18.0**.

Der eine bekannte Bruch zwischen den SDKs ist abgefangen:
`AVAudioSession.CategoryOptions.allowBluetooth` heisst ab iOS 26 `allowBluetoothHFP`.
`SpeechService.bluetoothOption` schaltet über `#if compiler(>=6.2)` um und übersetzt
damit unter beiden Xcode-Versionen warnungsfrei.

**Sprachmodus:** `SWIFT_VERSION = 5.0` und `SWIFT_STRICT_CONCURRENCY = minimal` sind
Absicht. Bietet Xcode „Update to recommended settings" an, darf das **nicht** blind
angenommen werden, wenn es diese beiden Werte anfassen will – der Umstieg auf Swift 6
gehört in eine eigene Runde. Vorbereitet ist er: die globalen Zwischenspeicher tragen
bereits `nonisolated(unsafe)` bzw. `@MainActor`.

## Vor der Einreichung

**`Docs/COMPLIANCE.md` lesen.** Kurzfassung der Pflichtpunkte:

- `AppInfo.swift`: echte Support-Adresse, erreichbare Datenschutz- und Bedingungs-URLs (DE + EN)
- OpenRouter-Prüfschlüssel mit Limit anlegen und in die Demo-Felder eintragen
- Review-Notizen aus `Docs/APP-REVIEW-NOTES.md` wörtlich einfügen
- Altersfreigabe: Chatbot ja, UGC ja, Webzugriff nein, Social Media nein → 13+/16+
- App Privacy: „User Content → Other User Content" und „User Content → Photos or Videos",
  beide App Functionality, nicht verknüpft, kein Tracking
- EU-Händlerstatus (DSA) abschließen – ohne ihn wird die App aus dem EU-Store entfernt
- Metadaten ohne Fremdmarken; Pflichthinweis „eigener API-Schlüssel erforderlich"

## Bekannte Grenzen

- **Anbieter „Eigener Endpunkt"** ist implementiert, aber absichtlich nicht freigeschaltet.
  Begründung und Nachrüstplan in `Docs/COMPLIANCE.md`.
- **Der Inhaltsfilter ist eine Stichwortliste** mit deutschen und englischen Regeln. Er
  erfüllt die Anforderung, ist aber pflegebedürftig. Für Version 1.1 empfohlen: den
  kostenlosen Moderations-Endpunkt des Anbieters aufrufen und die lokale Liste nur als
  Rückfallebene nutzen.
- **Kein Tool-Calling** – bewusst für Version 1.0.
- **Dokumente nur als Text.** PDF, Textdateien und Quelltext werden auf dem Gerät
  ausgelesen und als Text mitgeschickt. Eingescannte PDFs ohne Textebene weist die App ab
  und sagt auch warum – Texterkennung wäre ein eigenes Thema. Bilder gehen dagegen als
  Bild hinaus, verkleinert und als JPEG.
- **Vorlagenbilder nur über OpenRouter.** Die übrigen Anbieter nehmen zu einem Bildauftrag
  keine eigenen Bilder entgegen; die App sagt das vorher, statt die Vorlage stillschweigend
  wegzulassen.
- **Der Inhaltsfilter prüft Text, kein Bild.** Er sieht den Prompt, nicht das Ergebnis –
  und auch nicht, was auf einem angehängten Bild zu sehen ist. Bei erzeugten wie bei
  angehängten Bildern tragen die Moderation des Anbieters und die Melde- bzw.
  Sperrfunktion in der App. In `Docs/COMPLIANCE.md` steht, was das für die
  Altersfreigabe bedeutet.
- **Sprache lässt sich nur auf einem echten Gerät testen.** Der Simulator hat kein
  Mikrofon; die Erkennung auf dem Gerät setzt außerdem voraus, dass iOS die eingestellte
  Sprache heruntergeladen hat (Einstellungen › Allgemein › Tastatur › Diktat).
- **PHP, Python und alles andere Serverseitige läuft nicht auf dem Gerät.** Die Vorschau
  zeigt HTML, CSS und JavaScript. Mehr geht auf iOS nicht, und mehr darf auch nicht.
- **Die Kosten fürs Vorlesen meldet kein Anbieter zurück.** Sie erscheinen nur auf dessen
  Abrechnung, nicht in der App. Die Erkennung wird mitgerechnet, wo der Anbieter sie
  ausweist.
