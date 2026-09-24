//
//  AgentPromptBuilder.swift
//  RecallDropKit
//
//  Builds the actual requests for the agent pipeline:
//
//      persona prompt  +  RecallDrop output contract   → system prompt
//      capture context (OCR text, link, notes, image)  → user message
//
//  The output contract is appended at run time instead of being part of the
//  persona, so any imported agency-agents persona produces the structured
//  result RecallDrop needs.
//

import Foundation

/// Everything an agent may know about one capture.
public struct CaptureContext: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case screenshot, photo, link, note

        public var label: String {
            switch self {
            case .screenshot: "Screenshot"
            case .photo: "Photo"
            case .link: "Link"
            case .note: "Note"
            }
        }
    }

    public var kind: Kind
    public var title: String?
    public var extractedText: String?
    public var userNotes: String?
    public var sourceURL: URL?
    public var sourceAppName: String?
    public var linkTitle: String?
    public var linkDescription: String?
    public var existingTags: [String]
    public var capturedAt: Date
    public var image: AIImageInput?
    public var existingSummary: String?
    public var existingActionItems: [String]
    /// Results of earlier agents in a chain, passed on as extra context.
    public var previousAnalyses: [PreviousAnalysis]

    public init(
        kind: Kind,
        title: String? = nil,
        extractedText: String? = nil,
        userNotes: String? = nil,
        sourceURL: URL? = nil,
        sourceAppName: String? = nil,
        linkTitle: String? = nil,
        linkDescription: String? = nil,
        existingTags: [String] = [],
        capturedAt: Date = Date(),
        image: AIImageInput? = nil,
        existingSummary: String? = nil,
        existingActionItems: [String] = [],
        previousAnalyses: [PreviousAnalysis] = []
    ) {
        self.kind = kind
        self.title = title
        self.extractedText = extractedText
        self.userNotes = userNotes
        self.sourceURL = sourceURL
        self.sourceAppName = sourceAppName
        self.linkTitle = linkTitle
        self.linkDescription = linkDescription
        self.existingTags = existingTags
        self.capturedAt = capturedAt
        self.image = image
        self.existingSummary = existingSummary
        self.existingActionItems = existingActionItems
        self.previousAnalyses = previousAnalyses
    }
}

public struct PreviousAnalysis: Sendable, Hashable {
    public var agentName: String
    public var output: AgentOutput

    public init(agentName: String, output: AgentOutput) {
        self.agentName = agentName
        self.output = output
    }
}

/// Date, zone and language the prompts are written for.
public struct PromptEnvironment: Sendable, Hashable {
    public enum ResponseLanguage: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
        /// Answer in the language of the user's device.
        case device
        /// Answer in the language of the captured content.
        case matchCapture

        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .device: "My Language"
            case .matchCapture: "Language of the Capture"
            }
        }
    }

    public var now: Date
    public var timeZone: TimeZone
    public var locale: Locale
    public var responseLanguage: ResponseLanguage

    public init(now: Date = Date(), timeZone: TimeZone = .current, locale: Locale = .current,
                responseLanguage: ResponseLanguage = .device) {
        self.now = now
        self.timeZone = timeZone
        self.locale = locale
        self.responseLanguage = responseLanguage
    }

    /// English name of the user's language ("German"), used inside prompts.
    public var languageName: String {
        let code = locale.language.languageCode?.identifier ?? "en"
        let english = Locale(identifier: "en_US")
        return english.localizedString(forLanguageCode: code) ?? "English"
    }

    /// "Thursday, 2026-09-24 10:30" in the user's zone – unambiguous for models.
    public var formattedNow: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: now)
        let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let weekday = weekdays[((parts.weekday ?? 1) - 1 + 7) % 7]
        func padded(_ value: Int?, _ width: Int = 2) -> String {
            let digits = String(value ?? 0)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        return "\(weekday), \(padded(parts.year, 4))-\(padded(parts.month))-\(padded(parts.day)) "
            + "\(padded(parts.hour)):\(padded(parts.minute))"
    }

    func formatted(_ date: Date) -> String {
        var copy = self
        copy.now = date
        return copy.formattedNow
    }
}

public enum AgentPromptBuilder {
    /// OCR text beyond this length is cut to keep requests fast and cheap.
    public static let defaultMaxContextCharacters = 12_000

    // MARK: Analysis

