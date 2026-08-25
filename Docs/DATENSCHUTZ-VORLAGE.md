# Datenschutzerklärung – Vorlage

Diese Vorlage deckt die drei Elemente ab, die Apple nach Richtlinie 5.1.1(i) in einer
Datenschutzerklärung sehen will: **welche Daten**, **Weitergabe an Dritte**,
**Aufbewahrung und Löschung**. Sie ersetzt keine Rechtsberatung – lass sie prüfen,
insbesondere wegen DSGVO und Drittlandtransfer in die USA.

Veröffentliche sie unter der URL, die in `AppInfo.privacyPolicyURL` steht, **und** in einer
englischen Fassung. Dieselbe URL gehört in App Store Connect ins Feld „Privacy Policy URL".

---

## Deutsch

### Datenschutzerklärung für ByoKey

**Verantwortlich:** [Name], [Anschrift], [E-Mail]

#### 1. Grundsatz

ByoKey ist eine reine Geräte-App. Der Anbieter dieser App betreibt **keinen Server**,
erhebt keine Nutzungsdaten, verwendet keine Analyse- oder Werbe-Bibliotheken und erhält
zu keinem Zeitpunkt eine Kopie deiner Inhalte.

#### 2. Welche Daten die App verarbeitet

Auf deinem Gerät gespeichert:

- Chats, Nachrichten und deren Zeitstempel
- Projekte samt System-Prompt und Standardmodell
- Token- und Kostenangaben zu jeder Antwort
- App-Einstellungen und erteilte Datenfreigaben
- Deine API-Schlüssel
- im Sprachmodus vorübergehend die Tonaufnahme (siehe Abschnitt 3a)
- der ausgelesene Text und die verkleinerten Bilder deiner Anhänge, als eigene
  Dateien im App-Container

Chats, Projekte und Einstellungen liegen in einer Datei im App-Container mit
`NSFileProtectionCompleteUntilFirstUserAuthentication` (nach dem ersten Entsperren
seit dem Einschalten lesbar, davor nicht). API-Schlüssel liegen
ausschließlich in der iOS-Keychain mit `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` –
also ohne iCloud-Abgleich; sie verlassen das Gerät nur als Anmeldedaten gegenüber dem
von dir gewählten Anbieter.

#### 3. Weitergabe an Dritte

Nach deiner **ausdrücklichen, jederzeit widerrufbaren Zustimmung** überträgt die App
folgende Daten direkt von deinem Gerät an den von dir gewählten KI-Anbieter:

- den Text deiner Nachrichten
- den ausgelesenen Text von Dateien, die du anhängst
- Bilder, die du anhängst – auf dem Gerät verkleinert und als JPEG kodiert
- den System-Prompt des jeweiligen Projekts
- den bisherigen Verlauf des offenen Chats
- die Kennung des gewählten Modells sowie Temperatur und maximale Antwortlänge
- deinen API-Schlüssel, ausschließlich zur Authentifizierung
- technisch bedingt deine IP-Adresse

Empfänger:

- **OpenRouter, Inc.**, USA – <https://openrouter.ai/privacy>
  OpenRouter leitet die Anfrage an den Betreiber des von dir gewählten Modells weiter,
  zum Beispiel Anthropic, Google, Meta oder OpenAI.
- **OpenAI, L.L.C.**, USA – <https://openai.com/policies/privacy-policy>

Diese Unternehmen sind eigenständig Verantwortliche; es gelten deren
Datenschutzerklärungen. Die Verarbeitung findet in den USA statt, also außerhalb der EU.
Rechtsgrundlage der Übermittlung ist deine Einwilligung nach Art. 6 Abs. 1 lit. a und
Art. 49 Abs. 1 lit. a DSGVO. Ohne Zustimmung überträgt die App nichts – auch keine
Modell-Liste.

Eine Weitergabe an andere Empfänger findet nicht statt. Es gibt kein Tracking im Sinne
der App Tracking Transparency.

#### 3a. Sprachmodus und Dateiexport

