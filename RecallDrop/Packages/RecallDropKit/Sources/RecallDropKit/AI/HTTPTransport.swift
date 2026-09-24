//
//  HTTPTransport.swift
//  RecallDropKit
//
//  The only place that touches URLSession. Clients depend on the protocol,
//  so tests can replay recorded provider responses without a network.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(statusCode) }
}

public enum HTTPStreamEvent: Sendable {
    /// Always the first event: status code and headers.
    case head(statusCode: Int, headers: [String: String])
    /// One line of the body, without its line terminator. Blank lines are skipped.
    case line(String)
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
    func streamLines(_ request: URLRequest) -> AsyncThrowingStream<HTTPStreamEvent, any Error>
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AIError.invalidResponse("not an HTTP response")
            }
            return HTTPResponse(statusCode: http.statusCode, headers: Self.headers(of: http), body: data)
        } catch {
            throw AIError.from(error)
        }
    }

    public func streamLines(_ request: URLRequest) -> AsyncThrowingStream<HTTPStreamEvent, any Error> {
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    #if canImport(FoundationNetworking)
                    // Linux has no URLSession.bytes; deliver the body line by line after download.
                    let (data, response) = try await session.data(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw AIError.invalidResponse("not an HTTP response")
                    }
                    continuation.yield(.head(statusCode: http.statusCode, headers: Self.headers(of: http)))
                    let text = String(decoding: data, as: UTF8.self)
                    for line in text.split(whereSeparator: \.isNewline) where !line.isEmpty {
                        continuation.yield(.line(String(line)))
                    }
                    #else
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw AIError.invalidResponse("not an HTTP response")
                    }
                    continuation.yield(.head(statusCode: http.statusCode, headers: Self.headers(of: http)))
                    for try await line in bytes.lines {
                        continuation.yield(.line(line))
                    }
                    #endif
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AIError.from(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func headers(of response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                result[key.lowercased()] = value
            }
        }
        return result
    }
}
