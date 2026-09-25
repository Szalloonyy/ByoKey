//
//  CaptureUtilitiesTests.swift
//  RecallDropKitTests
//

import XCTest
import RecallDropKit

final class CaptureUtilitiesTests: XCTestCase {
    // MARK: HTML metadata

    func testOpenGraphParsingIgnoresAttributeOrder() {
        let html = """
        <html><head>
        <title>Fallback &amp; Title</title>
        <meta content="Big &quot;Idea&quot; &#8211; explained" property="og:title">
        <meta name='description' content='A page about ideas.'>
        <meta property="og:image" content="/images/cover.jpg" />
        <meta property="og:site_name" content="Idea Blog">
        <link rel="canonical" href="https://example.com/post">
        </head><body><p>Hello</p></body></html>
        """
        let metadata = HTMLMetadataParser.parse(html: html, baseURL: URL(string: "https://example.com/post?utm=1")!)
        XCTAssertEqual(metadata.title, "Big \"Idea\" – explained")
        XCTAssertEqual(metadata.summary, "A page about ideas.")
        XCTAssertEqual(metadata.imageURL?.absoluteString, "https://example.com/images/cover.jpg")
        XCTAssertEqual(metadata.siteName, "Idea Blog")
        XCTAssertEqual(metadata.canonicalURL?.absoluteString, "https://example.com/post")
    }

    func testTitleTagFallback() {
        let metadata = HTMLMetadataParser.parse(html: "<title>\n  Just a  title \n</title>", baseURL: URL(string: "https://a.b")!)
        XCTAssertEqual(metadata.title, "Just a title")
        XCTAssertNil(metadata.imageURL)
    }

    func testEntityDecodingAndPlainText() {
        XCTAssertEqual(HTMLMetadataParser.decodeEntities("Tom &amp; Jerry &#x1F600; &unknown; &#39;x&#39;"), "Tom & Jerry 😀 &unknown; 'x'")
        XCTAssertEqual(HTMLMetadataParser.plainText(fromHTML: "Line one<br>Line <b>two</b></p><p>Three"), "Line one\nLine two\nThree")
    }

    func testTwitterOEmbed() throws {
        let url = URL(string: "https://x.com/someone/status/1234567890")!
        let provider = try XCTUnwrap(OEmbedProvider(url: url))
        XCTAssertEqual(provider, .twitter)
        XCTAssertEqual(provider.endpoint(for: url)?.host, "publish.twitter.com")
        let json = Data("""
        {"author_name":"Some One","html":"<blockquote class=\\"twitter-tweet\\"><p lang=\\"en\\" dir=\\"ltr\\">Ship small, ship often.<br>Then iterate. <a href=\\"https://t.co/x\\">pic.twitter.com/x</a></p>&mdash; Some One (@someone) <a href=\\"https://x.com\\">Sep 1, 2026</a></blockquote>"}
        """.utf8)
        let metadata = try XCTUnwrap(provider.parse(json))
        XCTAssertEqual(metadata.title, "Some One on X")
        XCTAssertEqual(metadata.bodyText, "Ship small, ship often.\nThen iterate. pic.twitter.com/x")
        XCTAssertNil(OEmbedProvider(url: URL(string: "https://x.com/someone")!), "profiles are not posts")
    }

    func testYouTubeOEmbed() throws {
        XCTAssertEqual(OEmbedProvider(url: URL(string: "https://youtu.be/abc")!), .youtube)
        XCTAssertEqual(OEmbedProvider(url: URL(string: "https://www.youtube.com/watch?v=abc")!), .youtube)
        XCTAssertNil(OEmbedProvider(url: URL(string: "https://www.youtube.com/@channel")!))
        let metadata = try XCTUnwrap(OEmbedProvider.youtube.parse(Data("""
        {"title":"How to sketch","author_name":"Art School","thumbnail_url":"https://i.ytimg.com/vi/abc/hqdefault.jpg"}
        """.utf8)))
        XCTAssertEqual(metadata.title, "How to sketch")
        XCTAssertEqual(metadata.imageURL?.host, "i.ytimg.com")
    }

