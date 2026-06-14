import WidgetKit
import SwiftUI

// ============================================================
// MARK: - Shared Models (must match main app's Codable format)
// ============================================================

enum HabitStatus: String, Codable {
    case done
    case missed
}

enum HabitColor: String, Codable, CaseIterable {
    case blue, cyan, teal, green, lime, yellow, orange, red, pink, purple, indigo

    var color: Color {
        switch self {
        case .blue:   return Color(hex: "007AFF")
        case .cyan:   return Color(hex: "00D4FF")
        case .teal:   return Color(hex: "5AC8FA")
        case .green:  return Color(hex: "34C759")
        case .lime:   return Color(hex: "A8E063")
        case .yellow: return Color(hex: "FFCC00")
        case .orange: return Color(hex: "FF9500")
        case .red:    return Color(hex: "FF3B30")
        case .pink:   return Color(hex: "FF2D92")
        case .purple: return Color(hex: "AF52DE")
        case .indigo: return Color(hex: "5856D6")
        }
    }
}

enum FirstDayOfWeek: String, Codable {
    case monday
    case sunday
    case relative
}

struct Habit: Identifiable, Codable {
    let id: UUID
    var name: String
    var colorName: HabitColor
    // Synced with the main-app Habit (docs/knowledge/fix-ios-stability.md §3).
    // Optional so this read-only decoder accepts both pre- and post-notes JSON.
    var notes: String?
    var history: [String: HabitStatus]
    var createdAt: Date
    var order: Int

    var color: Color { colorName.color }
}

struct HabitGroup: Identifiable, Codable {
    let id: UUID
    var name: String
    var colorName: HabitColor
    var isExpanded: Bool
    var habits: [Habit]
    var createdAt: Date
    var order: Int
}

struct StorageData: Codable {
    let standaloneHabits: [Habit]
    let groups: [HabitGroup]
    let firstDayOfWeek: FirstDayOfWeek
}

// ============================================================
// MARK: - DateHelper (matches main app)
// ============================================================

struct DateHelper {
    static let calendar = Calendar.current

    static func dateKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static var todayKey: String { dateKey(for: Date()) }

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
            startOfWeek = calendar.date(byAdding: .day, value: -6 + weekOffset * 7, to: today) ?? today
        }

        let labels = ["ВС", "ПН", "ВТ", "СР", "ЧТ", "ПТ", "СБ"]
        var days: [WeekDay] = []
        for i in 0..<7 {
            let date = calendar.date(byAdding: .day, value: i, to: startOfWeek) ?? startOfWeek
            let key = dateKey(for: date)
            let weekdayIndex = calendar.component(.weekday, from: date)
            days.append(WeekDay(
                key: key,
                date: date,
                label: labels[weekdayIndex - 1],
                dayNumber: calendar.component(.day, from: date),
                isToday: key == todayKey
            ))
        }
        return days
    }
}

struct WeekDay: Identifiable {
    let id = UUID()
    let key: String
    let date: Date
    let label: String
    let dayNumber: Int
    let isToday: Bool
}

// ============================================================
// MARK: - Color(hex:) Extension
// ============================================================

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// ============================================================
// MARK: - Timeline Provider
// ============================================================

struct HabitWidgetProvider: TimelineProvider {
    let appGroupID = "group.com.fedor277.habittracker"
    let storageKey = "habitTrackerData"

    func placeholder(in context: Context) -> HabitEntry {
        HabitEntry(date: Date(), habits: Self.sampleHabits(), firstDayOfWeek: .monday)
    }

