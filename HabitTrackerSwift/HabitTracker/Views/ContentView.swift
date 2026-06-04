import SwiftUI

// MARK: - Selected Habit Wrapper (for .sheet)
struct SelectedHabitItem: Identifiable {
    let id = UUID()
    let habit: Habit
    let groupId: UUID?
}

// MARK: - Content View
struct ContentView: View {
    @EnvironmentObject var store: HabitStore
    @State private var weekOffset: Int = 0
    @State private var showAddSheet = false
    @State private var showSettingsSheet = false
    @State private var selectedHabit: SelectedHabitItem? = nil
    @State private var selectedGroup: HabitGroup? = nil

    // Reorder mode. A SEPARATE mode removes the impossible "long-press is BOTH
    // edit AND drag" conflict that broke every hand-rolled attempt. Layout is
    // identical to normal (days header + checkmarks stay) — only interactivity
    // changes: normal mode uses tap + long-press-to-edit; reorder mode uses the
    // NATIVE List drag-to-reorder (whole row lifts, neighbours move live), with
    // no edit grips. See docs/knowledge/fact-habit-tracker.md.
    @State private var isReordering = false

    // Live count of lines in the shared debug log — shown next to the navbar
    // copy icon (mirrors the Voice tab). Refreshed on appear + once a second.
    @State private var logLineCount: Int = 0
    private let logCountTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // Layout constants — shared between row rendering and the location-aware
    // tap router. Keep in sync with HabitRowView/GroupRowView (.padding 12,
    // left block .frame(width: 140)).
    private let rowHeight: CGFloat = 52
    private let hPadding: CGFloat = 12
    private let leftZoneWidth: CGFloat = 140

    init() {
        // INSTANT touch-down feedback. By default a UIScrollView holds the touch
        // ~150ms to decide "is this a scroll?", which delays press feedback.
        // Buttons feel instant precisely because the system bypasses that wait —
        // this makes our rows behave the same. App-wide + idempotent; scrolling
        // still works (the pan recogniser takes over on movement and cancels the
        // content touch). See docs/knowledge/fact-habit-tracker.md.
        UIScrollView.appearance().delaysContentTouches = false
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "1C1C1E")
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // Days header ALWAYS shown — keeping it in reorder mode means
                    // the list doesn't shift (user requirement).
                    DaysHeaderView(weekOffset: $weekOffset)

