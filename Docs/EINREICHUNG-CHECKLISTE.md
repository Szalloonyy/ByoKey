# ByoKey – Checkliste bis zur Einreichung

Stand: 21.08.2026. Abgearbeitet wird von oben nach unten; die Reihenfolge ist so gewählt,
dass nichts doppelt gemacht werden muss.

Was in dieser Liste **nicht** steht, ist erledigt. Der Quelltext, die Lokalisierung
(665 Schlüssel × DE/EN/PL), das Datenschutz-Manifest, das App-Icon, die Build-Einstellungen
und die Review-Notizen sind fertig und geprüft.

---

## 1. Was nur du tun kannst – ohne das geht gar nichts

### 1.1 Domain und Postfach

Die App zeigt an vier Stellen `support@byokey.app` und verlinkt
`https://byokey.app/privacy` sowie `/terms`. Domain und Adresse stehen
fest und sind überall eingetragen. Ein Prüfer, der auf „Datenschutzerklärung" tippt, darf
nicht im Nichts landen – das wäre der wahrscheinlichste Einzelgrund für eine Ablehnung
dieses Projekts (Richtlinie 1.2 „published contact information", 2.1 „App does not work
as expected").

- [x] Domain `byokey.app` – festgelegt und überall eingetragen
- [ ] Postfach `support@byokey.app` einrichten und **beantworten** – die Adresse ist der
      Meldeweg nach Richtlinie 1.2 und muss vor der Einreichung Post annehmen
- [ ] `byokey-website/` ins Wurzelverzeichnis hochladen (PHP ≥ 8.1, `chmod 700 .runtime`)
- [ ] Von aussen prüfen: `https://<domain>/privacy` und `/terms` müssen **HTTP 200**
      liefern, ebenso mit `?lang=de` und `?lang=pl`. Die alten Adressen
      `/datenschutz` und `/nutzungsbedingungen` müssen **301** auf die neuen liefern.
      Die Regeln stehen in der `.htaccess`; auf Hostern ohne `mod_rewrite` stattdessen
      in `AppInfo.legalURL` auf `datenschutz.php` und `nutzungsbedingungen.php`
      umstellen (die nginx-Entsprechung steht in `byokey-website/README.md`).
- [ ] Weicht die Domain von `byokey.app` ab: `ByoKey/AppInfo.swift` Zeilen 19–22 ändern
      und `OpenRouterProvider.swift` (`HTTP-Referer`) mit.

### 1.2 Impressum mit echten Daten

`byokey-website/inc/config.php` ist ausgefüllt: Maximilian Skibinski,
Wladimir-Komarow-Straße 41, 15517 Fürstenwalde, `support@byokey.app`, `+49 15569483487`.
Diese Werte erscheinen im Impressum, in der Datenschutzerklärung und in den
Nutzungsbedingungen.

- [x] `operator_name`, `operator_street`, `operator_zip`, `operator_city`, `operator_phone`
- [x] `vat_id` leer – blendet sich aus, solange keine USt-IdNr. vorhanden ist
- [x] `$updated` in `datenschutz.php` auf den 21.08.2026 gesetzt
- [ ] **Dieselben Angaben beim EU-Händlerstatus (DSA) hinterlegen.** Apple zeigt Name,
      Anschrift, Telefonnummer und E-Mail öffentlich auf der Produktseite an; weichen sie
      vom Impressum ab, ist das ein Widerspruch in zwei öffentlichen Registern.
- [ ] `$updated` in `nutzungsbedingungen.php` anfassen, sobald sich dort etwas ändert

### 1.3 Xcode 26 – vorbereitet, ein Handgriff bleibt

Seit dem **28.04.2026** nimmt App Store Connect nur noch Builds an, die gegen das
**iOS-26-SDK** erzeugt wurden. Das betrifft nur das SDK, mit dem gebaut wird – das
Bereitstellungsziel bleibt unberührt und steht weiter auf iOS 18.0.

Im Projekt erledigt:

- `LastUpgradeCheck` und `LastSwiftUpdateCheck` stehen auf `2600`
- `SDKROOT = iphoneos` zieht ohnehin immer das neueste installierte SDK – **es genügt,
  das Projekt mit Xcode 26 zu bauen**, eine Einstellung dafür gibt es gar nicht
- Der eine bekannte SDK-Bruch ist abgefangen: `AVAudioSession.CategoryOptions.allowBluetooth`
  heisst im iOS-26-SDK `allowBluetoothHFP`. `SpeechService.bluetoothOption` schaltet über
  `#if compiler(>=6.2)` um und übersetzt damit unter Xcode 16 **und** 26 warnungsfrei.
- Geprüft und unauffällig: kein `UIWebView`, kein `NSURLConnection`, kein `UIScreen.main`,
  keine `.appearance()`-Proxys, keine Fremdbibliothek. `SFSpeechRecognizer` ist in iOS 26
  **nicht** abgekündigt (`SpeechAnalyzer` ist die neue Empfehlung, nicht der Ersatzzwang).
- Die drei globalen Zwischenspeicher sind für Swift 6 vorbereitet
  (`nonisolated(unsafe)` bzw. `@MainActor`), damit ein späterer Sprachwechsel keine
  Fehlerlawine auslöst.

Was du tun musst:

- [ ] Projekt mit **Xcode 26** öffnen und archivieren
- [ ] **Falls Xcode „Update to recommended settings" anbietet: erst hinsehen, was es
      ändern will.** Akzeptiere es **nicht**, wenn `SWIFT_VERSION` auf `6.0` oder
      `SWIFT_STRICT_CONCURRENCY` auf `complete` gesetzt werden soll – der Quelltext ist
      auf Swift 5 mit `minimal` ausgelegt, und der Umstieg gehört in eine eigene Runde
      nach 1.0, nicht in die Einreichung.
- [ ] **Visuell durchklicken.** Mit dem iOS-26-SDK greift Apples neue
      Oberflächengestaltung automatisch auf alle Systemsteuerelemente durch:
      Navigationsleisten, Blätter, Knöpfe, `Form`, `List` und die Materialien in der
      Bildansicht. Der eigene Farbsatz (`Theme`) bleibt unberührt. Anzusehen sind vor
      allem `NavigationSplitView` auf dem iPad, die Symbolleisten in Chat und
      Einstellungen und der Sprachmodus im Vollbild.
      *(Der befristete Notausgang wäre `UIDesignRequiresCompatibility = true` in der
      Info.plist – bewusst nicht gesetzt: Apple nimmt ihn mit einem der nächsten SDKs
      wieder heraus, und dann steht dieselbe Arbeit erneut an.)*

### 1.4 Signierung – ein Klick

`CODE_SIGN_STYLE = Automatic` steht, und `DEVELOPMENT_TEAM = ""` ist in **beiden**
Konfigurationen angelegt. Xcode füllt den Wert selbst, sobald du das Team wählst – kein
Tippfehler-Risiko, keine falsch abgeschriebene ID.

- [ ] Xcode → Projektnavigator → Ziel **ByoKey** → **Signing & Capabilities** →
      unter *Team* deinen Entwickleraccount wählen. Xcode schreibt die zehnstellige ID
      danach in beide Konfigurationen.
- [ ] Danach prüfen: „Automatically manage signing" ist an, und unter *Signing
      Certificate* steht ein gültiges Zertifikat statt eines roten Hinweises.
- [ ] App-ID `de.byokey.app` im Developer-Portal anlegen – oder Xcode beim ersten
      Archivieren anlegen lassen. Die Kennung muss mit dem Eintrag in App Store Connect
      übereinstimmen.

### 1.5 Prüfschlüssel

Ohne Schlüssel ist die App für den Prüfer funktionslos – bei „Bring your own key"-Apps
der häufigste Ablehnungsgrund nach 2.1.

- [ ] OpenRouter-Schlüssel **nur für die Prüfung** anlegen, hartes Limit ca. 5 USD
- [ ] In App Store Connect: „Sign-in required" = **an**, User name `openrouter`
      (darf nicht leer sein), Password = der Schlüssel
- [ ] Während der laufenden Prüfung **nicht rotieren.** Ein mitten in der Prüfung ungültig
      gewordener Schlüssel ist eine selbst verursachte 2.1-Ablehnung.

### 1.6 Platzhalter in den Review-Notizen

- [x] `Docs/APP-REVIEW-NOTES.md`: Name, E-Mail und Telefonnummer sind eingetragen
- [ ] Den Block aus den Code-Fences wörtlich nach App Store Connect → App Review
      Information → Notes kopieren

---

## 2. App Store Connect

| Feld | Wert |
|---|---|
| **Privacy Policy URL** | `https://<domain>/privacy` – muss 200 liefern |
| **Support URL** | `https://<domain>/kontakt` – Pflichtfeld |
| **Marketing URL** | optional, `https://<domain>/` |
| **Kategorie** | Produktivität; Zweitkategorie z. B. Entwicklerwerkzeuge. **Nichts aus Gesundheit/Medizin** |
| **Export Compliance** | keine Aktion, `ITSAppUsesNonExemptEncryption = false` steht schon in der Info.plist |

### 2.1 Screenshots

`TARGETED_DEVICE_FAMILY = "1,2"` – iPad-Screenshots sind damit **Pflicht**, nicht optional.

- [ ] iPhone 6,9″: 1290 × 2796 **oder** 1320 × 2868
- [ ] iPad 13″: 2048 × 2732 **oder** 2064 × 2752
- [ ] **Erstes Bild: die Kostenaufschlüsselung mit Budgetbalken**, nicht das Onboarding.
      Das ist das Merkmal, das ByoKey von den hunderten generischen KI-Chat-Clients
      unterscheidet – und Richtlinie 4.3(b) (Übersättigung) ist bei dieser App-Art das
      zweitgrösste Risiko nach den toten Adressen.

### 2.2 Altersfreigabe

| Frage | Antwort |
|---|---|
| Chatbot / KI-generierte Inhalte | **ja** |
| Nutzergenerierte Inhalte | **ja** |
| Uneingeschränkter Webzugriff | **nein** – belegbar: die HTML-Vorschau ist doppelt eingezäunt (Navigationsfilter **und** Content-Security-Policy), sie erreicht das Netz nicht |
| Werbung, soziale Netzwerke, Glücksspiel | nein |
| Sexuelle Inhalte / Nacktheit, Gewalt, Schimpfwörter | **mindestens „selten/mild"** |
| Medizinische Informationen | „selten" – **niemals** „häufig", das löst die Medizinprodukte-Abfrage aus |

Erwartetes Ergebnis: 13+ oder 16+.

> **Bilderzeugung.** Der Inhaltsfilter arbeitet auf Text. Er prüft den Auftrag, **nicht**
> das erzeugte Bild. Ein Bildmodell kann Darstellungen liefern, die ein Textmodell nicht
> liefert. Wer bei „selten/mild" bleiben will, muss das verantworten; im Zweifel eine
> Stufe höher. Die Alternative wäre eine Positivliste geprüfter Bildmodelle statt der
> heutigen Erkennung über `output_modalities`.

### 2.3 App Privacy

Genau **zwei** Einträge – deckungsgleich mit `PrivacyInfo.xcprivacy`:

- User Content → **Other User Content** (Nachrichtentext, ausgelesener Dateitext)
- User Content → **Photos or Videos** (Bilder, die der Nutzer selbst anhängt)
- Zweck jeweils: **App Functionality**
- jeweils **nicht** mit dem Nutzer verknüpft, **nicht** für Tracking

Der zweite Eintrag kam mit den Bildanhängen dazu. Apple sieht für Fotos eine eigene
Kategorie vor; „Other User Content" deckt den ausgelesenen Text ab, nicht aber ein Bild.
Dass die App die Fotomediathek nie ausliest (PhotosPicker läuft in einem eigenen Prozess),
ändert daran nichts: entscheidend ist, dass das Bild das Gerät Richtung Anbieter verlässt.

Nichts sonst. Insbesondere **kein** „Audio Data": Aufnahmen gehen nur nach eigener Freigabe
an den vom Nutzer gewählten Anbieter, werden unmittelbar nach dem Hochladen vom Gerät
gelöscht und erreichen den Entwickler nie.

### 2.4 EU-Händlerstatus (DSA)

- [ ] App Store Connect → Business → Trader Status, mit den Daten aus 1.2.
      Pflicht seit 17.02.2025. **Ohne verifizierten Status wird die App aus dem
      EU-Store entfernt** – auch nachträglich.

### 2.5 Beschreibungstext

- [ ] Englisch (USA) **vollständig** – darin wird geprüft. Deutsch und Polnisch nachziehen,
      sonst bleiben die 665 übersetzten Texte im Store unsichtbar.
- [ ] Pflichthinweis nach 2.3.1 aufnehmen, sinngemäss:
      „ByoKey benötigt einen eigenen API-Schlüssel eines Drittanbieters. Die App verkauft
      kein Guthaben, erhält keine Provision und betreibt keinen eigenen Server."
- [ ] **Keine Fremdmarken** in Name, Untertitel oder Suchbegriffen (4.1(c), 5.2.5).
      Anbieternamen dürfen im Beschreibungstext sachlich genannt werden – aber nie so,
      dass eine Partnerschaft suggeriert wird. Nirgends „Siri-Stimme".

---

## 3. Vor dem Archivieren einmal durchspielen

- [ ] **Auf Englisch.** Sprache in den Einstellungen umstellen und die Bildschirme
      durchgehen, die ein Prüfer bei dieser App-Art ansteuert: Onboarding, Zustimmung,
      Melden, Fehlerfall, Berechtigungsdialoge.
- [ ] **Sprachmodus auf einem echten Gerät.** Der Simulator hat kein Mikrofon, und die
      Erkennung auf dem Gerät setzt voraus, dass iOS die eingestellte Sprache
      heruntergeladen hat (Einstellungen › Allgemein › Tastatur › Diktat).
- [ ] **Bild erzeugen, Chat verlassen, zurückkehren, scrollen.** Prüft Anzeige,
      Höhenreservierung und das Sichern in „Fotos" in einem Durchgang.
- [ ] **Bild anhängen – beide Wege.** Einmal über „Foto auswählen" (die Fotoauswahl darf
      **keinen** Berechtigungsdialog zeigen; tut sie es doch, steht ein falscher Schlüssel
      in der `Info.plist`), einmal über „Datei auswählen" aus der Dateien-App. Danach das
      Modell auf ein reines Textmodell wechseln und prüfen, dass die Warnleiste erscheint.
