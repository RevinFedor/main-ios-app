import SwiftUI

struct GroupRowView: View {
    @EnvironmentObject var store: HabitStore
    let group: HabitGroup
    // Precomputed once by the parent and passed in — see HabitRowView /
    // docs/knowledge/fact-habit-tracker.md. Recomputing weekDates() in every
    // row body each drag frame was part of the per-frame cost that made drag stiff.
    let days: [WeekDay]
    var isHighlighted: Bool = false

    var body: some View {
        // Pure visual row. Tap (anywhere) → expand, press → edit,
        // drag → reorder are all owned by the parent (ContentView).
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                Image(systemName: group.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(hex: "6E6E73"))
                    .frame(width: 20)

                HStack(spacing: 6) {
                    Text(group.name)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Text("\(group.habits.count)")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "8E8E93"))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color(hex: "3A3A3C")))
                }

                Spacer(minLength: 0)
            }
            .frame(width: 140, alignment: .leading)
            .frame(maxHeight: .infinity)

            // Progress circles (visual only)
            progressRow
        }
        .padding(.horizontal, 12)
        .background(rowBackground)
        .overlay(alignment: .top) {
            Rectangle().fill(Color(hex: "2C2C2E")).frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(hex: "2C2C2E")).frame(height: 1)
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        ZStack {
            Color.white.opacity(0.03)
            if isHighlighted {
                Color.white.opacity(0.07)
            }
        }
    }

    // MARK: - Progress Row

    private var progressRow: some View {
        HStack(spacing: 0) {
            ForEach(days) { day in
                CircleProgressView(
                    progress: group.progress(for: day.key),
                    color: group.color
                )
                .frame(maxWidth: .infinity)
                .frame(height: 44)
            }
        }
        .animation(nil, value: group.id) // Отключаем анимацию при reorder
    }
}

// MARK: - Circle Progress View

struct CircleProgressView: View {
    let progress: Double
    let color: Color
    var size: CGFloat = 22

    var body: some View {
        if progress >= 1.0 {
            // 100% complete - filled circle with checkmark
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: size, height: size)

                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
            }
        } else {
            // Partial progress - ring
            ZStack {
                Circle()
                    .stroke(Color(hex: "3A3A3C"), lineWidth: 2.5)
                    .frame(width: size, height: size)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(-90))
            }
        }
    }
}

#Preview {
    let days = DateHelper.weekDates(weekOffset: 0, firstDayOfWeek: .monday)
    return VStack(spacing: 0) {
        GroupRowView(
            group: HabitGroup(
                name: "Утро",
                colorName: .teal,
                isExpanded: true,
                habits: [
                    Habit(name: "Медитация", colorName: .teal),
                    Habit(name: "Душ", colorName: .cyan)
                ]
            ),
            days: days
        )

        GroupRowView(
            group: HabitGroup(
                name: "Вечер",
                colorName: .purple,
                isExpanded: false,
                habits: [Habit(name: "Книга", colorName: .purple)]
            ),
            days: days
        )
    }
    .background(Color(hex: "1C1C1E"))
    .environmentObject(HabitStore())
}
