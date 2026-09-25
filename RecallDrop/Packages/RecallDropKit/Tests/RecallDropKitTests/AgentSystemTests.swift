//
//  AgentSystemTests.swift
//  RecallDropKitTests
//

import XCTest
import RecallDropKit

final class AgentSystemTests: XCTestCase {
    // MARK: Built-ins

    func testBuiltInPersonas() {
        let all = BuiltInPersonas.all
        XCTAssertEqual(all.count, BuiltInPersonas.Key.allCases.count)
        XCTAssertEqual(all.filter(\.isDefault).count, 1)
        XCTAssertEqual(all.first?.id, BuiltInPersonas.ideaExtractorID)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        for persona in all {
            XCTAssertTrue(persona.isBuiltIn)
            XCTAssertTrue(persona.usesDefaultModel)
            XCTAssertTrue(persona.systemPrompt.contains("## "), "\(persona.name) follows the agency-agents structure")
            XCTAssertEqual(BuiltInPersonas.persona(forBuiltInKey: persona.builtInKey ?? "")?.id, persona.id)
        }
        XCTAssertEqual(BuiltInPersonas.all.map(\.id), BuiltInPersonas.all.map(\.id), "IDs are stable")
    }

    func testPersonaModelResolutionAndDuplicate() {
        var persona = BuiltInPersonas.persona(for: .actionPlanner)
        XCTAssertEqual(persona.resolvedModel(defaultModel: "gpt-4o"), "gpt-4o")
        persona.assignedModel = " openai/gpt-5-mini "
        XCTAssertEqual(persona.resolvedModel(defaultModel: "gpt-4o"), "openai/gpt-5-mini")
        let copy = persona.duplicated()
        XCTAssertNotEqual(copy.id, persona.id)
        XCTAssertNil(copy.builtInKey)
        XCTAssertFalse(copy.isDefault)
        XCTAssertEqual(copy.name, "Action Planner Copy")
    }

    func testAgentColorLooseNames() {
        XCTAssertEqual(AgentColor(loose: "Cyan"), .cyan)
        XCTAssertEqual(AgentColor(loose: "violet"), .purple)
        XCTAssertEqual(AgentColor(loose: "grey"), .gray)
        XCTAssertEqual(AgentColor(loose: "#12ab34"), .indigo)
    }

    // MARK: Markdown codec

    private let agencySample = """
    ---
    name: Frontend Developer
    description: Expert frontend developer specializing in modern web technologies, React/Vue/Angular frameworks, UI implementation, and performance optimization
    color: cyan
    tools: [Read, Write]
    model: sonnet
    ---

    # Frontend Developer Agent Personality

    You are **Frontend Developer**, an expert frontend developer who specializes in modern web technologies.

    ## 🧠 Your Identity & Memory
    - **Role**: Modern web application and UI implementation specialist
    """

    func testDecodeAgencyAgentsFile() throws {
        let persona = try PersonaMarkdownCodec.decode(agencySample)
        XCTAssertEqual(persona.name, "Frontend Developer")
        XCTAssertTrue(persona.roleDescription.hasPrefix("Expert frontend developer"))
        XCTAssertEqual(persona.colorName, "cyan")
        XCTAssertEqual(persona.assignedModel, "", "Claude Code aliases are not model IDs")
        XCTAssertTrue(persona.systemPrompt.hasPrefix("# Frontend Developer Agent Personality"))
        XCTAssertFalse(persona.systemPrompt.contains("---"))
        XCTAssertEqual(persona.emoji, "🎨")
        XCTAssertNil(persona.builtInKey)
    }

    func testDecodeWithoutFrontMatterUsesHeading() throws {
        let persona = try PersonaMarkdownCodec.decode("""
        # Growth Hacker Agent

        You find creative, low-cost ways to grow products.
        """)
        XCTAssertEqual(persona.name, "Growth Hacker")
        XCTAssertEqual(persona.roleDescription, "You find creative, low-cost ways to grow products.")
        XCTAssertEqual(persona.emoji, "📈")
    }

    func testDecodeBlockScalarsQuotesAndFallbackName() throws {
        let persona = try PersonaMarkdownCodec.decode("""
        ---
        description: >
          Reviews code for
          security issues.
        temperature: 3.5
        emoji: "🛡️"
        model: 'openai/gpt-4o'
        ---
        Check everything twice.
        """, fallbackName: "security-reviewer.md")
        XCTAssertEqual(persona.name, "Security Reviewer")
        XCTAssertEqual(persona.roleDescription, "Reviews code for security issues.")
        XCTAssertEqual(persona.temperature, 2.0)
        XCTAssertEqual(persona.emoji, "🛡️")
        XCTAssertEqual(persona.assignedModel, "openai/gpt-4o")
    }

    func testDecodeErrors() {
        XCTAssertThrowsError(try PersonaMarkdownCodec.decode("   \n")) {
            XCTAssertEqual($0 as? PersonaImportError, .empty)
        }
        XCTAssertThrowsError(try PersonaMarkdownCodec.decode("---\nname: Empty\n---\n\n")) {
            XCTAssertEqual($0 as? PersonaImportError, .missingPrompt)
        }
    }