- [ ] **Vorlagenbild an ein Bildmodell.** Über OpenRouter mit einem Bildmodell ein Foto
      anhängen und ohne eigenen Text senden – in der eigenen Blase muss „Erzeuge ein neues
      Bild auf Grundlage der angehängten Vorlage." stehen. Bei einem Anbieter ohne
      Vorlagen-Unterstützung muss die Warnleiste vorher erscheinen.
- [ ] **Querformat auf dem iPhone** – ist erlaubt und bei Composer, Sprachmodus-Vollbild
      und HTML-Vorschau ungetestet. Alternative: in der `Info.plist` auf reines Hochformat
      reduzieren.
- [ ] **iPad mit zwei Fenstern** (Stage Manager). `UIApplicationSupportsMultipleScenes`
      steht auf `true`, beide Fenster teilen sich denselben Zustand. Wenn ungetestet:
      für 1.0 auf `false` setzen.
- [ ] Entscheiden, ob die App auf Macs mit Apple Silicon angeboten wird
      (App Store Connect → Pricing and Availability). Standardmässig **ja**, getestet ist
      es nicht.
- [ ] Ab dem zweiten Upload derselben Version: `CURRENT_PROJECT_VERSION` erhöhen.

---

## 4. Bekannte Grenzen – bewusst so eingereicht

