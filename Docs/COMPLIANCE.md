# ByoKey – App-Review-Compliance

Stand der geprüften Richtlinien: **App Review Guidelines, Ausgabe Februar 2026**
(letzte inhaltliche Änderung 6. Feb. 2026; Regel 5.1.2(i) zu Drittanbieter-KI
kam am 13. Nov. 2025 hinzu). Altersfreigaben: 5-stufiges System (4+/9+/13+/16+/18+),
Fragebogen seit 31. Jan. 2026 verpflichtend, Social-Media-Fragen ab September 2026.

Dieses Dokument hat zwei Teile:
**A** – was die App bereits erfüllt und wo es im Code steht (das ist deine Argumentation,
falls abgelehnt wird).
**B** – was du vor dem Upload noch tun musst.

---

## A. Was im Code umgesetzt ist

### Richtlinie 5.1.2(i) – Datenweitergabe an Drittanbieter-KI

> *"You must clearly disclose where personal data will be shared with third parties,
> including with third-party AI, and obtain explicit permission before doing so."*

Apple lehnt an vier Punkten ab. Alle vier sind hart verdrahtet:

| Anforderung | Umsetzung | Datei |
|---|---|---|
| Anbieter **namentlich** nennen (nicht "powered by AI") | `legalEntity` = „OpenRouter, Inc. (USA)" steht in der Überschrift des Dialogs | `Services/OpenRouterProvider.swift`, `Views/ConsentView.swift` |
| **Konkreter Zweck** | `privacySummary` beschreibt Weiterleitung an den Modellbetreiber | `Services/OpenRouterProvider.swift` |
| **Datenarten einzeln** aufzählen | `dataCategories` – inkl. API-Schlüssel und IP-Adresse | `Services/OpenRouterProvider.swift` |
| **Aktive, widerrufbare** Zustimmung, nichts vorausgewählt | `ConsentStore.grant/revoke`, Standard = aus, Widerruf in Einstellungen | `State/ConsentStore.swift`, `Views/SettingsView.swift` |

**Die harte Sperre:** ohne Freigabe geht *kein* Netzwerkpaket raus – nicht einmal
die Modell-Liste. Geprüft an drei Stellen im Modell-Layer, nicht nur in der Oberfläche:

- `AppState.send(_:)` → `guard consent.hasConsent(for:)`
- `AppState.refreshModels(force:)` → `guard consent.hasConsent(for:)`
- `SettingsView.loadKeyInfo()` → `guard app.consent.hasConsent(for:)`

`ConsentStore.policyVersion` entwertet alte Zustimmungen, sobald sich Umfang oder
Empfänger ändern. **Erhöhe diese Zahl**, wenn sich für einen **bereits freigegebenen**
Anbieter etwas ändert – andere Datenarten, anderer Empfänger, anderer Zweck. Einen
*neuen* Anbieter aufzunehmen ist kein Grund: Zustimmungen werden je Anbieter gespeichert,
ein neuer startet ohnehin bei null, und eine Erhöhung würde nur alle bestehenden
Freigaben grundlos entwerten.

### Die neun Anbieter und wohin die Daten gehen

Jeder Eintrag in `ProviderRegistry.all` ist ein eigener Empfänger mit eigenem
Zustimmungsdialog, eigener Firmierung und eigenem Datenschutz-Link. Für die Prüfung
und für die App-Privacy-Angaben zählt: **ByoKey selbst erhält nichts**, und ohne
Freigabe geht zu keinem dieser Empfänger ein einziges Paket.

| Anbieter | Firmierung | Verarbeitung | Besonderheit |
|---|---|---|---|
| OpenRouter | OpenRouter, Inc. (USA) | USA | einziger mit Preisangaben in der Modell-Liste |
| Mistral AI | Mistral AI SAS (Frankreich) | **EU (Schweden)** | einziger mit dokumentierter EU-Verarbeitung; Anbieter widerspricht sich beim Thema Training |
| OpenAI | OpenAI, L.L.C. (USA) | USA | Audio-Endpunkte |
| Cerebras | Cerebras Systems Inc. (USA) | USA | keine Aufbewahrung laut Anbieter |
| DeepSeek | Hangzhou DeepSeek Artificial Intelligence Co., Ltd. (China) | **China** | Training standardmäßig an, nur per Widerspruch abschaltbar |
| Google Gemini | Google LLC (USA), in der EU Google Ireland Limited | weltweit | **kostenloses Kontingent: Training und menschliche Durchsicht** |
| Groq | Groq LLC (USA) / Groq UK Limited | USA | kein Training laut Vertrag |
| Together AI | Together Computer, Inc. (USA) | USA | kein Training ohne Einwilligung |
| xAI | X.AI LLC (USA) | unklar, vermutlich USA | Unterlagen widersprüchlich beim Thema Training |

**DeepSeek ist der kritischste Eintrag.** Der Zustimmungsdialog beginnt dort mit
„Achtung" und nennt beides ausdrücklich: Verarbeitung in der Volksrepublik China und
Training aus Eingaben, solange nicht widersprochen wird. Das ist kein Beiwerk – nach
Art. 49 Abs. 1 lit. a DSGVO trägt die Einwilligung eine Drittlandsübermittlung nur,
wenn der Nutzer über die Risiken **unterrichtet** wurde. Kürze diesen Text nicht.

Nicht aufgenommen: **Fireworks AI** – die Modellkennungen enthalten dort einen Pfad
(`accounts/fireworks/models/…`) und es gibt keine Modell-Liste im OpenAI-Format.

> **Warum „Eigener Endpunkt" nicht ausgeliefert wird:** `OpenAICompatibleProvider.custom`
> ist implementiert, steht aber bewusst nicht in `ProviderRegistry.all`. Bei einer frei
> eintragbaren URL ist der Empfänger unbekannt – das ist genau die generische Offenlegung,
> auf die Apple ablehnt. Außerdem wäre die Zustimmung nicht an den Host gebunden: ein
> Wechsel der Adresse würde eine erteilte Freigabe stillschweigend mitnehmen.
> Vor einer Freischaltung: Zustimmungsschlüssel auf `custom|<host>` umstellen,
> Betreibernamen abfragen, Schema auf `https` begrenzen.

### Richtlinie 1.2 – Nutzergenerierte Inhalte

Die App zeigt Modellausgaben an, fällt also unter 1.2. Alle vier Pflichten:

