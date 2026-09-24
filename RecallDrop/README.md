# RecallDrop

A visual "second brain" for iPhone, iPad and Mac. RecallDrop keeps the
screenshots, links and quick ideas you collect from Instagram, Safari, X and
elsewhere. It reads the text in every image on the device, makes everything
searchable and hands each capture to an AI agent that turns it into a title,
a summary, next steps and tags. You bring your own API key.

- **Platforms:** iOS 17+, iPadOS 17+, macOS 14+ (one SwiftUI codebase)
- **Stack:** Swift 6 (strict concurrency), SwiftUI, SwiftData, Observation,
  Vision, UserNotifications, URLSession. No third-party dependencies.
- **Storage:** SwiftData store and settings in an App Group (shared by the app
  and the share extension); API keys in the Keychain.
- **AI:** OpenRouter, OpenAI, Anthropic or any OpenAI-compatible server
  (Ollama, LM Studio, vLLM, Jan). An "Offline Only" switch keeps every capture
  on the device.

## Getting started

Requirements: Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
cd RecallDrop
xcodegen generate
open RecallDrop.xcodeproj
```

Before running on a device, open `Config/RecallDrop.xcconfig` and set:

| Setting | Value |
| --- | --- |
| `DEVELOPMENT_TEAM` | Your Apple Developer Team ID, e.g. `ABCDE12345` |
| `RD_BUNDLE_ID_PREFIX` | A reverse-DNS identifier you own, e.g. `com.yourname.recalldrop` |

Everything else follows from these two values:

- iOS app: `RD_BUNDLE_ID_PREFIX`; share extension: `RD_BUNDLE_ID_PREFIX.share`
- iOS App Group: `group.RD_BUNDLE_ID_PREFIX`
- macOS App Group: `TEAMID.RD_BUNDLE_ID_PREFIX`, the form sandboxed Mac apps use

Signing is automatic, so Xcode registers the identifiers and the App Group for
you. Each target reads its App Group from the `RDAppGroupIdentifier` key in its
Info.plist, so the entitlements and the code always use the same identifier.

Run the schemes:

- **RecallDrop-iOS**: the iPhone/iPad app, with the share extension embedded
- **RecallDropShare**: debugs the share extension (Xcode asks which app to share from)
- **RecallDrop-macOS**: the Mac app with its menu bar extra

The generated `RecallDrop.xcodeproj` is git-ignored. Run `xcodegen generate`
again after you add or remove files.

## Features

### Capture

- **iOS:** the floating **+** button offers Paste, Photo Library (up to 12
  images at once), Take Photo, Scan Document, Save a Link and Quick Note. The
  **Share Sheet extension** saves images, links, web pages and text from any
  app, with an optional note, reminder and agent choice. Home Screen quick
  actions: New Capture, Quick Note, Search.
- **macOS:** a **menu bar extra** with quick capture, a note field and the
  recent captures, each with 1-click agent buttons. The **Drop Shelf**, opened
  from the menu bar or with a shortcut, is a floating drop target on every
  Space for images, files, links and text; drop onto an agent's tile to run
  that agent. You can also capture a screen region, paste from the clipboard,
  write a quick note, drag onto the main window or import files.
- Links are enriched with their page title, description and preview image
  (Open Graph/Twitter tags, plus oEmbed for X and YouTube).

### Understanding

1. **OCR** with Vision `VNRecognizeTextRequest`: accurate or fast mode,
   automatic language detection and reading-order layout.
2. **Agent analysis.** The image (downscaled JPEG), the recognized text,
   link metadata and your notes go to the chosen agent. The agent returns
   structured JSON: `title`, `summary`, `actionableSteps`, `tags`, an optional
   `suggestedReminder` and `confidence`. The parser also handles fenced,
   truncated and plain-text replies.
3. **On-device fallback.** With Offline Only on, or without an API key, new
   captures get a title, summary and keyword tags built on the device, plus
   action items for the dates, links, phone numbers and addresses that
   NSDataDetector finds. If you pick an AI agent anyway, the capture gets the
   on-device result first and shows "Waiting for AI". The agent then runs
   automatically once you add a key or turn Offline Only off.

### Agents

Every agent is an `AgentPersona` with a name, system prompt, assigned model,
temperature and default flag, stored as an `AgentConfig` in SwiftData.
Built-in agents:

| Agent | Purpose |
| --- | --- |
| 💡 Idea Extractor | The core idea, why it matters, how to use it (the default agent) |
| ✅ Action Planner | Concrete, ordered next steps, deadlines and reminders |
| 🎨 Visual & Tech Inspector | Code, UI, charts, errors and technical details |
| 🔎 Research Analyst | Claims, sources, credibility and further reading |

Agent Manager (the Agents tab or sidebar entry):

- Create, edit, duplicate, reorder and delete agents. Each agent can use its
  own model, or leave the field empty to use the global default.
- Import and export agents as **Markdown with YAML front matter**, the format
  used by [msitarzewski/agency-agents](https://github.com/msitarzewski/agency-agents).
  The **Agency Gallery** browses that repository and imports agents directly.
- Run several agents on one capture, re-run a different agent from the detail
  view, or pick one from the agent selector sheet. Every run is kept, and you
  can switch which run's result the capture shows.
- **Chat with a capture:** streaming chat that includes the screenshot and its
  text.

### Organise and act

- Masonry grid with Inbox, Pinned, Reminders, Archive and a view per tag.
- Search that tolerates accents and letter case. It supports `"exact phrase"`,
  `-exclude`, `#tag`, `agent:name` and filters such as `is:pinned`,
  `is:archived`, `has:reminder`, `has:actions`, `is:link`, `is:note`,
  `is:image`, `is:unanalyzed` and `is:failed`.
