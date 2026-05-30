import SwiftUI

// MARK: - Selected Habit Wrapper (for .sheet)
struct SelectedHabitItem: Identifiable {
    let id = UUID()
    let habit: Habit
    let groupId: UUID?
}

// Non-@State scratch for the row gesture. A REFERENCE type on purpose: mutating
// it inside .onChanged during the PRESS phase does NOT invalidate the SwiftUI
// body, whereas mutating a @State value there re-renders the row and CANCELS the
// in-flight long-press before it can reach .onEnded (that was the "press just
// highlights, never opens the editor" bug — logs showed ENGAGE→RELEASE with no
// onEnded). Holds diagnostic counters AND armedIndex = the row whose long-press
// fired, so .onEnded can open the editor even on a perfectly still hold-release
// that never entered the drag phase. See docs/knowledge/fact-habit-tracker.md.
private final class GestureTrace {
    var frames = 0
    var lastLoggedDy: CGFloat = 0
    var phaseLogged = false
    var armedIndex: Int? = nil
    // Set true by the drag .onEnded when it consumes the gesture as a reorder,
    // so the pressedRow RELEASE handler knows NOT to also open the editor.
    var handled = false
}

// MARK: - Content View
struct ContentView: View {
    @EnvironmentObject var store: HabitStore
    @State private var weekOffset: Int = 0
    @State private var showAddSheet = false
    @State private var showSettingsSheet = false
    @State private var selectedHabit: SelectedHabitItem? = nil
    @State private var selectedGroup: HabitGroup? = nil

    // Drag state
    @State private var draggingIndex: Int? = nil
    @State private var draggingOffset: CGFloat = 0
    @State private var didDragMeaningfully: Bool = false
    // Press highlight driven by @GestureState, NOT @State. GestureState auto-
    // resets to nil the instant the gesture ends OR is cancelled — exactly the
    // Apple press-flash semantics. The old @State pressedIndex was cleared only
    // in .onEnded, but a quick tap CANCELS the sequenced gesture (so .onEnded
    // never runs) → the highlight got stuck. See docs/knowledge/fact-habit-tracker.md.
    @GestureState private var pressedRow: Int? = nil
    // Frozen copy of the flattened list captured at drag-start. While a drag is
    // in flight we render from this instead of the computed `store.allItems`,
    // which would otherwise re-sort + re-flatten O(n log n) on EVERY frame
    // (draggingOffset is @State → whole body re-renders 120×/s). This was the
    // #1 cause of the drag jerk. See docs/knowledge/fact-habit-tracker.md.
    @State private var dragSnapshot: [HabitItem]? = nil

