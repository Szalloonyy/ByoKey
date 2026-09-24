//
//  FlexibleDateParser.swift
//  RecallDropKit
//
//  Language models write dates in many ISO-8601 dialects ("2026-10-02",
//  "2026-10-02T09:00", "2026-10-02 09:00:00+02:00"). This parser accepts all
//  of them and interprets zone-less values in the user's time zone.
//

import Foundation

public enum FlexibleDateParser {
    private static let pattern =
        #"^(\d{4})-(\d{1,2})-(\d{1,2})(?:[T ](\d{1,2}):(\d{2})(?::(\d{2})(?:[.,]\d+)?)?)?\s*(Z|z|[+-]\d{2}(?::?\d{2})?)?$"#

    /// Parses a date or date-time. Date-only values get `defaultHour` o'clock.
    public static func parse(_ input: String, timeZone: TimeZone = .current, defaultHour: Int = 9) -> Date? {
        let string = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty,
              let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) else {
            return nil
        }

        func group(_ index: Int) -> String? {
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: string) else { return nil }
            return String(string[swiftRange])
        }
        func number(_ index: Int) -> Int? { group(index).flatMap { Int($0) } }

        guard let year = number(1), let month = number(2), let day = number(3),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        let hasTime = group(4) != nil
        let hour = hasTime ? (number(4) ?? 0) : defaultHour
        let minute = hasTime ? (number(5) ?? 0) : 0
        let second = number(6) ?? 0
        guard (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second) else { return nil }

        var zone = timeZone
        if let designator = group(7) {
            guard let parsed = parseZone(designator) else { return nil }
            zone = parsed
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: min(second, 59))
        guard let date = calendar.date(from: components) else { return nil }
        // Reject impossible days such as 2026-02-30 that Calendar would roll over.
        guard calendar.component(.day, from: date) == day, calendar.component(.month, from: date) == month else {
            return nil
        }
        return date
    }

    /// API timestamps (`2025-02-19T00:00:00Z`); zone-less values are read as UTC.
    public static func parseTimestamp(_ input: String) -> Date? {
        parse(input, timeZone: TimeZone(identifier: "UTC") ?? .current, defaultHour: 0)
    }

    private static func parseZone(_ designator: String) -> TimeZone? {
        if designator == "Z" || designator == "z" { return TimeZone(identifier: "UTC") }
        let sign = designator.hasPrefix("-") ? -1 : 1
        let digits = designator.dropFirst().replacingOccurrences(of: ":", with: "")
        guard let hours = Int(digits.prefix(2)) else { return nil }
        let minutes = digits.count >= 4 ? Int(digits.dropFirst(2).prefix(2)) ?? 0 : 0
        guard hours <= 14, minutes < 60 else { return nil }
        return TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60))
    }
}