    func testRoundTrip() throws {
        var original = BuiltInPersonas.persona(for: .visualTechInspector)
        original.assignedModel = "anthropic/claude-sonnet-5"
        original.roleDescription = "Looks at: UI, code & #colors"
        let markdown = PersonaMarkdownCodec.encode(original)
        XCTAssertTrue(markdown.hasPrefix("---\nname: Visual & Tech Inspector\n"))
        XCTAssertTrue(markdown.contains("description: \"Looks at: UI, code & #colors\""))

        let decoded = try PersonaMarkdownCodec.decode(markdown)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.roleDescription, original.roleDescription)
        XCTAssertEqual(decoded.systemPrompt, original.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(decoded.assignedModel, original.assignedModel)
        XCTAssertEqual(decoded.temperature, original.temperature)
        XCTAssertEqual(decoded.emoji, original.emoji)
        XCTAssertEqual(decoded.colorName, original.colorName)
    }

    func testFileNamesAndPrettifiedNames() {
        XCTAssertEqual(PersonaMarkdownCodec.fileName(for: BuiltInPersonas.persona(for: .visualTechInspector)), "visual-tech-inspector.md")
        XCTAssertEqual(PersonaMarkdownCodec.slug("  !!! "), "agent")
        XCTAssertEqual(PersonaMarkdownCodec.prettifiedName("design-ui-designer.md"), "Design UI Designer")
        XCTAssertEqual(PersonaMarkdownCodec.prettifiedName("engineering_devops-automator"), "Engineering DevOps Automator")
    }

    // MARK: Agency catalog

    func testParseTreeFiltersAndNamesEntries() throws {
        let tree = Data("""
        {"sha":"x","tree":[
          {"path":"README.md","type":"blob"},
          {"path":"design","type":"tree"},
          {"path":"design/design-ui-designer.md","type":"blob"},
          {"path":"design/README.md","type":"blob"},
          {"path":"engineering/engineering-frontend-developer.md","type":"blob"},
          {"path":".github/workflows/ci.md","type":"blob"},
          {"path":"examples/sample.md","type":"blob"},
          {"path":"project-management/studio producer.md","type":"blob"},
          {"path":"engineering/notes.txt","type":"blob"}
        ],"truncated":false}
        """.utf8)
        let entries = try AgencyAgentsCatalog.parseTree(tree, owner: "msitarzewski", repository: "agency-agents", branch: "main")
        XCTAssertEqual(entries.map(\.name), ["UI Designer", "Frontend Developer", "Studio Producer"])
        XCTAssertEqual(entries.map(\.category), ["Design", "Engineering", "Project Management"])
        XCTAssertEqual(entries.first?.rawURL.absoluteString,
                       "https://raw.githubusercontent.com/msitarzewski/agency-agents/main/design/design-ui-designer.md")
        XCTAssertEqual(entries.last?.rawURL.absoluteString,
                       "https://raw.githubusercontent.com/msitarzewski/agency-agents/main/project-management/studio%20producer.md")
    }

    func testGitHubRawURLConversion() {
        let blob = URL(string: "https://github.com/msitarzewski/agency-agents/blob/main/design/design-ui-designer.md")!
        XCTAssertEqual(AgencyAgentsCatalog.rawURL(forGitHubURL: blob)?.absoluteString,
                       "https://raw.githubusercontent.com/msitarzewski/agency-agents/main/design/design-ui-designer.md")
        let raw = URL(string: "https://raw.githubusercontent.com/a/b/main/c.md")!
        XCTAssertEqual(AgencyAgentsCatalog.rawURL(forGitHubURL: raw), raw)
        XCTAssertNil(AgencyAgentsCatalog.rawURL(forGitHubURL: URL(string: "https://github.com/msitarzewski/agency-agents")!))
        XCTAssertNil(AgencyAgentsCatalog.rawURL(forGitHubURL: URL(string: "https://example.com/agent.md")!))
    }

