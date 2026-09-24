//
//  NotificationCoordinator.swift
//  RecallDrop
//
//  Receives reminder notifications: shows them while the app is open,
//  opens the item on tap, and handles the Snooze / Archive actions.
//  Delegate methods are nonisolated and hop to the main actor with plain
//  values only, as UserNotifications calls them on arbitrary queues.
//

import Foundation
import UserNotifications
import RecallDropKit

@MainActor
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationCoordinator()

    private weak var environment: AppEnvironment?
    /// Actions that arrived before the environment was attached (cold launch from a notification).
    private var pendingActions: [(action: String, itemID: UUID)] = []

    func activate(with environment: AppEnvironment) {
        self.environment = environment
        UNUserNotificationCenter.current().delegate = self
        ReminderService.registerCategories()
        let queued = pendingActions
        pendingActions.removeAll()
        guard !queued.isEmpty else { return }
        Task {
            for entry in queued {
                await handle(action: entry.action, itemID: entry.itemID)
            }
        }
    }

    /// Installs the delegate as early as possible (before the environment exists).
    func installDelegate() {
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        guard let rawID = userInfo[ReminderService.itemIDKey] as? String, let itemID = UUID(uuidString: rawID) else { return }
        await handle(action: action, itemID: itemID)
    }

    /// Finishes before returning, so a background launch for a Snooze action
    /// is not suspended before the new reminder is scheduled.
    private func handle(action: String, itemID: UUID) async {
        guard let environment else {
            pendingActions.append((action, itemID))
            return
        }
        let context = environment.container.mainContext
        guard let item = CapturedItem.fetch(id: itemID, in: context) else { return }
        let reminders = environment.reminders
        let schedule = environment.settings.reminderSchedule

        switch action {
        case ReminderService.Action.snoozeHour.rawValue:
            let date = SnoozeOption.oneHour.date(relativeTo: Date(), schedule: schedule)
            await reminders.schedule(item, at: date)
        case ReminderService.Action.snoozeTomorrow.rawValue:
            let date = SnoozeOption.tomorrow.date(relativeTo: Date(), schedule: schedule)
            await reminders.schedule(item, at: date)
        case ReminderService.Action.archive.rawValue:
            item.isArchived = true
            reminders.cancelReminder(for: item)
        case UNNotificationDismissActionIdentifier:
            break
        default:
            // Tapped: the reminder did its job – clear it and show the item.
            reminders.cancelReminder(for: item)
            #if os(macOS)
            // Opens a window even when only the menu bar extra is running.
            MacCaptureCoordinator.shared.open(itemID: itemID)
            #else
            environment.router.open(itemID: itemID)
            #endif
        }
    }
}
