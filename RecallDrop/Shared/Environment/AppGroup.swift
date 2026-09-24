//
//  AppGroup.swift
//  RecallDrop
//
//  The App Group shared by the app and its share extension. Its identifier
//  comes from Info.plist (`RDAppGroupIdentifier`, filled from build settings
//  in Config/RecallDrop.xcconfig), so it follows the signing team instead of
//  being hard-coded.
//

import Foundation

enum AppGroup {
    static let infoPlistKey = "RDAppGroupIdentifier"

    static var identifier: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // An unexpanded "$(…)" means the build setting was missing.
        guard !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }

    /// The shared container, or `nil` when the entitlement is missing
    /// (e.g. an unsigned local build).
    static var containerURL: URL? {
        guard let identifier else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// Defaults shared with the extension; falls back to the app's own.
    static func makeUserDefaults() -> UserDefaults {
        if let identifier, containerURL != nil, let shared = UserDefaults(suiteName: identifier) {
            return shared
        }
        return .standard
    }

    /// A writable directory inside the shared container, or inside the
    /// app's own Application Support directory as a fallback.
    static func directory(named name: String) -> URL {
        let fileManager = FileManager.default
        if let base = containerURL?.appending(path: "Library/Application Support", directoryHint: .isDirectory) {
            let directory = base.appending(path: name, directoryHint: .isDirectory)
            if (try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)) != nil {
                return directory
            }
        }
        let fallback = URL.applicationSupportDirectory.appending(path: name, directoryHint: .isDirectory)
        try? fileManager.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }
}
