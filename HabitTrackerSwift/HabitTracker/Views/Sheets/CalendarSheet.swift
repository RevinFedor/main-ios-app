import SwiftUI

struct CalendarSheet: View {
    @EnvironmentObject var store: HabitStore
    @Environment(\.dismiss) var dismiss

    @State private var displayedMonth: Date = Date()

    private let calendar = Calendar.current
    private let russianMonths = [
        "Январь", "Февраль", "Март", "Апрель", "Май", "Июнь",
        "Июль", "Август", "Сентябрь", "Октябрь", "Ноябрь", "Декабрь"
    ]
    private let dayHeaders = ["ПН", "ВТ", "СР", "ЧТ", "ПТ", "СБ", "ВС"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Month navigation
                    monthHeader

                    // Day-of-week headers
                    dayOfWeekHeader

                    // Calendar grid
                    calendarGrid

                    // Legend
                    legendView
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .background(Color(hex: "1C1C1E"))
            .navigationTitle("Календарь")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") { dismiss() }
                        .foregroundColor(.blue)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Month Header

    private var monthHeader: some View {
        HStack {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    displayedMonth = calendar.date(byAdding: .month, value: -1, to: displayedMonth) ?? displayedMonth
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(canGoBack ? .blue : Color(hex: "3A3A3C"))
                    .frame(width: 44, height: 44)
            }
            .disabled(!canGoBack)

            Spacer()

            Text(monthYearLabel)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    displayedMonth = calendar.date(byAdding: .month, value: 1, to: displayedMonth) ?? displayedMonth
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(canGoForward ? .blue : Color(hex: "3A3A3C"))
                    .frame(width: 44, height: 44)
            }
            .disabled(!canGoForward)
        }
    }

    // MARK: - Day of Week Header

    private var dayOfWeekHeader: some View {
        HStack(spacing: 0) {
            ForEach(dayHeaders, id: \.self) { header in
                Text(header)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(hex: "8E8E93"))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Calendar Grid

    private var calendarGrid: some View {
        let weeks = weeksInMonth()

        return VStack(spacing: 4) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { dayIndex in
                        if dayIndex < week.count, let day = week[dayIndex] {
                            dayCellView(day: day)
                        } else {
                            Color.clear
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Day Cell

    private func dayCellView(day: CalendarDay) -> some View {
        let completedHabits = habitsCompleted(on: day.key)
        let isToday = day.key == DateHelper.todayKey

        return VStack(spacing: 3) {
            ZStack {
                if isToday {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 28, height: 28)
                }

                Text("\(day.dayNumber)")
                    .font(.system(size: 14, weight: isToday ? .bold : .regular))
                    .foregroundColor(isToday ? .white : day.isCurrentMonth ? .white : Color(hex: "3A3A3C"))
            }
            .frame(width: 28, height: 28)

            // Habit dots (max 4)
            if !completedHabits.isEmpty {
                HStack(spacing: 2) {
                    ForEach(Array(completedHabits.prefix(4).enumerated()), id: \.offset) { _, color in
                        Circle()
                            .fill(color)
                            .frame(width: 5, height: 5)
                    }
                }
                .frame(height: 5)
            } else {
                Color.clear.frame(height: 5)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 52)
    }

    // MARK: - Legend

    private var legendView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Привычки")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color(hex: "8E8E93"))

            let habits = allHabits
            if habits.isEmpty {
                Text("Нет привычек")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "6E6E73"))
            } else {
                ForEach(habits) { habit in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(habit.color)
                            .frame(width: 8, height: 8)
                        Text(habit.name)
                            .font(.system(size: 13))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Spacer()
                        Text(monthStats(for: habit))
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "8E8E93"))
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(hex: "2C2C2E"))
        )
        .padding(.top, 8)
    }

    // MARK: - Data Helpers

    private var allHabits: [Habit] {
        var habits = store.standaloneHabits
        for group in store.groups {
            habits.append(contentsOf: group.habits)
        }
        return habits.sorted { $0.order < $1.order }
    }

    private func habitsCompleted(on dateKey: String) -> [Color] {
        var colors: [Color] = []
        for habit in allHabits {
            if habit.history[dateKey] == .done {
                colors.append(habit.color)
            }
        }
        return colors
    }

    private func monthStats(for habit: Habit) -> String {
        let days = daysInDisplayedMonth()
        let doneCount = days.filter { habit.history[$0.key] == .done }.count
        return "\(doneCount)/\(days.count)"
    }

    // MARK: - Calendar Logic

    private var monthYearLabel: String {
        let month = calendar.component(.month, from: displayedMonth)
        let year = calendar.component(.year, from: displayedMonth)
        return "\(russianMonths[month - 1]) \(year)"
    }

    private var canGoBack: Bool {
        guard let earliest = earliestDate() else { return false }
        let earliestMonth = calendar.dateInterval(of: .month, for: earliest)?.start ?? earliest
        let currentMonth = calendar.dateInterval(of: .month, for: displayedMonth)?.start ?? displayedMonth
        return currentMonth > earliestMonth
    }

    private var canGoForward: Bool {
        let todayMonth = calendar.dateInterval(of: .month, for: Date())?.start ?? Date()
        let currentMonth = calendar.dateInterval(of: .month, for: displayedMonth)?.start ?? displayedMonth
        return currentMonth < todayMonth
    }

    private func earliestDate() -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        var allKeys: [String] = []
        for habit in allHabits {
            allKeys.append(contentsOf: habit.history.keys)
        }

        let dates = allKeys.compactMap { formatter.date(from: $0) }
        return dates.min()
    }

    private func daysInDisplayedMonth() -> [CalendarDay] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: displayedMonth) else { return [] }
        let daysCount = calendar.dateComponents([.day], from: monthInterval.start, to: monthInterval.end).day ?? 30

        var days: [CalendarDay] = []
        for i in 0..<daysCount {
            if let date = calendar.date(byAdding: .day, value: i, to: monthInterval.start) {
                days.append(CalendarDay(
                    date: date,
                    key: DateHelper.dateKey(for: date),
                    dayNumber: i + 1,
                    isCurrentMonth: true
                ))
            }
        }
        return days
    }

    private func weeksInMonth() -> [[CalendarDay?]] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: displayedMonth) else { return [] }
        let daysCount = calendar.dateComponents([.day], from: monthInterval.start, to: monthInterval.end).day ?? 30

        // Monday = 1, Sunday = 7
        let firstWeekday = calendar.component(.weekday, from: monthInterval.start)
        // Convert to Monday-based: Mon=0, Tue=1, ..., Sun=6
        let startOffset = (firstWeekday + 5) % 7

        var grid: [CalendarDay?] = Array(repeating: nil, count: startOffset)

        for i in 0..<daysCount {
            if let date = calendar.date(byAdding: .day, value: i, to: monthInterval.start) {
                grid.append(CalendarDay(
                    date: date,
                    key: DateHelper.dateKey(for: date),
                    dayNumber: i + 1,
                    isCurrentMonth: true
                ))
            }
        }

        // Pad to complete last week
        while grid.count % 7 != 0 {
            grid.append(nil)
        }

        // Split into weeks
        return stride(from: 0, to: grid.count, by: 7).map { i in
            Array(grid[i..<min(i + 7, grid.count)])
        }
    }
}

// MARK: - Calendar Day Model

struct CalendarDay: Identifiable {
    let id = UUID()
    let date: Date
    let key: String
    let dayNumber: Int
    let isCurrentMonth: Bool
}

#Preview {
    CalendarSheet()
        .environmentObject(HabitStore())
}
