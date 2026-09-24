//
//  ModelEnums.swift
//  RecallDrop
//
//  Enumerations stored as raw strings in SwiftData. Raw strings keep
//  predicates simple and survive enum changes without migrations.
//

import Foundation
import RecallDropKit

enum CaptureKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case screenshot
    case photo
    case link
    case note

    var id: String { rawValue }

    var label: String {
        switch self {
        case .screenshot: "Screenshot"
        case .photo: "Photo"
        case .link: "Link"
        case .note: "Note"
        }
    }

    var pluralLabel: String {
        switch self {
        case .screenshot: "Screenshots"
        case .photo: "Photos"
        case .link: "Links"
        case .note: "Notes"
        }
    }

    var symbolName: String {
        switch self {
        case .screenshot: "photo.on.rectangle"
        case .photo: "camera"
        case .link: "link"
        case .note: "note.text"
        }
    }

    var contextKind: CaptureContext.Kind {
        switch self {
        case .screenshot: .screenshot
        case .photo: .photo
        case .link: .link
        case .note: .note
        }
    }
}

enum ProcessingState: String, Codable, Sendable {
    /// Nothing to do.
    case idle
    /// Waiting in the queue (also set by the share extension).
    case pending
    case fetchingLink
    case recognizing
    case analyzing
    case completed
    case failed

    /// A job is (or was, before the app quit) actively working on the item.
    var isActive: Bool {
        self == .fetchingLink || self == .recognizing || self == .analyzing
    }

    var label: String {
        switch self {
        case .idle: "Saved"
        case .pending: "Waiting…"
        case .fetchingLink: "Loading link…"
        case .recognizing: "Reading text…"
        case .analyzing: "Analyzing…"
        case .completed: "Analyzed"
        case .failed: "Analysis failed"
        }
    }
}

enum ChatRole: String, Codable, Sendable {
    case user
    case assistant
}