**1. Methode zum Filtern anstößiger Inhalte** – `Services/ContentModeration.swift`
- Eingabefilter, bevor Text das Gerät verlässt (`screenInput`)
- Verbindlicher Sicherheits-System-Prompt vor **jeder** Anfrage; der Projekt-Prompt
  kann ihn nur ergänzen, nicht ersetzen (`AppState.buildTurns`)
- Ausgabefilter **schon während des Streams** (`screenStreamingChunk`), nicht erst am
  Ende: ein Filter, der den Text erst nach dem Lesen verdeckt, filtert nichts.
  Markierte Antworten sind eingeklappt und erscheinen erst nach ausdrücklichem Tippen
  (`MessageRow.flaggedPlaceholder`)
- Geprüft wird auch der **gesamte ausgehende Kontext**, nicht nur die neueste
  Nachricht – sonst genügen zwei Nachrichten zum Umgehen
- Wortgrenzen statt Teilstring-Treffer, plus Faltung von Leetspeak, Homoglyphen und
  unsichtbaren Zeichen. Gemessen: 0 von 19 Umgehungsvarianten kommen durch, bei 0
  Fehlalarmen auf einem Korpus alltäglicher Entwickler- und Autorenfragen
- Krisenäußerungen werden nie als Gewaltandrohung eingestuft; sie führen zum
  Hinweis auf die Telefonseelsorge
- Regeln in **Deutsch und Englisch** – die Prüfung findet auf Englisch statt
- Der Schalter „Strenger Inhaltsfilter" schaltet nur Grenzfälle zu. Die Kernregeln
  laufen immer, unabhängig von jeder Einstellung.

**2. Meldemechanismus** – `Views/ReportSheet.swift`
- „Inhalt melden" im „…"-Menü jeder Antwort
- Meldung wird **immer** lokal erfasst, auch wenn der Mailversand scheitert
  (auf einem Prüfgerät ohne Mailkonto sonst wirkungslos)
- Fällt der Mailversand aus, erscheint ein Dialog mit der Adresse und „Adresse kopieren"
- Protokoll unter Einstellungen › Meldungen

**3. Missbräuchliche Nutzer blockieren** – die App hat keine anderen Nutzer: keine Feeds,
keine Profile, kein Austausch zwischen Nutzern. Das funktionale Gegenstück ist
**„Modell sperren"** (`AppState.blockModel`). Gesperrte Modelle sind nicht mehr wählbar,
Verwaltung unter Einstellungen › Gesperrte Modelle. **Erkläre das in den Review-Notizen** –
sonst hakt der Prüfer den Punkt als fehlend ab.

**4. Veröffentlichte Kontaktdaten** – `AppInfo.supportEmail`, sichtbar unter
Einstellungen › Rechtliches und Kontakt. **Muss echt und betreut sein.**

**Null-Toleranz-Klausel** – muss aktiv akzeptiert werden, bevor die Chat-Oberfläche
überhaupt existiert (`RootView` → `OnboardingView`, Seite 3).

### Sprachmodus – Mikrofon, Spracherkennung, zweite Freigabe

Der Sprachmodus ist der Teil der App, an dem am meisten schiefgehen kann: er berührt
5.1.1 (Zwecktexte), 5.1.2(i) (zusätzlicher Empfänger von Sprachdaten) und 2.5.1
(Berechtigungen erst bei Bedarf). Umsetzung:

| Anforderung | Umsetzung | Datei |
|---|---|---|
| Zwecktexte **konkret**, nicht „für bessere Funktionen" | `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription` – beide nennen Zweck und Empfänger | `Support/Info.plist` |
| Abfrage **erst bei Benutzung** | `SpeechService.requestPermissions` läuft beim Öffnen des Sprachmodus, nie beim Start | `Services/SpeechService.swift` |
| Erkennung **auf dem Gerät** | `requiresOnDeviceRecognition = true`, solange iOS die Sprache dafür kann | `Services/SpeechService.swift` |
| Serverseitige Erkennung durch Apple nur mit Wissen des Nutzers | eigener Schalter in den Einstellungen, Standard = aus | `Views/SettingsView.swift` |
| Sprachdaten an den KI-Anbieter = **eigene** Zustimmung | `ConsentScope.audio`, getrennt von `.text` gespeichert | `State/ConsentStore.swift`, `Views/ConsentView.swift` |

