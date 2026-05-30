import SwiftUI

struct DaysHeaderView: View {
    @EnvironmentObject var store: HabitStore
    @Binding var weekOffset: Int
    @State private var showCalendar = false

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            // Date label - tap opens calendar
            Text(DateHelper.compactWeekLabel(weekOffset: weekOffset, firstDayOfWeek: store.firstDayOfWeek))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 140, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    showCalendar = true
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }

            // Days row
            HStack(spacing: 0) {
                let days = DateHelper.weekDates(weekOffset: weekOffset, firstDayOfWeek: store.firstDayOfWeek)
                ForEach(days) { day in
                    dayColumn(day: day)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 60)
        .background(Color(hex: "1C1C1E"))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(hex: "2C2C2E"))
                .frame(height: 1)
        }
        .gesture(
            DragGesture()
                .onEnded { value in
                    let threshold: CGFloat = 50
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        if value.translation.width > threshold {
                            weekOffset -= 1
                        } else if value.translation.width < -threshold {
                            weekOffset += 1
                        }
                    }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
        )
        .sheet(isPresented: $showCalendar) {
            CalendarSheet()
        }
    }

    // MARK: - Day Column

    private func dayColumn(day: WeekDay) -> some View {
        VStack(spacing: 4) {
            Text(day.label)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "8E8E93"))

            ZStack {
                if day.isToday {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 28, height: 28)
                }

                Text("\(day.dayNumber)")
                    .font(.system(size: 15, weight: day.isToday ? .bold : .medium))
                    .foregroundColor(.white)
            }
            .frame(width: 28, height: 28) // Фиксируем размер ZStack
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    VStack {
        DaysHeaderView(weekOffset: .constant(0))
        Spacer()
    }
    .background(Color(hex: "1C1C1E"))
    .environmentObject(HabitStore())
}
