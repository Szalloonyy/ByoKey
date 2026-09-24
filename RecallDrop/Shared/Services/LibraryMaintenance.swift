//
//  LibraryMaintenance.swift
//  RecallDrop
//
//  Library-wide operations: export, deleting items safely (cancelling their
//  jobs and reminders first) and erasing all data.
//

import Foundation
import SwiftData
import RecallDropKit

@MainActor
enum LibraryMaintenance {
    static func exportDocument(context: ModelContext) -> LibraryExportDocument {
        let items = (try? context.fetch(FetchDescriptor<CapturedItem>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
        let agents = AgentConfig.allSorted(in: context).map(\.persona)
        return LibraryExportDocument(captures: items.map(\.exportRepresentation), agents: agents)
    }

    static func delete(_ items: [CapturedItem], environment: AppEnvironment) {
        let context = environment.container.mainContext
        for item in items {
            environment.pipeline.discard(item.id)
            if item.hasReminder { ReminderService.removeNotification(for: item.id) }
            context.delete(item)
        }
        try? context.save()
    }

    static func deleteArchived(environment: AppEnvironment) {
        let context = environment.container.mainContext
        let descriptor = FetchDescriptor<CapturedItem>(predicate: #Predicate { $0.isArchived })
        let archived = (try? context.fetch(descriptor)) ?? []
        delete(archived, environment: environment)
    }

    /// Removes captures, custom agents, keys and preferences. Built-in agents are re-created.
    static func eraseEverything(environment: AppEnvironment) {
        let context = environment.container.mainContext
        let items = (try? context.fetch(FetchDescriptor<CapturedItem>())) ?? []
        delete(items, environment: environment)
        for agent in AgentConfig.allSorted(in: context) {
            context.delete(agent)
        }
        try? context.save()
        KeychainStore.removeAll()
        environment.catalog.clearCache()
        environment.settings.resetAll()
        environment.agents.seedBuiltInsIfNeeded()
    }
}
