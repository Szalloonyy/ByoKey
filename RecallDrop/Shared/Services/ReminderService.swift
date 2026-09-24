//
//  ReminderService.swift
//  RecallDrop
//
//  Resurfacing via local notifications ("Remind me in 2 hours", "Tonight",
//  "Tomorrow", …). Each item has at most one pending reminder, identified by
//  the item's ID. Notifications carry the capture's thumbnail and offer
//  Snooze / Archive actions right from the banner.
//
//  UserNotifications types are only touched inside nonisolated helpers that
//  exchange Sendable values, which keeps the main actor free of them.
//

import Foundation
import Observation
import SwiftData
import UserNotifications
import RecallDropKit

/// Sendable description of one notification to schedule.
struct ReminderPayload: Sendable {
    var itemID: UUID
    var title: String
    var body: String
    var date: Date
    var thumbnail: Data?
}

@MainActor
@Observable
final class ReminderService {
    nonisolated static let categoryIdentifier = "RECALLDROP_REMINDER"
    nonisolated static let itemIDKey = "itemID"

    enum Action: String {
        case snoozeHour = "RECALLDROP_SNOOZE_1H"
        case snoozeTomorrow = "RECALLDROP_SNOOZE_TOMORROW"
        case archive = "RECALLDROP_ARCHIVE"
    }

    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    private(set) var lastError: String?

    @ObservationIgnored private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorized || authorizationStatus == .provisional
    }

    /// The user turned notifications off for RecallDrop.
    var isDenied: Bool { authorizationStatus == .denied }

    var hasAskedForAuthorization: Bool { authorizationStatus != .notDetermined }

    // MARK: Authorization

    func refreshAuthorizationStatus() async {
        authorizationStatus = await Self.currentAuthorizationStatus()
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        let granted = await Self.requestSystemAuthorization()
        await refreshAuthorizationStatus()
        return granted
    }

    // MARK: Scheduling

    /// Schedules (or moves) the reminder for `item`. Returns false when
    /// notifications are not allowed; the date is stored either way so the
    /// item still shows up under Reminders.
    @discardableResult
    func schedule(_ item: CapturedItem, at date: Date) async -> Bool {
        item.reminderDate = date
        item.touch()
        try? item.modelContext?.save()

        if authorizationStatus == .notDetermined {
            await requestAuthorization()
        } else {
            await refreshAuthorizationStatus()
        }
        guard isAuthorized else {
            lastError = "Notifications are turned off for RecallDrop. Allow them in Settings to get reminders."
            return false
        }
        let payload = ReminderPayload(itemID: item.id, title: item.displayTitle, body: item.reminderBody,
                                      date: date, thumbnail: item.thumbnailData)
        do {
            try await Self.addNotification(payload)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func schedule(_ item: CapturedItem, preset: ReminderPreset) async {
        let date = preset.date(relativeTo: Date(), calendar: .current, schedule: settings.reminderSchedule)
        await schedule(item, at: date)
    }

    func cancelReminder(for item: CapturedItem) {
        item.reminderDate = nil
        item.touch()
        try? item.modelContext?.save()
        Self.removeNotifications(ids: [Self.requestIdentifier(for: item.id)])
    }

    /// Makes the system's pending notifications match the stored reminder dates
    /// (items deleted, reminders set by the share extension, restored backups).
    func reconcile(in context: ModelContext) async {
        await refreshAuthorizationStatus()
        guard isAuthorized else { return }
        let now = Date()
        let descriptor = FetchDescriptor<CapturedItem>(predicate: #Predicate { $0.reminderDate != nil })
        let items = (try? context.fetch(descriptor)) ?? []
        let upcoming = items.filter { ($0.reminderDate ?? .distantPast) > now }
        let wanted = Set(upcoming.map { Self.requestIdentifier(for: $0.id) })
        let pending = Set(await Self.pendingRequestIdentifiers())

        let stale = pending.subtracting(wanted)
        if !stale.isEmpty { Self.removeNotifications(ids: Array(stale)) }

        for item in upcoming where !pending.contains(Self.requestIdentifier(for: item.id)) {
            guard let date = item.reminderDate else { continue }
            let payload = ReminderPayload(itemID: item.id, title: item.displayTitle, body: item.reminderBody,
                                          date: date, thumbnail: item.thumbnailData)
            try? await Self.addNotification(payload)
        }
    }

    // MARK: Categories

    nonisolated static func registerCategories() {
        let snooze = UNNotificationAction(identifier: Action.snoozeHour.rawValue, title: "Snooze 1 Hour", options: [])
        let tomorrow = UNNotificationAction(identifier: Action.snoozeTomorrow.rawValue, title: "Tomorrow Morning", options: [])
        let archive = UNNotificationAction(identifier: Action.archive.rawValue, title: "Archive", options: [.destructive])
        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [snooze, tomorrow, archive],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    nonisolated static func requestIdentifier(for itemID: UUID) -> String {
        "recalldrop.reminder.\(itemID.uuidString)"
    }

    // MARK: UserNotifications bridge

    private nonisolated static func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private nonisolated static func requestSystemAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    private nonisolated static func pendingRequestIdentifiers() async -> [String] {
        await UNUserNotificationCenter.current().pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix("recalldrop.reminder.") }
    }

    private nonisolated static func removeNotifications(ids: [String]) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    private nonisolated static func addNotification(_ payload: ReminderPayload) async throws {
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier
        content.threadIdentifier = "recalldrop.reminders"
        content.userInfo = [itemIDKey: payload.itemID.uuidString]
        if let thumbnail = payload.thumbnail, let attachment = makeAttachment(thumbnail, itemID: payload.itemID) {
            content.attachments = [attachment]
        }

        var calendar = Calendar.current
        calendar.timeZone = .current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: payload.date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: requestIdentifier(for: payload.itemID), content: content, trigger: trigger)
        try await UNUserNotificationCenter.current().add(request)
    }

    /// The system moves the file into its own store, so a temporary copy is used.
    private nonisolated static func makeAttachment(_ data: Data, itemID: UUID) -> UNNotificationAttachment? {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "reminder-\(itemID.uuidString)-\(UUID().uuidString.prefix(8)).jpg")
        do {
            try data.write(to: url, options: .atomic)
            return try UNNotificationAttachment(identifier: "thumbnail", url: url, options: nil)
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }
}