Der Sprachmodus ist freiwillig; Mikrofon und Spracherkennung werden erst beim Öffnen
abgefragt. In der Voreinstellung **auf dem Gerät** laufen Aufnahme, Erkennung und
Sprachausgabe lokal, es wird nichts übertragen. Nur wenn du in den Einstellungen
ausdrücklich die serverseitige Erkennung erlaubst, geht die Aufnahme zur Umwandlung an
Apple. Wählst du den Weg **über den Anbieter**, wird die Aufnahme an den von dir
gewählten KI-Anbieter übertragen; dafür holt die App eine **eigene, von der
Text-Freigabe getrennte Zustimmung** ein (Art. 6 Abs. 1 lit. a, Art. 49 Abs. 1 lit. a
DSGVO), die jederzeit widerrufbar ist. Aufnahmen werden nach der Umwandlung sofort
gelöscht und sind auf 60 Sekunden je Beitrag begrenzt.

Bilder, die du anhängst, wählst du in der Fotoauswahl von iOS aus. Sie läuft in einem
eigenen Prozess: die App fragt **keine** Berechtigung für die Fotomediathek ab und liest
dort nichts – sie erhält genau die Bilder, die du antippst. Vor dem Senden werden sie auf
dem Gerät auf höchstens 1536 Bildpunkte verkleinert und als JPEG kodiert; übertragen wird
diese verkleinerte Fassung, nicht die Originaldatei. Der Inhaltsfilter der App prüft Text
und kann **nicht** beurteilen, was auf einem Bild zu sehen ist; dafür gelten die Prüfung
des jeweiligen Anbieters und die Melde- und Sperrfunktion in der App.

Beim Dateiexport werden erkannte Quelltextdateien auf dem Gerät abgelegt – einzeln oder
als Archiv – und über das Teilen-Blatt von iOS an den Ort weitergegeben, den du wählst.
Dabei wird nichts übertragen. Die Seitenvorschau zeigt HTML-Dateien lokal an, lädt keine
Internetadressen und speichert keine Cookies; ihr Ordner wird beim Schließen gelöscht.

#### 4. Aufbewahrung, Löschung, Widerruf

Der Anbieter dieser App speichert nichts, also gibt es serverseitig auch nichts zu löschen.
Auf dem Gerät:

- **Einstellungen › Daten › „Alle Daten löschen"** entfernt Chats, Projekte, Meldungen,
  Einstellungen, erteilte Freigaben und sämtliche API-Schlüssel unwiderruflich.
- Das Löschen der App entfernt Chats, Projekte und Einstellungen. Schlüssel in der
  Keychain überleben eine Deinstallation systembedingt – benutze vorher
  „Alle Daten löschen", wenn auch sie verschwinden sollen.
- Die Zustimmung zur Datenweitergabe widerrufst du unter
  **Einstellungen › Datenfreigabe**. Ab dem Widerruf wird nichts mehr gesendet.

Für Daten, die bereits beim KI-Anbieter liegen, wende dich bitte an diesen Anbieter;
nur er kann sie löschen.

#### 5. Deine Rechte

Dir stehen Auskunft, Berichtigung, Löschung, Einschränkung, Datenübertragbarkeit und
Widerspruch nach DSGVO zu. Da wir keine Daten erheben, richten sich Auskunfts- und
Löschbegehren zu übermittelten Inhalten an den jeweiligen KI-Anbieter. Für alles Übrige:
[E-Mail]. Beschwerderecht bei einer Aufsichtsbehörde besteht.

#### 6. Kinder

Die App richtet sich nicht an Kinder. Sie zeigt Ausgaben von KI-Modellen an, die trotz
Inhaltsfilter unangemessen sein können.

#### 7. Änderungen

Ändert sich Umfang oder Empfänger der Datenweitergabe, wird die Zustimmung in der App
erneut eingeholt.

Stand: [Datum]

---

## English

### Privacy Policy for ByoKey

**Controller:** [Name], [Address], [Email]

#### 1. Principle

