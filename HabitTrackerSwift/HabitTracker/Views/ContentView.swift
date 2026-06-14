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

    // Custom drag-reorder state. Used ONLY in reorder mode.
    // draggingIndex = which row is held; draggingOffset = its finger-tracked
    // y shift; dragSnapshot freezes the list order for the drag's lifetime so
    // the body stops re-sorting store.allItems every frame.
    @State private var draggingIndex: Int? = nil
    @State private var draggingOffset: CGFloat = 0
    @State private var dragSnapshot: [HabitItem]? = nil
    // Global-space Y where the long-press began — offset is globalY − dragStartY.
    // Global coords (not the row's local space) so the row's own .offset never
    // moves the origin (same feedback-loop invariant as the old .global).
    @State private var dragStartY: CGFloat = 0
    // Live global-space top of the scroll content (negative as the list scrolls).
    // Row index = (globalTouchY − contentTopY) / rowHeight — scroll-correct.
    @State private var contentTopY: CGFloat = 0

    // Live count of lines in the shared debug log — shown next to the navbar
    // copy icon (mirrors the Voice tab). Refreshed on appear + once a second.
    @State private var logLineCount: Int = 0
    private let logCountTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // Gates the copy-log / clear-log icons in this navbar. Toggled in
    // Settings → Диагностика; persisted in the App Group so flipping it there
    // updates this navbar live. Off by default. (Mirrors the Voice tab's devMode.)
    @AppStorage(VoiceRecordConfig.SharedKeys.showHabitLogButtons,
                store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var showHabitLogButtons: Bool = false

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

                // Quick log access — copy recent buffer / clear it without leaving
                // the screen. Shown only when the Settings → Диагностика toggle
                // "Показывать лог-кнопки" is on (off by default → clean navbar).
                // Full viewer always lives in Settings → Диагностика.
                if showHabitLogButtons {
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

    // MARK: - Reorder List (UIKit UILongPressGestureRecognizer, NOT a SwiftUI gesture)
    //
    // THREE pure-SwiftUI attempts failed to let the list scroll AND reorder:
    //   1. native List.onMove — has a ~0.5s post-drop re-arm lock (no fast serial
    //      reordering, the user's original complaint);
    //   2. per-row `.gesture(DragGesture(minDist:8))` + `.scrollDisabled` — a child
    //      drag via `.gesture` makes the ScrollView pan REQUIRE it to fail; a
    //      low-minDistance drag never fails → scroll dead;
    //   3. `.simultaneousGesture(DragGesture(minDist:0))` with an in-code timed
    //      long-press — STILL dead. The root cause (confirmed by deep research,
    //      WWDC24 "unified gesture model" session 10118 + forum 760035): SwiftUI's
    //      ScrollView pan recogniser is PRIVATE, so a SwiftUI child gesture can
    //      never deterministically coexist with it; on a physical iOS-26 device a
    //      child drag starves the pan regardless of attachment modifier.
    //
    // The robust path the research recommends: own the recogniser in UIKit. We use
    // the iOS-18 `UIGestureRecognizerRepresentable` to attach ONE real
    // `UILongPressGestureRecognizer` (minimumPressDuration 0.25, allowableMovement
    // 12) to the SwiftUI ScrollView. Its delegate returns
    // `shouldRecognizeSimultaneouslyWith == true` for the scroll pan, so a quick
    // swipe (which never satisfies the 0.25s press) scrolls, while a held press
    // begins the reorder. The SwiftUI rows + `.offset` make-room engine are kept
    // verbatim — only the gesture SOURCE moved to UIKit. There is no post-drop
    // lock: we call our own end logic in `.ended` and the recogniser re-arms
    // instantly. See docs/knowledge/fact-habit-tracker.md::Перестановка.

    private var displayItems: [HabitItem] { dragSnapshot ?? store.allItems }

    private var reorderList: some View {
        let days = DateHelper.weekDates(weekOffset: weekOffset, firstDayOfWeek: store.firstDayOfWeek)

        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(displayItems.enumerated()), id: \.element.id) { index, item in
                    let isDragging = draggingIndex == index
                    let itemOffset = offsetForRow(at: index)

                    reorderRow(for: item, index: index, days: days)
                        .frame(height: rowHeight)
                        .offset(y: itemOffset)
                        .zIndex(isDragging ? 100 : 0)
                        .scaleEffect(isDragging ? 1.02 : 1.0)
                        .shadow(color: isDragging ? Color.black.opacity(0.35) : .clear,
                                radius: isDragging ? 14 : 0, y: isDragging ? 6 : 0)
                        // Make-room spring runs ONLY while a drag is in flight
                        // (draggingIndex != nil) and only for NON-dragged rows.
                        // At DROP (draggingIndex == nil) the animation must be nil:
                        // the array reorders structurally (instant) AND every
                        // itemOffset returns ±rowHeight→0 in the same render. If
                        // the offset animated there, the row would spring from its
                        // already-correct new slot back toward the old offset and
                        // settle — the "right blocks change then change back" glitch
                        // (the title, one stable Text, hid it; the 7 checkmark
                        // columns made it obvious). Instant commit = seamless
                        // because the rows are already in their final spots.
                        // See docs/knowledge/fact-habit-tracker.md::Перестановка.
                        .animation((draggingIndex == nil || isDragging)
                                   ? nil
                                   : .interactiveSpring(response: 0.25, dampingFraction: 0.8),
                                   value: itemOffset)
                }
                Color.clear.frame(height: 100)
            }
            // Track the content's TRUE global top. As the list scrolls, this minY
            // goes negative; the row index = (globalTouchY − contentTopY)/rowHeight
            // is then scroll-correct by construction. (The earlier
            // convert(globalPoint:to:.named) approach silently ignored scroll —
            // it maps to an ANCESTOR space, but the named space was on this
            // descendant — so a scrolled list grabbed the row ~N above the finger.)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: {
                contentTopY = $0
            }
        }
        .scrollIndicators(.hidden)
        // The UIKit long-press owns scroll-vs-reorder arbitration (it coexists
        // with the pan via the delegate). .scrollDisabled adds a belt-and-braces
        // freeze once a row is actually grabbed so the held finger can't also
        // drag the content; flips exactly once at engage. Freezing also pins
        // contentTopY for the drag's lifetime, keeping the index math stable.
        .scrollDisabled(draggingIndex != nil)
        // The real recogniser, attached to the ScrollView. Callbacks report the
        // touch point in GLOBAL space; we subtract contentTopY for the row index.
        // Attached via .gesture (the UIGestureRecognizerRepresentable overload) —
        // simultaneity with the scroll pan is handled in UIKit by the coordinator
        // delegate's shouldRecognizeSimultaneouslyWith, NOT by a SwiftUI modifier.
        .gesture(
            ReorderLongPressGesture(
                minimumPressDuration: 0.25,
                onBegan: { globalY in
                    let idx = Int((globalY - contentTopY) / rowHeight)
                    guard idx >= 0, idx < displayItems.count else { return }
                    dragSnapshot = store.allItems
                    dragStartY = globalY
                    draggingIndex = idx
                    draggingOffset = 0
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                    VRLog.d("HABIT", "reorder GRAB idx=\(idx) globalY=\(Int(globalY)) top=\(Int(contentTopY))")
                },
                onChanged: { globalY in
                    guard draggingIndex != nil else { return }
                    draggingOffset = globalY - dragStartY
                },
                onEnded: { _ in endReorder() },
                onCancelled: { endReorder() }
            )
        )
    }

    /// Commit the in-flight reorder (if any) and clear all drag state. Called from
    /// both .ended and .cancelled so state can never stick (UIKit recognisers,
    /// unlike SwiftUI gestures, DO deliver a cancel state).
    private func endReorder() {
        defer {
            draggingIndex = nil
            draggingOffset = 0
            dragSnapshot = nil
            dragStartY = 0
        }
        guard let from = draggingIndex else { return }
        let target = targetIndex(from: from, offset: draggingOffset)
        guard target != from, target >= 0, target < displayItems.count else {
            VRLog.d("HABIT", "reorder END no-move from=\(from)")
            return
        }
        VRLog.d("HABIT", "reorder END from=\(from) → target=\(target)")
        store.reorderItem(from: from, to: target)
    }

    @ViewBuilder
    private func reorderRow(for item: HabitItem, index: Int, days: [WeekDay]) -> some View {
        // The WHOLE row is draggable — no handle glyph, so the layout matches
        // normal mode exactly (checkmarks don't shift). The grab is the UIKit
        // long-press on the ScrollView (see reorderList); a quick tap that never
        // reaches 0.25s still falls through to the group's expand-tap (so you can
        // open a group to drop into it). Habit rows are inert on tap.
        Group {
            switch item {
            case .habit(let habit, let groupId):
                HabitRowView(habit: habit, groupId: groupId, days: days,
                             isChild: groupId != nil, isLastChild: isLastChild(of: item))
            case .group(let group):
                GroupRowView(group: group, days: days)
                    .contentShape(Rectangle())
                    .onTapGesture { store.toggleGroupExpanded(group.id) }
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    /// Final landing index for the dragged row given its pixel offset.
    private func targetIndex(from: Int, offset: CGFloat) -> Int {
        let visualPos = CGFloat(from) * rowHeight + offset
        let raw = Int(round(visualPos / rowHeight))
        return max(0, min(displayItems.count - 1, raw))
    }

    /// Live make-room offset for each row while a drag is in flight.
    private func offsetForRow(at index: Int) -> CGFloat {
        guard let dragIdx = draggingIndex else { return 0 }
        if index == dragIdx { return draggingOffset }

        let target = targetIndex(from: dragIdx, offset: draggingOffset)
        if dragIdx < target {
            if index > dragIdx && index <= target { return -rowHeight }
        } else if dragIdx > target {
            if index >= target && index < dragIdx { return rowHeight }
        }
        return 0
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
    /// - group → expand/collapse anywhere on the row (full width); the right
    ///   zone has no per-day checkmarks to toggle, so the whole row is one target
    /// - habit, checkmark zone → toggle that day; left zone → nothing
    /// (Edit is long-press; reorder is the dedicated mode.)
    private func handleTap(at loc: CGPoint, item: HabitItem, rowWidth: CGFloat) {
        let checksStartX = hPadding + leftZoneWidth

        switch item {
        case .group(let group):
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

    // All three interactions (instant highlight, quick tap with x-location,
    // press-and-hold to edit) come from UIKit recognisers in RowGestureOverlay,
    // NOT from a Button. A SwiftUI Button's private _ButtonGesture owns the touch
    // until touch-up and starved the external tap+long-press on iOS 18/26 — both
    // expand-tap and edit-press silently died. The overlay's recognisers coexist
    // with the ScrollView pan (delegate → shouldRecognizeSimultaneouslyWith), so
    // scrolling works AND all three fire. See fact-habit-tracker.md::Обычный режим.
    @State private var isHighlighted = false

    private let longPressDelay: TimeInterval = 0.4
    private let moveTolerance: CGFloat = 12

    var body: some View {
        content
            .frame(height: rowHeight)
            .frame(maxWidth: .infinity)
            .background(isHighlighted ? Color.white.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
            .overlay(
                RowGestureOverlay(
                    onTap: { loc in onTap(loc) },
                    onEdit: { isHighlighted = false; onEdit() },
                    onHighlightChanged: { isHighlighted = $0 },
                    longPressDelay: longPressDelay,
                    moveTolerance: moveTolerance
                )
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

// MARK: - UIKit-backed row gestures (normal mode: tap + long-press + scroll)
//
// Replaces the Button + .onLongPressGesture + SpatialTapGesture stack, which is
// BROKEN on iOS 18/26: SwiftUI's Button installs a private _ButtonGesture that
// owns the touch-sequence until touch-up and starves any external long-press/tap
// attached over it, so neither tap (expand) nor long-press (edit) fired. Deep
// research (Perplexity, WWDC24 session 10118 + forum 760035) confirmed the only
// robust path is to own ALL recognisers in UIKit. All three are created in ONE
// UIView so require(toFail:) is guaranteed installed before the view appears:
//   • highlight — UILongPressGestureRecognizer(minimumPressDuration: 0): instant
//     touch-down tint, auto-cleared on .cancelled when the scroll pan wins.
//   • longPress (0.4s) — opens the editor.
//   • tap.require(toFail: longPress) — quick tap routes by x-location; a held
//     press routes to edit, never both.
// Every recogniser's delegate returns shouldRecognizeSimultaneouslyWith == true
// for the scroll pan (anything not one of our three) → scrolling always works.
// See docs/knowledge/fact-habit-tracker.md::Обычный режим.
private struct RowGestureOverlay: UIViewRepresentable {
    let onTap: (CGPoint) -> Void
    let onEdit: () -> Void
    let onHighlightChanged: (Bool) -> Void
    let longPressDelay: TimeInterval
    let moveTolerance: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap, onEdit: onEdit, onHighlightChanged: onHighlightChanged)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let c = context.coordinator

        // Instant touch-down highlight.
        let highlight = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.handleHighlight(_:)))
        highlight.minimumPressDuration = 0
        highlight.allowableMovement = 10_000   // never fails on movement; scroll cancels it
        highlight.delegate = c
        c.highlight = highlight
        view.addGestureRecognizer(highlight)

        // Press-and-hold → edit.
        let longPress = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = longPressDelay
        longPress.allowableMovement = moveTolerance
        longPress.delegate = c
        c.longPress = longPress
        view.addGestureRecognizer(longPress)

        // Quick tap → x-zone routing. Waits for the long-press to FAIL (finger
        // lifted before 0.4s) so a hold never also fires a tap.
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = c
        tap.require(toFail: longPress)
        c.tap = tap
        view.addGestureRecognizer(tap)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Closures capture per-render state (item identity, days) — refresh them.
        context.coordinator.onTap = onTap
        context.coordinator.onEdit = onEdit
        context.coordinator.onHighlightChanged = onHighlightChanged
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTap: (CGPoint) -> Void
        var onEdit: () -> Void
        var onHighlightChanged: (Bool) -> Void
        weak var tap: UITapGestureRecognizer?
        weak var longPress: UILongPressGestureRecognizer?
        weak var highlight: UILongPressGestureRecognizer?

        init(onTap: @escaping (CGPoint) -> Void,
             onEdit: @escaping () -> Void,
             onHighlightChanged: @escaping (Bool) -> Void) {
            self.onTap = onTap
            self.onEdit = onEdit
            self.onHighlightChanged = onHighlightChanged
        }

        @objc func handleTap(_ r: UITapGestureRecognizer) {
            guard r.state == .ended else { return }
            onTap(r.location(in: r.view))
        }

        @objc func handleLongPress(_ r: UILongPressGestureRecognizer) {
            if r.state == .began {
                onHighlightChanged(false)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onEdit()
            }
        }

        @objc func handleHighlight(_ r: UILongPressGestureRecognizer) {
            switch r.state {
            case .began: onHighlightChanged(true)
            case .ended, .cancelled, .failed: onHighlightChanged(false)
            default: break
            }
        }

        // Coexist with the ScrollView pan (and anything external); among OUR three
        // recognisers, only the highlight runs simultaneously — tap vs long-press
        // is governed by require(toFail:), not simultaneity.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            let ours: [UIGestureRecognizer?] = [tap, longPress, highlight]
            if ours.contains(where: { $0 === other }) {
                return g === highlight || other === highlight
            }
            return true   // external (scroll pan) — always allow
        }
    }
}

// MARK: - UIKit-backed reorder long-press
//
// A real UILongPressGestureRecognizer wrapped in the iOS-18
// UIGestureRecognizerRepresentable. This is the fix for "the reorder list won't
// scroll": three pure-SwiftUI attempts all starved the ScrollView pan because
// SwiftUI's pan recogniser is private and can't be coordinated against. Here the
// recogniser is ours, and its delegate returns shouldRecognizeSimultaneouslyWith
// == true for the scroll pan — so a quick swipe (which never satisfies the 0.25s
// press) scrolls, and a held press starts the reorder. Callbacks report the touch
// point in WINDOW space (the parent maps it to a row index). See
// docs/knowledge/fact-habit-tracker.md::Перестановка.
// Internal (not private) so the Voice History reorder mode can reuse the SAME
// scroll-coexisting long-press drag instead of duplicating it. It's a generic
// whole-row drag source — nothing Habits-specific — so sharing is clean.
struct ReorderLongPressGesture: UIGestureRecognizerRepresentable {
    let minimumPressDuration: TimeInterval
    let onBegan: (_ globalY: CGFloat) -> Void
    let onChanged: (_ globalY: CGFloat) -> Void
    let onEnded: (_ globalY: CGFloat) -> Void
    let onCancelled: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let g = UILongPressGestureRecognizer()
        g.minimumPressDuration = minimumPressDuration
        g.allowableMovement = 12          // a small jitter still counts as a hold
        g.delegate = context.coordinator  // → coexist with the scroll pan
        return g
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer,
                                         context: Context) {
        // location(in: nil) → window/global space. The parent subtracts the
        // content's global top (tracked via onGeometryChange) for the row index,
        // which is scroll-correct because that top moves with the scroll.
        let y = recognizer.location(in: nil).y
        switch recognizer.state {
        case .began:     onBegan(y)
        case .changed:   onChanged(y)
        case .ended:     onEnded(y)
        case .cancelled, .failed: onCancelled()
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        // THE crucial line: let our long-press and the ScrollView pan recognise
        // together. Without this the long-press would, once again, block the pan.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
    }
}

#Preview {
    ContentView()
        .environmentObject(HabitStore())
}
