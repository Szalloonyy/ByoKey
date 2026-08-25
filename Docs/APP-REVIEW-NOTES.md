# App Review Notes

Diesen Text **wörtlich** in App Store Connect → App Information → App Review Information → Notes
einfügen. Er ist auf Englisch, weil die Prüfung auf Englisch stattfindet, und er beantwortet
jede Richtlinie vorab, nach der ein Prüfer bei dieser Art App greifen würde.

Die Kontaktangaben sind eingetragen – der Block lässt sich unverändert kopieren.

---

```
ByoKey — notes for App Review

1. WHAT THE APP IS
ByoKey is a local client for AI chat APIs. The user supplies their own API key for a
third-party provider. Nine providers are supported (OpenRouter, Mistral AI, OpenAI,
Cerebras, DeepSeek, Google Gemini, Groq, Together AI, xAI); each is a separate recipient
with its own consent screen, its own named legal entity and its own privacy policy link. Requests go directly from the device to the
provider's official HTTPS endpoint. We operate no server of any kind. There is no account
system, no analytics, no ads, and no in-app purchase. Chats and projects are stored only in
the app container; API keys are stored only in the iOS Keychain with
kSecAttrAccessibleWhenUnlockedThisDeviceOnly (no iCloud sync).

2. HOW TO TEST — the app requires an API key, and one is provided
An OpenRouter API key is supplied in the Password field of this submission.
a) Launch the app. Swipe through the three onboarding pages and tap
   "Bedingungen akzeptieren und starten" (Accept terms and start).
b) Tap the gear icon at the top right of the sidebar to open "Einstellungen" (Settings).
c) Under "Datenfreigabe an KI-Anbieter" (Data sharing with AI providers), switch
   OpenRouter ON. The switch does not grant consent by itself: it opens the consent
   screen described in section 3, which names the recipient, itemizes every data
   category and links the provider's privacy policy. Consent is given there, by
   tapping "Zustimmen und senden" (Agree and send). Nothing is transmitted to any
   provider before that — which is why this step comes first. The same screen stays
   reachable afterwards via "Was gesendet wird ansehen" (See what is sent) in the
   same section.
d) Under "API-Schlüssel" (API keys), paste the key from the Password field, then tap
   "Sichern und prüfen" (Save and verify). You should see "Verbindung steht"
   (Connection works) with a green checkmark, followed by a dialog asking you to name
   the key — accept the suggested name with "Sichern" (Save) or type your own.
   Several keys per provider are supported; the one with the checkmark is the one in
   use. Keys live in the iOS keychain only, never in the app's state file.
e) Tap "Fertig" (Done), then type a message and send it. Token count and cost in USD
   appear under each answer.
f) Optional — file export: ask the model for a small web page ("Erstelle index.html und
   style.css"), then open the "…" menu on that answer and choose "Dateien exportieren"
   (Export files). The share sheet offers the files individually or as a .zip, and
   "Seite ansehen" (View page) renders the HTML locally — see section 8.
g) Optional — voice mode: tap the waveform button next to the text field. The default
   path runs entirely on the device and needs no further setup. The "i" button on that
   screen opens the explanation of why a chat model is not a voice model.
The app ships in German, English and Polish. It follows the device language on first
launch; the language can also be changed inside the app at any time under
Settings › Sprache (Language), with immediate effect. If your device is set to English,
every screen below appears in English.

3. GUIDELINE 5.1.2(i) — THIRD-PARTY AI DATA SHARING
Before the first byte leaves the device, the app presents a dedicated consent screen.
It appears on the first send, whenever the consent switch in Settings › Datenfreigabe is
turned on, and at any time via "Was gesendet wird ansehen" in that same section. It names the recipient by legal entity
("OpenRouter, Inc. (USA)"), states the concrete purpose, itemizes every data category
that is transmitted — message text, project system prompt, conversation history, model
identifier and generation settings, the API key used for authentication, and the IP
address — and links the provider's privacy policy. Consent requires an affirmative tap;
nothing is pre-selected and the default is off. Consent is stored per provider and per
purpose (text and audio are stored independently), is revocable at any time in Settings,
and takes effect immediately. Settings › Datenfreigabe shows the consent for the provider
that is currently selected, plus a second section listing every other provider the user
has already granted or stored a key for — so a granted consent is always reachable and
always revocable, while a user of a single provider is not asked to reason about eight
recipients they never contact — a revocation cancels a stream that is already running and
discards the result of an upload that is already in flight. Granting one provider never
grants another. Where a provider's own documentation states something the user should
weigh, the consent screen says so plainly — for example that DeepSeek processes data in
the People's Republic of China and uses inputs for training unless the user objects, or
that Google's free tier trains on and human-reviews API content. With consent off, the app
performs NO network call to the provider — not even fetching the model list. This is
enforced in the network layer itself: every provider method (chat completions, model
list, key and credit lookup, image generation, transcription, speech synthesis) calls
requireConsent() before it builds a URLRequest, and that check reads a lock-protected
mirror of the consent store, not any view state. A missing consent throws
ProviderError.consentRequired. The user interface has its own checks on top so the user
sees an explanation rather than an error — but the interface is not what enforces it.

4. GUIDELINE 1.2 — USER-GENERATED / AI-GENERATED CONTENT
The app displays output generated by third-party models, so all four requirements of 1.2
are implemented:
- Filtering: a content filter screens the user's input before it leaves the device and the
  model's answer before it is displayed. A mandatory, non-overridable safety system prompt
  is part of every request; a project's own system prompt is itself screened by the same
  filter before it is sent, and the safety rules are placed after it, so a project prompt
  can add to them but never replace them. Flagged answers are collapsed behind a warning
  and are only revealed on an explicit tap — while collapsed the message has no action row
  at all, so the text cannot be copied, exported or read aloud either, and the read-aloud
  path additionally refuses flagged messages in the model layer. The core rules cannot be switched off; the "strenger Inhaltsfilter"
  setting only adds further borderline flagging on top of them.
- Reporting: every assistant message has "Inhalt melden" (Report content) in its "…" menu.
  The report is always recorded in the app (Settings › Meldungen) and can additionally be
  sent by email to our published support address. If no mail account is configured, the app
  shows the address with a copy action rather than failing silently.
- Blocking: the app has no other users. There is no user-to-user communication, no feed,
  no profiles and nothing shared between users, so there is no user to block. The
  equivalent control we provide is blocking the AI model that produced the objectionable
  output ("Modell sperren"). Blocked models can no longer be selected and are managed
  under Settings › Gesperrte Modelle.
- Published contact information: support@byokey.app, shown in the app under
  Settings › Rechtliches und Kontakt and on our website. A permanent notice under the
  composer in every chat states that AI answers can be wrong and should be checked, and
  links a feedback form that opens a prepared email to the same address.
Users must actively accept terms containing a zero-tolerance clause for objectionable
content before the chat interface becomes reachable at all.

5. VOICE MODE — MICROPHONE, SPEECH RECOGNITION, SEPARATE CONSENT
Voice mode is optional and off until the user opens it. It has two independent paths and
the app explains the difference on a dedicated information screen inside the feature
("Sprache und Modelle"), because chat endpoints accept and return text only:
- On-device (default): SFSpeechRecognizer with requiresOnDeviceRecognition = true and
  AVSpeechSynthesizer. The recording never leaves the device; this path works with any chat model
  and costs nothing. Apple's server-side recognition is used only if the user turns it on
  explicitly in Settings; the default is off.
- Provider: the provider's own audio endpoints (/audio/transcriptions, /audio/speech).
  This requires the user to select audio-capable models and requires a SEPARATE consent,
  stored independently from the text consent (ConsentScope.audio) and revocable at any
  time — both from the voice screen and from Settings › Datenfreigabe, where a granted
  audio consent always appears next to the provider it belongs to, whichever provider is
  currently selected. Recordings are deleted from the device immediately after upload and are capped at
  60 seconds.
The microphone and speech-recognition permission prompts appear only when voice mode is
opened, never at launch. Usage descriptions in Info.plist state the concrete purpose and
the recipient. The consent check runs before every recording and before every synthesis in
the model layer (VoiceModeView.voiceGateOK), not only when the sheet is presented.
Revoking audio consent cancels a recording already in progress.
No audio is stored by the app and none reaches the developer, so no additional App Privacy
category is declared for this feature.

6. FILE EXPORT — WRITTEN, NEVER EXECUTED
When an answer contains source files (PHP, HTML, Swift, …), the user can review the
detected filenames, rename or deselect them, and save them through the standard share
sheet ("Save to Files") — either individually, under their own names, or bundled as a
.zip. The ZIP writer is our own code, contained in the app; nothing is downloaded,
unpacked, interpreted or executed at any point — the app writes text files. Filenames
proposed by a model are sanitized so they cannot escape the app's temporary directory,
and that directory is cleared when the sheet is opened and again when it is closed.

7. IMAGE GENERATION
Some providers offer image models. When the user selects one, the app sends the prompt to
that provider's image endpoint (/images or /images/generations) instead of the chat
endpoint, and displays the returned image. The image is stored only in the app container.
It can be saved in two ways, both add-only: a "Bild sichern" (Save image) button that calls
PHPhotoLibrary with PHAccessLevel.addOnly, and the standard share sheet. The app requests
NO read access to the photo library — NSPhotoLibraryUsageDescription is deliberately absent
from Info.plist, only NSPhotoLibraryAddUsageDescription is declared. Nothing is ever read,
fetched or enumerated from the library. Tapping an image opens a local full-screen viewer
(pinch and double-tap to zoom); it displays the file from the app container and performs
no network access.
Being explicit about the limit of our own filter: the content filter analyses text. It
screens the prompt before it is sent, exactly as it screens any other message, but it
cannot inspect a returned image. Objectionable imagery is therefore caught by the
provider's own moderation (all supported image providers run one) and by the user, who can
report any answer and block the model that produced it — the same two controls as for text.
No additional data leaves the device: the prompt goes to the provider the user has already
consented to, so no separate consent is introduced.

8. HTML PREVIEW — LOCAL FILES ONLY, NOT A BROWSER
The export screen can display the generated HTML files so the user can check a layout on
the device. This is the only WKWebView in the app and it is deliberately fenced in:
- It renders only files the user just generated, from the app's own temporary directory,
  loaded with loadFileURL(_:allowingReadAccessTo:). Nothing is downloaded. The app gains
  no functionality from it — without the preview the app does exactly the same things.
- Two independent fences, because they cover different things:
  (a) decidePolicyFor allows file:// URLs inside that one directory and nothing else.
      Every http/https URL, every redirect and every target="_blank" is cancelled and
      shown to the user as a blocked request. This covers navigations.
  (b) WebKit does not call that delegate for subresources, so every HTML file written for
      the preview additionally receives a Content-Security-Policy meta tag as the first
      element of its head: default-src, script-src, style-src, img-src, font-src,
      media-src, connect-src and frame-src are limited to 'self', file:, data: and blob:,
      with object-src, base-uri and form-action set to 'none'. CSP is an allow-list, so
      http: and https: are simply not on it. This covers remote images, stylesheets,
      fonts, fetch, XMLHttpRequest and navigator.sendBeacon.
  The preview therefore cannot be used as a general-purpose browser and cannot reach the
  network at all, which is why we answer "No" to unrestricted web access in the age
  rating.
- websiteDataStore is .nonPersistent(); the directory is deleted when the preview closes.
- JavaScript alert/confirm/prompt are answered and surfaced as a notice rather than left
  hanging.
PHP is not executed and cannot be — that would require an interpreter in the bundle,
which 2.5.2 forbids. The app states this in the preview itself.

9. GUIDELINE 4.7 / 2.5.2 — NO THIRD-PARTY SOFTWARE, NO DOWNLOADED CODE
The app does not download, host, or execute any third-party software. It contains no
JavaScript engine of its own, no dynamic code loading and no third-party packages.
Model responses are rendered as plain text and Markdown; code blocks are
syntax-highlighted for display and are never executed. The only web view is the local
HTML preview described in section 8.

10. GUIDELINE 3.1.1 / 3.1.3 — PAYMENTS
The app is free and has no in-app purchase. The user's API key pays the third-party
provider directly under the user's own contract with that provider; it does not unlock any
feature of ByoKey — every feature of the app is available without it. On explicit request
(Settings › "Verbrauch beim Anbieter abfragen") the app displays the credit usage the
provider reports for the user's own key. This is read-only account information. The app
contains no purchase mechanism, no link to buy credit and no call to action to purchase
anywhere.

11. FILE AND IMAGE ATTACHMENTS
The paperclip next to the text field opens a menu with two entries: "Choose photo" and
"Choose file".

Photos: "Choose photo" presents PhotosPicker (PHPickerViewController), which runs out of
process. The app therefore requests **no** photo library permission and never reads the
library; it receives exactly the images the user taps. A selected image is downscaled on
device to at most 1536 px on the long edge, re-encoded as JPEG and sent to the provider
as an image part of the message (or, for image-generation models, as
"input_references"). This exists because image models produce far better results from a
reference image than from a written description. Image attachments count against the
context budget with the usual tile estimate and are shown with that estimate before
sending. They cannot be truncated, so an image that does not fit is declined with an
explanation instead of being silently cut.

Content filter and images: the on-device filter reads text and cannot judge what an
image shows. The app does not pretend otherwise — this is stated in the privacy policy
and in the app. Image content is covered by the provider's own moderation and by the
in-app report and block functions required by Guideline 1.2, which apply to every
answer regardless of what was attached.

Files: "Choose file" opens the system document picker. Only PDFs, text
files, source code and images can be selected; everything else is greyed out. The text is
extracted **on device** (PDFKit for PDFs) and travels to the provider as part of the
message — the file itself is never uploaded. Extracted text passes the same content
filter as typed input, once, at attach time; a file whose content is blocked is not
attached at all. The extracted text is stored as a separate file in the app container
(protected with NSFileProtectionCompleteUntilFirstUserAuthentication) and is removed by
"Alle Daten löschen". The consent dialog names "the content of files you attach" as its
own data category. No new App Privacy category: this is User Content, as already
declared. Scanned PDFs without a text layer are rejected with an explanation; there is
no OCR. The consent dialog names "images you attach" as its own data category as well.

12. PRIVACY
The developer receives no user data at any point. The App Privacy declaration lists
User Content → Other User Content and User Content → Photos or Videos, both App
Functionality, not linked to the user, not used for tracking — reflecting that message
text, extracted file text and images the user attaches are transmitted to the user's
chosen provider after explicit consent. The same two entries are in
PrivacyInfo.xcprivacy. No tracking, no advertising identifiers, no analytics SDKs.

13. KNOWN LIMITS, DISCLOSED DELIBERATELY
The on-device keyword filter operates on German and English. Polish input is not matched
by the keyword rules; the binding safety system prompt and the output filter apply
regardless of language, as do the report and block functions. Version 1.1 will add the
provider's own moderation endpoint as the primary filter and keep the local rules as a
fallback. The filter reads text and cannot judge what an attached or generated image
shows — this is stated in the app, in the privacy policy and on the website.

14. CONTACT FOR THIS REVIEW
Maximilian Skibinski, support@byokey.app, +49 15569483487
```

---

## Demo-Felder

| Feld | Wert |
|---|---|
| Sign-in required | **an** |
| User name | `openrouter` (darf nicht leer sein) |
| Password | der Prüfschlüssel `sk-or-v1-…` |

**Wichtig:** einen eigenen OpenRouter-Schlüssel nur für die Prüfung anlegen, mit hartem
Limit (ca. 5 USD), und ihn **nicht rotieren**, solange die Prüfung läuft. Ein mitten in
der Prüfung ungültig gewordener Schlüssel ist eine selbst verursachte 2.1-Ablehnung.