    func getSnapshot(in context: Context, completion: @escaping (HabitEntry) -> ()) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HabitEntry>) -> ()) {
        let entry = loadEntry()
        // Refresh at midnight — habits are daily
        let tomorrow = Calendar.current.startOfDay(
            for: Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        )
        let timeline = Timeline(entries: [entry], policy: .after(tomorrow))
        completion(timeline)
    }

    private func loadEntry() -> HabitEntry {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(StorageData.self, from: data) else {
            return HabitEntry(date: Date(), habits: Self.sampleHabits(), firstDayOfWeek: .monday)
        }

        // Only standalone habits — skip groups and their children
        let habits = decoded.standaloneHabits.sorted { $0.order < $1.order }

        return HabitEntry(date: Date(), habits: habits, firstDayOfWeek: decoded.firstDayOfWeek)
    }

    static func sampleHabits() -> [Habit] {
        let today = DateHelper.todayKey
        let yesterday = DateHelper.dateKey(
            for: Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        )
        return [
            Habit(id: UUID(), name: "Зарядка", colorName: .blue,
                  history: [today: .done, yesterday: .done], createdAt: Date(), order: 0),
            Habit(id: UUID(), name: "Чтение", colorName: .orange,
                  history: [today: .done], createdAt: Date(), order: 1),
            Habit(id: UUID(), name: "Медитация", colorName: .purple,
                  history: [yesterday: .done], createdAt: Date(), order: 2),
            Habit(id: UUID(), name: "Вода", colorName: .cyan,
                  history: [:], createdAt: Date(), order: 3),
        ]
    }
}

// ============================================================
// MARK: - Timeline Entry
// ============================================================

struct HabitEntry: TimelineEntry {
    let date: Date
    let habits: [Habit]
    let firstDayOfWeek: FirstDayOfWeek
}

// ============================================================
// MARK: - Entry View (dispatches by family)
// ============================================================

struct HabitWidgetEntryView: View {
    var entry: HabitEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        Group {
            switch family {
            case .systemSmall:  SmallWidgetView(entry: entry)
            case .systemMedium: MediumWidgetView(entry: entry)
            default:            SmallWidgetView(entry: entry)
            }
        }
        // Tap anywhere on the habit widget → open the Habits tab in the app.
        .widgetURL(URL(string: "habittracker://habits"))
    }
}

// ============================================================
// MARK: - Helper: Last N days relative to today
// ============================================================

struct RecentDay: Identifiable {
    let id = UUID()
    let key: String
    let date: Date
    let label: String   // "MO", "TU", etc.
    let isToday: Bool
}

/// Returns days for small widget based on firstDayOfWeek setting.
/// For .relative: today is last (position count-1).
/// For .monday/.sunday: uses weekDates and takes first `count` days.
func smallWidgetDays(count: Int, firstDayOfWeek: FirstDayOfWeek) -> [RecentDay] {
    if firstDayOfWeek == .relative {
        return recentDays(count: count, todayPosition: count - 1)
    }
    // Week-based: take first `count` days from current week
    let week = DateHelper.weekDates(weekOffset: 0, firstDayOfWeek: firstDayOfWeek)
    let labels = ["ВС", "ПН", "ВТ", "СР", "ЧТ", "ПТ", "СБ"]
    let cal = Calendar.current
    let todayKey = DateHelper.todayKey
    return Array(week.prefix(count)).map { day in
        let wd = cal.component(.weekday, from: day.date)
        return RecentDay(
            key: day.key,
            date: day.date,
            label: labels[wd - 1],
            isToday: day.key == todayKey
        )
    }
}

func recentDays(count: Int, todayPosition: Int) -> [RecentDay] {
    // todayPosition: 0-indexed position of today in the array
    // e.g. count=5, todayPosition=4 → [today-4, today-3, today-2, today-1, today]
    // e.g. count=5, todayPosition=3 → [today-3, today-2, today-1, today, today+1]
    let labels = ["ВС", "ПН", "ВТ", "СР", "ЧТ", "ПТ", "СБ"]
    let cal = Calendar.current
    let today = Date()
    let offset = -todayPosition  // days before today for first element

    var days: [RecentDay] = []
    for i in 0..<count {
        let date = cal.date(byAdding: .day, value: offset + i, to: today)!
        let wd = cal.component(.weekday, from: date)
        days.append(RecentDay(
            key: DateHelper.dateKey(for: date),
            date: date,
            label: labels[wd - 1],
            isToday: i == todayPosition
        ))
    }
    return days
}

// ============================================================
// MARK: - Small Widget: current selection (change here)
// ============================================================

struct SmallWidgetView: View {
    var entry: HabitEntry
    var body: some View {
        // Switch between variants here:
        SmallVariantA(entry: entry)
    }
}