    func testFetcherMergesOEmbedAndPageMetadata() async {
        let transport = MockTransport(responses: [
            .json(#"{"title":"Video","author_name":"Creator","thumbnail_url":"https://i.ytimg.com/x.jpg"}"#),
            HTTPResponse(statusCode: 200, headers: ["content-type": "text/html"],
                         body: Data(#"<meta property="og:description" content="Page description">"#.utf8))
        ])
        let metadata = await LinkMetadataFetcher.fetch(URL(string: "https://youtu.be/abc")!, transport: transport)
        XCTAssertEqual(metadata.title, "Video")
        XCTAssertEqual(metadata.summary, "Video by Creator", "oEmbed wins over page tags")
        XCTAssertEqual(metadata.siteName, "YouTube")
        XCTAssertEqual(transport.requests.count, 1, "oEmbed already provided title, image and summary")
    }

    // MARK: Text heuristics

    func testHashtagsAndURLs() {
        XCTAssertEqual(TextHeuristics.hashtags(in: "Love this #DesignSystem and #ux_tips! Not #1 or email@x.com#y"), ["designsystem", "ux-tips"])
        let urls = TextHeuristics.urls(in: "See https://example.com/a, and (https://b.org/x). Also https://example.com/a")
        XCTAssertEqual(urls.map(\.absoluteString), ["https://example.com/a", "https://b.org/x"])
        XCTAssertEqual(TextHeuristics.standaloneURL(in: " https://instagram.com/p/xyz \n")?.host, "instagram.com")
        XCTAssertNil(TextHeuristics.standaloneURL(in: "look at https://a.b"))
    }

    func testSourceNamesAndDomainTags() {
        XCTAssertEqual(TextHeuristics.sourceAppName(for: URL(string: "https://www.instagram.com/p/1")!), "Instagram")
        XCTAssertEqual(TextHeuristics.sourceAppName(for: URL(string: "https://mobile.twitter.com/a/status/1")!), "X")
        XCTAssertEqual(TextHeuristics.domainTag(for: URL(string: "https://www.nytimes.com/2026/a.html")!), "nytimes")
        XCTAssertEqual(TextHeuristics.domainTag(for: URL(string: "https://gist.github.com/x")!), "github")
        XCTAssertEqual(TextHeuristics.sourceAppName(for: URL(string: "https://blog.example.org")!), "blog.example.org")
    }

    func testFallbackTitleSkipsInterfaceChrome() {
        let text = "9:41\n100%\nFollow\nThe best way to learn is to teach. Explain it simply.\nMore text"
        XCTAssertEqual(TextHeuristics.fallbackTitle(from: text), "The best way to learn is to teach. Explain it simply.")
        XCTAssertNil(TextHeuristics.fallbackTitle(from: "12\n34"))
    }

    func testTruncate() {
        XCTAssertEqual(TextHeuristics.truncate("short", maxLength: 10), "short")
        XCTAssertEqual(TextHeuristics.truncate("The quick brown fox jumps", maxLength: 16), "The quick brown…")
        XCTAssertEqual(TextHeuristics.truncate("Supercalifragilistic", maxLength: 8), "Superca…")
    }

    // MARK: OCR layout

    private func line(_ text: String, x: Double, y: Double, height: Double = 0.02, width: Double = 0.3, confidence: Double = 0.95) -> OCRLine {
        OCRLine(text: text, confidence: confidence, x: x, y: y, width: width, height: height)
    }

    func testReadingOrderGroupsRowsLeftToRight() {
        let lines = [
            line("right", x: 0.6, y: 0.801),
            line("left", x: 0.1, y: 0.8),
            line("below", x: 0.1, y: 0.7),
            line("top", x: 0.1, y: 0.9)
        ]
        XCTAssertEqual(OCRLayout.readingOrder(lines).map(\.text), ["top", "left", "right", "below"])
        XCTAssertEqual(OCRLayout.joinedText(lines), "top\n\nleft  right\n\nbelow")
    }

    func testParagraphBreaksOnlyForLargeGaps() {
        let lines = [line("one", x: 0.1, y: 0.80), line("two", x: 0.1, y: 0.775), line("three", x: 0.1, y: 0.60)]
        XCTAssertEqual(OCRLayout.joinedText(lines), "one\ntwo\n\nthree")
    }

    func testHeadlineCandidatePrefersLargeTextNearTop() {
        let lines = [
            line("9:41", x: 0.05, y: 0.97, height: 0.015),
            line("Weekend Market Guide", x: 0.1, y: 0.8, height: 0.045),
            line("Opening hours are 8 to 14 on Saturdays", x: 0.1, y: 0.7),
            line("Bring cash for the flower stand", x: 0.1, y: 0.65),
            line("Huge footer text", x: 0.1, y: 0.1, height: 0.06)
        ]
        XCTAssertEqual(OCRLayout.headlineCandidate(lines), "Weekend Market Guide")
        XCTAssertEqual(OCRLayout.averageConfidence(lines) ?? 0, 0.95, accuracy: 0.0001)
        XCTAssertNil(OCRLayout.headlineCandidate([line("same", x: 0, y: 0.8), line("size", x: 0, y: 0.7),
                                                  line("text", x: 0, y: 0.6), line("here", x: 0, y: 0.5)]))
    }

    // MARK: Local analysis

    func testLocalAnalysisBuildsUsefulOutput() {
        let now = Fixtures.date(2026, 9, 24, 10)
        let input = LocalAnalysisInput(
            kind: .screenshot,
            text: "Design Meetup\nThursday Oct 1 at 18:00 #design #community\nhttps://meetup.example.com/rsvp",
            lines: [OCRLine(text: "Design Meetup", confidence: 0.9, x: 0.1, y: 0.8, width: 0.5, height: 0.05),
                    OCRLine(text: "Thursday Oct 1 at 18:00 #design #community", confidence: 0.8, x: 0.1, y: 0.7, width: 0.8, height: 0.02),
                    OCRLine(text: "https://meetup.example.com/rsvp", confidence: 0.85, x: 0.1, y: 0.6, width: 0.6, height: 0.02)],
            sourceURL: URL(string: "https://www.instagram.com/p/1"),
            keywords: ["meetup"],
            detectedDates: [Fixtures.date(2026, 10, 1, 18), Fixtures.date(2020, 1, 1)],
            detectedLinks: [URL(string: "https://meetup.example.com/rsvp")!]
        )
        let output = LocalAnalysis.analyze(input, now: now, locale: Locale(identifier: "en_US"), timeZone: Fixtures.utc)
        XCTAssertEqual(output.title, "Design Meetup")
        XCTAssertEqual(output.suggestedReminder, Fixtures.date(2026, 10, 1, 18))
        XCTAssertTrue(output.actionableSteps.contains("Open https://meetup.example.com/rsvp"))
        XCTAssertTrue(output.actionableSteps.first?.hasPrefix("Follow up on") == true)
        XCTAssertTrue(output.tags.contains("design"))
        XCTAssertTrue(output.tags.contains("instagram"))
        XCTAssertTrue(output.tags.contains("event"))
        XCTAssertTrue(output.thoughtProcess.first?.contains("on this device") == true)
    }

    func testLocalAnalysisForEmptyImage() {
        let output = LocalAnalysis.analyze(LocalAnalysisInput(kind: .photo), now: Date())
        XCTAssertEqual(output.title, "Photo")
        XCTAssertTrue(output.thoughtProcess.contains("No text was found in the image."))
    }
}