                    if store.standaloneHabits.isEmpty && store.groups.isEmpty {
                        emptyState
                    } else if isReordering {
                        reorderList
                    } else {
                        normalList
                    }
                }

                // Floating buttons (bottom-right): reorder toggle stacked above
                // the add button. In reorder mode the toggle becomes "Done"; the
                // add button stays VISIBLE but disabled (dimmed).
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            reorderToggleButton
                            addButton
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Button {
                        withAnimation { weekOffset = 0 }
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    } label: {
                        Text("Home")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.white)
                    }
                }

                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showSettingsSheet = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .foregroundColor(.white)
                    }
                    .disabled(isReordering)
                }

                // Quick log access — copy recent buffer / clear it without
                // leaving the screen. Full viewer lives in Settings → Диагностика.
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        UIPasteboard.general.string = VRLog.readRecent(maxLines: 400)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        logLineCount = VRLog.lineCount()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "doc.on.doc")
                            Text("\(logLineCount)")
                                .font(.caption.monospacedDigit())
                        }
                        .foregroundColor(.white)
                    }
                    .accessibilityLabel("Скопировать лог, \(logLineCount) строк")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        VRLog.clear()
                        UINotificationFeedbackGenerator().notificationOccurred(.warning)
                        logLineCount = 0
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                    .accessibilityLabel("Очистить лог")
                }
            }
            .onReceive(logCountTimer) { _ in
                let n = VRLog.lineCount()
                if n != logLineCount { logLineCount = n }
            }
            .task { logLineCount = VRLog.lineCount() }
            .sheet(isPresented: $showAddSheet) { AddHabitSheet() }
            .sheet(isPresented: $showSettingsSheet) { SettingsSheet() }
            .sheet(item: $selectedHabit) { selected in
                EditHabitSheet(habit: selected.habit, groupId: selected.groupId)
            }
            .sheet(item: $selectedGroup) { group in
                EditGroupSheet(group: group)
            }
        }
    }

    // MARK: - Normal List (tap + long-press-to-edit, NO drag)
    //
    // Each row is the NormalRow subview, which owns its press highlight in LOCAL
    // @State. This is the fix for both "long-press feels ~1s / flaky" and "dead
    // period after release": the OLD code drove the highlight from a @State on
    // THIS parent, so every touch-down re-rendered the whole LazyVStack, which
    // tore down & rebuilt every row's gesture recognisers mid-press — resetting
    // the long-press timer and leaving a window where the next row wouldn't
    // recognise. Local per-row state re-renders only that one row, so neighbours'
    // recognisers are untouched. See docs/knowledge/fact-habit-tracker.md.

    private var normalList: some View {
        let days = DateHelper.weekDates(weekOffset: weekOffset, firstDayOfWeek: store.firstDayOfWeek)

        return GeometryReader { geo in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.allItems, id: \.id) { item in
                        NormalRow(
                            item: item,
                            days: days,
                            isLastChild: isLastChild(of: item),
                            rowHeight: rowHeight,
                            onTap: { loc in handleTap(at: loc, item: item, rowWidth: geo.size.width) },
                            onEdit: { openEditor(for: item) }
                        )
                    }
                    Color.clear.frame(height: 100)
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: - Reorder List (native List + .onMove, no edit grips)
    //
    // A plain List with .onMove gives the system long-press-drag reorder WITHOUT
    // edit mode: the whole row lifts and neighbours reposition live (the
    // "six-dots" behaviour, minus the dots — the grips were just the edit-mode
    // affordance). Days/checkmarks stay visible but inert; tapping a GROUP still
    // expands it so you can drop inside. .onMove feeds the tested
    // store.reorderItem. See docs/knowledge/fact-habit-tracker.md.

    private var reorderList: some View {
        let days = DateHelper.weekDates(weekOffset: weekOffset, firstDayOfWeek: store.firstDayOfWeek)

        return List {
            ForEach(store.allItems, id: \.id) { item in
                reorderRow(for: item, days: days)
                    .frame(height: rowHeight)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color(hex: "1C1C1E"))
                    .listRowSeparator(.hidden)
            }
            .onMove(perform: moveItems)

            Color.clear
                .frame(height: 100)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .moveDisabled(true)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(hex: "1C1C1E"))
    }

    @ViewBuilder
    private func reorderRow(for item: HabitItem, days: [WeekDay]) -> some View {
        // PLAIN rows — NO Button, NO highlight gesture. Both were found to fight
        // the native List reorder recognizer on iOS 26: a Button caused the
        // post-drop dead period; a simultaneousGesture(DragGesture) for highlight
        // STOLE the touch so the long-press-to-drag never started (no haptic, no
        // lift). The native drag needs the row's touch unclaimed. Visual feedback
        // during reorder is the row LIFTING under the finger. Group keeps a tap to
        // expand (TapGesture fails on a long hold, so it doesn't block the drag).
        // See docs/knowledge/fact-habit-tracker.md::Перестановка.
        switch item {
        case .habit(let habit, let groupId):
            HabitRowView(
                habit: habit,
                groupId: groupId,
                days: days,
                isChild: groupId != nil,
                isLastChild: isLastChild(of: item)
            )
        case .group(let group):
            GroupRowView(group: group, days: days)
                .contentShape(Rectangle())
                .onTapGesture { store.toggleGroupExpanded(group.id) }
        }
    }

    /// Translate List's insert-style (source, toOffset) into the "land on this
    /// item" index store.reorderItem expects, then delegate.
    private func moveItems(from source: IndexSet, to destination: Int) {
        guard let s = source.first else { return }
        let count = store.allItems.count
        let target = destination >= count ? count - 1 : (destination > s ? destination - 1 : destination)
        guard target != s, target >= 0 else { return }
        VRLog.d("HABIT", "reorder move from=\(s) toOffset=\(destination) → target=\(target)")
        store.reorderItem(from: s, to: target)
    }

    private func openEditor(for item: HabitItem) {
        switch item {
        case .habit(let habit, let groupId):
            selectedHabit = SelectedHabitItem(habit: habit, groupId: groupId)
        case .group(let group):
            selectedGroup = group
        }
    }

    // MARK: - Tap Router (location-aware, normal mode only)

    /// A quick tap is dispatched by where on the row the finger landed:
    /// - group, left (name) zone → expand/collapse; right zone → nothing
    /// - habit, checkmark zone → toggle that day; left zone → nothing
    /// (Edit is long-press; reorder is the dedicated mode.)
    private func handleTap(at loc: CGPoint, item: HabitItem, rowWidth: CGFloat) {
        let checksStartX = hPadding + leftZoneWidth

        switch item {
        case .group(let group):
            guard loc.x < checksStartX else { return }
            VRLog.d("HABIT", "tap expand group='\(group.name)' → \(group.isExpanded ? "collapse" : "expand")")
            store.toggleGroupExpanded(group.id)

        case .habit(let habit, let gid):
            guard loc.x >= checksStartX else {
                VRLog.d("HABIT", "tap left-zone habit='\(habit.name)' → no-op")
                return
            }

            let days = DateHelper.weekDates(weekOffset: weekOffset, firstDayOfWeek: store.firstDayOfWeek)
            guard !days.isEmpty else { return }

            let zoneWidth = rowWidth - hPadding - checksStartX
            guard zoneWidth > 0 else { return }

            let dayWidth = zoneWidth / CGFloat(days.count)
            let rel = loc.x - checksStartX
            let idx = min(max(0, Int(rel / dayWidth)), days.count - 1)
            VRLog.d("HABIT", "tap toggle habit='\(habit.name)' day=\(days[idx].key)")
            store.toggleHabit(habit.id, dateKey: days[idx].key, groupId: gid)
        }
    }

    private func isLastChild(of item: HabitItem) -> Bool {
        guard case .habit(let habit, let groupId) = item,
              let groupId = groupId,
              let group = store.groups.first(where: { $0.id == groupId }) else {
            return false
        }
        let sortedHabits = group.habits.sorted { $0.order < $1.order }
        return sortedHabits.last?.id == habit.id
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("Нет привычек")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
            Text("Нажми + чтобы добавить первую")
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "8E8E93"))
            Spacer()
        }
    }

    // MARK: - Floating buttons

    private var reorderToggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { isReordering.toggle() }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } label: {
            ZStack {
                Circle()
                    .fill(isReordering ? Color.green : Color(hex: "3A3A3C"))
                    .frame(width: 56, height: 56)
                    .shadow(color: Color.black.opacity(0.3), radius: 10, y: 4)

                Image(systemName: isReordering ? "checkmark" : "arrow.up.arrow.down")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
        .buttonStyle(FABPressStyle())
        .padding(.trailing, 20)
        .accessibilityLabel(isReordering ? "Готово" : "Режим перестановки")
    }

    private var addButton: some View {
        Button {
            showAddSheet = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            ZStack {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 56, height: 56)
                    .shadow(color: Color.blue.opacity(0.35), radius: 14, y: 6)

                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
        .buttonStyle(FABPressStyle())
        .padding(.trailing, 20)
        .padding(.bottom, 32)
        .disabled(isReordering)
        .opacity(isReordering ? 0.4 : 1)
        .accessibilityLabel("Добавить привычку")
    }
}

// MARK: - Normal Row (local press state)
//
// Owns its press highlight in LOCAL @State so a touch re-renders only THIS row,
// never the whole list. That is what makes the press instant and kills the
// post-release dead period (see normalList comment + fact-habit-tracker.md).
private struct NormalRow: View {
    @EnvironmentObject var store: HabitStore
    let item: HabitItem
    let days: [WeekDay]
    let isLastChild: Bool
    let rowHeight: CGFloat
    let onTap: (CGPoint) -> Void
    let onEdit: () -> Void

    // Highlight is driven by a Button's ButtonStyle.isPressed — the mechanism
    // research AND the user ("like buttons") both name as reliably INSTANT inside
    // a ScrollView. A Button gets special scroll-view touch handling that
    // bypasses the ~150ms content-touch delay AND the iOS-26 ScrollView
    // gesture-arbitration regression that kept every raw-gesture highlight laggy
    // (this device is iOS 26.4). The Button's own action is empty; a simultaneous
    // min-distance-0 drag supplies the tap LOCATION + timing (a Button gives
    // neither), and a simultaneous long-press opens the editor. The flag stops a
    // hold from also firing a tap. See docs/knowledge/fact-habit-tracker.md.
    @State private var startLoc: CGPoint = .zero
    @State private var pressStart: Date? = nil
    @State private var longPressFired = false

    private let longPressDelay: TimeInterval = 0.4
    private let moveTolerance: CGFloat = 12

    var body: some View {
        Button {} label: {
            content
                .frame(height: rowHeight)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(RowPressStyle())                  // INSTANT touch-down highlight
        .simultaneousGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    if pressStart == nil {
                        pressStart = Date()
                        startLoc = value.location
                        longPressFired = false
                    }
                }
                .onEnded { value in
                    let start = pressStart
                    pressStart = nil
                    guard !longPressFired, let s = start else { return }
                    let elapsed = Date().timeIntervalSince(s)
                    let drift = hypot(value.location.x - startLoc.x,
                                      value.location.y - startLoc.y)
                    guard elapsed < longPressDelay, drift < moveTolerance else { return }
                    onTap(value.location)              // QUICK TAP → x-zone routing
                }
        )
        .simultaneousGesture(
            LongPressGesture(minimumDuration: longPressDelay)
                .onEnded { _ in
                    longPressFired = true
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onEdit()
                }
        )
    }

    @ViewBuilder
    private var content: some View {
        switch item {
        case .habit(let habit, let groupId):
            HabitRowView(
                habit: habit,
                groupId: groupId,
                days: days,
                isChild: groupId != nil,
                isLastChild: isLastChild,
                isHighlighted: false
            )
        case .group(let group):
            GroupRowView(group: group, days: days, isHighlighted: false)
        }
    }
}

// Row press style: INSTANT touch-down tint. A custom ButtonStyle reading
// configuration.isPressed is the research-confirmed reliable way to highlight a
// row on touch-down inside a ScrollView (Button bypasses the content-touch delay
// + iOS-26 gesture-arbitration lag). animation(nil) = no fade, appears at once.
private struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(configuration.isPressed ? Color.white.opacity(0.12) : Color.clear)
            .animation(nil, value: configuration.isPressed)
    }
}

// FAB-specific press style: tight scale + slight dim on touch-down,
// no slow easing — feels like a hardware key.
private struct FABPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

#Preview {
    ContentView()
        .environmentObject(HabitStore())
}
