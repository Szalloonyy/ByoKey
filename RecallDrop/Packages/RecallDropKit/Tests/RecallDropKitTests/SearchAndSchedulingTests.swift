//
//  SearchAndSchedulingTests.swift
//  RecallDropKitTests
//

import XCTest
import RecallDropKit

final class SearchAndSchedulingTests: XCTestCase {
    // MARK: Search

    func testQueryParsing() {
        let query = SearchQuery(parsing: #"Café "exact phrase" -spam #Design is:pinned has:reminder agent:idea is:unknownflag"#)
        XCTAssertEqual(query.terms, ["cafe", "is:unknownflag"])
        XCTAssertEqual(query.phrases, ["exact phrase"])
        XCTAssertEqual(query.excludedTerms, ["spam"])
        XCTAssertEqual(query.requiredTags, ["design"])
        XCTAssertEqual(query.flags, [.pinned, .reminder])
        XCTAssertEqual(query.agentName, "idea")
        XCTAssertFalse(query.isEmpty)
        XCTAssertTrue(SearchQuery(parsing: "   ").isEmpty)
    }

    private func record(title: String, text: String, tags: [String] = [], flags: Set<SearchQuery.Flag> = [], agents: [String] = []) -> SearchRecord {
        SearchRecord(
            foldedTitle: SearchText.fold(title),
            foldedIndex: SearchText.buildIndex(title: title, extractedText: text, notes: nil, summary: nil, tags: tags,
                                               actionItems: [], sourceURL: nil, agentName: agents.first),
            tags: tags,
            flags: flags,
            foldedAgentNames: agents.map(SearchText.fold)
        )
    }

    func testMatcherRequiresAllTermsAndRanksTitleMatches() throws {
        let titleHit = record(title: "Crème brûlée recipe", text: "Dessert with sugar crust")
        let bodyHit = record(title: "Dinner ideas", text: "Maybe a creme brulee for dessert")
        let query = SearchQuery(parsing: "creme brul")
        let titleScore = try XCTUnwrap(SearchMatcher.score(query, record: titleHit))
        let bodyScore = try XCTUnwrap(SearchMatcher.score(query, record: bodyHit))
        XCTAssertGreaterThan(titleScore, bodyScore)
        XCTAssertNil(SearchMatcher.score(SearchQuery(parsing: "creme pizza"), record: titleHit))
    }

    func testMatcherFiltersByTagsFlagsExclusionsAndAgent() {
        let item = record(title: "Pricing page", text: "Annual toggle and slider", tags: ["design", "pricing"],
                          flags: [.pinned, .image], agents: ["Visual & Tech Inspector"])
        XCTAssertNotNil(SearchMatcher.score(SearchQuery(parsing: "#design is:pinned slider"), record: item))
        XCTAssertNil(SearchMatcher.score(SearchQuery(parsing: "#marketing"), record: item))
        XCTAssertNil(SearchMatcher.score(SearchQuery(parsing: "is:archived"), record: item))
        XCTAssertNil(SearchMatcher.score(SearchQuery(parsing: "pricing -slider"), record: item))
        XCTAssertNotNil(SearchMatcher.score(SearchQuery(parsing: "agent:visual"), record: item))
        XCTAssertNil(SearchMatcher.score(SearchQuery(parsing: "agent:planner"), record: item))
        XCTAssertNotNil(SearchMatcher.score(SearchQuery(parsing: #""annual toggle""#), record: item))
        XCTAssertNotNil(SearchMatcher.score(SearchQuery(), record: item), "an empty query matches everything")
    }

    func testIndexIncludesSourceAppAndFolds() {
        let index = SearchText.buildIndex(title: "Ünïcode", extractedText: "OCR text", notes: "My NOTES", summary: "Sum",
                                          tags: ["tag"], actionItems: ["Buy milk"],
                                          sourceURL: URL(string: "https://www.instagram.com/p/1"), agentName: "Idea Extractor")
        for expected in ["unicode", "ocr text", "my notes", "buy milk", "instagram", "idea extractor", "tag"] {
            XCTAssertTrue(index.contains(expected), expected)
        }
    }

    func testSnippet() {
        let text = String(repeating: "lorem ", count: 30) + "the Brûlée appears here " + String(repeating: "ipsum ", count: 30)
        let snippet = SearchSnippet.make(from: text, terms: ["brulee"], radius: 20)
        XCTAssertEqual(snippet?.hasPrefix("…"), true)
        XCTAssertEqual(snippet?.hasSuffix("…"), true)
        XCTAssertEqual(snippet?.contains("Brûlée"), true)
        XCTAssertNil(SearchSnippet.make(from: "nothing", terms: ["absent"]))
    }

    // MARK: Reminders

    private let zone = Fixtures.berlin
    private var calendar: Calendar { Fixtures.calendar(zone) }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 9) -> Date {
        Fixtures.date(2026, month, day, hour, minute, zone: zone)
    }

    func testInTwoHours() {
        let now = date(24, 10, 30).addingTimeInterval(17)
        XCTAssertEqual(ReminderPreset.inTwoHours.date(relativeTo: now, calendar: calendar), date(24, 12, 30))
    }

    func testTonight() {
        XCTAssertEqual(ReminderPreset.tonight.date(relativeTo: date(24, 10), calendar: calendar), date(24, 20))
        XCTAssertEqual(ReminderPreset.tonight.date(relativeTo: date(24, 20, 5), calendar: calendar), date(24, 21, 15))
        XCTAssertEqual(ReminderPreset.tonight.date(relativeTo: date(24, 23, 30), calendar: calendar), date(25, 20))
        let custom = ReminderSchedule(eveningHour: 18)
        XCTAssertEqual(ReminderPreset.tonight.date(relativeTo: date(24, 10), calendar: calendar, schedule: custom), date(24, 18))
    }

    func testTomorrowAndNextWeek() {
        // 2026-09-24 is a Thursday.
        XCTAssertEqual(ReminderPreset.tomorrow.date(relativeTo: date(24, 23, 50), calendar: calendar), date(25, 9))
        XCTAssertEqual(ReminderPreset.nextWeek.date(relativeTo: date(24, 10), calendar: calendar), date(28, 9))
        XCTAssertEqual(ReminderPreset.nextWeek.date(relativeTo: date(28, 7), calendar: calendar), date(5, 9, month: 10), "Monday → the following Monday")
        XCTAssertEqual(ReminderPreset.nextWeek.date(relativeTo: date(27, 12), calendar: calendar), date(28, 9), "Sunday → tomorrow")
    }

    func testThisWeekend() {
        XCTAssertEqual(ReminderPreset.thisWeekend.date(relativeTo: date(24, 10), calendar: calendar), date(26, 10))
        XCTAssertEqual(ReminderPreset.thisWeekend.date(relativeTo: date(26, 8), calendar: calendar), date(26, 10), "Saturday morning")
        XCTAssertEqual(ReminderPreset.thisWeekend.date(relativeTo: date(26, 15), calendar: calendar), date(27, 10), "Saturday afternoon → Sunday")
        XCTAssertEqual(ReminderPreset.thisWeekend.date(relativeTo: date(27, 15), calendar: calendar), date(3, 10, month: 10), "Sunday afternoon → next Saturday")
    }

    func testSnooze() {
        XCTAssertEqual(SnoozeOption.oneHour.date(relativeTo: date(24, 10, 12), calendar: calendar), date(24, 11, 12))
        XCTAssertEqual(SnoozeOption.tomorrow.date(relativeTo: date(24, 10), calendar: calendar), date(25, 9))
        XCTAssertEqual(ReminderPreset.quickChoices, [.inTwoHours, .tonight, .tomorrow])
    }

    // MARK: Masonry

    func testMasonryBalancesColumns() {
        let columns = MasonryDistributor.distribute(heights: [300, 100, 100, 100, 200], columns: 2)
        XCTAssertEqual(columns, [[0, 4], [1, 2, 3]])
        XCTAssertEqual(MasonryDistributor.distribute(heights: [1, 2, 3], columns: 0), [[0, 1, 2]])
        XCTAssertEqual(MasonryDistributor.distribute(heights: [], columns: 3), [[], [], []])
    }

    func testColumnCountAndAspectRatio() {
        XCTAssertEqual(MasonryDistributor.columnCount(forWidth: 390, minimumColumnWidth: 160, spacing: 12), 2)
        XCTAssertEqual(MasonryDistributor.columnCount(forWidth: 1400, minimumColumnWidth: 220, spacing: 16, maximumColumns: 5), 5)
        XCTAssertEqual(MasonryDistributor.columnCount(forWidth: 100, minimumColumnWidth: 220, spacing: 16), 1)
        XCTAssertEqual(MasonryDistributor.clampedAspectRatio(width: 1170, height: 2532), 1.9)
        XCTAssertEqual(MasonryDistributor.clampedAspectRatio(width: 1000, height: 500), 0.5)
        XCTAssertEqual(MasonryDistributor.clampedAspectRatio(width: 0, height: 500), 1.2)
    }

    func testImageSizing() {
        XCTAssertTrue(ImageSizing.fitting(width: 4000, height: 3000, maxDimension: 1568) == (1568, 1176))
        XCTAssertTrue(ImageSizing.fitting(width: 800, height: 600, maxDimension: 1568) == (800, 600))
        XCTAssertTrue(ImageSizing.fitting(width: 1170, height: 2532, maxDimension: 400) == (185, 400))
    }

    // MARK: Export

    func testLibraryExportRoundTrip() throws {
        let capture = ExportedCapture(id: UUID(), createdAt: Fixtures.date(2026, 9, 24, 9), kind: "screenshot",
                                      title: "Poster", summary: "An event", actionItems: ["Buy tickets"],
                                      completedActionItems: ["Buy tickets"], tags: ["music"],
                                      sourceURL: URL(string: "https://instagram.com/p/1"), isPinned: true)
        let document = LibraryExportDocument(exportedAt: Fixtures.date(2026, 9, 24, 12), captures: [capture],
                                             agents: BuiltInPersonas.all)
        let decoded = try LibraryExportDocument.decode(document.encoded())
        XCTAssertEqual(decoded.format, LibraryExportDocument.formatIdentifier)
        XCTAssertEqual(decoded.captures, [capture])
        XCTAssertEqual(decoded.agents, BuiltInPersonas.all)
        XCTAssertEqual(LibraryExportDocument.suggestedFileName(for: Fixtures.date(2026, 3, 5, 12), calendar: Fixtures.calendar()),
                       "RecallDrop Library 2026-03-05.json")
    }

    func testMarkdownExport() {
        let capture = ExportedCapture(id: UUID(), createdAt: Fixtures.date(2026, 9, 24, 9), kind: "screenshot",
                                      title: "Poster", summary: "An event\nwith two lines", actionItems: ["Buy tickets", "Invite Sam"],
                                      completedActionItems: ["Buy tickets"], tags: ["music", "event"], extractedText: "OCR",
                                      notes: "Remember the jacket", sourceURL: URL(string: "https://instagram.com/p/1"),
                                      sourceApp: "Instagram", lastAgentName: "Action Planner")
        let markdown = CaptureMarkdownExporter.markdown(for: capture, locale: Locale(identifier: "en_US"), timeZone: Fixtures.utc)
        XCTAssertTrue(markdown.hasPrefix("# Poster\n\n> An event\n> with two lines"))
        XCTAssertTrue(markdown.contains("[Instagram](https://instagram.com/p/1)"))
        XCTAssertTrue(markdown.contains("**Tags:** #music #event"))
        XCTAssertTrue(markdown.contains("- [x] Buy tickets\n- [ ] Invite Sam"))
        XCTAssertTrue(markdown.contains("## Notes\nRemember the jacket"))
        XCTAssertTrue(markdown.contains("```\nOCR\n```"))
        XCTAssertTrue(markdown.contains("**Analyzed by:** Action Planner"))
    }
}
