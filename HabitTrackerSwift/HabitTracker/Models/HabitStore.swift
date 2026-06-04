import SwiftUI
import Combine
import WidgetKit

// MARK: - Habit Store (Main ViewModel)
@MainActor
class HabitStore: ObservableObject {
    // Top-level items (habits not in any group)
    @Published var standaloneHabits: [Habit] = []
    // Groups with their nested habits
    @Published var groups: [HabitGroup] = []

    // Settings
    @Published var firstDayOfWeek: FirstDayOfWeek = .monday

    private let storageKey = "habitTrackerData"
    private let appGroupIdentifier = "group.com.fedor277.habittracker"

    init() {
        loadData()
        // Add sample data if empty
        if standaloneHabits.isEmpty && groups.isEmpty {
            addSampleData()
        }
    }

    // MARK: - Computed Properties

    // All items sorted for display
    var allItems: [HabitItem] {
        var items: [HabitItem] = []

        // Merge standalone habits and groups, sort by order
        var allTopLevel: [(order: Int, item: HabitItem)] = []

        for habit in standaloneHabits {
            allTopLevel.append((habit.order, .habit(habit, groupId: nil)))
        }
        for group in groups {
            allTopLevel.append((group.order, .group(group)))
        }

        allTopLevel.sort { $0.order < $1.order }

        for (_, item) in allTopLevel {
            items.append(item)

            // If it's an expanded group, add its children
            if case .group(let group) = item, group.isExpanded {
                for habit in group.habits.sorted(by: { $0.order < $1.order }) {
                    items.append(.habit(habit, groupId: group.id))
                }
            }
        }

        return items
    }

    // MARK: - Habit Actions

    func toggleHabit(_ habitId: UUID, dateKey: String, groupId: UUID? = nil) {
        if let groupId = groupId {
            // Habit is in a group
            if let groupIndex = groups.firstIndex(where: { $0.id == groupId }),
               let habitIndex = groups[groupIndex].habits.firstIndex(where: { $0.id == habitId }) {
                let currentStatus = groups[groupIndex].habits[habitIndex].history[dateKey]
                let newStatus: HabitStatus = currentStatus == .done ? .missed : .done
                groups[groupIndex].habits[habitIndex].history[dateKey] = newStatus
                triggerHaptic(.medium)
            }
        } else {
            // Standalone habit
            if let index = standaloneHabits.firstIndex(where: { $0.id == habitId }) {
                let currentStatus = standaloneHabits[index].history[dateKey]
                let newStatus: HabitStatus = currentStatus == .done ? .missed : .done
                standaloneHabits[index].history[dateKey] = newStatus
                triggerHaptic(.medium)
            }
        }
        saveData()
    }

    func toggleGroupExpanded(_ groupId: UUID) {
        if let index = groups.firstIndex(where: { $0.id == groupId }) {
            withAnimation(.easeInOut(duration: 0.25)) {
                groups[index].isExpanded.toggle()
            }
            triggerHaptic(.light)
            saveData()
        }
    }

    // MARK: - Add/Edit/Delete

    func addHabit(name: String, color: HabitColor) {
        let maxOrder = max(
            standaloneHabits.map(\.order).max() ?? -1,
            groups.map(\.order).max() ?? -1
        )
        let habit = Habit(name: name, colorName: color, order: maxOrder + 1)
        standaloneHabits.append(habit)
        triggerHaptic(.success)
        saveData()
    }

    func addGroup(name: String, color: HabitColor, habitNames: [String]) {
        let maxOrder = max(
            standaloneHabits.map(\.order).max() ?? -1,
            groups.map(\.order).max() ?? -1
        )

        let habits = habitNames.enumerated().map { index, habitName in
            Habit(name: habitName, colorName: color, order: index)
        }

        let group = HabitGroup(
            name: name,
            colorName: color,
            isExpanded: true,
            habits: habits,
            order: maxOrder + 1
        )
        groups.append(group)
        triggerHaptic(.success)
        saveData()
    }

    func updateHabit(_ habitId: UUID, name: String, color: HabitColor, groupId: UUID? = nil) {
        if let groupId = groupId {
            if let groupIndex = groups.firstIndex(where: { $0.id == groupId }),
               let habitIndex = groups[groupIndex].habits.firstIndex(where: { $0.id == habitId }) {
                groups[groupIndex].habits[habitIndex].name = name
                groups[groupIndex].habits[habitIndex].colorName = color
            }
        } else {
            if let index = standaloneHabits.firstIndex(where: { $0.id == habitId }) {
                standaloneHabits[index].name = name
                standaloneHabits[index].colorName = color
            }
        }
        triggerHaptic(.success)
        saveData()
    }

    func updateGroup(_ groupId: UUID, name: String, color: HabitColor) {
        if let index = groups.firstIndex(where: { $0.id == groupId }) {
            groups[index].name = name
            groups[index].colorName = color
        }
        triggerHaptic(.success)
        saveData()
    }

    func deleteHabit(_ habitId: UUID, groupId: UUID? = nil) {
        if let groupId = groupId {
            if let groupIndex = groups.firstIndex(where: { $0.id == groupId }) {
                groups[groupIndex].habits.removeAll { $0.id == habitId }
            }
        } else {
            standaloneHabits.removeAll { $0.id == habitId }
        }
        triggerHaptic(.warning)
        saveData()
    }

    func deleteGroup(_ groupId: UUID, keepHabits: Bool) {
        if let index = groups.firstIndex(where: { $0.id == groupId }) {
            if keepHabits {
                // Move habits to standalone
                let habits = groups[index].habits
                for var habit in habits {
                    habit.order = (standaloneHabits.map(\.order).max() ?? -1) + 1
                    standaloneHabits.append(habit)
                }
            }
            groups.remove(at: index)
        }
        triggerHaptic(.warning)
        saveData()
    }

    // MARK: - Drag & Drop (iOS 26 Native API)

    // Get habit by ID (searches both standalone and in groups)
    func habit(by id: UUID) -> Habit? {
        if let habit = standaloneHabits.first(where: { $0.id == id }) {
            return habit
        }
        for group in groups {
            if let habit = group.habits.first(where: { $0.id == id }) {
                return habit
            }
        }
        return nil
    }

