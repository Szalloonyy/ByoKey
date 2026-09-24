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
        let (container, issue) = PersistenceController.makeContainer()
        let settings = SettingsStore()
        let catalog = ModelCatalogStore()
        let pipeline = AgentPipeline(container: container, settings: settings, catalog: catalog)
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
            router.showToast(issue.message)
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

    private func externalStoreDidChange() {
        lastSeenExternalChange = settings.lastExternalChange
        storeRevision += 1
        pipeline.resumePendingWork()
    }
}