    public static func analysisRequest(
        persona: AgentPersona,
        context: CaptureContext,
        model: String,
        environment: PromptEnvironment,
        maxOutputTokens: Int?,
        includeImage: Bool,
        useJSONMode: Bool
    ) -> AIRequest {
        let images = includeImage ? [context.image].compactMap { $0 } : []
        return AIRequest(
            model: model,
            systemPrompt: analysisSystemPrompt(for: persona, environment: environment),
            messages: [.user(analysisUserMessage(for: context, environment: environment, imageAttached: !images.isEmpty),
                             images: images)],
            temperature: persona.temperature,
            maxOutputTokens: maxOutputTokens,
            responseFormat: useJSONMode ? .jsonObject : .text
        )
    }

    public static func analysisSystemPrompt(for persona: AgentPersona, environment: PromptEnvironment) -> String {
        let personaPrompt = persona.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = personaPrompt.isEmpty
            ? "You are \(persona.displayName), a helpful analyst. \(persona.roleDescription)"
            : personaPrompt
        return identity + "\n\n" + outputContract(environment: environment)
    }

    public static func outputContract(environment: PromptEnvironment) -> String {
        """
        ---
        ## RecallDrop Output Contract (always follow)
        You are running inside RecallDrop, a private visual second brain. The user captured something they don't want to forget – a screenshot, photo, link or quick note. Apply your role above to this capture.

        Reply with ONE JSON object and nothing else: no Markdown code fences, no text before or after it. Use exactly these keys:
        {
          "title": "specific, human-readable title, at most 70 characters",
          "summary": "1–4 sentences capturing the essence",
          "actionableSteps": ["concrete next step", "…"],
          "tags": ["lowercase-tag", "…"],
          "thoughtProcess": ["short observation or reasoning step", "…"],
          "suggestedReminder": "YYYY-MM-DDTHH:MM" or null,
          "confidence": 0.0 to 1.0
        }

        Rules:
        - actionableSteps: 0–7 items, each starting with a verb. Use [] when nothing is actionable.
        - tags: 3–7 items, lowercase, no "#", hyphens instead of spaces.
        - thoughtProcess: 2–6 brief strings showing how you analyzed the capture (what you saw, how you interpreted it).
        - suggestedReminder: a future local date and time only when a follow-up time is clearly useful, otherwise null.
        - Base everything on the capture. Never invent facts, numbers or links. If text is unreadable, say so in the summary.
        - \(languageInstruction(environment))
        - Current local date and time: \(environment.formattedNow) (\(environment.timeZone.identifier)).
        """
    }

    static func languageInstruction(_ environment: PromptEnvironment) -> String {
        switch environment.responseLanguage {
        case .device:
            return "Write title, summary, steps and thoughtProcess in \(environment.languageName), even when the capture uses another language. Keep quotes, names and code in their original language."
        case .matchCapture:
            return "Write title, summary, steps and thoughtProcess in the main language of the capture (use \(environment.languageName) if unclear). Keep quotes, names and code in their original language."
        }
    }

    public static func analysisUserMessage(
        for context: CaptureContext,
        environment: PromptEnvironment,
        imageAttached: Bool,
        maxCharacters: Int = defaultMaxContextCharacters
    ) -> String {
        var sections = ["Analyze this capture from my RecallDrop inbox."]
        sections.append(contextBlock(for: context, environment: environment, maxCharacters: maxCharacters))
        if !context.previousAnalyses.isEmpty {
            sections.append(previousAnalysesBlock(context.previousAnalyses))
        }
        if imageAttached {
            sections.append("The captured image is attached. Read it carefully – the on-device OCR text above may contain recognition errors.")
        } else if context.kind == .screenshot || context.kind == .photo {
            sections.append("The image itself is not attached; rely on the extracted text and metadata.")
        }
        sections.append("Respond with the JSON object described in your instructions.")
        return sections.joined(separator: "\n\n")
    }

