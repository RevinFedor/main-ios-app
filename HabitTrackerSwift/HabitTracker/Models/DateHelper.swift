import Foundation

// MARK: - Date Helper
struct DateHelper {
    static let calendar = Calendar.current

    // Cached on purpose: `dateKey` is on the hot render path (every habit row
    // calls weekDates() → dateKey() ~7× per body evaluation, and the list
    // re-renders every frame during a drag). Allocating a fresh DateFormatter
    // per call was the #1 cause of drag stiffness — building a DateFormatter
    // spins up an ICU/CFDateFormatter and is one of the most expensive common
    // Cocoa ops. One shared instance is safe here: all calls are on the main
    // actor (SwiftUI render). Output is byte-identical to the old per-call
    // formatter, so existing history keys keep matching.
    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // Format: "2025-12-19"
    static func dateKey(for date: Date) -> String {
        keyFormatter.string(from: date)
    }

    static var todayKey: String {
        dateKey(for: Date())
    }

    // Get week dates for given offset
    static func weekDates(
        weekOffset: Int = 0,
        firstDayOfWeek: FirstDayOfWeek = .monday
    ) -> [WeekDay] {
        let today = Date()
        let todayKey = dateKey(for: today)
        let currentWeekday = calendar.component(.weekday, from: today)

        var startOfWeek: Date

        switch firstDayOfWeek {
        case .monday:
            let diff = (currentWeekday + 5) % 7
            startOfWeek = calendar.date(byAdding: .day, value: -diff + weekOffset * 7, to: today) ?? today
        case .sunday:
            startOfWeek = calendar.date(byAdding: .day, value: -(currentWeekday - 1) + weekOffset * 7, to: today) ?? today
        case .relative:
            // Today is the last visible column, show [today-6 ... today].
            startOfWeek = calendar.date(byAdding: .day, value: -6 + weekOffset * 7, to: today) ?? today
        }

        var days: [WeekDay] = []
        for i in 0..<7 {
            let date = calendar.date(byAdding: .day, value: i, to: startOfWeek) ?? startOfWeek
            let key = dateKey(for: date)
            let weekdayIndex = calendar.component(.weekday, from: date)

            days.append(WeekDay(
                key: key,
                date: date,
                label: weekdayLabels[weekdayIndex - 1],
                dayNumber: calendar.component(.day, from: date),
                isToday: key == todayKey
            ))
        }

        return days
    }

    private static let weekdayLabels = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]

    private static let monthsShort = [
        "янв", "фев", "мар", "апр", "май", "июн",
        "июл", "авг", "сен", "окт", "ноя", "дек"
    ]

    // Compact week label: "16-22 дек"
    static func compactWeekLabel(weekOffset: Int, firstDayOfWeek: FirstDayOfWeek = .monday) -> String {
        let days = weekDates(weekOffset: weekOffset, firstDayOfWeek: firstDayOfWeek)
        guard let first = days.first, let last = days.last else { return "" }

        let startDay = calendar.component(.day, from: first.date)
        let endDay = calendar.component(.day, from: last.date)
        let startMonth = monthsShort[calendar.component(.month, from: first.date) - 1]
        let endMonth = monthsShort[calendar.component(.month, from: last.date) - 1]

        if startMonth == endMonth {
            return "\(startDay)-\(endDay) \(endMonth)"
        } else {
            return "\(startDay) \(startMonth) - \(endDay) \(endMonth)"
        }
    }
}

// MARK: - Week Day Model
struct WeekDay: Identifiable {
    // Identity MUST be the date string, NOT a fresh UUID. weekDates() rebuilds
    // these structs on every body pass; with a per-call UUID, ForEach saw 7 new
    // identities each time the store published a change (e.g. a group toggle
    // wrapped in withAnimation), so the header's day columns animated out+in —
    // the "Monday/Tuesday flicker on expand/collapse". The date key is stable
    // across recomputations → same column keeps its identity, no transition.
    var id: String { key }
    let key: String
    let date: Date
    let label: String
    let dayNumber: Int
    let isToday: Bool
}

// MARK: - First Day of Week
enum FirstDayOfWeek: String, Codable {
    case monday
    case sunday
    case relative  // today is always the last column
}