    // Get group ID that contains a habit
    func groupId(for habitId: UUID) -> UUID? {
        for group in groups {
            if group.habits.contains(where: { $0.id == habitId }) {
                return group.id
            }
        }
        return nil
    }

    // Move habit by ID to a target group (nil = standalone)
    func moveHabit(id habitId: UUID, toGroup targetGroupId: UUID?) {
        print("      🚚 moveHabit: habitId=\(habitId.uuidString.prefix(8)) → targetGroup=\(String(describing: targetGroupId?.uuidString.prefix(8)))")

        let sourceGroupId = groupId(for: habitId)
        print("         sourceGroupId=\(String(describing: sourceGroupId?.uuidString.prefix(8)))")

        // Don't move if same location
        if sourceGroupId == targetGroupId {
            print("         ⏭️ Same location, skipping")
            return
        }

        // Find and remove from source
        var movedHabit: Habit?

        if let sourceGroupId = sourceGroupId {
            if let groupIndex = groups.firstIndex(where: { $0.id == sourceGroupId }),
               let habitIndex = groups[groupIndex].habits.firstIndex(where: { $0.id == habitId }) {
                movedHabit = groups[groupIndex].habits.remove(at: habitIndex)
                print("         Removed from group '\(groups[groupIndex].name)' at index \(habitIndex)")
            }
        } else {
            if let index = standaloneHabits.firstIndex(where: { $0.id == habitId }) {
                movedHabit = standaloneHabits.remove(at: index)
                print("         Removed from standalone at index \(index)")
            }
        }

        guard var habit = movedHabit else {
            print("         ❌ Habit not found!")
            return
        }

        // Add to target
        if let targetGroupId = targetGroupId {
            if let groupIndex = groups.firstIndex(where: { $0.id == targetGroupId }) {
                habit.order = (groups[groupIndex].habits.map(\.order).max() ?? -1) + 1
                groups[groupIndex].habits.append(habit)
                groups[groupIndex].isExpanded = true
                print("         ✅ Added to group '\(groups[groupIndex].name)' with order \(habit.order)")
            }
        } else {
            habit.order = max(
                standaloneHabits.map(\.order).max() ?? -1,
                groups.map(\.order).max() ?? -1
            ) + 1
            standaloneHabits.append(habit)
            print("         ✅ Added to standalone with order \(habit.order)")
        }

        triggerHaptic(.success)
        saveData()
    }

    // Reorder flat list item from one index to another
    // destinationIndex = -1 means "before first element" (used to extract from group when group is first)
    func reorderItem(from sourceIndex: Int, to destinationIndex: Int) {
        let items = allItems
        guard sourceIndex >= 0, sourceIndex < items.count,
              destinationIndex >= -1, destinationIndex < items.count,
              sourceIndex != destinationIndex else {
            print("⚠️ REORDER GUARD FAILED: src=\(sourceIndex) dst=\(destinationIndex) count=\(items.count)")
            return
        }

        let sourceItem = items[sourceIndex]

        print("📦 REORDER: \(sourceIndex) → \(destinationIndex)")
        print("   Source: \(sourceItem.debugName)")

        // Специальный случай: destinationIndex = -1 означает "перед первым элементом"
        if destinationIndex == -1 {
            print("   Dest: [BEFORE FIRST]")

            switch sourceItem {
            case .habit(let habit, let sourceGroupId):
                if sourceGroupId != nil {
                    // Выносим из группы и ставим первым в top-level
                    print("   → extractToFirstPosition (from group)")
                    extractHabitToFirstPosition(habitId: habit.id)
                } else {
                    // Уже standalone — делаем первым
                    print("   → moveToFirstPosition (standalone)")
                    moveStandaloneToFirst(habitId: habit.id)
                }
            case .group(let group):
                // Группу делаем первой
                print("   → moveGroupToFirst")
                moveGroupToFirst(groupId: group.id)
            }
        } else {
            let destItem = items[destinationIndex]
            print("   Dest: \(destItem.debugName)")

            switch sourceItem {
            case .habit(let habit, let sourceGroupId):
                handleHabitReorder(
                    habit: habit,
                    sourceGroupId: sourceGroupId,
                    sourceIndex: sourceIndex,
                    destItem: destItem,
                    destIndex: destinationIndex
                )

            case .group(let group):
                print("   → reorderGroup")
                reorderGroup(groupId: group.id, toFlatIndex: destinationIndex)
            }
        }

        // Log final state
        print("   ✅ After reorder, allItems:")
        for (i, item) in allItems.enumerated() {
            print("      [\(i)] \(item.debugName)")
        }

        triggerHaptic(.medium)
    }

    /// Выносит habit из группы и ставит первым среди top-level
    private func extractHabitToFirstPosition(habitId: UUID) {
        print("      🔝 extractHabitToFirstPosition: habitId=\(habitId.uuidString.prefix(8))")

        // Находим и удаляем из группы
        var movedHabit: Habit?

        for (groupIndex, group) in groups.enumerated() {
            if let habitIndex = group.habits.firstIndex(where: { $0.id == habitId }) {
                movedHabit = groups[groupIndex].habits.remove(at: habitIndex)
                // Обновляем orders в группе
                for (i, _) in groups[groupIndex].habits.enumerated() {
                    groups[groupIndex].habits[i].order = i
                }
                print("         Removed from group '\(group.name)' at index \(habitIndex)")
                break
            }
        }

        guard var habit = movedHabit else {
            print("         ❌ Habit not found in any group!")
            return
        }

        // Добавляем в standalone
        standaloneHabits.append(habit)

        // Собираем top-level и ставим habit первым
        var topLevel: [(id: UUID, isGroup: Bool)] = []
        for item in allItems {
            switch item {
            case .habit(let h, let gId) where gId == nil:
                topLevel.append((h.id, false))
            case .group(let g):
                topLevel.append((g.id, true))
            default:
                break
            }
        }

        // habit уже в allItems (мы добавили в standaloneHabits)
        // Находим его и перемещаем в начало
        if let currentIdx = topLevel.firstIndex(where: { $0.id == habitId }) {
            let item = topLevel.remove(at: currentIdx)
            topLevel.insert(item, at: 0)
        }

        // Обновляем orders
        for (newOrder, item) in topLevel.enumerated() {
            if item.isGroup {
                if let idx = groups.firstIndex(where: { $0.id == item.id }) {
                    groups[idx].order = newOrder
                }
            } else {
                if let idx = standaloneHabits.firstIndex(where: { $0.id == item.id }) {
                    standaloneHabits[idx].order = newOrder
                }
            }
        }

        print("         ✅ Now first in top-level")
        saveData()
    }

