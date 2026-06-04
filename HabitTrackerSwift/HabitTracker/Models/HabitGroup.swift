import SwiftUI
import UniformTypeIdentifiers

// MARK: - Habit Group Model
struct HabitGroup: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var colorName: HabitColor
    var isExpanded: Bool
    var habits: [Habit]
    var createdAt: Date
    var order: Int

    init(
        id: UUID = UUID(),
        name: String,
        colorName: HabitColor = .blue,
        isExpanded: Bool = true,
        habits: [Habit] = [],
        createdAt: Date = Date(),
        order: Int = 0
    ) {
        self.id = id
        self.name = name
        self.colorName = colorName
        self.isExpanded = isExpanded
        self.habits = habits
        self.createdAt = createdAt
        self.order = order
    }

    var color: Color { colorName.color }

    // Progress for a specific date (0.0 - 1.0)
    func progress(for dateKey: String) -> Double {
        guard !habits.isEmpty else { return 0 }
        let doneCount = habits.filter { $0.history[dateKey] == .done }.count
        return Double(doneCount) / Double(habits.count)
    }

    // Group streak (days when ALL habits were done)
    var streak: Int {
        guard !habits.isEmpty else { return 0 }

        let calendar = Calendar.current
        var streak = 0
        var checkDate = Date()
        let todayKey = DateHelper.dateKey(for: checkDate)

        // If today not 100%, start from yesterday
        if progress(for: todayKey) < 1.0 {
            checkDate = calendar.date(byAdding: .day, value: -1, to: checkDate) ?? checkDate
        }

        while true {
            let key = DateHelper.dateKey(for: checkDate)
            if progress(for: key) == 1.0 {
                streak += 1
                checkDate = calendar.date(byAdding: .day, value: -1, to: checkDate) ?? checkDate
            } else {
                break
            }
        }

        return streak
    }
}

// MARK: - Transferable for Drag & Drop (Group headers can be reordered too)
extension HabitGroup: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .habitGroup)
    }
}

extension UTType {
    static var habitGroup: UTType {
        UTType(exportedAs: "com.habittracker.habitgroup")
    }
}

// MARK: - Unified Item for mixed lists
enum HabitItem: Identifiable, Equatable, Hashable {
    case habit(Habit, groupId: UUID?)
    case group(HabitGroup)

    var id: UUID {
        switch self {
        case .habit(let habit, _): return habit.id
        case .group(let group): return group.id
        }
    }

    var order: Int {
        switch self {
        case .habit(let habit, _): return habit.order
        case .group(let group): return group.order
        }
    }

    /// Debug name for logging
    var debugName: String {
        switch self {
        case .habit(let habit, let groupId):
            let location = groupId == nil ? "standalone" : "in group"
            return "Habit(\(habit.name), \(location))"
        case .group(let group):
            return "Group(\(group.name), \(group.habits.count) habits)"
        }
    }

    /// Plain display name (used by the drag preview).
    var debugTitle: String {
        switch self {
        case .habit(let habit, _): return habit.name
        case .group(let group): return group.name
        }
    }
}
