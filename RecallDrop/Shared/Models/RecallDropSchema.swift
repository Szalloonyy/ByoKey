//
//  RecallDropSchema.swift
//  RecallDrop
//
//  The SwiftData schema. Models live inside a VersionedSchema from day one
//  so future changes can ship with a proper migration plan instead of a
//  store reset. The main app and the share extension open the same store in
//  the App Group container (see PersistenceController).
//

import Foundation
import SwiftData

enum RecallDropSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [CapturedItem.self, AgentConfig.self, AgentRun.self, ChatMessage.self]
    }

    /// Anything the user captured: a screenshot, photo, link or note.
    @Model
    final class CapturedItem {
        @Attribute(.unique) var id: UUID = UUID()
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var reminderDate: Date?

        @Attribute(.externalStorage) var imageData: Data?
        @Attribute(.externalStorage) var thumbnailData: Data?
        var imageWidth: Double = 0
        var imageHeight: Double = 0

        var extractedText: String?
        var ocrConfidence: Double?
        /// Recognized lines with positions (JSON-encoded `[OCRLine]`).
        var ocrLinesData: Data?

        var aiSummary: String?
        var actionItems: [String] = []
        var completedActionItems: [String] = []
        var title: String = ""
        /// Once the user renames an item, agents stop overwriting the title.
        var isTitleUserEdited: Bool = false
        var userNotes: String?

        var sourceURL: URL?
        var sourceAppName: String?
        var linkTitle: String?
        var linkDescription: String?
        var linkMetadataFetched: Bool = false

        var tags: [String] = []
        var isArchived: Bool = false
        var isPinned: Bool = false

        var lastUsedAgentId: UUID?
        var lastUsedAgentName: String?
        var lastUsedAgentEmoji: String?
        var lastUsedAgentColorName: String?

        var kindRaw: String = CaptureKind.screenshot.rawValue
        var processingStateRaw: String = ProcessingState.idle.rawValue
        var processingError: String?
        /// Agents still to run on this item – survives app restarts and hand-offs
        /// from the share extension.
        var pendingAgentIds: [UUID] = []
        var suggestedReminderDate: Date?

        /// Folded text of everything searchable, rebuilt by `refreshSearchIndex()`.
        var searchIndex: String = ""

        @Relationship(deleteRule: .cascade, inverse: \AgentRun.item)
        var agentRuns: [AgentRun] = []

        @Relationship(deleteRule: .cascade, inverse: \ChatMessage.item)
        var chatMessages: [ChatMessage] = []

        init(id: UUID = UUID(), kind: CaptureKind, createdAt: Date = Date()) {
            self.id = id
            self.kindRaw = kind.rawValue
            self.createdAt = createdAt
            self.updatedAt = createdAt
        }
    }

    /// A stored agent persona (built-in or user-created).
    @Model
    final class AgentConfig {
        @Attribute(.unique) var id: UUID = UUID()
        var name: String = ""
        var roleDescription: String = ""
        var systemInstructions: String = ""
        /// Model ID override; `nil` uses the global default model.
        var preferredModel: String?
        var isBuiltIn: Bool = false
        var builtInKey: String?
        var temperature: Double = 0.5
        var isDefault: Bool = false
        var emoji: String = "🤖"
        var colorName: String = "indigo"
        var sortOrder: Int = 0
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        /// Where an imported persona came from (file name or URL).
        var importSource: String?

        init(id: UUID = UUID(), name: String) {
            self.id = id
            self.name = name
        }
    }

    /// One agent's result for one item. Items keep every run, so users can
    /// switch between the views of different agents.
    @Model
    final class AgentRun {
        @Attribute(.unique) var id: UUID = UUID()
        var createdAt: Date = Date()
        var agentId: UUID?
        var agentName: String = ""
        var agentEmoji: String = ""
        var agentColorName: String = "indigo"
        var modelIdentifier: String = ""
        var providerRaw: String = ""
        var title: String = ""
        var summary: String = ""
        var actionableSteps: [String] = []
        var tags: [String] = []
        var thoughtProcess: [String] = []
        var suggestedReminder: Date?
        var confidence: Double?
        var rawOutput: String = ""
        var durationSeconds: Double = 0
        var inputTokens: Int?
        var outputTokens: Int?
        var usedImage: Bool = false
        var wasStructured: Bool = true
        var isOffline: Bool = false
        var chainPosition: Int = 0
        /// Notes about automatic adjustments ("image not supported by model", …).
        var adjustmentNotes: [String] = []
        var item: CapturedItem?

        init(id: UUID = UUID(), createdAt: Date = Date()) {
            self.id = id
            self.createdAt = createdAt
        }
    }

    /// One turn of a "Chat with Screenshot" conversation.
    @Model
    final class ChatMessage {
        @Attribute(.unique) var id: UUID = UUID()
        var createdAt: Date = Date()
        var roleRaw: String = ChatRole.user.rawValue
        var content: String = ""
        var agentId: UUID?
        var agentName: String?
        var modelIdentifier: String?
        var isError: Bool = false
        var item: CapturedItem?

        init(role: ChatRole, content: String, createdAt: Date = Date()) {
            self.roleRaw = role.rawValue
            self.content = content
            self.createdAt = createdAt
        }
    }
}

enum RecallDropMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [RecallDropSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

typealias CapturedItem = RecallDropSchemaV1.CapturedItem
typealias AgentConfig = RecallDropSchemaV1.AgentConfig
typealias AgentRun = RecallDropSchemaV1.AgentRun
typealias ChatMessage = RecallDropSchemaV1.ChatMessage