    /// Перемещает standalone habit на первую позицию
    private func moveStandaloneToFirst(habitId: UUID) {
        print("      🔝 moveStandaloneToFirst: habitId=\(habitId.uuidString.prefix(8))")

        var topLevel: [(id: UUID, isGroup: Bool)] = []
        for item in allItems {
            switch item {
            case .habit(let h, let gId) where gId == nil:
                topLevel.append((h.id, false))
            case .group(let g):
                topLevel.append((g.id, true))
            default:
                break
            }
        }

        guard let currentIdx = topLevel.firstIndex(where: { $0.id == habitId }) else {
            print("         ❌ Habit not found in top-level!")
            return
        }

        if currentIdx == 0 {
            print("         ⏭️ Already first")
            return
        }

        let item = topLevel.remove(at: currentIdx)
        topLevel.insert(item, at: 0)

        // Обновляем orders
        for (newOrder, item) in topLevel.enumerated() {
            if item.isGroup {
                if let idx = groups.firstIndex(where: { $0.id == item.id }) {
                    groups[idx].order = newOrder
                }
            } else {
                if let idx = standaloneHabits.firstIndex(where: { $0.id == item.id }) {
                    standaloneHabits[idx].order = newOrder
                }
            }
        }

        print("         ✅ Now first in top-level")
        saveData()
    }

    /// Перемещает группу на первую позицию
    private func moveGroupToFirst(groupId: UUID) {
        print("      🔝 moveGroupToFirst: groupId=\(groupId.uuidString.prefix(8))")

        var topLevel: [(id: UUID, isGroup: Bool)] = []
        for item in allItems {
            switch item {
            case .habit(let h, let gId) where gId == nil:
                topLevel.append((h.id, false))
            case .group(let g):
                topLevel.append((g.id, true))
            default:
                break
            }
        }

        guard let currentIdx = topLevel.firstIndex(where: { $0.id == groupId && $0.isGroup }) else {
            print("         ❌ Group not found in top-level!")
            return
        }

        if currentIdx == 0 {
            print("         ⏭️ Already first")
            return
        }

        let item = topLevel.remove(at: currentIdx)
        topLevel.insert(item, at: 0)

        // Обновляем orders
        for (newOrder, item) in topLevel.enumerated() {
            if item.isGroup {
                if let idx = groups.firstIndex(where: { $0.id == item.id }) {
                    groups[idx].order = newOrder
                }
            } else {
                if let idx = standaloneHabits.firstIndex(where: { $0.id == item.id }) {
                    standaloneHabits[idx].order = newOrder
                }
            }
        }

        print("         ✅ Now first in top-level")
        saveData()
    }

    /// Обрабатывает все случаи перемещения habit
    private func handleHabitReorder(
        habit: Habit,
        sourceGroupId: UUID?,
        sourceIndex: Int,
        destItem: HabitItem,
        destIndex: Int
    ) {
        switch destItem {
        case .habit(_, let destGroupId):
            if sourceGroupId == destGroupId {
                // Оба в одном контейнере — reorder внутри
                print("   → reorderWithinContainer (same container)")
                reorderWithinContainer(habitId: habit.id, groupId: sourceGroupId, toFlatIndex: destIndex)
            } else {
                // Разные контейнеры — переместить
                print("   → moveHabitToPosition (different container)")
                moveHabitToPosition(habitId: habit.id, toGroupId: destGroupId, nearFlatIndex: destIndex)
            }

        case .group(let targetGroup):
            // Тащим на header группы
            // Поведение зависит от состояния группы (свернута/развернута)

            if !targetGroup.isExpanded {
                // === СВЕРНУТАЯ ГРУППА ===
                // Работаем с группой как с блоком, не заходим внутрь
                print("   [Collapsed group mode]")

                if sourceGroupId == targetGroup.id {
                    // Из этой же группы на её свернутый header — вынести перед группой
                    print("   → extractHabitBeforeGroup (from collapsed group)")
                    extractHabitBeforeGroup(habitId: habit.id, groupId: targetGroup.id)
                } else if sourceIndex < destIndex {
                    // Тащим СВЕРХУ ВНИЗ на свернутую группу → ставим ПОСЛЕ группы
                    print("   → moveHabitAfterGroup (dragging down onto collapsed group)")
                    moveHabitAfterGroup(habitId: habit.id, afterGroupId: targetGroup.id)
                } else {
                    // Тащим СНИЗУ ВВЕРХ на свернутую группу → ставим ПЕРЕД группой
                    print("   → moveHabitBeforeGroup (dragging up onto collapsed group)")
                    moveHabitBeforeGroup(habitId: habit.id, beforeGroupId: targetGroup.id)
                }

            } else {
                // === РАЗВЕРНУТАЯ ГРУППА ===
                // Работаем с содержимым группы
                print("   [Expanded group mode]")

                if sourceGroupId == targetGroup.id {
                    // Тащим на header СВОЕЙ группы = ВЫНЕСТИ из группы
                    print("   → extractHabitBeforeGroup (dragging to own expanded header = exit)")
                    extractHabitBeforeGroup(habitId: habit.id, groupId: targetGroup.id)
                } else if sourceGroupId != nil {
                    // Тащим из ДРУГОЙ группы на header этой группы — внести в эту группу
                    print("   → moveHabitToGroup (from another group into expanded)")
                    moveHabitToPosition(habitId: habit.id, toGroupId: targetGroup.id, nearFlatIndex: destIndex)
                } else {
                    // Standalone тащим на header группы — внести в группу
                    print("   → moveHabitToGroup (standalone into expanded group)")
                    moveHabitToPosition(habitId: habit.id, toGroupId: targetGroup.id, nearFlatIndex: destIndex)
                }
            }
        }
    }