ByoKey is a device-only app. The developer operates **no server**, collects no usage data,
uses no analytics or advertising libraries, and never receives a copy of your content.

#### 2. Data the app processes

Stored on your device: chats and messages with timestamps, projects including system prompt
and default model, token and cost figures per answer, app settings and granted permissions,
and your API keys. In voice mode, the audio recording is held temporarily (see section 3a).
The extracted text and the downscaled images of your attachments are held as separate files
inside the app container.

Chats, projects and settings are held in a file inside the app container with
`NSFileProtectionCompleteUntilFirstUserAuthentication`. API keys are held only in the iOS Keychain with
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — no iCloud sync. Keys leave the device only
as credentials presented to the provider you selected.

#### 3. Sharing with third parties

After your **explicit, revocable consent**, the app transmits the following directly from
your device to the AI provider you selected: your message text, the extracted text of files
you attach, images you attach (downscaled on device and encoded as JPEG),
the project's system prompt, the current conversation history, the model
identifier together with temperature and maximum response length, your API key for
authentication, and — unavoidably — your IP address.

Recipients:

- **OpenRouter, Inc.**, USA — <https://openrouter.ai/privacy>. OpenRouter forwards the
  request to the operator of the model you selected, e.g. Anthropic, Google, Meta or OpenAI.
- **OpenAI, L.L.C.**, USA — <https://openai.com/policies/privacy-policy>

These companies act as independent controllers under their own privacy policies. Processing
takes place in the United States, outside the EU. The legal basis is your consent under
Art. 6(1)(a) and Art. 49(1)(a) GDPR. Without consent the app transmits nothing — not even
the model list. No data is shared with any other recipient. There is no tracking within the
meaning of App Tracking Transparency.

#### 3a. Voice mode and file export

Voice mode is optional; microphone and speech recognition are requested only when you open
it. In the default **on-device** setting, recording, recognition and speech output run
locally and nothing is transmitted. Only if you explicitly allow server-side recognition in
Settings does the recording go to Apple for conversion. If you choose the **provider**
path, the recording is transmitted to the AI provider you selected; the app obtains a
**separate consent for this, distinct from the text consent** (Art. 6(1)(a), Art. 49(1)(a)
GDPR), revocable at any time. Recordings are deleted immediately after conversion and are
capped at 60 seconds per turn.

Images you attach are chosen in the iOS photo picker. It runs in a separate process: the
app requests **no** photo library permission and reads nothing there — it receives exactly
the images you tap. Before sending, they are downscaled on the device to at most 1536
pixels and encoded as JPEG; it is this downscaled version that is transmitted, not the
original file. The app's content filter reads text and **cannot** judge what an image
shows; the provider's own moderation and the report and block functions in the app cover
that.

For file export, detected source files are written on the device – individually or as an
archive – and handed to the destination you choose through the iOS share sheet. Nothing is
transmitted. The page preview renders HTML locally, loads no internet addresses and stores
no cookies; its directory is deleted when it closes.

#### 4. Retention, deletion, withdrawal

The developer stores nothing, so there is nothing to delete server-side. On the device:
**Settings › Data › "Alle Daten löschen"** irreversibly removes chats, projects, reports,
settings, granted permissions and all API keys. Deleting the app removes chats, projects
and settings; keychain entries survive an uninstall by design, so use "Alle Daten löschen"
first if the keys should go too.
Consent is withdrawn under **Settings › Datenfreigabe**; from that moment nothing is sent.
For data already held by an AI provider, please contact that provider directly.

#### 5. Your rights

You have the rights of access, rectification, erasure, restriction, portability and
objection under the GDPR. As we collect no data, requests concerning transmitted content
should be addressed to the respective AI provider. For anything else: [Email]. You may
lodge a complaint with a supervisory authority.

#### 6. Children

The app is not directed at children. It displays output from AI models which, despite the
content filter, may be inappropriate.

#### 7. Changes

If the scope or the recipients of data sharing change, consent is requested again in the app.

Last updated: [Date]