    func testFetchMarkdownRejectsHTML() async {
        let transport = MockTransport(responses: [
            HTTPResponse(statusCode: 200, headers: ["content-type": "text/html; charset=utf-8"], body: Data("<!DOCTYPE html><html></html>".utf8))
        ])
        do {
            _ = try await AgencyAgentsCatalog.fetchMarkdown(from: URL(string: "https://example.com/page")!, transport: transport)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CatalogError, .notMarkdown)
        }
    }

    func testCatalogRateLimit() async {
        let transport = MockTransport(responses: [.json(#"{"message":"API rate limit exceeded"}"#, status: 403)])
        let catalog = AgencyAgentsCatalog(transport: transport)
        do {
            _ = try await catalog.fetchEntries()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CatalogError, .rateLimited)
        }
        XCTAssertEqual(transport.requests.first?.url?.absoluteString,
                       "https://api.github.com/repos/msitarzewski/agency-agents/git/trees/main?recursive=1")
    }

    // MARK: Prompt builder

    private let environment = PromptEnvironment(
        now: Fixtures.date(2026, 9, 24, 8, 30),
        timeZone: Fixtures.berlin,
        locale: Locale(identifier: "de_DE")
    )

    func testAnalysisRequestCombinesPersonaContractAndContext() {
        let persona = BuiltInPersonas.persona(for: .actionPlanner)
        let context = CaptureContext(
            kind: .screenshot,
            extractedText: "Concert tickets on sale Friday 10:00",
            userNotes: "Ask Sam",
            sourceURL: URL(string: "https://www.instagram.com/p/abc"),
            sourceAppName: "Instagram",
            existingTags: ["music"],
            capturedAt: Fixtures.date(2026, 9, 24, 8, 0),
            image: Fixtures.sampleImage
        )
        let request = AgentPromptBuilder.analysisRequest(
            persona: persona, context: context, model: "gpt-4o", environment: environment,
            maxOutputTokens: 4096, includeImage: true, useJSONMode: true
        )
        XCTAssertEqual(request.model, "gpt-4o")
        XCTAssertEqual(request.temperature, persona.temperature)
        XCTAssertEqual(request.responseFormat, .jsonObject)
        XCTAssertTrue(request.containsImages)

        let system = request.systemPrompt ?? ""
        XCTAssertTrue(system.hasPrefix("# Action Planner"))
        XCTAssertTrue(system.contains("RecallDrop Output Contract"))
        XCTAssertTrue(system.contains("\"actionableSteps\""))
        XCTAssertTrue(system.contains("German"), "answers in the device language")
        XCTAssertTrue(system.contains("Thursday, 2026-09-24 10:30"), system)
        XCTAssertTrue(system.contains("Europe/Berlin"))

        let user = request.messages.first?.text ?? ""
        XCTAssertTrue(user.contains("Concert tickets on sale Friday 10:00"))
        XCTAssertTrue(user.contains("<user_notes>\nAsk Sam"))
        XCTAssertTrue(user.contains("Source app: Instagram"))
        XCTAssertTrue(user.contains("Existing tags: music"))
        XCTAssertTrue(user.contains("The captured image is attached"))
    }

    func testAnalysisRequestWithoutImageAndWithChain() {
        let context = CaptureContext(
            kind: .photo,
            extractedText: String(repeating: "a", count: 20),
            previousAnalyses: [PreviousAnalysis(agentName: "Idea Extractor",
                                                output: AgentOutput(title: "Idea", summary: "Sum", actionableSteps: ["Do"]))]
        )
        let request = AgentPromptBuilder.analysisRequest(
            persona: BuiltInPersonas.persona(for: .researchAnalyst), context: context, model: "m",
            environment: environment, maxOutputTokens: nil, includeImage: false, useJSONMode: false
        )
        XCTAssertFalse(request.containsImages)
        XCTAssertEqual(request.responseFormat, .text)
        let user = request.messages.first?.text ?? ""
        XCTAssertTrue(user.contains("<previous_analyses"))
        XCTAssertTrue(user.contains("### Idea Extractor"))
        XCTAssertTrue(user.contains("not attached"))
    }

    func testLongTextIsTruncated() {
        let text = String(repeating: "x", count: AgentPromptBuilder.defaultMaxContextCharacters + 500)
        let message = AgentPromptBuilder.analysisUserMessage(
            for: CaptureContext(kind: .note, extractedText: text), environment: environment, imageAttached: false
        )
        XCTAssertTrue(message.contains("500 more characters omitted"))
    }

    func testMatchCaptureLanguageInstruction() {
        var env = environment
        env.responseLanguage = .matchCapture
        let system = AgentPromptBuilder.analysisSystemPrompt(for: BuiltInPersonas.persona(for: .ideaExtractor), environment: env)
        XCTAssertTrue(system.contains("main language of the capture"))
    }

    func testChatRequestAttachesImageToFirstUserMessage() {
        let context = CaptureContext(kind: .screenshot, extractedText: "OCR", image: Fixtures.sampleImage,
                                     existingSummary: "A summary", existingActionItems: ["Step"])
        let request = AgentPromptBuilder.chatRequest(
            persona: BuiltInPersonas.persona(for: .ideaExtractor), context: context,
            history: [.user("What is it?"), .assistant("A poster."), .user("Colors?")],
            model: "m", environment: environment, maxOutputTokens: 2048, includeImage: true
        )
        XCTAssertEqual(request.messages.count, 3)
        XCTAssertTrue(request.messages[0].hasImages)
        XCTAssertFalse(request.messages[2].hasImages)
        let system = request.systemPrompt ?? ""
        XCTAssertTrue(system.contains("RecallDrop Chat Mode"))
        XCTAssertTrue(system.contains("Summary so far: A summary"))
        XCTAssertTrue(system.contains("<extracted_text"))
        XCTAssertFalse(system.contains("Output Contract"))
    }
}
