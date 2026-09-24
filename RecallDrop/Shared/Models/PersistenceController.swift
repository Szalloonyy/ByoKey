//
//  PersistenceController.swift
//  RecallDrop
//
//  Opens the SwiftData store in the App Group container so the app and the
//  share extension read and write the same database. A store that cannot be
//  opened is moved aside (never deleted) and a fresh one is created; if even
//  that fails, the app runs on an in-memory store and says so.
//

import Foundation
import SwiftData

enum PersistenceIssue: Equatable, Sendable {
    /// The previous store could not be opened and was moved to `backupName`.
    case recoveredFromCorruption(backupName: String)
    /// No store could be opened on disk; data will not be saved.
    case inMemoryFallback(reason: String)

    var message: String {
        switch self {
        case .recoveredFromCorruption(let backupName):
            "Your library could not be opened, so RecallDrop started a new one. The old data was kept as “\(backupName)”."
        case .inMemoryFallback(let reason):
            "RecallDrop could not open its library (\(reason)). Captures made now will not be saved."
        }
    }
}

enum PersistenceController {
    static let storeName = "RecallDrop"

    static var storeDirectory: URL { AppGroup.directory(named: "RecallDrop") }

    static var storeURL: URL {
        storeDirectory.appending(path: "\(storeName).store", directoryHint: .notDirectory)
    }

    static var schema: Schema { Schema(versionedSchema: RecallDropSchemaV1.self) }

    static func makeContainer() -> (container: ModelContainer, issue: PersistenceIssue?) {
        let url = storeURL
        do {
            return (try openContainer(at: url), nil)
        } catch {
            let backupName = moveStoreAside(at: url)
            do {
                let container = try openContainer(at: url)
                return (container, backupName.map { .recoveredFromCorruption(backupName: $0) })
            } catch {
                return (makeInMemoryContainer(), .inMemoryFallback(reason: error.localizedDescription))
            }
        }
    }

    static func makeInMemoryContainer() -> ModelContainer {
        let configuration = ModelConfiguration(storeName, schema: schema, isStoredInMemoryOnly: true, allowsSave: true)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // The in-memory store only fails for a broken schema – a programming error.
            fatalError("RecallDrop's data model is invalid: \(error)")
        }
    }

    private static func openContainer(at url: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            storeName,
            schema: schema,
            url: url,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, migrationPlan: RecallDropMigrationPlan.self, configurations: [configuration])
    }

    /// Renames the store and its SQLite side files; returns the new base name.
    private static func moveStoreAside(at url: URL) -> String? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        let stamp = Int(Date().timeIntervalSince1970)
        let backupBase = "\(storeName)-unreadable-\(stamp)"
        let directory = url.deletingLastPathComponent()
        for suffix in ["", "-shm", "-wal"] {
            let source = directory.appending(path: "\(storeName).store\(suffix)")
            guard fileManager.fileExists(atPath: source.path(percentEncoded: false)) else { continue }
            let destination = directory.appending(path: "\(backupBase).store\(suffix)")
            try? fileManager.moveItem(at: source, to: destination)
        }
        return "\(backupBase).store"
    }
}