Diese Punkte sind keine Fehler, sondern Entscheidungen. Sie stehen hier, damit sie nicht
in der Prüfung überraschen:

- **Der Inhaltsfilter arbeitet auf Deutsch und Englisch.** Polnische Eingaben treffen die
  Stichwortregeln nicht; der verbindliche Sicherheits-System-Prompt und der Ausgabefilter
  greifen weiterhin. Für 1.1 ist der Moderations-Endpunkt des Anbieters damit nicht mehr
  nur eine Verbesserung, sondern die Antwort auf eine echte Lücke.
- **Der Filter sieht kein Bild.** Weder das erzeugte noch das angehängte. Siehe
  Altersfreigabe oben; in der App und in der Datenschutzerklärung steht es ausdrücklich.
- **Bilder gehen an jedes gewählte Modell.** Die App filtert nicht danach, ob ein Modell
  Bilder versteht: das weiss der Anbieter, nicht sie. Passt es erkennbar nicht, warnt sie
  vorher; sendet der Nutzer trotzdem, ist die Fehlermeldung des Anbieters die ehrlichere
  Auskunft als ein stillschweigend weggelassenes Bild.
- **Anbieter „Eigener Endpunkt"** ist implementiert, aber bewusst nicht freigeschaltet:
  bei frei eintragbarer Adresse wäre der Empfänger unbekannt, und die Zustimmung nach
  5.1.2(i) liesse sich nicht sinnvoll einholen.
- **Kein Konto, kein Server, kein Kauf.** Damit entfallen 3.1.1 und 3.1.3(f) vollständig –
  aber auch jede Möglichkeit, einem Nutzer bei einem verlorenen Verlauf zu helfen.