// ============================================================
// MARK: - Variant A: 5 days × 4 habits, names + dots
// ============================================================

struct SmallVariantA: View {
    var entry: HabitEntry
    @Environment(\.widgetRenderingMode) var renderingMode

    private var habits: [Habit] { Array(entry.habits.prefix(4)) }
    private let dotSize: CGFloat = 14
    private let colWidth: CGFloat = 20

    // Use setting: week-based or relative
    private var days: [RecentDay] {
        smallWidgetDays(count: 5, firstDayOfWeek: entry.firstDayOfWeek)
    }

    var body: some View {
        VStack(spacing: 5) {
            // Day labels with today circle
            HStack(spacing: 0) {
                Spacer().frame(maxWidth: .infinity)
                ForEach(days) { day in
                    dayLabel(day)
                        .frame(width: colWidth)
                }
            }

            // Habit rows
            ForEach(habits) { habit in
                HStack(spacing: 0) {
                    HStack(spacing: 3) {
                        Circle().fill(habit.color).frame(width: 5, height: 5)
                            .widgetAccentable()
                        Text(habit.name)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    ForEach(days) { day in
                        dot(done: habit.history[day.key] == .done, color: habit.color)
                            .frame(width: colWidth)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .containerBackground(for: .widget) { Color(.systemBackground) }
    }

    @ViewBuilder
    private func dayLabel(_ day: RecentDay) -> some View {
        ZStack {
            if day.isToday {
                Circle()
                    .fill(Color.blue.opacity(0.25))
                    .frame(width: 16, height: 16)
            }
            Text(day.label)
                .font(.system(size: 8, weight: day.isToday ? .bold : .medium))
                .foregroundStyle(day.isToday ? .primary : .secondary)
                .widgetAccentable()
        }
    }

    @ViewBuilder
    private func dot(done: Bool, color: Color) -> some View {
        Circle()
            .fill(done ? color : Color.primary.opacity(0.07))
            .frame(width: dotSize, height: dotSize)
            .overlay {
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .widgetAccentable()
    }
}

// ============================================================
// MARK: - Variant B: 5 days × 6 habits, NO names, bigger dots
// ============================================================
// Layout (just colored dot grid):
//  MO  TU  WE  TH  FR
//  🔵  ○   🔵  🔵  🔵
//  ○   🟠  ○   🟠  ○
//  🟣  🟣  ○   🟣  ○
//  ○   ○   🔵  ○   🔵
//  🟢  🟢  🟢  ○   🟢
//  ○   🟡  ○   🟡  ○

struct SmallVariantB: View {
    var entry: HabitEntry
    @Environment(\.widgetRenderingMode) var renderingMode

    private var habits: [Habit] { Array(entry.habits.prefix(6)) }
    private var days: [RecentDay] { smallWidgetDays(count: 5, firstDayOfWeek: entry.firstDayOfWeek) }
    private let dotSize: CGFloat = 18
    private let spacing: CGFloat = 6

    var body: some View {
        VStack(spacing: 4) {
            // Day labels
            HStack(spacing: spacing) {
                ForEach(days) { day in
                    Text(day.label)
                        .font(.system(size: 8, weight: day.isToday ? .bold : .medium))
                        .foregroundStyle(day.isToday ? .primary : .secondary)
                        .frame(width: dotSize)
                        .widgetAccentable()
                }
            }

            // Grid: rows = habits, cols = days
            ForEach(habits) { habit in
                HStack(spacing: spacing) {
                    ForEach(days) { day in
                        let done = habit.history[day.key] == .done
                        Circle()
                            .fill(done ? habit.color : habit.color.opacity(0.12))
                            .frame(width: dotSize, height: dotSize)
                            .overlay {
                                if done {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .widgetAccentable()
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(6)
        .containerBackground(for: .widget) { Color(.systemBackground) }
    }
}

// ============================================================
// MARK: - Variant C: 5 days × 5 habits, short names, today=4th
// ============================================================
// Layout:
//        WE TH FR SA SU
//  Зар   ○  ●  ●  .  .
//  Чте   ●  ○  ●  .  .
//  Мед   ○  ●  ○  .  .
//  Вод   ●  ●  ●  .  .
//  Душ   ○  ○  ●  .  .

struct SmallVariantC: View {
    var entry: HabitEntry
    @Environment(\.widgetRenderingMode) var renderingMode

    private var habits: [Habit] { Array(entry.habits.prefix(5)) }
    private var days: [RecentDay] { smallWidgetDays(count: 5, firstDayOfWeek: entry.firstDayOfWeek) }
    private let dotSize: CGFloat = 13
    private let colWidth: CGFloat = 18

    var body: some View {
        VStack(spacing: 4) {
            // Day labels
            HStack(spacing: 0) {
                Spacer().frame(maxWidth: .infinity)
                ForEach(days) { day in
                    Text(day.label)
                        .font(.system(size: 7, weight: day.isToday ? .bold : .medium))
                        .foregroundStyle(day.isToday ? .primary : .secondary)
                        .frame(width: colWidth)
                        .widgetAccentable()
                }
            }

            // Habit rows
            ForEach(habits) { habit in
                HStack(spacing: 0) {
                    HStack(spacing: 3) {
                        Circle().fill(habit.color).frame(width: 4, height: 4)
                            .widgetAccentable()
                        Text(habit.name)
                            .font(.system(size: 9, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    ForEach(days) { day in
                        let done = habit.history[day.key] == .done
                        Circle()
                            .fill(done ? habit.color : Color.primary.opacity(0.06))
                            .frame(width: dotSize, height: dotSize)
                            .overlay {
                                if done {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 6, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .widgetAccentable()
                            .frame(width: colWidth)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(4)
        .containerBackground(for: .widget) { Color(.systemBackground) }
    }
}

// ============================================================
// MARK: - Variant D: 5 days × 4 habits, NO names, BIG dots, today=5th
// ============================================================
// Layout (maximum dot size):
//   MO   TU   WE   TH   FR
//   🔵   ○    🔵   🔵   🔵
//   ○    🟠   ○    🟠   ○
//   🟣   🟣   ○    🟣   ○
//   ○    ○    🔵   ○    🔵

struct SmallVariantD: View {
    var entry: HabitEntry
    @Environment(\.widgetRenderingMode) var renderingMode

    private var habits: [Habit] { Array(entry.habits.prefix(4)) }
    private var days: [RecentDay] { smallWidgetDays(count: 5, firstDayOfWeek: entry.firstDayOfWeek) }
    private let dotSize: CGFloat = 24
    private let spacing: CGFloat = 6

    var body: some View {
        VStack(spacing: 5) {
            // Day labels
            HStack(spacing: spacing) {
                ForEach(days) { day in
                    Text(day.label)
                        .font(.system(size: 9, weight: day.isToday ? .bold : .medium))
                        .foregroundStyle(day.isToday ? .primary : .secondary)
                        .frame(width: dotSize)
                        .widgetAccentable()
                }
            }

            // Big dot grid
            ForEach(habits) { habit in
                HStack(spacing: spacing) {
                    ForEach(days) { day in
                        let done = habit.history[day.key] == .done
                        Circle()
                            .fill(done ? habit.color : habit.color.opacity(0.12))
                            .frame(width: dotSize, height: dotSize)
                            .overlay {
                                if done {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .widgetAccentable()
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(6)
        .containerBackground(for: .widget) { Color(.systemBackground) }
    }
}

// ============================================================
// MARK: - Medium Widget (week view)
// ============================================================

struct MediumWidgetView: View {
    var entry: HabitEntry
    @Environment(\.widgetRenderingMode) var renderingMode

    private var displayHabits: [Habit] { Array(entry.habits.prefix(4)) }
    private var weekDates: [WeekDay] {
        DateHelper.weekDates(weekOffset: 0, firstDayOfWeek: entry.firstDayOfWeek)
    }

    private let dotSize: CGFloat = 18
    private let colWidth: CGFloat = 26

    var body: some View {
        VStack(spacing: 8) {
            // Day labels header — right-aligned
            HStack(spacing: 0) {
                Spacer()
                ForEach(weekDates) { day in
                    ZStack {
                        if day.isToday {
                            Circle()
                                .fill(Color.blue.opacity(0.25))
                                .frame(width: 22, height: 22)
                        }
                        Text(day.label)
                            .font(.system(size: 10, weight: day.isToday ? .bold : .medium))
                            .foregroundStyle(day.isToday ? .primary : .secondary)
                            .widgetAccentable()
                    }
                    .frame(width: colWidth)
                }
            }

            // Habit rows with dots — names left, dots right
            ForEach(displayHabits) { habit in
                HStack(spacing: 0) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(habit.color)
                            .frame(width: 6, height: 6)
                            .widgetAccentable()
                        Text(habit.name)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    ForEach(weekDates) { day in
                        let isDone = habit.history[day.key] == .done
                        Circle()
                            .fill(isDone ? habit.color : Color.primary.opacity(0.08))
                            .frame(width: dotSize, height: dotSize)
                            .overlay {
                                if isDone {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .widgetAccentable()
                            .frame(width: colWidth)
                    }
                }
            }

            if displayHabits.isEmpty {
                Text("Добавьте привычки в приложении")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .containerBackground(for: .widget) {
            Color(.systemBackground)
        }
    }
}

// ============================================================
// MARK: - Widget Configuration
// ============================================================

struct HabitWidget_: Widget {
    let kind: String = "HabitWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HabitWidgetProvider()) { entry in
            HabitWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Habit Tracker")
        .description("Прогресс привычек на главном экране")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

// ============================================================
// MARK: - Rich sample data for previews
// ============================================================

extension HabitWidgetProvider {
    static func richSampleHabits() -> [Habit] {
        let cal = Calendar.current
        let today = Date()
        func key(_ offset: Int) -> String {
            DateHelper.dateKey(for: cal.date(byAdding: .day, value: offset, to: today)!)
        }

        return [
            Habit(id: UUID(), name: "Зарядка", colorName: .blue, history: [
                key(0): .done, key(-1): .done, key(-2): .done, key(-3): .missed, key(-4): .done
            ], createdAt: today, order: 0),
            Habit(id: UUID(), name: "Чтение", colorName: .orange, history: [
                key(0): .done, key(-1): .missed, key(-2): .done, key(-3): .done, key(-4): .missed
            ], createdAt: today, order: 1),
            Habit(id: UUID(), name: "Медитация", colorName: .purple, history: [
                key(0): .missed, key(-1): .done, key(-2): .done, key(-3): .done, key(-4): .done
            ], createdAt: today, order: 2),
            Habit(id: UUID(), name: "Вода", colorName: .cyan, history: [
                key(0): .done, key(-1): .done, key(-2): .missed, key(-3): .done, key(-4): .missed
            ], createdAt: today, order: 3),
            Habit(id: UUID(), name: "Холодный душ", colorName: .green, history: [
                key(0): .done, key(-1): .missed, key(-2): .done, key(-3): .missed, key(-4): .done
            ], createdAt: today, order: 4),
            Habit(id: UUID(), name: "Завтрак", colorName: .yellow, history: [
                key(0): .done, key(-1): .done, key(-2): .done, key(-3): .done, key(-4): .missed
            ], createdAt: today, order: 5),
        ]
    }
}

// ============================================================
// MARK: - Previews (all variants)
// ============================================================

private let previewEntry = HabitEntry(
    date: .now,
    habits: HabitWidgetProvider.richSampleHabits(),
    firstDayOfWeek: .monday
)

#Preview("A: 5d × 4h + names", as: .systemSmall) {
    HabitWidget_()
} timeline: { previewEntry }

#Preview("B: 5d × 6h no names", as: .systemSmall) {
    HabitWidget_()
} timeline: { previewEntry }

#Preview("C: 5d × 5h + names (today=4th)", as: .systemSmall) {
    HabitWidget_()
} timeline: { previewEntry }

#Preview("D: 5d × 4h big dots", as: .systemSmall) {
    HabitWidget_()
} timeline: { previewEntry }

#Preview("Medium", as: .systemMedium) {
    HabitWidget_()
} timeline: { previewEntry }