- Reminders: "In 2 Hours", "Tonight", "Tomorrow", "This Weekend", "Next Week"
  or a custom date. Notifications show a thumbnail and offer Snooze 1 Hour,
  Tomorrow Morning and Archive. Agents can suggest a reminder date for you to
  accept.
- Checkable action items, editable title, notes and tags, and a zoomable image
  viewer.
- Export the whole library as JSON or a single capture as Markdown. Deep links:
  `recalldrop://item/<uuid>`, `recalldrop://capture`, `recalldrop://note`,
  `recalldrop://search`.

## AI providers (bring your own key)

Settings → AI Provider:

| Provider | Base URL | Notes |
| --- | --- | --- |
| OpenRouter | `https://openrouter.ai/api/v1` | Hundreds of models, many multimodal. The model list shows vision support and free models. |
| OpenAI | `https://api.openai.com/v1` | Chat Completions; `max_completion_tokens` and reasoning models are handled. |
| Anthropic | `https://api.anthropic.com/v1` | Messages API (`anthropic-version: 2023-06-01`), images and streaming. |
| Custom / Local | `http://localhost:11434/v1` | Any OpenAI-compatible server. Presets for Ollama, LM Studio, vLLM and Jan. |

- Keys stay in the Keychain, shared with the share extension through the App
  Group's Keychain access group on iOS.
- **Test Connection** checks the key, lists the models and sends a tiny request.
- Each agent can override the global default model.
- Requests adapt when a model rejects an option: RecallDrop retries without
  temperature, without images, without JSON mode or with fewer output tokens,
  and says what changed.
- **Offline Only** blocks every network call to AI providers. Link previews
  still load unless you turn off Load Link Previews in the Capture & Analysis
  settings.

**Local models from an iPhone:** `localhost` on the phone is the phone itself.
Run Ollama on your Mac with `OLLAMA_HOST=0.0.0.0 ollama serve` and use
`http://your-mac.local:11434/v1`. iOS asks for Local Network access the first
time. Plain HTTP is allowed only for local hosts (`NSAllowsLocalNetworking`).

## macOS specifics

| Global shortcut (works in any app) | Default |
| --- | --- |
| Capture Screen Region | ⌃⌥⌘S |
| Capture Clipboard | ⌃⌥⌘V |
| Quick Note | ⌃⌥⌘N |
| Show/Hide Drop Shelf | ⌃⌥⌘D |

