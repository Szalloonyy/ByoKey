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

    /// Opens the store. With `allowsRecovery`, a store that cannot be opened
    /// is moved aside and a new one is created; the share extension passes
    /// false so it never renames files the app may have open.
    static func makeContainer(allowsRecovery: Bool) -> (container: ModelContainer, issue: PersistenceIssue?) {
        let url = storeURL
        do {
            return (try openContainer(at: url), nil)
        } catch {
            guard allowsRecovery, let backup = moveStoreAside(at: url) else {
                return (makeInMemoryContainer(), .inMemoryFallback(reason: error.localizedDescription))
            }
            do {
                let container = try openContainer(at: url)
                return (container, .recoveredFromCorruption(backupName: backup.name))
            } catch {
                // A new store fails as well, so the old one was not the problem
                // (full disk, permissions): put it back for the next launch.
                restore(backup)
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

    private struct StoreBackup {
        var name: String
        /// Moved files: original location → backup location.
        var moves: [(from: URL, to: URL)]
    }

    /// Renames the store, its SQLite side files and its folder of externally
    /// stored images; returns what was moved, or nil when there was no store.
    private static func moveStoreAside(at url: URL) -> StoreBackup? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        let stamp = Int(Date().timeIntervalSince1970)
        let backupBase = "\(storeName)-unreadable-\(stamp)"
        let directory = url.deletingLastPathComponent()
        let names = ["", "-shm", "-wal"].map { ("\(storeName).store\($0)", "\(backupBase).store\($0)") }
            + [(".\(storeName)_SUPPORT", ".\(backupBase)_SUPPORT")]
        var moves: [(from: URL, to: URL)] = []
        for (original, backup) in names {
            let source = directory.appending(path: original)
            guard fileManager.fileExists(atPath: source.path(percentEncoded: false)) else { continue }
            let destination = directory.appending(path: backup)
            if (try? fileManager.moveItem(at: source, to: destination)) != nil {
                moves.append((source, destination))
            }
        }
        return moves.isEmpty ? nil : StoreBackup(name: "\(backupBase).store", moves: moves)
    }

    /// Undoes `moveStoreAside`, replacing whatever the failed attempt created.
    private static func restore(_ backup: StoreBackup) {
        let fileManager = FileManager.default
        for move in backup.moves {
            try? fileManager.removeItem(at: move.from)
            try? fileManager.moveItem(at: move.to, to: move.from)
        }
    }
}
