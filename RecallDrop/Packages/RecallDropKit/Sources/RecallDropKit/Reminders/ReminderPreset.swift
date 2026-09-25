//
//  ReminderPreset.swift
//  RecallDropKit
//
//  The quick "Remind me" choices and how they map to a concrete time.
//  Kept free of UserNotifications so the rules are unit-testable.
//

import Foundation

public struct ReminderSchedule: Sendable, Hashable, Codable {
    /// Hour used for "Tomorrow" and "Next Week".
    public var morningHour: Int
    /// Hour used for "Tonight".
    public var eveningHour: Int
    /// Hour used for "This Weekend".
    public var weekendHour: Int

    public init(morningHour: Int = 9, eveningHour: Int = 20, weekendHour: Int = 10) {
        self.morningHour = min(max(morningHour, 0), 23)
        self.eveningHour = min(max(eveningHour, 0), 23)
        self.weekendHour = min(max(weekendHour, 0), 23)
    }

    public static let `default` = ReminderSchedule()
}

public enum ReminderPreset: String, CaseIterable, Identifiable, Sendable, Codable {
    case inTwoHours
    case tonight
    case tomorrow
    case thisWeekend
    case nextWeek

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .inTwoHours: "In 2 Hours"
        case .tonight: "Tonight"
        case .tomorrow: "Tomorrow"
        case .thisWeekend: "This Weekend"
        case .nextWeek: "Next Week"
        }
    }

    public var symbolName: String {
        switch self {
        case .inTwoHours: "clock.arrow.circlepath"
        case .tonight: "moon.stars"
        case .tomorrow: "sunrise"
        case .thisWeekend: "sofa"
        case .nextWeek: "calendar"
        }
    }

    /// The presets required everywhere a quick reminder is offered.
    public static let quickChoices: [ReminderPreset] = [.inTwoHours, .tonight, .tomorrow]

    public func date(relativeTo now: Date, calendar: Calendar = .current, schedule: ReminderSchedule = .default) -> Date {
        switch self {
        case .inTwoHours:
            return Self.droppingSeconds(now.addingTimeInterval(2 * 3600), calendar: calendar)

        case .tonight:
            let evening = Self.at(hour: schedule.eveningHour, on: now, calendar: calendar)
            if evening > now.addingTimeInterval(15 * 60) { return evening }
            // Already evening: an hour from now, rounded up to the quarter hour, if that is still today.
            let later = Self.roundedUpToQuarterHour(now.addingTimeInterval(3600), calendar: calendar)
            if calendar.isDate(later, inSameDayAs: now) { return later }
            return Self.at(hour: schedule.eveningHour, on: Self.adding(days: 1, to: now, calendar: calendar), calendar: calendar)

        case .tomorrow:
            return Self.at(hour: schedule.morningHour, on: Self.adding(days: 1, to: now, calendar: calendar), calendar: calendar)

        case .thisWeekend:
            let weekday = calendar.component(.weekday, from: now) // 1 = Sunday … 7 = Saturday
            if weekday == 7 || weekday == 1 {
                let today = Self.at(hour: schedule.weekendHour, on: now, calendar: calendar)
                if today > now.addingTimeInterval(15 * 60) { return today }
                if weekday == 7 {
                    return Self.at(hour: schedule.weekendHour, on: Self.adding(days: 1, to: now, calendar: calendar), calendar: calendar)
                }
            }
            let daysUntilSaturday = (7 - weekday + 7) % 7
            let offset = daysUntilSaturday == 0 ? 7 : daysUntilSaturday
            return Self.at(hour: schedule.weekendHour, on: Self.adding(days: offset, to: now, calendar: calendar), calendar: calendar)

        case .nextWeek:
            let weekday = calendar.component(.weekday, from: now)
            var daysUntilMonday = (2 - weekday + 7) % 7
            if daysUntilMonday == 0 { daysUntilMonday = 7 }
            return Self.at(hour: schedule.morningHour, on: Self.adding(days: daysUntilMonday, to: now, calendar: calendar), calendar: calendar)
        }
    }

    // MARK: Calendar helpers

    static func at(hour: Int, on day: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
    }

    static func adding(days: Int, to date: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: days, to: date) ?? date.addingTimeInterval(Double(days) * 86_400)
    }

    static func droppingSeconds(_ date: Date, calendar: Calendar) -> Date {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return calendar.date(from: components) ?? date
    }

    static func roundedUpToQuarterHour(_ date: Date, calendar: Calendar) -> Date {
        let base = droppingSeconds(date, calendar: calendar)
        let minute = calendar.component(.minute, from: base)
        let remainder = minute % 15
        guard remainder != 0 || base < date else { return base }
        return calendar.date(byAdding: .minute, value: 15 - remainder, to: base) ?? base
    }
}

/// Snooze choices offered on a delivered reminder notification.
public enum SnoozeOption: String, CaseIterable, Sendable {
    case oneHour
    case tonight
    case tomorrow

    public var title: String {
        switch self {
        case .oneHour: "Snooze 1 Hour"
        case .tonight: "Tonight"
        case .tomorrow: "Tomorrow Morning"
        }
    }

    public func date(relativeTo now: Date, calendar: Calendar = .current, schedule: ReminderSchedule = .default) -> Date {
        switch self {
        case .oneHour: ReminderPreset.droppingSeconds(now.addingTimeInterval(3600), calendar: calendar)
        case .tonight: ReminderPreset.tonight.date(relativeTo: now, calendar: calendar, schedule: schedule)
        case .tomorrow: ReminderPreset.tomorrow.date(relativeTo: now, calendar: calendar, schedule: schedule)
        }
    }
}