**Die harte Sperre gilt auch hier.** Der vierte Prüfpunkt im Modell-Layer ist
`VoiceModeView.voiceGateOK()`. Er läuft **vor jeder Aufnahme und vor jeder
Sprachsynthese**, nicht nur beim Öffnen des Blattes – sonst genügten zwei Tipper
(Blatt öffnen, Abbruch wegklicken, „Sprechen" drücken), um ohne Freigabe eine
Audiodatei hochzuladen. Wird die Audio-Freigabe in den Einstellungen widerrufen,
bricht `AppState` eine laufende Aufnahme sofort ab.

**Zwei getrennte Wege, und das steht auch so in der App** (`Views/VoiceInfoView.swift`):

- **Auf dem Gerät** (Standard): `SFSpeechRecognizer` + `AVSpeechSynthesizer`. Funktioniert
  mit *jedem* Chat-Modell, kostet nichts, die Aufnahme verlässt das Gerät nicht.
  In diesem Modus wird **keine** Audio-Freigabe verlangt, weil auch nichts übertragen wird.
- **Über den Anbieter**: `/audio/transcriptions` und `/audio/speech`. Braucht zwei
  zusätzliche, audiofähige Modelle und die Audio-Freigabe. Aufnahmen werden nach dem
  Hochladen sofort vom Gerät gelöscht, Aufnahmedauer ist auf 60 s begrenzt.

> **Warum die Erklärseite Pflicht ist, nicht Zierde:** „Sprachmodus" weckt die Erwartung,
> jedes Modell in der Liste könne sprechen. Kann es nicht – Chat-Endpunkte nehmen Text und
> geben Text. Ohne diese Erklärung landet die Enttäuschung in den Bewertungen und im
> Support, und ein Prüfer, der „Voice" in der Beschreibung liest und ein stummes Modell
> antrifft, greift zu 2.3.1 (irreführende Beschreibung).

**Wichtig für das App-Privacy-Label:** der Sprachmodus fügt **keine neue Kategorie** hinzu.
Audio wird nicht gespeichert und nicht an den Entwickler übertragen; im Anbietermodus ist
die Aufnahme derselbe „User Content", der schon deklariert ist. Deklariere insbesondere
**nicht** „Audio Data" als separaten Punkt – das würde Rückfragen auslösen, die du mit
„wird sofort gelöscht" beantworten müsstest.

**`ConsentStore.policyVersion` erhöhen**, wenn du den Umfang der Audio-Freigabe änderst.

### Dateiexport als ZIP

Wenn eine Antwort Quelltextdateien enthält (PHP, HTML, Swift, …), lassen sie sich als ZIP
sichern: `Services/CodeArtifactExtractor.swift` erkennt Dateinamen und Sprache,
`Views/ArtifactExportView.swift` zeigt sie zum Prüfen und Umbenennen,
`Services/ZipArchive.swift` packt sie, `ShareLink` übergibt an „In Dateien sichern".

Richtlinienrelevant sind zwei Punkte:

- **2.5.2 – kein nachgeladener Code.** Der ZIP-Schreiber ist bewusst selbst geschrieben
  statt als Fremdbibliothek eingebunden, und die App **führt nichts aus**, was sie
  exportiert. Sie schreibt Textdateien in ein Archiv, mehr nicht. Kein
  `NSFileCoordinator(.forUploading)`, kein Entpacken, kein Interpreter.
- **Datenschutz.** Die Dateien liegen nur so lange im temporären Ordner, wie das
  Teilen-Blatt offen ist; `ZipArchive.clearExports()` räumt beim Öffnen und beim Schließen
  auf. Dateinamen aus Modellausgaben werden bereinigt (`sanitizeFilename`,
  `sanitizeRelativePath`) – ein Modell, das `../../irgendwas` vorschlägt, kann nicht aus
  dem Ordner ausbrechen.

Für `PrivacyInfo.xcprivacy` ändert sich nichts: Dateien im eigenen temporären Ordner
lösen keine der `NSPrivacyAccessedAPICategory`-Pflichten aus. `NSFileTimestamp` wäre nur
nötig, wenn die App Zeitstempel *fremder* Dateien ausläse.

Neben dem ZIP gibt es **Einzeldateien** (`ShareLink(items:)`) – gesichert landen sie unter
ihrem eigenen Namen im gewählten Ordner, also als `index.php` und `style.css` statt als
Archiv.

### Die HTML-Vorschau – der einzige WKWebView der App

`Views/HTMLPreviewView.swift` zeigt erzeugte HTML-Dateien an, damit sich ein Layout auf
dem Gerät prüfen lässt. Das ist der Punkt, an dem ein Prüfer am ehesten nachfragt, also
hier die Begründung vollständig:

| Einwand | Antwort |
|---|---|
| **2.5.2** „lädt Code nach und führt ihn aus" | Es wird nichts nachgeladen. Die Dateien stammen aus der Modellantwort, liegen im eigenen temporären Ordner und werden als **Inhalt** angezeigt – wie ein Betrachter ein Dokument anzeigt. Die App erhält dadurch keine neue Funktion; ohne die Vorschau kann sie exakt dasselbe. |
| **4.7** „Mini-Apps / HTML5-Spiele" | Die Vorschau ist kein Katalog fremder Inhalte und keine Plattform. Sie zeigt genau das an, was der Nutzer selbst gerade erzeugt hat – vergleichbar mit der Vorschau in jedem Quelltext-Editor im Store. |
| **Altersfreigabe: unrestricted web access?** | **Nein.** `decidePolicyFor` lässt ausschließlich `file://`-Adressen unterhalb des Vorschauordners zu. Jede `http(s)`-Adresse, jede Weiterleitung, jeder `target="_blank"` wird abgewiesen und dem Nutzer als blockierter Aufruf angezeigt. Die Vorschau lässt sich nicht als Browser zweckentfremden. |
| **Datenschutz** | `websiteDataStore = .nonPersistent()`: keine Cookies, kein lokaler Speicher über die Vorschau hinaus. Der Ordner wird beim Schließen gelöscht. |

Zusätzlich abgefangen: `alert()`, `confirm()` und `prompt()` werden beantwortet und als
Hinweis angezeigt, statt WebKit hängen zu lassen; `didFailProvisionalNavigation` sorgt
dafür, dass ein Ladefehler sichtbar wird statt als weiße Seite zu enden.

**PHP wird nicht ausgeführt und kann es nicht.** Dafür bräuchte es einen Interpreter im
Bundle – genau das verbietet 2.5.2. Die Vorschau sagt das offen an; in den Store-Text
gehört derselbe Hinweis, sonst ist „Website auf dem iPhone testen" nach 2.3.1 zu weit
gegriffen.

> **Wenn du das Risiko lieber ganz vermeiden willst:** Die Vorschau ist die einzige
> Stelle mit WebKit. `HTMLPreviewView.swift` löschen und in
> `ArtifactExportView` den Knopf „Seite ansehen" entfernen genügt – Export und ZIP
> bleiben davon unberührt. Dann stimmt auch wieder der Satz „enthält keinen WKWebView"
> aus den Review-Notizen, den du in diesem Fall zurückändern musst.

### Sprachen der App

Die Oberfläche liegt auf **Deutsch, Englisch und Polnisch** vor
(`Localization/Localizable.xcstrings`, Quellsprache Deutsch). Umgeschaltet wird in der App
selbst, zusätzlich greift die Sprachwahl von iOS.

Was daraus für die Einreichung folgt:

- **App Store Connect:** Für jede Sprache, die die App beherrscht, sollten auch die
  Metadaten hinterlegt sein – Name, Untertitel, Beschreibung, Keywords, Screenshots.
  Eine App mit polnischer Oberfläche und ausschliesslich deutschem Store-Eintrag ist
  kein Ablehnungsgrund, aber sie verschenkt genau die Nutzer, für die die Übersetzung
  gemacht wurde. Mindestens **Englisch (USA)** muss vollständig sein: das ist die
  Sprache, in der geprüft wird.
- **Review-Notizen:** Der Hinweis, dass die Prüfoberfläche auf Englisch erscheint, wenn
  das Prüfgerät auf Englisch steht, ist bereits enthalten. Ohne ihn wird jeder Screenshot
  im Review-Bericht auf Deutsch angefordert.
- **Rechtstexte:** Datenschutzerklärung und Nutzungsbedingungen gibt es auf Deutsch und
  Englisch. Für polnische Nutzer weist die Website auf die verbindlichen Fassungen hin.
  Das ist zulässig; nur muss die URL in App Store Connect erreichbar sein und darf nicht
  auf eine Sprache verweisen, die es nicht gibt.
- **Altersfreigabe und App Privacy** ändern sich durch die Übersetzung nicht.
- **Der Inhaltsfilter arbeitet auf Deutsch und Englisch.** Polnische Eingaben laufen
  durch den verbindlichen Sicherheits-System-Prompt und den Ausgabefilter, aber die
  Stichwortregeln greifen dort nicht. Für Version 1.1 gilt die Empfehlung am Ende dieses
  Dokuments umso mehr: den Moderations-Endpunkt des Anbieters dazunehmen, der arbeitet
  sprachunabhängig.

### Preisangaben – 2.3.1

Ein Sprachmodell wie `openai/whisper-1` meldet in der Modell-Liste `prompt: "0"` und
`completion: "0"`, weil es dort keine Tokens gibt; abgerechnet wird nach Audiolänge.
Die App hat solche Modelle früher als **„kostenlos"** ausgewiesen – eine falsche
Preisangabe, und bei einer App, deren Alleinstellungsmerkmal die Kostentransparenz ist,
der peinlichste denkbare Fehler. `AIModel.isFree` wertet jetzt auch `audio`, `request`
und `image` aus und schliesst audiofähige Modelle aus; angezeigt wird
„Abrechnung nach Audiolänge" bzw. „nach Zeichen".

### Bilderzeugung – die heikelste Erweiterung

Modelle, die Bilder ausgeben, sprechen einen anderen Endpunkt als der Chat
(`/images` bei OpenRouter, `/images/generations` bei OpenAI, Together, xAI und Google).
Vorher landete jede Bildbitte bei `/chat/completions`; das Modell antwortete mit Text und
behauptete mitunter, ein Bild erzeugt zu haben – übertragen wurde nie eines. Die App
erkennt Bildmodelle jetzt an `architecture.output_modalities` und leitet sie um.

Was daraus folgt:

| Punkt | Stand |
|---|---|
| **1.2 – Filtern** | Der Inhaltsfilter arbeitet auf Text. **Ein erzeugtes Bild kann er nicht prüfen.** Gefiltert wird die *Eingabe*, also der Bildauftrag – dieselben Regeln wie für jede andere Nachricht. Ein Bild, das trotz harmloser Beschreibung anstößig ausfällt, fängt nur der Anbieter ab (alle fünf betreiben eigene Moderation) oder der Nutzer per Meldung. **Schreibe das so in die Review-Notizen**, statt es offen zu lassen. |
| **1.2 – Melden** | Unverändert: „Inhalt melden" liegt im Menü jeder Antwort und erfasst auch Bildantworten. |
| **1.2 – Sperren** | Unverändert: „Modell sperren" nimmt auch Bildmodelle aus der Auswahl. |
| **Altersfreigabe** | **Hier muss neu bewertet werden.** Ein Bildgenerator kann Darstellungen erzeugen, die ein Textmodell nicht liefert. Bleibe bei „Sexuelle Inhalte / Nacktheit: selten/mild" nur, wenn du das verantworten willst; im Zweifel eine Stufe höher. Die Frage nach uneingeschränktem Webzugriff bleibt **nein**. |
| **5.1.2(i)** | Keine neue Zustimmung nötig: das Bild entsteht beim **selben** Anbieter, für den die Freigabe bereits erteilt wurde. Übertragen wird der Bildauftrag – also Text, wie bisher. |
| **Berechtigung** | In der `Info.plist` steht `NSPhotoLibraryAddUsageDescription` – und **nur** dieser Schlüssel. Zwei Wege führen dorthin: der Knopf „Bild sichern" (direkter `PHPhotoLibrary`-Aufruf mit `PHAccessLevel.addOnly`) und „In Fotos sichern" im Teilen-Blatt. Beide laufen im Prozess der App, und **ohne den Zwecktext beendet iOS die App beim Antippen**. `NSPhotoLibraryUsageDescription` fehlt bewusst: er löste die grosse Freigabe aus, und gelesen wird aus der Mediathek nichts – kein `PHAsset.fetch`, kein Picker. |
| **Fotozugriff abgelehnt** | Wird sauber behandelt und unterscheidet drei Fälle: abgelehnt (Verweis auf Einstellungen › Datenschutz › Fotos), durch Bildschirmzeit oder Geräteverwaltung **eingeschränkt** (dort hilft der Verweis nicht, das sagt die Meldung auch), und technisch fehlgeschlagen. Gefragt wird höchstens einmal – ein zweiter Aufruf zeigt keinen Systemdialog mehr und wäre eine leere Geste. |
| **Vollbildansicht** | Antippen öffnet das Bild formatfüllend, mit Zoom. Sie zeigt ausschliesslich die Datei aus dem App-Container und ruft **nichts** aus dem Netz ab – kein zweiter Webview, keine 4.7-Frage. |
| **App Privacy** | Unverändert. Bilder liegen im App-Container, gehen an niemanden ausser den gewählten Anbieter und erreichen den Entwickler nie. Deklariere **keine** zusätzliche Kategorie. |

Die Bilddateien liegen bewusst **nicht** in `byokey-state.json`, sondern einzeln im
Ordner `byokey-bilder` mit demselben Dateischutz. Die Zustandsdatei wird bei jeder
Änderung komplett neu geschrieben – ein Bild darin wären zwei Megabyte pro Tastendruck.
„Alle Daten löschen" entfernt den Ordner mit; verwaiste Bilder räumt der Start auf.

Zwei Fallen stecken genau in dieser Trennung, beide inzwischen zugenagelt:

- **Das Aufräumen darf nur laufen, wenn der Zustand wirklich gelesen wurde.** Nach einem
  Lese- **oder Dekodierfehler** ist `conversations` leer; ohne die Bedingung `!loadFailed`
  löschte `removeOrphans` sämtliche Bilder – also genau die Dateien, auf die die soeben in
  Quarantäne gelegte Zustandsdatei noch zeigt. Bei einem Dekodierfehler wird `loadFailed`
  deshalb ebenfalls gesetzt, nicht nur beim Lesefehler.
- **Der Dateiname muss sofort auf die Platte.** `finishImage` schreibt bei einem Bild
  synchron (`saveNow`) statt über die 600-Millisekunden-Verzögerung. Stirbt der Prozess in
  diesem Fenster, kennt niemand mehr den Dateinamen, und der nächste Start räumt die Datei
  als Waise weg – das Bild wäre nach einem Neustart spurlos verschwunden.

Angezeigt wird über `Services/ImageFileLoader.swift` (ImageIO, mit Verkleinerung auf
Anzeigegrösse) und **nicht** über `AsyncImage`. Letzteres geht für eine lokale Datei durch
`URLSession` samt Zwischenspeicher; genau daran scheiterte die Anzeige beim zweiten Öffnen
eines Chats, obwohl die Datei unversehrt im Ordner lag.

### Stimmen im Sprachmodus

Die Auswahl (`Views/VoicePickerView.swift`) listet, was `AVSpeechSynthesisVoice.speechVoices()`
auf dem jeweiligen Gerät zurückgibt – nach Qualität gruppiert, mit Hörprobe. **Keine fest
eingebauten Stimmkennungen**, insbesondere keine `com.apple.ttsbundle.siri_*`: Siri-Stimmen
gibt Apple Fremd-Apps nicht frei, und ein Zugriff über eine private Schnittstelle wäre eine
Ablehnung nach 2.5.1. Personal Voice (iOS 17+) wird über
`AVSpeechSynthesizer.requestPersonalVoiceAuthorization` angefragt – ein eigener
Info.plist-Zwecktext ist dafür nicht nötig, die Freigabe läuft über den Systemdialog.

Nicht in den Store-Text schreiben: „Siri-Stimme". Das wäre nach 2.3.1 falsch und nach 5.2.5
zusätzlich eine unzulässige Anlehnung an eine Apple-Marke.

### Datenfreigabe zeigt nur, was zählt (20.08.2026)

Der Abschnitt „Datenfreigabe an KI-Anbieter" listete alle neun Anbieter untereinander.
Wer OpenRouter eingerichtet hatte, sah darunter Mistral, DeepSeek, xAI und den Rest – und
musste raten, ob er die auch freigeben soll. Unübersichtlich, und sachlich irreführend: an
einen Anbieter, den man nicht benutzt, geht ohnehin nichts.

Jetzt zeigt der Abschnitt den **aktiven** Anbieter. Ein zweiter Abschnitt „Weitere
Anbieter" erscheint nur dann, wenn es welche gibt, für die bereits eine Freigabe erteilt
oder ein Schlüssel hinterlegt wurde.

**Warum die zweite Liste nicht wegfallen darf:** eine erteilte Zustimmung muss jederzeit
widerrufbar sein. Würde sie mit dem Anbieterwechsel aus der Ansicht verschwinden, wäre der
Widerruf faktisch an einen Anbieterwechsel gekoppelt – und die Zusage in den
Review-Notizen („revocable at any time in Settings") nicht mehr wahr. Die Bedingung ist
deshalb bewusst weit gefasst: Textfreigabe **oder** Audiofreigabe **oder** hinterlegter
Schlüssel genügt, damit ein Anbieter sichtbar bleibt.

### Was sich in dieser Runde geändert hat (19.08.2026)

Eine vollständige Prüfung von Quelltext gegen Dokumentation hat vier Stellen gefunden, an
denen die **Zusage schärfer formuliert war als die Umsetzung**. Alle vier sind geschlossen;
sie stehen hier, weil genau solche Lücken bei einer Prüfung teuer werden.

| Zusage | Was fehlte | Jetzt |
|---|---|---|
| „Jede Netzadresse in der Vorschau wird abgewiesen" | `decidePolicyFor` ruft WebKit **nur für Navigationen** auf, nicht für Unterressourcen. `<img src="https://…">`, entfernte Stylesheets, Webschriften sowie `fetch`, `XMLHttpRequest` und `sendBeacon` gingen ungefiltert hinaus. | Jede HTML-Datei der Vorschau bekommt beim Schreiben eine **Content-Security-Policy** als erstes Kopfelement: erlaubt sind `'self'`, `file:`, `data:`, `blob:`; `object-src`, `base-uri` und `form-action` stehen auf `'none'`. CSP ist eine Positivliste, `http:` und `https:` stehen schlicht nicht darauf. |
| „Im Modell-Layer erzwungen, nicht nur in der Oberfläche" | Zwei der vier Prüfungen lagen in SwiftUI-Ansichten, und `ProviderError.consentRequired` wurde nirgends geworfen. Es gab keinen erreichbaren Bypass – aber die Aussage stimmte nicht, und jede künftige Änderung hätte sie lautlos brechen können. | `requireConsent()` steht in **jeder** Netzmethode vor dem Bau des `URLRequest` und liest einen gesperrten Spiegel des Zustimmungsspeichers (`ConsentGate`). |
| „Markierte Antworten erst nach ausdrücklichem Antippen" | Die Fußzeile wurde unabhängig von der Markierung gezeigt: „Antwort kopieren" und „Vorlesen" griffen auf den verdeckten Volltext zu, im Anbieter-Modus wurde er dabei sogar hochgeladen. | Bei verdeckter Antwort entfällt die Fußzeile; `toggleSpeak` weist markierte Nachrichten zusätzlich im Modell-Layer ab. |
| „Mit einem Tippen restlos entfernt" | Eine früher in Quarantäne gelegte Zustandsdatei (`byokey-state-defekt-*.json`) enthielt den vollständigen Verlauf und überlebte das Löschen. | `deleteAllData()` räumt sie mit. |

Dazu zwei Punkte, die keine Richtlinienfrage sind, aber dieselbe Sorgfalt verdienen:

- **Der Projekt-Prompt wird jetzt mitgefiltert.** `screenOutgoingContext` verwarf pauschal
  alle System-Nachrichten – ausgenommen sind jetzt nur noch die beiden **eigenen**
  Sicherheitstexte, die naturgemäss benennen, was sie verbieten.
- **Zwei Fehltreffer im Krisenfilter.** „ritz" als Wortbestandteil traf „Spritze" und
  „Fritzbox" – und ein Treffer dort setzt in `screenInput` die Blockregel für
  Gewaltandrohung aus. Umgekehrt schalteten die Ausschlüsse „sie", „ihr", „meine" die
  Krisenregel bei Sätzen wie „ich will mich umbringen, ich halte das mit ihr nicht mehr
  aus" ab. Beides korrigiert: Wortformen statt Wortbestandteile, Wortfolgen statt blosser
  Pronomen.

### Weitere Punkte

| Richtlinie | Status |
|---|---|
| **4.2** Mindestfunktionalität | Unkritisch: Kostenrechnung pro Nachricht/Chat/Projekt/Monat, Budgetbalken, Projekte mit System-Prompt, Modellauswahl mit Preisen und Kontextlänge, Modellsperren, Meldeprotokoll, ZIP-Export der erzeugten Dateien, Sprachmodus, vollständige Datenlöschung. Deutlich mehr als eine verpackte Website. |
| **4.3(b)** Übersättigung | Reales Risiko – generische KI-Clients werden häufig abgelehnt. Gegenmaßnahme nur im Marketing: Kostenkontrolle, BYOK und der Dateiexport nach vorn, nicht „chatten mit KI". |
| **2.5.2** Kein nachgeladener Code | Kein JavaScriptCore, kein `dlopen`, keine Fremdbibliothek. Markdown und Code-Highlighting sind selbst geschrieben und rendern nur Text. Exportierte Dateien werden geschrieben, nie ausgeführt. Der einzige WKWebView ist die HTML-Vorschau – eingezäunt auf lokale Dateien, Begründung weiter oben. |
| **2.5.1** Berechtigungen | Mikrofon und Spracherkennung werden erst beim Öffnen des Sprachmodus abgefragt, nie beim Start. Keine ungenutzten Purpose-Strings in der `Info.plist`. |
| **3.1.1 / 3.1.3** | App ist kostenlos, hat keine In-App-Käufe. Der Schlüssel schaltet **keine** App-Funktion frei – alles funktioniert auch ohne. Passt auf 3.1.3(f) („Free Stand-alone Apps"). |
| **5.1.1** Datenkontrolle | Kein Konto, kein Server. „Alle Daten löschen" entfernt Chats, Projekte, Meldungen, Einstellungen, Freigaben und alle Keychain-Einträge. |
| **Verschlüsselung / Export** | `ITSAppUsesNonExemptEncryption = false` – nur TLS und System-Keychain, beides befreit. Erspart die „Missing Compliance"-Abfrage bei jedem Upload. |
| **ATS** | Kein `NSAppTransportSecurity`-Eintrag → App Transport Security voll aktiv. |
| **Schlüsselspeicherung** | Keychain mit `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, **kein** iCloud-Sync. Mehrere benannte Schlüssel je Anbieter, je einer unter `apikey.entry.<uuid>`; die Zustandsdatei kennt nur Kennung, Anbieter und Namen – weder den Schlüssel noch seine verkürzte Darstellung. Anbieter und Name stehen zusätzlich als `kSecAttrLabel` am Keychain-Eintrag, damit sich die Liste nach einem Dateiverlust wiederherstellen lässt. Zustandsdatei mit `.completeFileProtectionUntilFirstUserAuthentication` – verschlüsselt auf der Platte, aber lesbar, wenn iOS die App im gesperrten Zustand startet. |
| **Angehängte Dateien** | PDF, Text und Quelltext werden **auf dem Gerät** ausgelesen; übertragen wird nur der Text, nie die Datei. Der Inhalt läuft beim Anhängen durch denselben Inhaltsfilter wie getippter Text (Richtlinie 1.2) – blockiert er, wird die Datei nicht angehängt. Die Datenkategorie „Der Inhalt von Dateien, die du anhängst" steht namentlich im Zustimmungsdialog (Richtlinie 5.1.2(i)). Ablage als eigene Datei im Container mit `.completeFileProtectionUntilFirstUserAuthentication`; „Alle Daten löschen" entfernt sie mit. **Keine** neue Kategorie im Privacy Manifest: es bleibt bei „User Content". |
| **Angehängte Bilder** | Die Auswahl läuft über `PhotosPicker` (`PHPickerViewController`) in einem **eigenen Prozess**: ByoKey fragt deshalb **keine** Fotoberechtigung ab und liest die Mediathek nie – die App bekommt genau die Bilder, die der Nutzer antippt. `NSPhotoLibraryUsageDescription` steht bewusst **nicht** in der `Info.plist`; nur `NSPhotoLibraryAddUsageDescription` für das Sichern erzeugter Bilder. Vor dem Senden wird auf dem Gerät auf höchstens 1536 px verkleinert und als JPEG kodiert. Übertragen wird das verkleinerte Bild – über `/chat/completions` als Bildteil der Nachricht, bei einem Bildmodell an dessen Endpunkt als `input_references`. Die App filtert dabei **nicht** nach den Fähigkeiten des Modells: was ein Modell kann, weiß der Anbieter, und ein stillschweigend weggelassenes Bild wäre für den Nutzer schlechter als die Fehlermeldung des Anbieters. Passen Anhang und Modell erkennbar nicht zusammen, warnt die Chat-Ansicht **vor** dem Senden. Die Datenkategorie „Bilder, die du anhängst" steht namentlich im Zustimmungsdialog (Richtlinie 5.1.2(i)). Ablage wie bei Dateien im Container mit `.completeFileProtectionUntilFirstUserAuthentication`; „Alle Daten löschen" entfernt sie mit. Im Privacy Manifest **eine** zusätzliche Kategorie: `NSPrivacyCollectedDataTypePhotosorVideos` neben `…OtherUserContent`. Apple sieht für Fotos eine eigene vor, und ein Bild ist kein „ausgelesener Text". Muss mit den App-Privacy-Antworten in App Store Connect übereinstimmen. |
| **Inhaltsfilter und Bilder** | Der Filter auf dem Gerät liest Text. Was auf einem Bild zu sehen ist, kann er **nicht** beurteilen – und die App behauptet es auch nirgends. Für Bildinhalte greifen die Prüfung des Anbieters und die Melde- und Sperrfunktion nach Richtlinie 1.2, die für jede Antwort gilt. So steht es auch in der Datenschutzerklärung und in den Hinweisen für die Prüfung. |
| **Fehlertexte des Anbieters** | Werden vor dem Speichern geschwärzt (`KeychainStore.redactingSecrets`): mehrere Dienste geben bei HTTP 401 den abgelehnten Schlüssel in verkürzter Form zurück, und dieser Text landet als Nachricht im Verlauf. |

### Die rote Linie bei den Kosten

Die Anzeige des Anbieter-Guthabens (`fetchKeyInfo`) ist reine Leseinformation ohne Link.
So ist sie zulässig. **Sie kippt sofort in einen Verstoß gegen 3.1.1, wenn du**
einen „Guthaben aufladen"-Knopf, einen Link auf `openrouter.ai/credits` oder eine
Benachrichtigung bei niedrigem Guthaben hinzufügst. Auch die HTTP-402-Fehlermeldung
darf keinen Aufladehinweis bekommen.

---

## B. Vor dem Upload zu erledigen

### 1. Kontaktangaben – `ByoKey/AppInfo.swift` (eingetragen)

```swift
static let supportEmail     = "support@byokey.app"
// Englische Adressen; die Sprache des Textes kommt über ?lang= aus der App.
static var privacyPolicyURL: URL? { legalURL("privacy") }   // …/privacy?lang=de
static var termsURL: URL?         { legalURL("terms")   }   // …/terms?lang=en
```

`OpenRouterProvider.applyIdentityHeaders` schickt denselben Ursprung als `HTTP-Referer`.
Offen bleibt nur die Tatsache, dass die Adressen auch **antworten** müssen: Website
hochladen, Postfach `support@` einrichten.
Richtlinie 2.1(a) verlangt ausdrücklich „fully functional URLs"; ein 404 hinter dem
Datenschutz-Link ist eine sichere Ablehnung. Beide Seiten **auf Deutsch und Englisch** –
die Prüfung läuft auf Englisch.

**Fertige Website liegt bei:** `byokey-website/` enthält Vorstellseite, Datenschutz,
Nutzungsbedingungen, Impressum und Kontaktformular als lauffähiges PHP, zweisprachig.
Nur `inc/config.php` muss ausgefüllt werden. Details in `byokey-website/README.md`.

Textvorlagen zum Nachlesen: `Docs/DATENSCHUTZ-VORLAGE.md`, `Docs/NUTZUNGSBEDINGUNGEN-VORLAGE.md`

### 2. Bundle Identifier und Team

In Xcode → Target ByoKey → Signing & Capabilities:
`PRODUCT_BUNDLE_IDENTIFIER` steht auf `de.byokey.app`. Auf deine eigene ID ändern
und Team auswählen.

### 3. Demo-Zugang für die Prüfung (Richtlinie 2.1)

Ohne Schlüssel ist die App für den Prüfer eine leere Hülle – das ist eine der
häufigsten Ablehnungen bei BYOK-Apps. Eine eingebaute Demo ohne Schlüssel wäre nur
mit vorheriger Genehmigung durch Apple erlaubt. Also:

1. Bei OpenRouter einen **eigenen Schlüssel nur für die Prüfung** anlegen,
   mit hartem Limit (ca. 5 USD).
2. App Store Connect → App Review Information:
   - „Sign-in required": **an**
   - Benutzername: `openrouter` (Feld darf nicht leer sein)
   - Passwort: der Schlüssel `sk-or-v1-…`
3. Diesen Schlüssel **nicht rotieren**, solange die Prüfung läuft.
4. Notizen aus `Docs/APP-REVIEW-NOTES.md` wörtlich einfügen.

### 4. Altersfreigabe

Antworte danach, was das Modell ausgeben *kann*, nicht danach, was du beabsichtigst.

| Frage | Antwort |
|---|---|
| Chatbot / KI-Funktion | **Ja** |
| Nutzergenerierte Inhalte | **Ja** |
| Werbung | Nein |
| Uneingeschränkter Webzugriff | **Nein.** Die HTML-Vorschau ist der einzige WKWebView und lädt ausschließlich lokale Dateien; jede Netzadresse wird abgewiesen. Diese Antwort ist verteidigbar – aber nur, weil der Zaun im Modell-Layer sitzt. Wer ihn entfernt, muss hier auf **Ja** wechseln und landet in der höchsten Stufe (18+). |
| Soziale Medien (Pflicht ab Sept. 2026) | **Nein** – kein Feed, keine Verbreitung zwischen Nutzern |
| Sexuelle Inhalte / Schimpfwörter / Gewalt | mindestens **selten / mild** |
| Medizinische Informationen | **selten** – niemals „häufig" |

Der Sprachmodus und der Dateiexport ändern an der Einstufung nichts: kein zusätzlicher
Inhaltstyp, keine Verbreitung zwischen Nutzern.

**Erwartetes Ergebnis: 13+, realistisch 16+.**

Zwei Fallen:
- **„Häufig" bei medizinischen Informationen** löst seit März 2026 die Pflicht zur
  Angabe eines regulatorischen Medizinprodukte-Status aus. Halte
  `LSApplicationCategoryType` auf `public.app-category.productivity` und wähle keine
  Zweitkategorie aus Health/Medical.
- **18+ vermeiden**, solange es nicht zwingend ist: seit 24. Feb. 2026 müssen Nutzer
  in Australien, Brasilien und Singapur eine Altersverifikation bestehen, um 18+-Apps
  zu laden. Hochstufen kannst du später jederzeit.

### 5. App Privacy („Nutrition Label")

Verlockend wäre **„Data Not Collected"** – nach Apples Definition sogar vertretbar,
weil du keinen Server betreibst. **Tu es trotzdem nicht.** Ein Prüfer sieht dieses
Label neben einem Vollbild-Dialog, der sagt „deine Nachrichten gehen an OpenRouter, Inc.".
Genau dieser Widerspruch ist ein dokumentierter 5.1.2(i)-Ablehnungsgrund.

Deklariere stattdessen **genau zwei** Einträge – deckungsgleich mit
`ByoKey/PrivacyInfo.xcprivacy`:

- **User Content → Other User Content** (Nachrichtentext, ausgelesener Dateitext)
- **User Content → Photos or Videos** (Bilder, die der Nutzer selbst anhängt)
- Zweck jeweils: **App Functionality**
- jeweils **Not linked to the user** und **Not used for tracking**

Der zweite Eintrag kam mit den Bildanhängen dazu: Apple sieht für Fotos eine eigene
Kategorie vor, und ein Bild ist kein „ausgelesener Text". Dass die App die Mediathek nie
ausliest (PhotosPicker läuft ausser Prozess), ändert daran nichts – entscheidend ist, dass
das Bild das Gerät Richtung Anbieter verlässt.

Sonst nichts: keine Identifiers, keine Usage Data, keine Diagnostics, keine Contact Info.
Übermäßiges Deklarieren zieht nur Rückfragen nach sich. Insbesondere **kein „Audio Data"**
für den Sprachmodus – siehe die Begründung im Abschnitt zum Sprachmodus.

Der API-Schlüssel bekommt keine eigene Kategorie; er wird in der Datenschutzerklärung
behandelt. Die Angaben müssen zu `ByoKey/PrivacyInfo.xcprivacy` passen – dort ist
dieselbe Kategorie plus `NSPrivacyAccessedAPICategoryUserDefaults / CA92.1` hinterlegt
(ohne diese Datei scheitert der Upload mit **ITMS-91053**).

### 6. EU-Händlerstatus (DSA)

Apps ohne verifizierten Händlerstatus werden **aus dem EU-App-Store entfernt** –
gilt seit 17. Feb. 2025 und wird durchgesetzt. Für dich als deutschen Entwickler Pflicht:
App Store Connect → Business → Trader Status. Name, Anschrift, Telefon und E-Mail
erscheinen dann öffentlich auf der Produktseite – das erfüllt nebenbei die
„published contact information" aus Richtlinie 1.2.

### 7. Metadaten

Häufigster Ablehnungsgrund bei BYOK-Apps. Richtlinie 4.1(c) (Nov. 2025):
*„You cannot use another developer's icon, brand, or product name in your app's icon
or name."*

- **Name, Untertitel, Keywords: keine** Fremdmarken – kein „ChatGPT", „GPT", „Claude",
  „Gemini", „OpenAI", „Anthropic", „DeepSeek".
- **In der Beschreibung** ist die sachliche Kompatibilitätsangabe zulässig:
  „kompatibel mit OpenRouter und OpenAI-kompatiblen Endpunkten". Keine fremden Logos
  im Icon oder in Screenshots.
- **Modell-IDs in der App** (`anthropic/claude-…`) kommen aus der Anbieter-API und sind
  sachliche Bezeichner – unkritisch.
- **Pflichthinweis in der Beschreibung** (Richtlinie 2.3.1):
  > „Hinweis: ByoKey benötigt einen eigenen API-Schlüssel eines Drittanbieters
  > (z. B. OpenRouter). Die Nutzung der KI-Modelle rechnet dieser Anbieter direkt mit
  > dir ab. ByoKey verkauft kein Guthaben, erhält keine Provision und betreibt keinen
  > eigenen Server."
- **Screenshots**: iPhone **und** iPad. Zeige die App in Benutzung, nicht den
  Onboarding-Screen. Erstes Bild: Kostenaufschlüsselung oder Budgetübersicht, nicht
  die Chat-Begrüßung – das arbeitet zugleich gegen den 4.3-Verdacht. Keine
  beliebige Modellausgabe abfotografieren (muss 4+-tauglich sein).
- **Sprachmodus in der Beschreibung** nur mit dem Zusatz, dass er ein sprachfähiges
  Modell voraussetzt, wenn er über den Anbieter laufen soll. „Sprich mit jeder KI" wäre
  nach 2.3.1 irreführend. Formulierungsvorschlag:
  > „Sprachmodus: sprechen und vorlesen lassen. Auf dem Gerät mit jedem Modell,
  > über den Anbieter mit dessen Sprachmodellen – nicht jeder Anbieter bietet sie an."

### 8. Laufender Betrieb

Richtlinie 1.2 verlangt „timely responses to concerns". Das ist kein einmaliger Haken:

- Meldungen an `supportEmail` zeitnah bearbeiten
- `ContentModeration.rules` nachschärfen, wenn Meldungen Lücken zeigen
- **Stärkere Option für Version 1.1:** Da Nutzer ohnehin einen Schlüssel haben, den
  kostenlosen Moderations-Endpunkt des Anbieters aufrufen
  (`POST /v1/moderations`, `omni-moderation-latest`) und die lokale Liste nur als
  Rückfallebene nutzen. Das macht aus einer Stichwortliste eine belastbare
  „method for filtering objectionable material".

---

## Checkliste

- [ ] `AppInfo.swift`: echte Support-Adresse und erreichbare URLs (DE + EN)
- [ ] Datenschutzerklärung und Nutzungsbedingungen veröffentlicht
- [ ] Bundle Identifier und Signing-Team gesetzt
- [ ] `PrivacyInfo.xcprivacy` im Target enthalten
- [ ] OpenRouter-Prüfschlüssel mit Limit angelegt, in Demo-Feldern eingetragen
- [ ] Review-Notizen aus `Docs/APP-REVIEW-NOTES.md` eingefügt
- [ ] Altersfreigabe-Fragebogen ausgefüllt (Chatbot ja, UGC ja, Web nein, Social nein)
- [ ] HTML-Vorschau auf dem Gerät geprüft: eine Seite mit `<a href="https://…">` antippen –
      es muss der Hinweis „Externer Aufruf blockiert" erscheinen, nicht die Seite
- [ ] App Privacy: „User Content → Other User Content" **und** „User Content → Photos or
      Videos" – beide App Functionality, nicht verknüpft, kein Tracking
- [ ] EU-Händlerstatus abgeschlossen
- [ ] Metadaten frei von Fremdmarken, Pflichthinweis in der Beschreibung
- [ ] App-Store-Metadaten mindestens auf Englisch (USA) vollständig; Deutsch und
      Polnisch nachziehen, sonst bleibt die Übersetzung im Store unsichtbar
- [ ] Jeden der neun Anbieter einmal mit echtem Schlüssel durchgespielt: Modell-Liste
      lädt, Antwort kommt, Tokenzahl erscheint (oder fehlt nachvollziehbar)
- [ ] Screenshots iPhone + iPad, Kostenansicht zuerst
- [ ] `ITSAppUsesNonExemptEncryption = false` belassen, keine ungenutzten Purpose-Strings
- [ ] Sprachmodus einmal auf einem echten Gerät durchgespielt (Simulator hat kein Mikrofon):
      Freigabedialoge erscheinen, Erkennung läuft auf dem Gerät, Widerruf stoppt die Aufnahme
- [ ] Beschreibung des Sprachmodus enthält den Hinweis auf sprachfähige Modelle (2.3.1)
- [ ] ZIP-Export einmal geprüft: „In Dateien sichern" legt ein Archiv ab, das sich öffnen lässt

---

## Quellen

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Richtlinien-Update 13. Nov. 2025 – 5.1.2(i), 4.1(c), 4.7](https://developer.apple.com/news/?id=ey6d8onl)
- [Richtlinien-Update 6. Feb. 2026 – 1.2](https://developer.apple.com/news/?id=d75yllv4)
- [Neue Altersfreigaben in App Store Connect](https://developer.apple.com/news/?id=ks775ehf)
- [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/)
- [EU-Händlerstatus](https://developer.apple.com/news/upcoming-requirements/?id=02172025a)
- [Altersverifikation Texas/Utah/Louisiana](https://developer.apple.com/news/?id=sg176nne)
