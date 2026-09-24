//
//  TestSupport.swift
//  RecallDropKitTests
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RecallDropKit

/// Replays canned responses and records every request it receives.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    struct StreamReply {
        var status: Int
        var lines: [String]
    }

    private let lock = NSLock()
    private var queuedResponses: [HTTPResponse]
    private var queuedStreams: [StreamReply]
    private var recorded: [URLRequest] = []

    init(responses: [HTTPResponse] = [], streams: [StreamReply] = []) {
        self.queuedResponses = responses
        self.queuedStreams = streams
    }

    private func synchronized<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var requests: [URLRequest] {
        synchronized { recorded }
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        synchronized {
            recorded.append(request)
            guard !queuedResponses.isEmpty else {
                return HTTPResponse(statusCode: 500, body: Data("{\"error\":\"no canned response\"}".utf8))
            }
            return queuedResponses.removeFirst()
        }
    }

    func streamLines(_ request: URLRequest) -> AsyncThrowingStream<HTTPStreamEvent, any Error> {
        let reply: StreamReply = synchronized {
            recorded.append(request)
            return queuedStreams.isEmpty ? StreamReply(status: 500, lines: []) : queuedStreams.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.head(statusCode: reply.status, headers: [:]))
            for line in reply.lines { continuation.yield(.line(line)) }
            continuation.finish()
        }
    }
}

extension HTTPResponse {
    static func json(_ string: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: ["content-type": "application/json"], body: Data(string.utf8))
    }
}

extension URLRequest {
    /// The JSON body as a dictionary.
    var jsonBody: [String: Any] {
        guard let body = httpBody,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [:] }
        return object
    }
}

enum Fixtures {
    static let utc = TimeZone(identifier: "UTC")!
    static let berlin = TimeZone(identifier: "Europe/Berlin")!

    static func calendar(_ zone: TimeZone = utc) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.firstWeekday = 2
        return calendar
    }

    /// Builds a date in `zone`.
    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0,
                     zone: TimeZone = utc) -> Date {
        calendar(zone).date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    static let sampleImage = AIImageInput(data: Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02]), mimeType: "image/jpeg")
}