    /// The `<capture>` block shared by analysis and chat.
    public static func contextBlock(for context: CaptureContext, environment: PromptEnvironment,
                                    maxCharacters: Int = defaultMaxContextCharacters) -> String {
        var metadata = ["Type: \(context.kind.label)", "Captured: \(environment.formatted(context.capturedAt))"]
        if let app = context.sourceAppName?.nonEmpty { metadata.append("Source app: \(app)") }
        if let url = context.sourceURL { metadata.append("Source URL: \(url.absoluteString)") }
        if let title = context.title?.nonEmpty { metadata.append("Current title: \(title)") }
        if !context.existingTags.isEmpty { metadata.append("Existing tags: \(context.existingTags.joined(separator: ", "))") }

        var blocks = ["<capture>\n" + metadata.joined(separator: "\n") + "\n</capture>"]

        if context.linkTitle?.nonEmpty != nil || context.linkDescription?.nonEmpty != nil {
            var link: [String] = []
            if let title = context.linkTitle?.nonEmpty { link.append("Page title: \(title)") }
            if let description = context.linkDescription?.nonEmpty {
                link.append("Description: \(truncated(description, to: 2000))")
            }
            blocks.append("<link_preview>\n" + link.joined(separator: "\n") + "\n</link_preview>")
        }
        if let text = context.extractedText?.nonEmpty {
            let source = context.kind == .note ? "note text" : (context.kind == .link ? "page text" : "on-device OCR")
            blocks.append("<extracted_text source=\"\(source)\">\n\(truncated(text, to: maxCharacters))\n</extracted_text>")
        }
        if let notes = context.userNotes?.nonEmpty {
            blocks.append("<user_notes>\n\(truncated(notes, to: 4000))\n</user_notes>")
        }
        return blocks.joined(separator: "\n\n")
    }

    static func previousAnalysesBlock(_ analyses: [PreviousAnalysis]) -> String {
        let entries = analyses.map { analysis -> String in
            var lines = ["### \(analysis.agentName)"]
            if !analysis.output.title.isEmpty { lines.append("Title: \(analysis.output.title)") }
            if !analysis.output.summary.isEmpty { lines.append("Summary: \(analysis.output.summary)") }
            if !analysis.output.actionableSteps.isEmpty {
                lines.append("Steps:\n" + analysis.output.actionableSteps.map { "- \($0)" }.joined(separator: "\n"))
            }
            if !analysis.output.tags.isEmpty { lines.append("Tags: \(analysis.output.tags.joined(separator: ", "))") }
            return lines.joined(separator: "\n")
        }
        return "<previous_analyses note=\"Earlier agents in this chain already produced these results. Build on them from your own perspective instead of repeating them.\">\n"
            + entries.joined(separator: "\n\n") + "\n</previous_analyses>"
    }

    static func truncated(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let kept = text.prefix(limit)
        return "\(kept)\n[… \(text.count - limit) more characters omitted]"
    }

    // MARK: Chat

    public static func chatRequest(
        persona: AgentPersona,
        context: CaptureContext,
        history: [AIMessage],
        model: String,
        environment: PromptEnvironment,
        maxOutputTokens: Int?,
        includeImage: Bool
    ) -> AIRequest {
        var messages = history
        if includeImage, let image = context.image,
           let firstUser = messages.firstIndex(where: { $0.role == .user }) {
            messages[firstUser].parts.insert(.image(image), at: 0)
        }
        return AIRequest(
            model: model,
            systemPrompt: chatSystemPrompt(for: persona, context: context, environment: environment),
            messages: messages,
            temperature: persona.temperature,
            maxOutputTokens: maxOutputTokens,
            responseFormat: .text
        )
    }

    public static func chatSystemPrompt(for persona: AgentPersona, context: CaptureContext,
                                        environment: PromptEnvironment) -> String {
        var summaryLines: [String] = []
        if let summary = context.existingSummary?.nonEmpty { summaryLines.append("Summary so far: \(summary)") }
        if !context.existingActionItems.isEmpty {
            summaryLines.append("Action items so far:\n" + context.existingActionItems.map { "- \($0)" }.joined(separator: "\n"))
        }
        let personaPrompt = persona.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        \(personaPrompt.isEmpty ? "You are \(persona.displayName)." : personaPrompt)

        ---
        ## RecallDrop Chat Mode
        You are chatting with the user about one capture from their RecallDrop library. Stay in your role, but answer conversationally in Markdown: short paragraphs, bullet lists where they help, no JSON. Be specific to this capture and say so when it does not contain the answer.
        - \(languageInstruction(environment).replacingOccurrences(of: "title, summary, steps and thoughtProcess", with: "your answers"))
        - Current local date and time: \(environment.formattedNow) (\(environment.timeZone.identifier)).
        \(context.image == nil ? "" : "- The captured image is attached to the first user message.")

        \(contextBlock(for: context, environment: environment))
        \(summaryLines.isEmpty ? "" : "\n" + summaryLines.joined(separator: "\n"))
        """
    }

    /// Starter questions offered in an empty chat.
    public static let suggestedChatPrompts: [String] = [
        "What's the key idea here?",
        "Turn this into a to-do list.",
        "Explain the design and tech used.",
        "Translate the text into my language.",
        "What should I research next?"
    ]
}

extension String {
    /// `nil` for empty or whitespace-only strings.
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