    // Gesture bookkeeping + diagnostic counters live in a reference type (see
    // GestureTrace) so mutating them mid-press doesn't re-render the row and
    // cancel the long-press. Reset in .onEnded.
    @State private var trace = GestureTrace()

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
    // Min finger travel (pt) before a press counts as a drag (→ reorder)
    // rather than a press-and-release (→ edit).
    private let dragThreshold: CGFloat = 10

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "1C1C1E")
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    DaysHeaderView(weekOffset: $weekOffset)

                    if store.standaloneHabits.isEmpty && store.groups.isEmpty {
                        emptyState
                    } else {
                        reorderableList
                    }
                }

                // FAB
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        addButton
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

    // MARK: - Reorderable List

    /// Items to render. During a drag this is the frozen snapshot (no per-frame
    /// re-sort); otherwise the live computed list.
    private var displayItems: [HabitItem] {
        dragSnapshot ?? store.allItems
    }

    private var reorderableList: some View {
        // Computed ONCE per frame here, not inside every row body. weekDates is
        // the same for all rows (depends only on weekOffset + firstDayOfWeek),
        // so per-row recomputation was N× wasted work each drag frame.
        let days = DateHelper.weekDates(weekOffset: weekOffset, firstDayOfWeek: store.firstDayOfWeek)

        return GeometryReader { geo in
            ScrollView {
                // LazyVStack (matches the original light version). VStack was
                // eager: a 120Hz draggingOffset @State change re-evaluated the
                // body and rebuilt EVERY row each frame → jank that scaled with
                // row count (worst on a big expanded group). Lazy only rebuilds
                // visible rows. Scroll is frozen during drag (see below), so no
                // rows are culled mid-drag and offset index-math stays valid.
                LazyVStack(spacing: 0) {
                    ForEach(Array(displayItems.enumerated()), id: \.element.id) { index, item in
                        let isDragging = draggingIndex == index
                        let itemOffset = offsetForRow(at: index)

                        itemRow(item: item, index: index, days: days)
                            .frame(height: rowHeight)
                            .contentShape(Rectangle())
                            // ── Gesture stack (see docs/knowledge/fact-habit-tracker.md) ──
                            // Press/drag (edit + reorder) and quick-tap (toggle/
                            // expand) are SEPARATE gestures combined with
                            // .simultaneousGesture — NOT .exclusively(before:).
                            // .exclusively starved the tap completely: a sequenced
                            // long-press claims the touch-down, and when it fails on
                            // a quick lift the tap never received that touch, so it
                            // never fired (on-device logs: zero `tap …` lines for
                            // hundreds of taps). Simultaneous recognition lets the tap
                            // fire on a quick lift while the long-press simply fails.
                            // Double-fire on a deliberate hold (long-press→edit AND
                            // tap) is blocked by the pressedRow gate: once the 0.3s
                            // long-press engages, pressedRow == index, so the tap bows
                            // out. A quick tap (<0.3s) never sets pressedRow → it
                            // fires. SpatialTap gives the location for X-routing:
                            // toggle a day (habit) / expand (group) / no-op (left zone).
                            .gesture(dragGesture(at: index))
                            .simultaneousGesture(
                                SpatialTapGesture(coordinateSpace: .local).onEnded { e in
                                    // Gate on trace.armedIndex, NOT pressedRow:
                                    // pressedRow (@GestureState) has already reset
                                    // to nil by the time this .onEnded runs (the
                                    // tap fires BEFORE the pressedRow RELEASE — see
                                    // logs), so a pressedRow gate never suppresses.
                                    // armedIndex is set on long-press engage and
                                    // not cleared until RELEASE (after this), so it
                                    // reliably marks "a long-press owns this touch".
                                    guard trace.armedIndex == nil else {
                                        VRLog.d("HABIT", "tap SUPPRESSED (long-press armed) idx=\(index)")
                                        return
                                    }
                                    handleTap(at: e.location, item: item, rowWidth: geo.size.width)
                                }
                            )
                            .offset(y: itemOffset)
                            .zIndex(isDragging ? 100 : 0)
                            .scaleEffect(isDragging ? 1.02 : 1.0)
                            .shadow(color: isDragging ? Color.black.opacity(0.35) : .clear,
                                    radius: isDragging ? 14 : 0,
                                    y: isDragging ? 6 : 0)
                            // Only NON-dragged rows animate their make-room slide;
                            // the dragged row tracks the finger 1:1 (nil animation).
                            .animation(
                                isDragging ? nil : .interactiveSpring(response: 0.25, dampingFraction: 0.8),
                                value: itemOffset
                            )
                    }

                    Color.clear.frame(height: 100)
                }
            }
            .scrollIndicators(.hidden)
            // ⚠️ REMOVED: .scrollDisabled(pressedRow != nil).
            // Toggling scrollDisabled MID-GESTURE (pressedRow flips at the 0.3s
            // long-press) re-installs the ScrollView's recognisers, which
            // CANCELS the in-flight .exclusively(drag, before: tap) stack. That
            // single line is what killed tap + expand + long-press and left the
            // @GestureState highlight stuck. The robust scroll-vs-drag answer is
            // being researched; this is a DIAGNOSTIC build. See fact-habit-tracker.md.
            //
            // pressedRow (the @GestureState) is our RELIABLE engage/release
            // signal — it flips nil→idx exactly when the 0.3s long-press wins and
            // idx→nil exactly when the whole gesture ends OR is cancelled. We hang
            // BOTH "arm for edit" and "edit on release" off it, because a
            // sequenced LongPress+Drag does NOT call its .onEnded when the press
            // is released WITHOUT a drag ever starting (SwiftUI quirk — that was
            // the "зажатие просто выделяет, меню не открывается" баг). The drag's
            // own .onEnded still handles the reorder case (it fires only once the
            // Drag sub-gesture actually began). See fact-habit-tracker.md.
            .onChange(of: pressedRow) { old, new in
                if old == nil, let n = new {
                    // Long-press engaged: arm this row + Apple-style "picked up"
                    // haptic. armedIndex is set HERE, not in the gesture's
                    // .onChanged .first(true), because this .onChange always fires
                    // whereas .first(true) was observed to skip occasionally
                    // (ENGAGE appeared in logs with no phase=PRESS).
                    trace.armedIndex = n
                    trace.handled = false
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    VRLog.d("HABIT", "press ENGAGE row=\(n) (armed)")
                } else if new == nil, let o = old {
                    // RELIABLE TERMINAL. This fires on every gesture end AND every
                    // cancel (proven: ENGAGE/RELEASE logged for 100% of holds),
                    // whereas the drag's .onEnded is SKIPPED for a pure long-press
                    // release and even for a drag that the simultaneous tap
                    // cancels mid-flight. So edit + full state reset live HERE.
                    //
                    // Edit iff NOT consumed as a reorder. trace.handled is set by
                    // the drag .onEnded, which fires ~13ms BEFORE this for a real
                    // reorder (proven by on-device timestamps), so handled is
                    // already true by now in the reorder case. A still hold or a
                    // tiny twitch whose drag got cancelled never sets handled → edit.
                    let items = displayItems
                    if !trace.handled, let ai = trace.armedIndex, ai >= 0, ai < items.count {
                        VRLog.d("HABIT", "RELEASE→EDIT \(items[ai].debugName) row=\(o)")
                        openEditor(for: items[ai])
                    } else {
                        VRLog.d("HABIT", "RELEASE no-edit row=\(o) handled=\(trace.handled)")
                    }
                    // Reset EVERYTHING here — covers the case where a drag started
                    // but was cancelled WITHOUT .onEnded (its defer never ran, so
                    // draggingIndex/dragSnapshot would otherwise leak → stuck
                    // scale/shadow on the row + wrong displayItems next gesture).
                    draggingIndex = nil
                    draggingOffset = 0
                    didDragMeaningfully = false
                    dragSnapshot = nil
                    trace.armedIndex = nil
                    trace.handled = false
                    trace.phaseLogged = false
                    trace.frames = 0
                    trace.lastLoggedDy = 0
                }
            }
        }
    }

    // MARK: - Tap Router (location-aware)

    /// A quick tap is dispatched by where on the row the finger landed:
    /// - group, left (name) zone → expand/collapse; right zone → nothing
    /// - habit, checkmark zone → toggle that day; left zone → nothing
    /// (Edit is press+release anywhere; reorder is press+drag anywhere.)
    private func handleTap(at loc: CGPoint, item: HabitItem, rowWidth: CGFloat) {
        let checksStartX = hPadding + leftZoneWidth

        switch item {
        case .group(let group):
            // Only the title zone toggles expand; tapping the progress circles
            // does nothing (matches prior behaviour).
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

    // MARK: - Offset Calculation

    /// Рассчитывает offset для строки с учетом drag
    private func offsetForRow(at index: Int) -> CGFloat {
        guard let dragIdx = draggingIndex else {
            return 0 // Нет drag — нет offset
        }

        if index == dragIdx {
            // Это перетаскиваемый элемент — двигается с пальцем
            return draggingOffset
        }

        // Рассчитываем куда визуально переместился dragged элемент
        let draggedVisualPosition = CGFloat(dragIdx) * rowHeight + draggingOffset
        let draggedTargetIndex = Int(round(draggedVisualPosition / rowHeight))
        // Разрешаем -1 для "перед первым элементом"
        let clampedTarget = max(-1, min(displayItems.count - 1, draggedTargetIndex))

        // Если текущий index находится между оригинальной и целевой позицией dragged элемента
        // — нужно сдвинуть эту строку
        if dragIdx < clampedTarget {
            // Тащим вниз: элементы между dragIdx+1 и clampedTarget должны сдвинуться вверх
            if index > dragIdx && index <= clampedTarget {
                return -rowHeight
            }
        } else if dragIdx > clampedTarget {
            // Тащим вверх: элементы между clampedTarget и dragIdx-1 должны сдвинуться вниз
            // Для clampedTarget = -1, все элементы от 0 до dragIdx-1 должны сдвинуться
            let effectiveTarget = max(0, clampedTarget)
            if index >= effectiveTarget && index < dragIdx {
                return rowHeight
            }
        }

        return 0
    }

    // MARK: - Press / Drag Gesture
    //
    // Backbone: LongPress(0.3, maxDist:10).sequenced(before: Drag(minDist:3))
    // - .updating($pressedRow) → highlight row while pressing/dragging; auto-
    //   clears on end/cancel (Apple press-flash). A quick tap (<0.3s) never
    //   triggers it, so the background no longer activates on a plain tap.
    // - .second → drag phase. minDist:3 gives a dead-zone so the row doesn't
    //   twitch on engage. translation >10pt ⇒ reorder, not an edit.
    // - .onEnded → moved → reorder; else (pure press+release) → edit.
    // maxDistance:10 lets a fast vertical swipe fail the long-press so the
    // parent ScrollView keeps the touch and scrolls.
    //
    // ⚠️ coordinateSpace: .global (NOT .local) on the DragGesture — THIS is the
    // fix for the whole "дёрганье" / from=N-to=N saga. The dragged row is moved
    // by .offset(y: draggingOffset), and draggingOffset IS this gesture's
    // translation.height. In .local, the row's own offset moves the gesture's
    // coordinate origin, so the NEXT translation is measured against a frame
    // that just moved → a feedback loop: dy climbs, then collapses back toward 0
    // while the finger is still down (on-device logs: -23→-65→-7→finalDy=5,
    // reorder to==from). A fast decisive drag could outrun it (that's why it
    // "sometimes worked"). The gesture itself was never cancelled — frame counts
    // (72, 46) prove it ran to completion. .global is screen space; .offset
    // never moves it, so translation tracks the finger 1:1. See fact-habit-tracker.md.
    private func dragGesture(at index: Int) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3, maximumDistance: 10)
            .sequenced(before: DragGesture(minimumDistance: 3, coordinateSpace: .global))
            .updating($pressedRow) { value, state, _ in
                switch value {
                case .first(true):        state = index   // pressing
                case .second(true, _):    state = index   // dragging
                default:                  state = nil
                }
            }
            .onChanged { value in
                switch value {
                case .first(true):
                    // Long-press cleared the 0.3s threshold (finger still down,
                    // not yet moved). Arming + haptic happen in the pressedRow
                    // ENGAGE handler (reliable); here we only log the phase
                    // (best-effort — this case was seen to skip occasionally).
                    if !trace.phaseLogged {
                        trace.phaseLogged = true
                        VRLog.d("HABIT", "phase=PRESS (longpress fired) idx=\(index)")
                    }
                case .second(true, let drag):
                    if draggingIndex == nil {
                        // Freeze the list order for the duration of the drag so
                        // the body stops re-sorting store.allItems every frame.
                        dragSnapshot = store.allItems
                        draggingIndex = index
                        didDragMeaningfully = false
                        trace.frames = 0
                        trace.lastLoggedDy = 0
                        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                        let name = (index < displayItems.count) ? displayItems[index].debugName : "?"
                        VRLog.d("HABIT", "drag START idx=\(index) \(name)")
                    }
                    if let drag = drag {
                        trace.frames += 1
                        let dy = drag.translation.height
                        draggingOffset = dy
                        // Threshold checked live (not just on end) so a drag-out
                        // and back-to-origin still counts as a reorder, never an edit.
                        if hypot(drag.translation.width, dy) > dragThreshold {
                            didDragMeaningfully = true
                        }
                        // Throttled travel log: every ~20pt.
                        if abs(dy - trace.lastLoggedDy) >= 20 {
                            trace.lastLoggedDy = dy
                            VRLog.d("HABIT", "drag move dy=\(Int(dy)) frame=\(trace.frames)")
                        }
                    }
                default:
                    break
                }
            }
            .onEnded { _ in
                // IMPORTANT: for a pure long-press release (the Drag sub-gesture
                // never started) SwiftUI does NOT call this at all — that path is
                // handled in .onChange(of: pressedRow) (RELEASE→EDIT). This fires
                // only when the drag actually began. Edit has a SINGLE source of
                // truth (the RELEASE handler); here we only do reorder.
                defer {
                    draggingIndex = nil
                    draggingOffset = 0
                    didDragMeaningfully = false
                    dragSnapshot = nil
                    // trace.* is reset in the pressedRow RELEASE handler, which
                    // runs right after this and reads trace.handled.
                }

                let items = displayItems

                if let di = draggingIndex, didDragMeaningfully, di >= 0, di < items.count {
                    // Real reorder. Mark handled so RELEASE won't also edit.
                    trace.handled = true
                    let toIndex = calculateTargetIndex(from: di, offset: draggingOffset)
                    VRLog.d("HABIT", "onEnded REORDER from=\(di) to=\(toIndex) frames=\(trace.frames) finalDy=\(Int(draggingOffset))")
                    if toIndex != di {
                        store.reorderItem(from: di, to: toIndex)
                    }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } else {
                    // Drag started but never passed the 10pt threshold → not a
                    // reorder. Leave trace.handled false so the RELEASE handler
                    // opens the editor (press-release semantics).
                    VRLog.d("HABIT", "onEnded small-move (→ edit via RELEASE) frames=\(trace.frames) finalDy=\(Int(draggingOffset))")
                }
            }
    }

    private func openEditor(for item: HabitItem) {
        switch item {
        case .habit(let habit, let groupId):
            selectedHabit = SelectedHabitItem(habit: habit, groupId: groupId)
        case .group(let group):
            selectedGroup = group
        }
    }

    private func calculateTargetIndex(from index: Int, offset: CGFloat) -> Int {
        let itemCount = displayItems.count
        let rowsMoved = Int(round(offset / rowHeight))
        let newIndex = index + rowsMoved
        // -1 разрешён для "перед первым элементом" (вынести habit из группы)
        return max(-1, min(itemCount - 1, newIndex))
    }

    // MARK: - Item Row

    @ViewBuilder
    private func itemRow(item: HabitItem, index: Int, days: [WeekDay]) -> some View {
        let isDragging = draggingIndex == index
        let isHighlighted = (pressedRow == index) || isDragging

        switch item {
        case .habit(let habit, let groupId):
            let isChild = groupId != nil

            HabitRowView(
                habit: habit,
                groupId: groupId,
                days: days,
                isChild: isChild,
                isLastChild: isLastChildInGroup(habit: habit, groupId: groupId),
                isHighlighted: isHighlighted
            )

        case .group(let group):
            GroupRowView(
                group: group,
                days: days,
                isHighlighted: isHighlighted
            )
        }
    }

    private func isLastChildInGroup(habit: Habit, groupId: UUID?) -> Bool {
        guard let groupId = groupId,
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

    // MARK: - FAB

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
        .accessibilityLabel("Добавить привычку")
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
