//
//  AppEnvironment.swift
//  RecallDrop
//
//  Owns the long-lived objects (store, settings, pipeline, reminders, …) and
//  wires them together. The app uses one shared instance; the share
//  extension creates its own over the same App Group store.
//

import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class AppEnvironment {
    enum Role {
        case app
        case shareExtension
    }

    static let shared = AppEnvironment(role: .app)

    let role: Role
    let container: ModelContainer
    let persistenceIssue: PersistenceIssue?
    let settings: SettingsStore
    let catalog: ModelCatalogStore
    let pipeline: AgentPipeline
    let reminders: ReminderService
    let capture: CaptureService
    let agents: AgentLibrary
    let router: AppRouter

    /// Bumped when another process changed the store; root views use it as
    /// their identity so every @Query fetches again.
    private(set) var storeRevision = 0

    @ObservationIgnored private var lastSeenExternalChange: TimeInterval = 0
    @ObservationIgnored private var didStart = false

    init(role: Role) {
        // Only the app may move an unreadable store aside; the extension never
        // touches the files the app may have open.
        let (container, issue) = PersistenceController.makeContainer(allowsRecovery: role == .app)
        let settings = SettingsStore()
        let catalog = ModelCatalogStore()
        let pipeline = AgentPipeline(container: container, settings: settings, catalog: catalog)
        if role == .shareExtension {
            // Share extensions get roughly 120 MB: one job at a time, smaller OCR bitmaps.
            pipeline.claimsWork = true
            pipeline.maxConcurrentJobs = 1
            pipeline.ocrMaxDimension = 2048
        }
        let reminders = ReminderService(settings: settings)
        let capture = CaptureService(container: container, pipeline: pipeline, reminders: reminders)
        capture.processesImmediately = role == .app

        self.role = role
        self.container = container
        self.persistenceIssue = issue
        self.settings = settings
        self.catalog = catalog
        self.pipeline = pipeline
        self.reminders = reminders
        self.capture = capture
        self.agents = AgentLibrary(container: container)
        self.router = AppRouter()
        self.lastSeenExternalChange = settings.lastExternalChange

        pipeline.onItemFinished = { [weak self] itemID in
            self?.pipelineDidFinish(itemID)
        }
    }

    /// One-time setup after launch.
    func start() {
        guard !didStart else { return }
        didStart = true
        agents.seedBuiltInsIfNeeded()
        guard role == .app else { return }
        NotificationCoordinator.shared.activate(with: self)
        ExternalChangeMonitor.shared.start { [weak self] in
            self?.externalStoreDidChange()
        }
        pipeline.resumePendingWork()
        if let issue = persistenceIssue {
            router.alertMessage = issue.message
        }
        Task {
            await reminders.reconcile(in: container.mainContext)
        }
    }

    /// Called whenever the app comes to the foreground.
    func didBecomeActive() {
        guard role == .app else { return }
        if settings.lastExternalChange > lastSeenExternalChange {
            externalStoreDidChange()
        }
        pipeline.resumePendingWork()
        Task {
            await reminders.reconcile(in: container.mainContext)
            if catalog.needsRefresh(settings.provider), settings.aiUnavailableReason == nil {
                await catalog.refresh(settings.provider, settings: settings)
            }
        }
    }

    /// A reminder scheduled at capture time still shows the placeholder title;
    /// once an agent named the capture, the notification is sent again.
    private func pipelineDidFinish(_ itemID: UUID) {
        guard let item = CapturedItem.fetch(id: itemID, in: container.mainContext),
              let date = item.reminderDate, date > Date() else { return }
        let reminders = self.reminders
        Task {
            await reminders.refreshNotification(for: item)
        }
    }

    private func externalStoreDidChange() {
        lastSeenExternalChange = settings.lastExternalChange
        storeRevision += 1
        pipeline.resumePendingWork()
    }
}