    /// Перемещает habit ПОСЛЕ указанной группы (в top-level)
    private func moveHabitAfterGroup(habitId: UUID, afterGroupId: UUID) {
        print("      📍 moveHabitAfterGroup: habitId=\(habitId.uuidString.prefix(8)), afterGroupId=\(afterGroupId.uuidString.prefix(8))")

        // Удаляем habit из текущего места
        var movedHabit: Habit?
        let sourceGroupId = groupId(for: habitId)

        if let sourceGroupId = sourceGroupId {
            if let groupIndex = groups.firstIndex(where: { $0.id == sourceGroupId }),
               let habitIndex = groups[groupIndex].habits.firstIndex(where: { $0.id == habitId }) {
                movedHabit = groups[groupIndex].habits.remove(at: habitIndex)
                for (i, _) in groups[groupIndex].habits.enumerated() {
                    groups[groupIndex].habits[i].order = i
                }
                print("         Removed from group")
            }
        } else {
            if let index = standaloneHabits.firstIndex(where: { $0.id == habitId }) {
                movedHabit = standaloneHabits.remove(at: index)
                print("         Removed from standalone")
            }
        }

        guard let habit = movedHabit else {
            print("         ❌ Habit not found")
            return
        }

        // Добавляем в standalone
        standaloneHabits.append(habit)

        // Собираем top-level и находим позицию группы
        var topLevel: [(id: UUID, isGroup: Bool)] = []
        for item in allItems {
            switch item {
            case .habit(let h, let gId) where gId == nil:
                topLevel.append((h.id, false))
            case .group(let g):
                topLevel.append((g.id, true))
            default:
                break
            }
        }

        guard let groupTopIdx = topLevel.firstIndex(where: { $0.id == afterGroupId && $0.isGroup }),
              let habitTopIdx = topLevel.firstIndex(where: { $0.id == habitId && !$0.isGroup }) else {
            print("         ❌ Group or habit not in top-level")
            return
        }

        // Перемещаем habit ПОСЛЕ группы
        let item = topLevel.remove(at: habitTopIdx)
        let insertIdx: Int
        if habitTopIdx < groupTopIdx {
            // habit был до группы, после remove группа сдвинулась
            insertIdx = groupTopIdx // вставляем после группы (которая теперь на groupTopIdx - 1 + 1 = groupTopIdx)
        } else {
            // habit был после группы
            insertIdx = groupTopIdx + 1
        }
        topLevel.insert(item, at: min(insertIdx, topLevel.count))

        print("         Inserted at top-level index \(insertIdx) (after group)")

        // Обновляем orders
        for (newOrder, item) in topLevel.enumerated() {
            if item.isGroup {
                if let idx = groups.firstIndex(where: { $0.id == item.id }) {
                    groups[idx].order = newOrder
                }
            } else {
                if let idx = standaloneHabits.firstIndex(where: { $0.id == item.id }) {
                    standaloneHabits[idx].order = newOrder
                }
            }
        }

        print("         ✅ Done")
        saveData()
    }

    /// Перемещает habit ПЕРЕД указанной группой (в top-level)
    private func moveHabitBeforeGroup(habitId: UUID, beforeGroupId: UUID) {
        print("      📍 moveHabitBeforeGroup: habitId=\(habitId.uuidString.prefix(8)), beforeGroupId=\(beforeGroupId.uuidString.prefix(8))")

        // Удаляем habit из текущего места
        var movedHabit: Habit?
        let sourceGroupId = groupId(for: habitId)

        if let sourceGroupId = sourceGroupId {
            if let groupIndex = groups.firstIndex(where: { $0.id == sourceGroupId }),
               let habitIndex = groups[groupIndex].habits.firstIndex(where: { $0.id == habitId }) {
                movedHabit = groups[groupIndex].habits.remove(at: habitIndex)
                for (i, _) in groups[groupIndex].habits.enumerated() {
                    groups[groupIndex].habits[i].order = i
                }
                print("         Removed from group")
            }
        } else {
            if let index = standaloneHabits.firstIndex(where: { $0.id == habitId }) {
                movedHabit = standaloneHabits.remove(at: index)
                print("         Removed from standalone")
            }
        }

        guard let habit = movedHabit else {
            print("         ❌ Habit not found")
            return
        }

        // Добавляем в standalone
        standaloneHabits.append(habit)

        // Собираем top-level и находим позицию группы
        var topLevel: [(id: UUID, isGroup: Bool)] = []
        for item in allItems {
            switch item {
            case .habit(let h, let gId) where gId == nil:
                topLevel.append((h.id, false))
            case .group(let g):
                topLevel.append((g.id, true))
            default:
                break
            }
        }

        guard let groupTopIdx = topLevel.firstIndex(where: { $0.id == beforeGroupId && $0.isGroup }),
              let habitTopIdx = topLevel.firstIndex(where: { $0.id == habitId && !$0.isGroup }) else {
            print("         ❌ Group or habit not in top-level")
            return
        }

        // Перемещаем habit ПЕРЕД группой
        let item = topLevel.remove(at: habitTopIdx)
        let insertIdx = habitTopIdx < groupTopIdx ? groupTopIdx - 1 : groupTopIdx
        topLevel.insert(item, at: insertIdx)

        print("         Inserted at top-level index \(insertIdx) (before group)")

        // Обновляем orders
        for (newOrder, item) in topLevel.enumerated() {
            if item.isGroup {
                if let idx = groups.firstIndex(where: { $0.id == item.id }) {
                    groups[idx].order = newOrder
                }
            } else {
                if let idx = standaloneHabits.firstIndex(where: { $0.id == item.id }) {
                    standaloneHabits[idx].order = newOrder
                }
            }
        }

        print("         ✅ Done")
        saveData()
    }

