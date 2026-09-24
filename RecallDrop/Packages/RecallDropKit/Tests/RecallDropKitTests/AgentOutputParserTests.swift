//
//  AgentOutputParserTests.swift
//  RecallDropKitTests
//

import XCTest
import RecallDropKit

final class AgentOutputParserTests: XCTestCase {
    private let now = Fixtures.date(2026, 9, 24, 10, 30, zone: Fixtures.berlin)

    private func parse(_ raw: String) -> ParsedAgentOutput {
        AgentOutputParser.parse(raw, now: now, timeZone: Fixtures.berlin)
    }

    func testCleanJSON() {
        let result = parse("""
        {"title":"Onboarding emails that convert","summary":"Three-email sequence.","actionableSteps":["Draft email 1","Schedule A/B test"],
         "tags":["Marketing","#Email Marketing","marketing"],"thoughtProcess":["Saw a tweet thread","It lists a sequence"],
         "suggestedReminder":"2026-09-25T09:00","confidence":0.82}
        """)
        XCTAssertTrue(result.wasStructured)
        XCTAssertEqual(result.output.title, "Onboarding emails that convert")
        XCTAssertEqual(result.output.actionableSteps, ["Draft email 1", "Schedule A/B test"])
        XCTAssertEqual(result.output.tags, ["marketing", "email-marketing"])
        XCTAssertEqual(result.output.thoughtProcess.count, 2)
        XCTAssertEqual(result.output.suggestedReminder, Fixtures.date(2026, 9, 25, 9, 0, zone: Fixtures.berlin))
        XCTAssertEqual(result.output.confidence ?? 0, 0.82, accuracy: 0.0001)
    }

    func testFencedJSONWithPreambleAndAliases() {
        let result = parse("""
        Sure! Here is the analysis:
        ```json
        {
          "Title": "## Pricing page idea",
          "description": "A slider-based pricing table.",
          "action_items": [{"step": "Sketch the slider", "details": "mobile first"}, {"text": "Compare with competitors"}],
          "keywords": "pricing, ui, Conversion Rate",
          "reasoning": "- Looked at layout\\n- Identified slider",
          "reminder": null,
          "confidence": "90%"
        }
        ```
        Let me know if you need more.
        """)
        XCTAssertTrue(result.wasStructured)
        XCTAssertEqual(result.output.title, "Pricing page idea")
        XCTAssertEqual(result.output.summary, "A slider-based pricing table.")
        XCTAssertEqual(result.output.actionableSteps, ["Sketch the slider – mobile first", "Compare with competitors"])
        XCTAssertEqual(result.output.tags, ["pricing", "ui", "conversion-rate"])
        XCTAssertEqual(result.output.thoughtProcess, ["Looked at layout", "Identified slider"])
        XCTAssertNil(result.output.suggestedReminder)
        XCTAssertEqual(result.output.confidence ?? 0, 0.9, accuracy: 0.0001)
    }

