import SwiftUI

struct HabitRowView: View {
    @EnvironmentObject var store: HabitStore
    let habit: Habit
    let groupId: UUID?
    // Precomputed by the parent ONCE per frame and passed in — see
    // docs/knowledge/fact-habit-tracker.md. Recomputing weekDates() inside every
    // row body each drag frame was part of the per-frame cost that made the
    // drag stiff.
    let days: [WeekDay]
    var isChild: Bool = false
    var isLastChild: Bool = false
    var isHighlighted: Bool = false

    var body: some View {
        // Pure visual row. ALL gestures (tap-to-toggle, press-to-edit,
        // drag-to-reorder) are owned by the parent in ContentView and routed
        // by X-location — see docs/knowledge/fact-habit-tracker.md. No Button,
        // no .onTapGesture here: a Button nested under the row's long-press
        // gesture is exactly what caused the "first tap only highlights" bug.
        HStack(spacing: 0) {
            // Left block: connector + name. Width MUST match
            // ContentView.leftZoneWidth (140) so the tap router splits zones
            // correctly.
            HStack(spacing: 0) {
                if isChild {
                    Text(isLastChild ? "└" : "├")
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: "6E6E73"))
                        .frame(width: 20)
                }

                Text(habit.name)
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .frame(width: 140, alignment: .leading)
            .frame(maxHeight: .infinity)

            // Checkmarks row (visual only)
            checkmarksRow
        }
        .padding(.horizontal, 12)
        .background(rowBackground)
        .overlay(alignment: .top) {
            // Top + bottom borders belong to THIS row so they travel with it
            // during drag — a single shared divider would leave gaps as
            // neighbours offset.
            Rectangle().fill(Color(hex: "2C2C2E")).frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(hex: "2C2C2E")).frame(height: 1)
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        let base: Color = isChild ? Color.black.opacity(0.18) : Color.clear
        ZStack {
            base
            if isHighlighted {
                Color.white.opacity(0.07)
            }
        }
    }

    // MARK: - Checkmarks Row

    private var checkmarksRow: some View {
        HStack(spacing: 0) {
            ForEach(days) { day in
                statusIcon(for: day.key)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
        }
        // Strip ALL inherited animation from this subtree. During reorder the
        // parent row animates its .offset (make-room spring), and that
        // transaction would otherwise leak into the checkmarks — and because
        // every row's days share identical ids (Monday==Monday across rows),
        // SwiftUI tried to "move" a checkmark vertically between rows, so the
        // icons slid in from the top/bottom on drop. .transaction nil makes the
        // checkmarks teleport with their row instead of animating independently.
        // (A plain .animation(nil, value:) only catches that one value, not the
        // inherited transaction — see docs/knowledge/fact-habit-tracker.md.)
        .transaction { $0.animation = nil }
    }

    // MARK: - Status Icon

    @ViewBuilder
    private func statusIcon(for dateKey: String) -> some View {
        let status = habit.history[dateKey]

        if status == .done {
            Image(systemName: "checkmark")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(habit.color)
        } else {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(Color(hex: "6E6E73"))
        }
    }
}

#Preview {
    let days = DateHelper.weekDates(weekOffset: 0, firstDayOfWeek: .monday)
    return VStack(spacing: 0) {
        HabitRowView(
            habit: Habit(name: "Зарядка", colorName: .blue),
            groupId: nil,
            days: days
        )

        HabitRowView(
            habit: Habit(name: "Медитация", colorName: .teal),
            groupId: UUID(),
            days: days,
            isChild: true,
            isLastChild: false
        )

        HabitRowView(
            habit: Habit(name: "Душ", colorName: .cyan),
            groupId: UUID(),
            days: days,
            isChild: true,
            isLastChild: true
        )
    }
    .background(Color(hex: "1C1C1E"))
    .environmentObject(HabitStore())
}