    /// Проверяет, является ли habit первым в своей группе
    private func isFirstInGroup(habitId: UUID, groupId: UUID) -> Bool {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupId }) else {
            return false
        }
        let sortedHabits = groups[groupIndex].habits.sorted { $0.order < $1.order }
        return sortedHabits.first?.id == habitId
    }

    /// Выносит habit из группы и ставит его ПЕРЕД этой группой
    private func extractHabitBeforeGroup(habitId: UUID, groupId: UUID) {
        print("      🚪 extractHabitBeforeGroup: habitId=\(habitId.uuidString.prefix(8)), groupId=\(groupId.uuidString.prefix(8))")

        guard let groupIndex = groups.firstIndex(where: { $0.id == groupId }),
              let habitIndex = groups[groupIndex].habits.firstIndex(where: { $0.id == habitId }) else {
            print("         ❌ Not found")
            return
        }

        // Удаляем из группы
        var habit = groups[groupIndex].habits.remove(at: habitIndex)

        // Обновляем orders в группе
        for (i, _) in groups[groupIndex].habits.enumerated() {
            groups[groupIndex].habits[i].order = i
        }

        print("         Removed from group '\(groups[groupIndex].name)'")

        // Добавляем в standalone
        standaloneHabits.append(habit)

        // Собираем top-level в текущем порядке
        var topLevel: [(id: UUID, isGroup: Bool)] = []
        for item in allItems {
            switch item {
            case .habit(let h, let gId) where gId == nil:
                topLevel.append((h.id, false))
            case .group(let g):
                topLevel.append((g.id, true))
            default:
                break
            }
        }

        // Находим позицию группы в top-level
        guard let groupTopIdx = topLevel.firstIndex(where: { $0.id == groupId && $0.isGroup }) else {
            print("         ❌ Group not in top-level")
            return
        }

        // Находим где сейчас habit в top-level (он был добавлен в конец)
        guard let habitTopIdx = topLevel.firstIndex(where: { $0.id == habitId && !$0.isGroup }) else {
            print("         ❌ Habit not in top-level")
            return
        }

        // Перемещаем habit ПЕРЕД группой
        let item = topLevel.remove(at: habitTopIdx)
        // После remove индексы могли сдвинуться
        let insertIdx = habitTopIdx < groupTopIdx ? groupTopIdx - 1 : groupTopIdx
        topLevel.insert(item, at: insertIdx)

        print("         Inserted at top-level index \(insertIdx) (before group at \(groupTopIdx))")

        // Обновляем orders
        for (newOrder, item) in topLevel.enumerated() {
            if item.isGroup {
                if let idx = groups.firstIndex(where: { $0.id == item.id }) {
                    groups[idx].order = newOrder
                }
            } else {
                if let idx = standaloneHabits.firstIndex(where: { $0.id == item.id }) {
                    standaloneHabits[idx].order = newOrder
                }
            }
        }

        print("         ✅ Done. New top-level order: \(topLevel.map { $0.id.uuidString.prefix(4) })")
        saveData()
    }

    /// Делает habit первым в его группе
    private func makeFirstInGroup(habitId: UUID, groupId: UUID) {
        print("      🥇 makeFirstInGroup: habitId=\(habitId.uuidString.prefix(8)), groupId=\(groupId.uuidString.prefix(8))")

        guard let groupIndex = groups.firstIndex(where: { $0.id == groupId }),
              let fromIndex = groups[groupIndex].habits.firstIndex(where: { $0.id == habitId }) else {
            print("         ❌ Not found")
            return
        }

        if fromIndex == 0 {
            print("         ⏭️ Already first")
            return
        }

        let habit = groups[groupIndex].habits.remove(at: fromIndex)
        groups[groupIndex].habits.insert(habit, at: 0)

        // Update orders
        for (i, _) in groups[groupIndex].habits.enumerated() {
            groups[groupIndex].habits[i].order = i
        }

        print("         ✅ Done. New order: \(groups[groupIndex].habits.map { $0.name })")
        saveData()
    }

    /// Перемещает habit в указанную группу (или standalone) на позицию около destFlatIndex
    private func moveHabitToPosition(habitId: UUID, toGroupId: UUID?, nearFlatIndex: Int) {
        print("      🚚 moveHabitToPosition: habitId=\(habitId.uuidString.prefix(8)) → group=\(String(describing: toGroupId?.uuidString.prefix(8))), nearFlatIndex=\(nearFlatIndex)")

        let sourceGroupId = groupId(for: habitId)

        // Находим и удаляем из источника
        var movedHabit: Habit?

        if let sourceGroupId = sourceGroupId {
            if let groupIndex = groups.firstIndex(where: { $0.id == sourceGroupId }),
               let habitIndex = groups[groupIndex].habits.firstIndex(where: { $0.id == habitId }) {
                movedHabit = groups[groupIndex].habits.remove(at: habitIndex)
                // Обновляем orders в исходной группе
                for (i, _) in groups[groupIndex].habits.enumerated() {
                    groups[groupIndex].habits[i].order = i
                }
                print("         Removed from group at index \(habitIndex)")
            }
        } else {
            if let index = standaloneHabits.firstIndex(where: { $0.id == habitId }) {
                movedHabit = standaloneHabits.remove(at: index)
                print("         Removed from standalone at index \(index)")
            }
        }

        guard var habit = movedHabit else {
            print("         ❌ Habit not found!")
            return
        }

        // Добавляем в целевой контейнер
        if let toGroupId = toGroupId {
            // Добавляем в группу
            guard let groupIndex = groups.firstIndex(where: { $0.id == toGroupId }) else {
                print("         ❌ Target group not found!")
                return
            }

            // Определяем позицию внутри группы
            // nearFlatIndex указывает на элемент в плоском списке
            // Нужно найти позицию внутри группы

            let flatItems = allItems
            var insertPosition = 0

            if nearFlatIndex < flatItems.count {
                let nearItem = flatItems[nearFlatIndex]
                if case .group(let g) = nearItem, g.id == toGroupId {
                    // Тащим на header группы — вставляем первым
                    insertPosition = 0
                } else if case .habit(let h, let gId) = nearItem, gId == toGroupId {
                    // Тащим на habit внутри этой группы — вставляем на его позицию
                    if let pos = groups[groupIndex].habits.firstIndex(where: { $0.id == h.id }) {
                        insertPosition = pos
                    }
                }
            }

            insertPosition = min(insertPosition, groups[groupIndex].habits.count)
            habit.order = insertPosition
            groups[groupIndex].habits.insert(habit, at: insertPosition)
            groups[groupIndex].isExpanded = true

            // Обновляем orders
            for (i, _) in groups[groupIndex].habits.enumerated() {
                groups[groupIndex].habits[i].order = i
            }

            print("         ✅ Added to group '\(groups[groupIndex].name)' at position \(insertPosition)")

        } else {
            // Добавляем в standalone
            // Нужно определить позицию среди top-level элементов

            // Собираем top-level в текущем порядке
            var topLevel: [(id: UUID, isGroup: Bool)] = []
            for item in allItems {
                switch item {
                case .habit(let h, let gId) where gId == nil:
                    topLevel.append((h.id, false))
                case .group(let g):
                    topLevel.append((g.id, true))
                default:
                    break
                }
            }

            // Находим куда вставить
            var insertTopIdx = topLevel.count // по умолчанию в конец

            let flatItems = allItems
            if nearFlatIndex < flatItems.count {
                let nearItem = flatItems[nearFlatIndex]
                switch nearItem {
                case .habit(let h, let gId) where gId == nil:
                    if let idx = topLevel.firstIndex(where: { $0.id == h.id }) {
                        insertTopIdx = idx
                    }
                case .group(let g):
                    if let idx = topLevel.firstIndex(where: { $0.id == g.id }) {
                        insertTopIdx = idx
                    }
                case .habit(_, let gId) where gId != nil:
                    // Тащим на habit внутри группы — используем позицию группы
                    if let gId = gId, let idx = topLevel.firstIndex(where: { $0.id == gId }) {
                        insertTopIdx = idx
                    }
                default:
                    break
                }
            }

            // Вставляем habit и обновляем все orders
            standaloneHabits.append(habit)

            // Пересчитываем orders для всех top-level
            var newTopLevel = topLevel
            newTopLevel.insert((habit.id, false), at: min(insertTopIdx, newTopLevel.count))

            for (newOrder, item) in newTopLevel.enumerated() {
                if item.isGroup {
                    if let idx = groups.firstIndex(where: { $0.id == item.id }) {
                        groups[idx].order = newOrder
                    }
                } else {
                    if let idx = standaloneHabits.firstIndex(where: { $0.id == item.id }) {
                        standaloneHabits[idx].order = newOrder
                    }
                }
            }

            print("         ✅ Added to standalone at top-level position \(insertTopIdx)")
        }

        saveData()
    }

    private func reorderWithinContainer(habitId: UUID, groupId: UUID?, toFlatIndex: Int) {
        print("      🔄 reorderWithinContainer: habitId=\(habitId.uuidString.prefix(8)), groupId=\(String(describing: groupId?.uuidString.prefix(8))), toFlatIndex=\(toFlatIndex)")

        if let groupId = groupId {
            // Reorder within group
            guard let groupIndex = groups.firstIndex(where: { $0.id == groupId }),
                  let fromLocalIndex = groups[groupIndex].habits.firstIndex(where: { $0.id == habitId }) else {
                print("         ❌ Group or habit not found")
                return
            }

            let habitsCount = groups[groupIndex].habits.count
            print("         Group[\(groupIndex)] '\(groups[groupIndex].name)', fromLocalIndex=\(fromLocalIndex), habitsCount=\(habitsCount)")

            // Найдем где начинается группа в плоском списке
            let flatItems = allItems
            var groupHeaderFlatIndex = 0
            for (i, item) in flatItems.enumerated() {
                if case .group(let g) = item, g.id == groupId {
                    groupHeaderFlatIndex = i
                    break
                }
            }
            let habitsStartFlatIndex = groupHeaderFlatIndex + 1

            // toFlatIndex - индекс в плоском списке, конвертируем в локальный индекс группы
            let toLocalIndex = toFlatIndex - habitsStartFlatIndex
            let clampedToLocal = max(0, min(habitsCount - 1, toLocalIndex))

            print("         groupHeaderFlatIndex=\(groupHeaderFlatIndex), habitsStartFlatIndex=\(habitsStartFlatIndex)")
            print("         toLocalIndex=\(toLocalIndex), clampedToLocal=\(clampedToLocal)")

            if fromLocalIndex == clampedToLocal {
                print("         ⏭️ Same position, skipping")
                return
            }

            // Правильное перемещение в массиве:
            // 1. Убираем элемент с fromLocalIndex
            // 2. Вставляем на clampedToLocal, но учитывая сдвиг после remove
            let habit = groups[groupIndex].habits.remove(at: fromLocalIndex)

            // После remove индексы >= fromLocalIndex сдвигаются на -1
            // Если toLocal > fromLocal, нужно скорректировать
            var insertAt = clampedToLocal
            if clampedToLocal > fromLocalIndex {
                // Элементы между from и to сдвинулись вверх,
                // поэтому вставляем на clampedToLocal (без -1, т.к. мы хотим ПОСЛЕ элемента который был на to)
                insertAt = clampedToLocal
            }
            insertAt = min(insertAt, groups[groupIndex].habits.count)

            print("         Moving: remove at \(fromLocalIndex), insert at \(insertAt)")
            groups[groupIndex].habits.insert(habit, at: insertAt)

            // Update orders
            for (i, _) in groups[groupIndex].habits.enumerated() {
                groups[groupIndex].habits[i].order = i
            }
            print("         ✅ Done. New order: \(groups[groupIndex].habits.map { $0.name })")

        } else {
            // Reorder standalone habits among other top-level items
            guard let fromIdx = standaloneHabits.firstIndex(where: { $0.id == habitId }) else {
                print("         ❌ Standalone habit not found")
                return
            }

            print("         Standalone habit fromIdx=\(fromIdx)")

            // Собираем все top-level элементы в порядке отображения
            var topLevel: [(id: UUID, isGroup: Bool)] = []
            for item in allItems {
                switch item {
                case .habit(let h, let gId) where gId == nil:
                    topLevel.append((h.id, false))
                case .group(let g):
                    topLevel.append((g.id, true))
                default:
                    break // skip habits in groups
                }
            }

            guard let fromTopIdx = topLevel.firstIndex(where: { $0.id == habitId }) else {
                print("         ❌ Habit not in top-level")
                return
            }

            // toFlatIndex может указывать на:
            // - другой standalone habit
            // - group header
            // Нужно найти ближайший top-level элемент
            let flatItems = allItems
            var toTopIdx = fromTopIdx

            if toFlatIndex < flatItems.count {
                let targetItem = flatItems[toFlatIndex]
                switch targetItem {
                case .habit(let h, let gId) where gId == nil:
                    if let idx = topLevel.firstIndex(where: { $0.id == h.id }) {
                        toTopIdx = idx
                    }
                case .group(let g):
                    if let idx = topLevel.firstIndex(where: { $0.id == g.id }) {
                        toTopIdx = idx
                    }
                case .habit(_, let gId) where gId != nil:
                    // Тащим на habit внутри группы — найдем group header
                    if let gId = gId, let idx = topLevel.firstIndex(where: { $0.id == gId }) {
                        toTopIdx = idx
                    }
                default:
                    break
                }
            }

            print("         topLevel count=\(topLevel.count), fromTopIdx=\(fromTopIdx), toTopIdx=\(toTopIdx)")

            if fromTopIdx == toTopIdx {
                print("         ⏭️ Same position, skipping")
                return
            }

            // Обновляем orders всех top-level элементов
            var newTopLevel = topLevel
            let item = newTopLevel.remove(at: fromTopIdx)
            let insertAt = toTopIdx > fromTopIdx ? toTopIdx : toTopIdx
            newTopLevel.insert(item, at: min(insertAt, newTopLevel.count))

            // Применяем новые orders
            for (newOrder, item) in newTopLevel.enumerated() {
                if item.isGroup {
                    if let idx = groups.firstIndex(where: { $0.id == item.id }) {
                        groups[idx].order = newOrder
                    }
                } else {
                    if let idx = standaloneHabits.firstIndex(where: { $0.id == item.id }) {
                        standaloneHabits[idx].order = newOrder
                    }
                }
            }
            print("         ✅ Done standalone reorder")
        }
        saveData()
    }

    private func reorderGroup(groupId: UUID, toFlatIndex: Int) {
        print("      🔄 reorderGroup: groupId=\(groupId.uuidString.prefix(8)), toFlatIndex=\(toFlatIndex)")

        // Собираем все top-level элементы в порядке отображения
        var topLevel: [(id: UUID, isGroup: Bool)] = []
        for item in allItems {
            switch item {
            case .habit(let h, let gId) where gId == nil:
                topLevel.append((h.id, false))
            case .group(let g):
                topLevel.append((g.id, true))
            default:
                break // skip habits in groups
            }
        }

        guard let fromTopIdx = topLevel.firstIndex(where: { $0.id == groupId && $0.isGroup }) else {
            print("         ❌ Group not found in top-level")
            return
        }

        // Находим target top-level index из flat index
        let flatItems = allItems
        var toTopIdx = fromTopIdx

        if toFlatIndex < flatItems.count {
            let targetItem = flatItems[toFlatIndex]
            switch targetItem {
            case .habit(let h, let gId) where gId == nil:
                if let idx = topLevel.firstIndex(where: { $0.id == h.id }) {
                    toTopIdx = idx
                }
            case .group(let g):
                if let idx = topLevel.firstIndex(where: { $0.id == g.id }) {
                    toTopIdx = idx
                }
            case .habit(_, let gId) where gId != nil:
                // Target is habit inside a group — use that group's position
                if let gId = gId, let idx = topLevel.firstIndex(where: { $0.id == gId }) {
                    toTopIdx = idx
                }
            default:
                break
            }
        }

        print("         topLevel count=\(topLevel.count), fromTopIdx=\(fromTopIdx), toTopIdx=\(toTopIdx)")

        if fromTopIdx == toTopIdx {
            print("         ⏭️ Same position, skipping")
            return
        }

        // Перемещаем
        var newTopLevel = topLevel
        let item = newTopLevel.remove(at: fromTopIdx)
        let insertAt = toTopIdx > fromTopIdx ? toTopIdx : toTopIdx
        newTopLevel.insert(item, at: min(insertAt, newTopLevel.count))

        // Применяем новые orders
        for (newOrder, item) in newTopLevel.enumerated() {
            if item.isGroup {
                if let idx = groups.firstIndex(where: { $0.id == item.id }) {
                    groups[idx].order = newOrder
                }
            } else {
                if let idx = standaloneHabits.firstIndex(where: { $0.id == item.id }) {
                    standaloneHabits[idx].order = newOrder
                }
            }
        }
        print("         ✅ Done group reorder")
        saveData()
    }

    // Legacy methods for compatibility
    func moveHabitInGroup(groupId: UUID, from source: IndexSet, to destination: Int) {
        if let groupIndex = groups.firstIndex(where: { $0.id == groupId }) {
            groups[groupIndex].habits.move(fromOffsets: source, toOffset: destination)
            for (index, _) in groups[groupIndex].habits.enumerated() {
                groups[groupIndex].habits[index].order = index
            }
            saveData()
        }
    }

    // MARK: - Menu-based reordering (native-iOS migration)
    //
    // Clean POSITIONAL move used by the row context menu. Unlike reorderItem
    // (which has drag-onto-target semantics and is now unused), these swap with
    // the immediately adjacent sibling / top-level item — predictable for the
    // Up / Down menu actions. A top-level item moves among top-level items; a
    // grouped habit moves among its siblings only (cross-container moves are the
    // separate "Вынести из группы" / "В группу…" actions via moveHabit).
    // See docs/knowledge/fact-habit-tracker.md::Native-iOS жесты.

    private func topLevelOrdered() -> [(id: UUID, isGroup: Bool)] {
        var combined: [(order: Int, id: UUID, isGroup: Bool)] = []
        for h in standaloneHabits { combined.append((h.order, h.id, false)) }
        for g in groups { combined.append((g.order, g.id, true)) }
        combined.sort { $0.order < $1.order }
        return combined.map { ($0.id, $0.isGroup) }
    }

    private func applyTopLevel(_ order: [(id: UUID, isGroup: Bool)]) {
        for (newOrder, it) in order.enumerated() {
            if it.isGroup {
                if let idx = groups.firstIndex(where: { $0.id == it.id }) { groups[idx].order = newOrder }
            } else {
                if let idx = standaloneHabits.firstIndex(where: { $0.id == it.id }) { standaloneHabits[idx].order = newOrder }
            }
        }
    }

    /// (index, count) of an item within its container (top-level, or its group).
    private func neighborIndex(_ item: HabitItem) -> (index: Int, count: Int) {
        switch item {
        case .group(let g):
            let order = topLevelOrdered()
            return (order.firstIndex(where: { $0.id == g.id && $0.isGroup }) ?? -1, order.count)
        case .habit(let h, let gid):
            if let gid = gid, let gi = groups.firstIndex(where: { $0.id == gid }) {
                let sorted = groups[gi].habits.sorted { $0.order < $1.order }
                return (sorted.firstIndex(where: { $0.id == h.id }) ?? -1, sorted.count)
            } else {
                let order = topLevelOrdered()
                return (order.firstIndex(where: { $0.id == h.id && !$0.isGroup }) ?? -1, order.count)
            }
        }
    }

    func canMoveUp(_ item: HabitItem) -> Bool { neighborIndex(item).index > 0 }
    func canMoveDown(_ item: HabitItem) -> Bool {
        let n = neighborIndex(item)
        return n.index >= 0 && n.index < n.count - 1
    }

    func moveUp(_ item: HabitItem) { swapItem(item, up: true) }
    func moveDown(_ item: HabitItem) { swapItem(item, up: false) }

    private func swapItem(_ item: HabitItem, up: Bool) {
        switch item {
        case .group(let g):
            swapTopLevel(id: g.id, isGroup: true, up: up)
        case .habit(let h, let gid):
            if let gid = gid {
                swapSibling(habitId: h.id, groupId: gid, up: up)
            } else {
                swapTopLevel(id: h.id, isGroup: false, up: up)
            }
        }
    }

    private func swapTopLevel(id: UUID, isGroup: Bool, up: Bool) {
        var order = topLevelOrdered()
        guard let i = order.firstIndex(where: { $0.id == id && $0.isGroup == isGroup }) else { return }
        let j = up ? i - 1 : i + 1
        guard j >= 0, j < order.count else { return }
        order.swapAt(i, j)
        applyTopLevel(order)
        triggerHaptic(.light)
        saveData()
    }

    private func swapSibling(habitId: UUID, groupId: UUID, up: Bool) {
        guard let gi = groups.firstIndex(where: { $0.id == groupId }) else { return }
        var sorted = groups[gi].habits.sorted { $0.order < $1.order }
        guard let i = sorted.firstIndex(where: { $0.id == habitId }) else { return }
        let j = up ? i - 1 : i + 1
        guard j >= 0, j < sorted.count else { return }
        sorted.swapAt(i, j)
        for k in sorted.indices { sorted[k].order = k }
        groups[gi].habits = sorted
        triggerHaptic(.light)
        saveData()
    }

    // MARK: - Persistence

    // Serial queue for off-main persistence. Every habit toggle / expand calls
    // saveData; doing the App-Group write + WidgetCenter.reloadAllTimelines()
    // (documented-expensive) + the deprecated blocking synchronize() on the MAIN
    // thread froze it for ~0.1–0.3s per tap — the on-device "dead period" where
    // the next row wouldn't respond until the freeze cleared. See
    // docs/knowledge/fact-habit-tracker.md::Мёртвый период.
    private static let persistQueue = DispatchQueue(label: "habittracker.persist", qos: .utility)

    func saveData() {
        // EVERYTHING off-main. The @Published arrays are already mutated (that's
        // what drives the UI); saveData only persists. Capturing the StorageData
        // on main is a cheap copy-on-write snapshot — the expensive part is
        // JSONEncoder().encode of the full history (185 entries × hundreds of
        // days = tens of thousands of dict entries → ~100–300ms). That encode
        // used to run on MAIN right after a reorder drop, blocking the thread
        // exactly when the user tried to pick up the next row → the reorder-mode
        // "dead period" (highlight appears via the system Button, but the native
        // List can't re-arm its drag until main is free). Now encode + both
        // UserDefaults writes + the widget reload all run on persistQueue, so the
        // main thread is free the instant the drop finishes. See
        // docs/knowledge/fact-habit-tracker.md::Мёртвый период.
        let snapshot = StorageData(
            standaloneHabits: standaloneHabits,
            groups: groups,
            firstDayOfWeek: firstDayOfWeek
        )
        let key = storageKey
        let group = appGroupIdentifier
        Self.persistQueue.async {
            guard let encoded = try? JSONEncoder().encode(snapshot) else { return }
            UserDefaults.standard.set(encoded, forKey: key)
            UserDefaults(suiteName: group)?.set(encoded, forKey: key)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private func loadData() {
        // Try to load from App Group first (if migrated/newer), then fallback to standard
        var loadedData: Data?
        
        if let sharedDefaults = UserDefaults(suiteName: appGroupIdentifier),
           let data = sharedDefaults.data(forKey: storageKey) {
            loadedData = data
        } else {
            loadedData = UserDefaults.standard.data(forKey: storageKey)
        }

        if let data = loadedData,
           let decoded = try? JSONDecoder().decode(StorageData.self, from: data) {
            standaloneHabits = decoded.standaloneHabits
            groups = decoded.groups
            firstDayOfWeek = decoded.firstDayOfWeek
        }
    }

    // MARK: - Sample Data

    private func addSampleData() {
        standaloneHabits = [
            Habit(name: "Зарядка", colorName: .blue, order: 0),
            Habit(name: "Чтение", colorName: .orange, order: 1)
        ]

        let morningHabits = [
            Habit(name: "Медитация", colorName: .teal, order: 0),
            Habit(name: "Холодный душ", colorName: .cyan, order: 1),
            Habit(name: "Здоровый завтрак", colorName: .green, order: 2)
        ]

        groups = [
            HabitGroup(
                name: "Утро",
                colorName: .teal,
                isExpanded: true,
                habits: morningHabits,
                order: 2
            )
        ]
    }

    // MARK: - Haptics

    private func triggerHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred()
    }

    private func triggerHaptic(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(type)
    }
}

// MARK: - Storage Data
struct StorageData: Codable {
    let standaloneHabits: [Habit]
    let groups: [HabitGroup]
    let firstDayOfWeek: FirstDayOfWeek
}