- Change or turn off the shortcuts in Settings → Menu Bar & Shortcuts. Each
  shortcut needs ⌘ or ⌃. They use Carbon hot keys, so they need no
  Accessibility permission. RecallDrop shows a warning when another app
  already owns a shortcut. When a shortcut is used from another app, the
  result appears in a short message at the top of the screen.
- **Capture Screen Region** runs the system `screencapture` tool and needs the
  **Screen Recording** permission (System Settings → Privacy & Security).
  Dropping, pasting and importing screenshots work without it.
- Options: hide the Dock icon (menu-bar-only mode), launch at login, and show
  the Drop Shelf at startup. Closing the last window keeps RecallDrop running
  in the menu bar.
- The app is sandboxed with the hardened runtime. Entitlements: outgoing
  network connections, user-selected files and the App Group.

## Project layout

```
RecallDrop/
├── project.yml                  XcodeGen spec (3 targets, 3 schemes)
├── Config/                      xcconfig, Info.plists, entitlements per target
├── Resources/                   Asset catalog (app icon, accent colour), privacy manifest
├── Packages/RecallDropKit/      Platform-independent core (Foundation only) + unit tests
│   └── Sources/RecallDropKit/
│       ├── AI/                  Provider kinds, OpenAI-compatible and Anthropic clients,
│       │                        SSE streaming, adaptive retries, error mapping, model capabilities
│       ├── Agents/              AgentPersona, built-in personas, prompt builder,
│       │                        structured output parser, Markdown codec, agency-agents catalog
│       ├── Capture/             Link metadata, OCR layout, text heuristics, on-device analysis
│       ├── Search/              Query syntax, folding, scoring, snippets
│       ├── Reminders/           Reminder presets and snooze options
│       ├── Layout/              Masonry distribution
│       └── Export/              JSON library export, Markdown export
├── Shared/                      Code shared by the iOS app, macOS app and share extension
│   ├── App/                     @main app, scenes, root modifiers, welcome screen
│   ├── Environment/             AppEnvironment (dependency container), App Group, router
│   ├── Models/                  SwiftData schema (CapturedItem, AgentConfig, AgentRun,
│   │                            ChatMessage), migration plan, persistence
│   ├── Services/                OCR, capture, agent pipeline, AI settings, Keychain,
│   │                            reminders, notifications, model catalog, chat, maintenance
│   ├── Components/              Theme, badges, image view, agent chips, clipboard helpers
│   └── Features/                Library (ItemGridView), Detail (ItemDetailView), Chat,
│                                Agents (AgentManagerView), Settings (AISettingsView),
│                                Search (SearchAndFilterView)
├── iOS/                         Tab UI, floating + button, capture sheet, camera and
│                                document scanner, quick actions
├── ShareExtension/              Share Sheet extension UI and controller
└── macOS/                       Menu bar extra, Drop Shelf, Quick Note panel, global
                                 shortcuts, screen capture, sidebar window, settings
```

The share extension compiles only `Shared/Models`, `Shared/Services`,
`Shared/Components` and `Shared/Environment`, all of which use only APIs that
are safe for app extensions. It saves a capture, optionally runs the agent
within the time the system gives it, and posts a Darwin notification so a
running app reloads right away.

## Tests

The core package builds and tests on macOS and Linux:

```sh
cd Packages/RecallDropKit
swift test
```

In Xcode, select the **RecallDropKit** package scheme and press ⌘U. The tests
cover both AI clients (request encoding, response parsing, streaming, errors
and retries against a mock transport), the output parser, persona Markdown,
search, reminders, masonry layout, link metadata and OCR layout.

## Privacy

- No analytics, no tracking and no developer server. Network requests go only
  to the AI provider you configure, to the pages you capture (for link
  previews) and to GitHub when you open the Agency Gallery.
- Images sent to an AI provider are downscaled JPEGs. You can stop sending
  images and send only the recognized text (Settings → AI Provider).
- The privacy manifest (`Resources/PrivacyInfo.xcprivacy`) declares the
  UserDefaults API use (reasons CA92.1 and 1C8F.1 for the App Group).