    func testTrailingCommasAndNestedWrapper() {
        let result = parse(#"{"result": {"title": "Nested", "summary": "Inside", "tags": ["a1", "b2",],}}"#)
        XCTAssertTrue(result.wasStructured)
        XCTAssertEqual(result.output.title, "Nested")
        XCTAssertEqual(result.output.tags, ["a1", "b2"])
    }

    func testTruncatedJSONIsRepaired() {
        let result = parse(#"{"title": "Cut off reply", "summary": "The model stopped", "actionableSteps": ["First step", "Second st"#)
        XCTAssertTrue(result.wasStructured)
        XCTAssertEqual(result.output.title, "Cut off reply")
        XCTAssertEqual(result.output.summary, "The model stopped")
        XCTAssertEqual(result.output.actionableSteps.first, "First step")
    }

    func testTruncatedInsideKeyDropsIncompleteMember() {
        let result = parse(#"{"title": "Partial", "summary": "Kept", "actionab"#)
        XCTAssertTrue(result.wasStructured)
        XCTAssertEqual(result.output.title, "Partial")
        XCTAssertEqual(result.output.summary, "Kept")
    }

    func testBracesInsideStringsDoNotConfuseExtraction() {
        let result = parse(#"{"title": "Use {curly} braces", "summary": "A \"quoted\" } brace"}"#)
        XCTAssertEqual(result.output.title, "Use {curly} braces")
        XCTAssertEqual(result.output.summary, #"A "quoted" } brace"#)
    }

    func testPlainTextFallback() {
        let result = parse("""
        # Weekend hiking plan
        A scenic 12 km loop near the lake with a café at the halfway point.
        - Check the weather forecast
        - Pack snacks and water
        1. Book the train
        Tags: hiking, outdoors
        #travel
        """)
        XCTAssertFalse(result.wasStructured)
        XCTAssertEqual(result.output.title, "Weekend hiking plan")
        XCTAssertTrue(result.output.summary.contains("scenic 12 km loop"))
        XCTAssertEqual(result.output.actionableSteps, ["Check the weather forecast", "Pack snacks and water", "Book the train"])
        XCTAssertEqual(Set(result.output.tags), ["hiking", "outdoors", "travel"])
    }

    func testPastRemindersAreIgnored() {
        let result = parse(#"{"title": "Old event", "summary": "x", "suggestedReminder": "2026-09-01T09:00:00Z"}"#)
        XCTAssertNil(result.output.suggestedReminder)
    }

    func testReminderWithOffsetAndDateOnly() {
        let withOffset = parse(#"{"title": "t", "summary": "s", "suggestedReminder": "2026-10-01T18:30:00+02:00"}"#)
        XCTAssertEqual(withOffset.output.suggestedReminder, Fixtures.date(2026, 10, 1, 16, 30, zone: Fixtures.utc))
        let dateOnly = parse(#"{"title": "t", "summary": "s", "suggestedReminder": "2026-10-02"}"#)
        XCTAssertEqual(dateOnly.output.suggestedReminder, Fixtures.date(2026, 10, 2, 9, 0, zone: Fixtures.berlin))
    }

    func testLongTitlesAreTruncatedAtWordBoundary() {
        let longTitle = String(repeating: "word ", count: 40)
        let result = parse("{\"title\": \"\(longTitle)\", \"summary\": \"s\"}")
        XCTAssertLessThanOrEqual(result.output.title.count, AgentOutputParser.maximumTitleLength)
        XCTAssertTrue(result.output.title.hasSuffix("…"))
    }

    func testEmptyJSONFallsBackToText() {
        let result = parse(#"{"unrelated": 1}"#)
        XCTAssertFalse(result.wasStructured)
    }

    func testTagNormalizer() {
        XCTAssertEqual(TagNormalizer.normalize("#Product Design"), "product-design")
        XCTAssertEqual(TagNormalizer.normalize("  UX_Tips!! "), "ux-tips")
        XCTAssertEqual(TagNormalizer.normalize("C++"), "c++")
        XCTAssertEqual(TagNormalizer.normalize("Café Culture"), "café-culture")
        XCTAssertNil(TagNormalizer.normalize("###"))
        XCTAssertEqual(TagNormalizer.normalize(["A", "a", "#a", "b"]), ["a", "b"])
        XCTAssertEqual(TagNormalizer.merge(["design"], with: ["Design", "ui"]), ["design", "ui"])
        let long = TagNormalizer.normalize(String(repeating: "x", count: 50))
        XCTAssertEqual(long?.count, TagNormalizer.maximumLength)
    }

    func testFlexibleDateParser() {
        let zone = Fixtures.berlin
        XCTAssertEqual(FlexibleDateParser.parse("2026-10-02T09:15", timeZone: zone), Fixtures.date(2026, 10, 2, 9, 15, zone: zone))
        XCTAssertEqual(FlexibleDateParser.parse("2026-10-02 09:15:30.123Z", timeZone: zone),
                       Fixtures.date(2026, 10, 2, 9, 15, zone: Fixtures.utc).addingTimeInterval(30))
        XCTAssertEqual(FlexibleDateParser.parse("2026-10-02T09:15-0500", timeZone: zone), Fixtures.date(2026, 10, 2, 14, 15))
        XCTAssertNil(FlexibleDateParser.parse("2026-02-30", timeZone: zone))
        XCTAssertNil(FlexibleDateParser.parse("next friday", timeZone: zone))
        XCTAssertNil(FlexibleDateParser.parse("2026-13-01", timeZone: zone))
        XCTAssertEqual(FlexibleDateParser.parseTimestamp("2025-02-19T00:00:00Z"), Fixtures.date(2025, 2, 19))
    }
}
