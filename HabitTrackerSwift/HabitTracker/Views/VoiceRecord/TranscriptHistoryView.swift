import AVFoundation
import SwiftUI

// Top filter for the History list, in segmented-control order:
//   • All    — every recording.
//   • Voices — raw transcribed voice recordings only: everything EXCEPT curated
//              notes. This is the default tab.
//   • Notes  — only the entries the user curated (custom title or +Notes flag).
private enum HistoryFilter: String, CaseIterable {
    case all = "All"
    case voices = "Voices"
    case notes = "Notes"
}

struct TranscriptHistoryView: View {
    @EnvironmentObject var recorder: RecordingCoordinator
    @Environment(\.dismiss) var dismiss
    @StateObject private var player = AudioPlayerController()
    @State private var filter: HistoryFilter = .voices
    // Two-phase merge animation. Phase 1: a short render-only effect on the
    // source row (fade + small slide toward its neighbour) set via @State.
    // Phase 2: commit the data merge inside withAnimation, letting List's own
    // native row-removal slide every row below up to close the gap in one
    // coordinated motion. We do NOT collapse the row's height with scaleEffect —
    // that's render-only, doesn't reflow the List, and left a gap while the
    // neighbours stayed put. List owns the reflow; we only own the leave.
    // mergeEdge = the neighbour's direction: ↑ → .top (slides up toward the
    // card above), ↓ → .bottom.
    @State private var mergingId: UUID? = nil
    @State private var mergeEdge: Edge = .top
    // Reorder mode — ported from the Habits tab's WHOLE-ROW drag (not native
    // List/.onMove, which only drags from a trailing handle). A bottom-right FAB
    // (⇅ → ✓) flips this; in reorder mode the List is swapped for a custom
    // ScrollView+LazyVStack whose every card is grab-able via a UIKit long-press
    // that coexists with the scroll pan (ReorderLongPressGesture, shared with
    // Habits). The manual order persists via sortIndex and takes priority over
    // the date (TranscriptStore.reorder), letting the user place a note next to a
    // non-adjacent one to then merge "через одну".
    @State private var isReordering = false

    // ── Custom drag state (reorder mode only), mirroring ContentView ──────────
    // draggingIndex = held row; draggingOffset = finger-tracked y shift;
    // dragSnapshot freezes the visible order for the drag's lifetime so the body
    // stops re-sorting every frame; dragStartY = global Y where the press began;
    // contentTopY = live global top of the scroll content (negative as it
    // scrolls) for a scroll-correct row hit-test.
    @State private var draggingIndex: Int? = nil
    @State private var draggingOffset: CGFloat = 0
    @State private var dragSnapshot: [TranscriptEntry]? = nil
    @State private var dragStartY: CGFloat = 0
    @State private var contentTopY: CGFloat = 0
    // History cards are VARIABLE height (Habits rows are a fixed 52pt), so the
    // make-room + hit-test math can't assume one rowHeight. We measure each row's
    // height (keyed by entry id) and its global-space midY, and use those for
    // both the cumulative layout and the "which row is the finger over" test.
    @State private var rowHeights: [UUID: CGFloat] = [:]
    @State private var rowMidYs: [UUID: CGFloat] = [:]
    // Resting row centers SNAPSHOT at grab time. The drag math must use these,
    // not the live rowMidYs — once rows start making room via .offset their live
    // midY moves, which would feed back into the target calc (target → offsets →
    // midYs → target oscillation). Frozen at onBegan (when no offset is applied
    // yet, so rowMidYs holds true resting centers) and used for the whole drag.
    @State private var frozenMidYs: [UUID: CGFloat] = [:]
    // Phase 1: short render-only "card leaving" effect before the data commit.
    // (Phase 2's reflow timing lives in mergeEntry's own withAnimation.)
    private static let mergePhase1 = 0.16
    // Prepared in onAppear so the first merge's haptic doesn't pay the ~200ms
    // Taptic Engine cold-start on the main thread (one of the lag sources).
    private let mergeHaptic = UINotificationFeedbackGenerator()

    // How many entries are notes — shown as "(N)" on the Notes tab.
    private var notesCount: Int {
        recorder.history.lazy.filter { $0.isNote }.count
    }

    // The history filtered by the active tab. Voices = recordings that are NOT
    // notes; Notes = only notes; All = everything.
    private var filteredEntries: [TranscriptEntry] {
        switch filter {
        case .all:    return recorder.history
        case .voices: return recorder.history.filter { !$0.isNote }
        case .notes:  return recorder.history.filter { $0.isNote }
        }
    }

    // Per-tab empty placeholder.
    @ViewBuilder
    private var emptyState: some View {
        switch filter {
        case .all:
            ContentUnavailableView(
                "No recordings yet",
                systemImage: "waveform",
                description: Text("Recordings will appear here.")
            )
        case .voices:
            ContentUnavailableView(
                "No voice recordings",
                systemImage: "waveform",
                description: Text("Recordings you haven't titled appear here.")
            )
        case .notes:
            ContentUnavailableView(
                "No notes yet",
                systemImage: "note.text",
                description: Text("Give a recording a title to keep it here.")
            )
        }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if recorder.history.isEmpty {
                        ContentUnavailableView(
                            "No recordings yet",
                            systemImage: "waveform",
                            description: Text("Recordings will appear here.")
                        )
                    } else {
                        let entries = filteredEntries
                        if entries.isEmpty {
                            emptyState
                        } else if isReordering {
                            reorderList(entries: dragSnapshot ?? entries)
                        } else {
                            List {
                                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                    row(index: index, entry: entry, entries: entries)
                                        .listRowSeparator(.hidden)
                                        .listRowBackground(Color.clear)
                                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                                }
                            }
                            .listStyle(.plain)
                        }
                    }
                }

                // Bottom-right FAB to toggle reorder mode (moved here from the
                // top-left toolbar at the user's request — same corner as the
                // Habits reorder FAB). ⇅ → ✓. Shown only when there are at least
                // two visible rows to reorder. Sits above the player bar.
                if filteredEntries.count > 1 {
                    reorderFAB
                        .padding(.trailing, 20)
                        .padding(.bottom, player.currentId != nil ? 96 : 28)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    // Three tabs now (All · Voices · Notes) — let the segmented
                    // control take the available centre width instead of
                    // .fixedSize() so it doesn't crowd the Done button.
                    Picker("Filter", selection: $filter) {
                        ForEach(HistoryFilter.allCases, id: \.self) { f in
                            // Notes tab carries a count of how many notes exist.
                            Text(f == .notes && notesCount > 0
                                 ? "\(f.rawValue) (\(notesCount))"
                                 : f.rawValue)
                                .tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isReordering)   // don't switch tabs mid-drag-session
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            // Switching tabs exits reorder mode so we never strand the user in a
            // mode whose row set just changed under them.
            .onChange(of: filter) { _, _ in
                if isReordering { exitReorder() }
            }
            .safeAreaInset(edge: .bottom) {
                if player.currentId != nil {
                    PlayerBar(player: player)
                }
            }
        }
        .onAppear { mergeHaptic.prepare() }
        .onDisappear { player.stop() }
        // While reordering, block the sheet's pull-to-dismiss. The whole-card
        // drag uses a UIKit long-press that recognises SIMULTANEOUSLY with other
        // gestures (so a quick swipe still scrolls) — but that also feeds a
        // downward card-drag into the sheet's dismiss pan, so the sheet slid down
        // instead of the card moving (the user's "меню опускается вниз"). Habits
        // never hit this because it's a full tab, not a sheet. The FAB ✓ and the
        // Done button still dismiss (those are programmatic, not the swipe), so
        // disabling the interactive swipe here costs nothing.
        .interactiveDismissDisabled(isReordering)
    }

    // The reorder-mode toggle FAB (bottom-right). ⇅ enters, ✓ commits-by-exit
    // (every drag already persisted as it happened). Matches the Habits FAB
    // idiom: filled circle, grey→green.
    private var reorderFAB: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if isReordering { exitReorder() } else { isReordering = true }
            }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } label: {
            ZStack {
                Circle()
                    .fill(isReordering ? Color.green : Color(white: 0.25))
                    .frame(width: 52, height: 52)
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                Image(systemName: isReordering ? "checkmark" : "arrow.up.arrow.down")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isReordering ? "Готово, выйти из режима перестановки" : "Режим перестановки")
    }

    private func exitReorder() {
        isReordering = false
        draggingIndex = nil
        draggingOffset = 0
        dragSnapshot = nil
        dragStartY = 0
        frozenMidYs = [:]
    }

    // One history card with native .swipeActions: swipe-left reveals three
    // icon-only buttons in a horizontal row — Delete (edge, full-swipe), merge
    // ↓, merge ↑. icon-only (no titles) keeps each button as narrow as the
    // glyph; native swipe buttons stay reliable in a List (a custom gesture
    // would fight List's scroll on iOS 18/26 — see research).
    @ViewBuilder
    private func row(index: Int, entry: TranscriptEntry, entries: [TranscriptEntry]) -> some View {
        // Resolve merge neighbours from the VISIBLE (filtered) list, not the
        // full history. Under the Voices tab notes are hidden, so the card shown
        // above/below isn't necessarily the adjacent entry in recorder.history —
        // merging must follow what the user sees.
        let upTargetId   = index > 0 ? entries[index - 1].id : nil
        let downTargetId = index < entries.count - 1 ? entries[index + 1].id : nil
        EntryRow(
            entry: entry,
            isCurrentlyPlaying: player.currentId == entry.id,
            isReloading: recorder.reloadingId == entry.id,
            onPlayTap: { player.toggle(entry: entry) },
            onReloadTap: { Task { await recorder.reloadTranscript(id: entry.id) } },
            onDeleteTap: {
                if player.currentId == entry.id { player.stop() }
                recorder.deleteHistory(id: entry.id)
            },
            onEditDate: { newDate in recorder.updateEntryDate(id: entry.id, date: newDate) },
            onEditTitle: { newTitle in recorder.updateEntryTitle(id: entry.id, title: newTitle) },
            onToggleNote: { recorder.toggleEntryNote(id: entry.id) }
        )
        // Phase-1 "card leaving" effect for merge: fade + small slide toward the
        // neighbour. The reflow (rows below sliding up) is List's native removal
        // reacting to the data change in animateMerge's phase 2.
        .offset(y: mergingId == entry.id ? (mergeEdge == .top ? -22 : 22) : 0)
        .opacity(mergingId == entry.id ? 0 : 1.0)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            // Order: first button sits nearest the edge. Delete first so a full
            // swipe deletes; then merge ↓, merge ↑. All icon-only.
            Button(role: .destructive) {
                if player.currentId == entry.id { player.stop() }
                recorder.deleteHistory(id: entry.id)
            } label: {
                SwipeDeleteLabel()
            }
            .tint(.red)

            if let targetId = downTargetId {
                Button {
                    if player.currentId == entry.id { player.stop() }
                    animateMerge(sourceId: entry.id, targetId: targetId, edge: .bottom)
                } label: {
                    Label("Merge down", systemImage: "arrow.down.to.line")
                }
                .labelStyle(.iconOnly)
                .tint(.gray)
            }
            if let targetId = upTargetId {
                Button {
                    if player.currentId == entry.id { player.stop() }
                    animateMerge(sourceId: entry.id, targetId: targetId, edge: .top)
                } label: {
                    Label("Merge up", systemImage: "arrow.up.to.line")
                }
                .labelStyle(.iconOnly)
                .tint(.gray)
            }
        }
    }

    // ── Reorder mode: whole-card drag (ported from ContentView's Habits drag) ──
    // A ScrollView+LazyVStack (NOT a List — List only drags from a handle). Every
    // card is grab-able via the shared UIKit ReorderLongPressGesture, which
    // coexists with the scroll pan (quick swipe scrolls, 0.25s hold grabs). Cards
    // are variable height, so we measure each row and drive the make-room offsets
    // and hit-test from real heights, not a constant rowHeight.
    private func reorderList(entries: [TranscriptEntry]) -> some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    let isDragging = draggingIndex == index
                    reorderRow(entry: entry)
                        .offset(y: offsetForRow(at: index, entries: entries))
                        .zIndex(isDragging ? 100 : 0)
                        .scaleEffect(isDragging ? 1.02 : 1.0)
                        .shadow(color: isDragging ? .black.opacity(0.35) : .clear,
                                radius: isDragging ? 14 : 0, y: isDragging ? 6 : 0)
                        // Make-room spring for non-dragged rows while a drag is in
                        // flight; nil at drop so the structural reorder commits
                        // instantly without a spring-back (same rule as Habits).
                        .animation((draggingIndex == nil || isDragging)
                                   ? nil
                                   : .interactiveSpring(response: 0.25, dampingFraction: 0.8),
                                   value: draggingOffset)
                        // Measure this row's height + global midY for the drag math.
                        .background(
                            GeometryReader { geo in
                                Color.clear
                                    .onAppear {
                                        rowHeights[entry.id] = geo.size.height
                                        rowMidYs[entry.id] = geo.frame(in: .global).midY
                                    }
                                    .onChange(of: geo.frame(in: .global).midY) { _, newY in
                                        rowMidYs[entry.id] = newY
                                    }
                                    .onChange(of: geo.size.height) { _, newH in
                                        rowHeights[entry.id] = newH
                                    }
                            }
                        )
                }
                Color.clear.frame(height: 100)
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
        }
        .scrollIndicators(.hidden)
        .scrollDisabled(draggingIndex != nil)
        .gesture(
            ReorderLongPressGesture(
                minimumPressDuration: 0.25,
                onBegan: { globalY in
                    guard let idx = rowIndex(atGlobalY: globalY, entries: entries) else { return }
                    // Freeze the resting centers NOW (before any .offset is
                    // applied) so the target/make-room math reads stable
                    // positions for the whole drag.
                    frozenMidYs = rowMidYs
                    dragSnapshot = entries
                    dragStartY = globalY
                    draggingIndex = idx
                    draggingOffset = 0
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                },
                onChanged: { globalY in
                    guard draggingIndex != nil else { return }
                    draggingOffset = globalY - dragStartY
                },
                onEnded: { _ in endReorderDrag(entries: entries) },
                onCancelled: { endReorderDrag(entries: entries) }
            )
        )
    }

    // One card in reorder mode: the SAME EntryRow visual, plus a decorative ≡
    // handle on the right (kept for now per the user — the whole card is the grab
    // target, the handle is just an affordance). Inert to taps (no expand / swipe
    // / context) — the only interaction is the drag.
    private func reorderRow(entry: TranscriptEntry) -> some View {
        HStack(spacing: 8) {
            EntryRow(
                entry: entry,
                isCurrentlyPlaying: false,
                isReloading: false,
                onPlayTap: {}, onReloadTap: {}, onDeleteTap: {},
                onEditDate: { _ in }, onEditTitle: { _ in },
                onToggleNote: {},
                interactive: false
            )
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.trailing, 4)
        }
        .contentShape(Rectangle())
    }

    // Hit-test: which visible row is the finger over, using measured global midYs
    // (variable-height-safe). Falls back to nil if nothing measured yet.
    private func rowIndex(atGlobalY y: CGFloat, entries: [TranscriptEntry]) -> Int? {
        var best: (idx: Int, dist: CGFloat)? = nil
        for (i, e) in entries.enumerated() {
            guard let mid = rowMidYs[e.id] else { continue }
            let d = abs(mid - y)
            if best == nil || d < best!.dist { best = (i, d) }
        }
        return best?.idx
    }

    // Live make-room offset for each row during a drag, using measured heights.
    // The dragged row follows the finger; rows between its origin and the current
    // target shift by the dragged row's height to open the gap.
    private func offsetForRow(at index: Int, entries: [TranscriptEntry]) -> CGFloat {
        guard let dragIdx = draggingIndex else { return 0 }
        if index == dragIdx { return draggingOffset }
        let target = targetIndex(entries: entries)
        let draggedH = (rowHeights[entries[dragIdx].id] ?? 80) + 10  // + LazyVStack spacing
        if dragIdx < target {
            if index > dragIdx && index <= target { return -draggedH }
        } else if dragIdx > target {
            if index >= target && index < dragIdx { return draggedH }
        }
        return 0
    }

    // Current landing index for the dragged row: the row whose FROZEN resting
    // center is closest to the dragged row's current visual center (frozen origin
    // + finger offset). Frozen centers avoid the target↔offset feedback loop.
    private func targetIndex(entries: [TranscriptEntry]) -> Int {
        guard let dragIdx = draggingIndex,
              let originMid = frozenMidYs[entries[dragIdx].id] else { return draggingIndex ?? 0 }
        let visualMid = originMid + draggingOffset
        var best = (idx: dragIdx, dist: CGFloat.greatestFiniteMagnitude)
        for (i, e) in entries.enumerated() {
            guard let mid = frozenMidYs[e.id] else { continue }
            let d = abs(mid - visualMid)
            if d < best.dist { best = (i, d) }
        }
        return best.idx
    }

    // Commit the drag: compute the new visible order and persist it (the store
    // renumbers sortIndex across all history; hidden rows stay pinned to their
    // visible neighbours). Clears drag state either way.
    private func endReorderDrag(entries: [TranscriptEntry]) {
        defer {
            draggingIndex = nil
            draggingOffset = 0
            dragSnapshot = nil
            dragStartY = 0
            frozenMidYs = [:]
        }
        guard let from = draggingIndex else { return }
        let to = targetIndex(entries: entries)
        guard to != from, from >= 0, from < entries.count, to >= 0, to < entries.count else { return }
        var ids = entries.map { $0.id }
        let moved = ids.remove(at: from)
        ids.insert(moved, at: to)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Task { await recorder.reorderHistory(orderedVisibleIds: ids) }
    }

    // Two-phase merge. Phase 1: flag the source row so it fades + slides toward
    // its target neighbour. Phase 2, after the animation: commit the merge into
    // the explicit target, letting List's native removal slide the rows below
    // up to close the gap. source/target are resolved from the visible list
    // (see row(...)) so it works under any tab filter.
    private func animateMerge(sourceId: UUID, targetId: UUID, edge: Edge) {
        mergeEdge = edge
        // Haptic fired here (already prepared in onAppear) so it lands at the
        // tap, not after the disk work; firing it cold or post-merge added its
        // own ~200ms Taptic warm-up to the perceived lag.
        mergeHaptic.notificationOccurred(.success)
        mergeHaptic.prepare()  // re-arm for the next merge
        // Phase 1 — brief render-only effect on the source row (fade + slide
        // toward the neighbour). This is NOT a layout collapse: scaleEffect /
        // offset don't reflow the List, so trying to "shrink the height" here
        // just leaves a gap while neighbours stay put (the bug we had). Keep it
        // short; its only job is to show the card leaving toward its target.
        withAnimation(.easeIn(duration: Self.mergePhase1)) {
            mergingId = sourceId
        }
        // Phase 2 — commit the data merge. mergeEntry is async: it does the
        // .wav concat + JSON I/O on a background task and animates the history
        // swap on the main actor (List's native row-removal slides everything
        // below up). Awaiting off the main thread is what removed the 0.5–1s
        // freeze at the start of the animation.
        Task {
            // Let the phase-1 leave animation play before committing (async
            // sleep — does NOT block the main thread the way the old
            // DispatchQueue.asyncAfter + sync I/O did).
            try? await Task.sleep(for: .seconds(Self.mergePhase1))
            await recorder.mergeEntry(sourceId: sourceId, targetId: targetId)
            mergingId = nil
        }
    }
}

// Delete button label for .swipeActions. At the normal reveal width it's just
// the trash glyph; when a full-swipe stretches the button across the row, the
// extra space would otherwise be empty red — so once the button is wide enough
// we show "Удалить запись" centred, with the trash pinned left. GeometryReader
// reads the button's own width (SwiftUI stretches the label to fill it).
private struct SwipeDeleteLabel: View {
    // Past this width the button is clearly in full-swipe (well beyond the
    // ~64pt a single icon button occupies), so reveal the text.
    private let textThreshold: CGFloat = 120

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= textThreshold
            ZStack {
                if wide {
                    Text("Удалить запись")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                Image(systemName: "trash")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: wide ? .leading : .center)
                    .padding(.leading, wide ? 24 : 0)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

// Applies a .contextMenu only when `enabled`. In reorder mode the History card
// must NOT carry a context menu — its long-press would compete with the reorder
// long-press recogniser. SwiftUI has no first-class "conditionally drop a
// modifier", so this wraps it: enabled → attach menu+preview; disabled → return
// the content untouched.
private struct ConditionalContextMenu: ViewModifier {
    let enabled: Bool
    let menu: () -> AnyView
    let preview: () -> AnyView

    func body(content: Content) -> some View {
        if enabled {
            content.contextMenu(menuItems: { menu() }, preview: { preview() })
        } else {
            content
        }
    }
}

// Divider drawn between two folded recordings in an expanded merged card. It
// marks where the join happened ("в месте склеивания отображался разделитель")
// so the user can see how the note was assembled. On copy the same join is just
// a blank line (plainText) — this is purely a visual reading aid. A thin hairline
// with a small centred merge glyph; vertical padding gives the two text blocks
// breathing room so the seam reads as a boundary, not part of either side.
private struct MergeSeam: View {
    var body: some View {
        HStack(spacing: 8) {
            line
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
            line
        }
        .padding(.vertical, 8)
        .accessibilityLabel("Место склейки")
    }

    private var line: some View {
        Rectangle()
            .fill(Color.white.opacity(0.14))
            .frame(height: 1)
    }
}

// ─── One history row ────────────────────────────────────────────────────

private struct EntryRow: View {
    let entry: TranscriptEntry
    let isCurrentlyPlaying: Bool
    let isReloading: Bool
    let onPlayTap: () -> Void
    let onReloadTap: () -> Void
    let onDeleteTap: () -> Void
    let onEditDate: (Date) -> Void
    let onEditTitle: (String?) -> Void
    let onToggleNote: () -> Void
    // When false (reorder mode) the card is purely visual: tap-to-expand, the
    // editable title/date chips, the copy button and the context menu are all
    // disabled so a drag is never mistaken for a tap. Defaults true so every
    // existing call site is unchanged.
    var interactive: Bool = true

    // Chat handoff: picker → POST → switch to the AI Chat tab. The router owns
    // progress/error (root-level, survives the tab switch); dismiss closes the
    // history sheet so the switch is visible.
    @EnvironmentObject private var router: TabRouter
    @ObservedObject private var chatStore = VoiceChatStore.shared
    @Environment(\.dismiss) private var dismissSheet
    @State private var showChatPicker = false

    // Briefly true right after a copy so the copy button shows a checkmark.
    @State private var isCopiedFlash = false
    @State private var expanded = false
    @State private var showDateEditor = false
    @State private var showTitleEditor = false
    // Audio length ("2:43" / "1:02:09"), shown in the footer for every entry
    // that has a .wav. Loaded once off the main thread in `.task(id:)` below and
    // cached here so scrolling/animation re-renders never stat the file. nil
    // when the entry has no audio (footer simply omits it).
    @State private var durationText: String? = nil

    // Collapsed preview line count. Was 6; the user asked for 3 so more
    // entries fit on screen at once. Tap the text (or the chevron) to expand
    // to the full transcript.
    private static let collapsedLineLimit = 3
    // Card corner radius — used by both the always-on background and the
    // context-menu preview so the corners never change shape on interaction.
    static let cardCornerRadius: CGFloat = 14

    // Drives the note-badge icon on the title chip — shown when the entry is a
    // note (explicit +Notes flag OR a custom title), per the model.
    private var hasCustomTitle: Bool { entry.isNote }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // ── Header: editable title chip (left) · copy button (right) ──
            // The date used to sit here; it moved to the bottom-right corner.
            // The copy button takes its place (same chip height/style) and
            // flips to a checkmark briefly when tapped.
            HStack(spacing: 6) {
                titleChip
                Spacer(minLength: 8)
                if isReloading {
                    ProgressView().controlSize(.mini).tint(.orange)
                }
                chatButton
                copyButton
            }

            // ── Transcript (tap to expand/collapse) ──
            // No withAnimation on the collapse: animating the line-limit change
            // makes the List re-measure the row mid-flight and yank the scroll
            // offset (the card jumps up then back down). An instant toggle
            // avoids the re-measure jitter the user reported on collapse.
            if entry.text.isEmpty {
                Text("(audio only — text was empty)")
                    .italic()
                    .foregroundStyle(.secondary)
            } else if expanded && entry.hasMergeSeams {
                // Expanded + merged: render each folded recording as its own
                // block with a MergeSeam divider between them, so the user can
                // see where the glue points are. Collapsed view and every copy/
                // title path use the flattened plainText instead — the seam is
                // purely a reading aid that costs one blank line on copy.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entry.textSegments.enumerated()), id: \.offset) { idx, seg in
                        if idx > 0 { MergeSeam() }
                        Text(seg)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { expanded.toggle() }
            } else {
                // Collapsed, or an unmerged entry: a single Text of the
                // flattened plainText (seams already shown as blank lines).
                // lineLimit caps the collapsed height; plainText == text for
                // entries that were never merged.
                Text(entry.plainText)
                    .font(.body)
                    .lineLimit(expanded ? nil : Self.collapsedLineLimit)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        expanded.toggle()
                    }
            }

            // ── Footer: Show more + char count + duration (left) · date (right) ──
            // Left cluster, in order:
            //   [⌄ Show more]  [charcount]  │  [m:ss]
            // Char count stays COUPLED to Show more (same >110 gate it always
            // had) — so a short note with no Show more shows JUST the duration
            // bottom-left (the user's
            // "если Show more не показывается, тогда просто длительность"). The
            // thin divider separates the char count from the duration, and only
            // appears when the char count is present.
            HStack(spacing: 8) {
                // Gate + char count use the flattened plainText so the
                // invisible merge marker(s) don't inflate the count or trip the
                // Show-more threshold (each seam is one control char).
                let plain = entry.plainText
                let showsMore = plain.count > 110
                if showsMore {
                    Button {
                        expanded.toggle()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.caption2.bold())
                            Text(expanded ? "Show less" : "Show more")
                                .font(.caption.bold())
                        }
                        .foregroundStyle(Color(hex: "8AB4F8"))
                    }
                    .buttonStyle(.plain)
                    // Total character count, right next to Show more.
                    Text("\(plain.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                }
                if let dur = durationText {
                    // Divider only when the char count sits to its left.
                    if showsMore {
                        Text("│")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.25))
                    }
                    Text(dur)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 8)
                dateChip
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        // Permanent rounded card background. Previously the rounded corners only
        // appeared during the long-press context-menu preview (iOS lifts the row
        // with rounded corners), so the card visibly jumped from square to
        // rounded on interaction. Giving it a constant rounded fill + clipShape
        // — and matching the contextMenu preview shape below — removes that
        // jump; the card is always rounded.
        .background(
            RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .clipShape(RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous))
        // In reorder mode (interactive == false) the card is inert: no tap-to-
        // expand, no chip edits, and crucially NO context menu — its long-press
        // would fight the reorder long-press. allowsHitTesting kills the inner
        // taps; the contextMenu is dropped entirely below.
        .allowsHitTesting(interactive)
        .modifier(ConditionalContextMenu(enabled: interactive,
                                         menu: { AnyView(contextMenuContent) },
                                         preview: { AnyView(previewCard) }))
        .sheet(isPresented: $showDateEditor) {
            DateEditorSheet(initialDate: entry.timestamp) { newDate in
                onEditDate(newDate)
            }
        }
        .sheet(isPresented: $showTitleEditor) {
            TitleEditorSheet(
                initialTitle: entry.title ?? "",
                placeholder: TranscriptEntry.deriveTitle(from: entry.text)
            ) { newTitle in
                onEditTitle(newTitle)
            }
        }
        // Compute the audio length once, off the main thread, keyed on the
        // audio path so a merge (which rewrites the .wav to a new path) reloads
        // it. Statting the file is cheap but it's still I/O — keeping it out of
        // the render path matches the "no sync I/O on main" rule that fixed the
        // merge-animation freeze (see fix-ios-stability.md::main-thread I/O).
        .task(id: entry.audioPath) {
            guard let path = entry.audioPath else { durationText = nil; return }
            let formatted = await Task.detached(priority: .utility) {
                Self.wavDurationString(path: path)
            }.value
            durationText = formatted
        }
    }

    // Exact duration of one of our .wav files from its byte size — every file we
    // write is 16 kHz s16le mono (see TranscriptStore.wavHeader), so
    // seconds = (fileSize − 44-byte header) / (16000 · 2 bytes). No need to open
    // an AVAudioFile: the format is fixed and the header is constant. nil if the
    // file is missing or smaller than a bare header. Runs off the main actor.
    nonisolated static func wavDurationString(path: String) -> String? {
        let bytesPerSecond = VoiceRecordConfig.targetSampleRate * 2  // mono s16le
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else { return nil }
        let pcmBytes = max(0, size.intValue - 44)
        let seconds = Double(pcmBytes) / bytesPerSecond
        guard seconds >= 0.5 else { return nil }  // sub-half-second → not worth showing
        return formatDuration(seconds)
    }

    // m:ss, or h:mm:ss once it crosses an hour. monospacedDigit at the call site
    // keeps it from wiggling as the seconds change width.
    nonisolated static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    // Context-menu items, extracted so the card can present them only when
    // interactive (reorder mode drops the whole menu).
    @ViewBuilder
    private var contextMenuContent: some View {
        if entry.audioPath != nil {
            Button(action: onPlayTap) {
                Label(isCurrentlyPlaying ? "Pause" : "Play",
                      systemImage: isCurrentlyPlaying ? "pause.fill" : "play.fill")
            }
        }
        if !entry.text.isEmpty {
            Button {
                UIPasteboard.general.string = copyPayload
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } label: { Label("Copy Text", systemImage: "doc.on.doc") }
        }
        Button(action: onToggleNote) {
            Label(entry.isNote ? "In Notes" : "Notes",
                  systemImage: entry.isNote ? "checkmark.circle.fill" : "note.text.badge.plus")
        }
        // Share the raw .wav file — lets the user send the audio to a Mac /
        // anywhere via the system share sheet. ShareLink with the file URL exports
        // the actual file, not a string.
        if let path = entry.audioPath {
            ShareLink(item: URL(fileURLWithPath: path)) {
                Label("Поделиться аудио", systemImage: "square.and.arrow.up")
            }
        }
        if entry.audioPath != nil {
            Button(action: onReloadTap) { Label("Return Scribble", systemImage: "arrow.clockwise") }
        }
        Button(role: .destructive, action: onDeleteTap) { Label("Delete", systemImage: "trash") }
    }

    // Editable title pill on the LEFT. Shows the user's custom title or the
    // auto-derived first words. No pencil glyph — the user knows it's editable
    // (same as the date chip). A [N] badge appears when this entry folds in
    // more than one original recording (after merges).
    private var titleChip: some View {
        Button {
            showTitleEditor = true
        } label: {
            HStack(spacing: 5) {
                // Curated notes get a small badge. Plain raw transcripts get none.
                if hasCustomTitle {
                    Image(systemName: "note.text")
                        .font(.caption2)
                        .foregroundStyle(.yellow.opacity(0.9))
                }
                Text(entry.displayTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                if entry.noteCount > 1 {
                    Text("[\(entry.noteCount)]")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Edit title")
    }

    // Date pill on the RIGHT. Tappable, opens the graphical date/time editor.
    // Pencil glyph removed at the user's request — the chip styling alone
    // signals it's editable.
    private var dateChip: some View {
        Button {
            showDateEditor = true
        } label: {
            Text(entry.timestamp.formatted(.dateTime.day().month().hour().minute()))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Edit date and time")
    }

    // Copy pill on the RIGHT of the header (where the date used to be). Same
    // chip height/style as the title/date chips; flips to a checkmark for a
    // moment after a tap to confirm. Copies the same payload as the context
    // menu's "Copy Text" (date header + blank line + transcript).
    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = copyPayload
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.easeOut(duration: 0.15)) { isCopiedFlash = true }
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(.easeOut(duration: 0.2)) { isCopiedFlash = false }
            }
        } label: {
            Image(systemName: isCopiedFlash ? "checkmark" : "doc.on.doc")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isCopiedFlash ? .green : .secondary)
                // Fixed icon box so the doc↔checkmark swap can't change the
                // chip's height/width — the two glyphs have different intrinsic
                // sizes, and letting them drive layout made the capsule (and the
                // whole List row) re-measure and jump up-then-down on each flip.
                .frame(width: 16, height: 16)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Copy text")
    }

    // Chat pill — sits LEFT of the copy pill on every card type. Opens the same
    // prompt picker as the Voice page's Chat button, then POSTs this entry's
    // text to the Mac and jumps to the AI Chat tab on the new conversation.
    // The history sheet is dismissed first so the tab switch is visible (the
    // root chatCreating capsule/alert live under the sheet otherwise).
    private var chatButton: some View {
        Button {
            guard !chatStore.offline, !router.chatCreating else { return }
            showChatPicker = true
        } label: {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .disabled(chatStore.offline || router.chatCreating)
        .opacity(chatStore.offline || router.chatCreating ? 0.45 : 1)
        .accessibilityLabel("Send to chat")
        .sheet(isPresented: $showChatPicker) {
            VoiceChatPromptPicker(
                onPick: { pid, vid, _ in
                    showChatPicker = false
                    sendToChat(promptId: pid, variationId: vid)
                },
                onSkip: {
                    showChatPicker = false
                    sendToChat(promptId: nil, variationId: nil)
                }
            )
            .presentationDetents([.medium, .large])
        }
    }

    private func sendToChat(promptId: String?, variationId: String?) {
        guard !chatStore.offline, !router.chatCreating else { return }
        // Close the history sheet so the root progress capsule + the eventual
        // tab switch are actually visible.
        dismissSheet()
        router.chatCreating = true
        Task {
            defer { router.chatCreating = false }
            do {
                let id = try await VoiceChatAPI.send(text: entry.plainText, promptId: promptId, variationId: variationId)
                router.openChat(id)
            } catch {
                router.chatCreateError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    // Clipboard payload for both the copy button and the context-menu copy:
    //   line 1: date: 2026-05-31 07:10:38
    //   line 2: <blank>
    //   line 3: <title>
    //   line 4: <transcript>
    private var copyPayload: String {
        // plainText, not text — merge seams become a single blank line in the
        // clipboard ("при копировании это будет обычный пробел, одна пустая
        // строка"); the in-app divider has no clipboard equivalent.
        "date: \(Self.copyDateFormatter.string(from: entry.timestamp))\n\n\(entry.displayTitle)\n\(entry.plainText)"
    }

    // Fixed yyyy-MM-dd HH:mm:ss stamp for the copy header (not locale-formatted
    // — the user asked for this exact shape).
    private static let copyDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    // Context-menu long-press preview. A simple titled card with the same
    // rounded shape as the row so the corners don't morph when the menu opens.
    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.displayTitle)
                .font(.headline)
                .foregroundStyle(.white)
            Text(entry.text.isEmpty ? "(audio only)" : entry.plainText)
                .font(.body)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(8)
        }
        .padding(16)
        .frame(maxWidth: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous)
                .fill(Color(white: 0.15))
        )
    }
}

// NOTE: a custom swipe-reveal with circular vertically-stacked buttons (and an
// optional full-swipe-to-delete) was prototyped here and worked, but it
// required moving off List to ScrollView+LazyVStack and hand-tuning widths /
// thresholds. The user reverted to native .swipeActions (icon-only) for
// reliability; the custom approach is documented as a viable-but-fiddly option.


// ─── Date editor sheet ──────────────────────────────────────────────────

private struct DateEditorSheet: View {
    let initialDate: Date
    let onSave: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date: Date

    init(initialDate: Date, onSave: @escaping (Date) -> Void) {
        self.initialDate = initialDate
        self.onSave = onSave
        _date = State(initialValue: initialDate)
    }

    var body: some View {
        NavigationStack {
            VStack {
                DatePicker(
                    "Date & time",
                    selection: $date,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.graphical)
                .padding()
                Spacer()
            }
            .navigationTitle("Edit date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(date)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// ─── Title editor sheet ─────────────────────────────────────────────────

private struct TitleEditorSheet: View {
    let initialTitle: String
    // The auto-derived title (first words of the transcript) — shown as the
    // text-field placeholder and used by "Reset to auto" so the user sees what
    // the default would be.
    let placeholder: String
    // Passes nil when the field is empty → store reverts to auto-derived.
    let onSave: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @FocusState private var focused: Bool

    init(initialTitle: String, placeholder: String, onSave: @escaping (String?) -> Void) {
        self.initialTitle = initialTitle
        self.placeholder = placeholder
        self.onSave = onSave
        _title = State(initialValue: initialTitle)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(placeholder, text: $title, axis: .vertical)
                        .focused($focused)
                        .lineLimit(1...3)
                } footer: {
                    Text("Leave empty to use the first words of the transcript.")
                }
                if !title.isEmpty {
                    Button("Reset to auto", role: .destructive) {
                        title = ""
                    }
                }
            }
            .navigationTitle("Edit title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(trimmed.isEmpty ? nil : trimmed)
                        dismiss()
                    }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.height(220), .medium])
    }
}

// ─── Persistent player bar shown when something is playing ──────────────

private struct PlayerBar: View {
    @ObservedObject var player: AudioPlayerController

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Button {
                    player.toggleCurrent()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text(player.currentTitle ?? "Playing")
                        .font(.caption.bold())
                        .lineLimit(1)
                        .foregroundStyle(.white)
                    Text(timeString(player.currentTime) + " / " + timeString(player.duration))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // Speed button — single tap cycles 1 → 1.5 → 2 → 2.5 → (wrap).
                // Sits just left of the close ✕. monospacedDigit + fixed width so
                // the label ("1.5×"/"2×") doesn't shift the close button as the
                // text width changes.
                Button {
                    player.cycleRate()
                } label: {
                    Text(VoiceRecordConfig.playbackRateLabel(player.rate))
                        .font(.caption.bold().monospacedDigit())
                        .frame(width: 44, height: 28)
                }
                .buttonStyle(.bordered)
                .tint(.blue)
                .accessibilityLabel("Playback speed \(VoiceRecordConfig.playbackRateLabel(player.rate))")
                Button {
                    player.stop()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .tint(.gray)
            }
            Slider(value: Binding(
                get: { player.currentTime },
                set: { player.seek(to: $0) }
            ), in: 0...max(player.duration, 0.1))
            .tint(.blue)
        }
        .padding(12)
        .background(.thinMaterial)
    }

    private func timeString(_ t: TimeInterval) -> String {
        let secs = max(0, Int(t))
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }
}

// ─── Player controller ──────────────────────────────────────────────────

@MainActor
final class AudioPlayerController: ObservableObject {
    @Published private(set) var currentId: UUID? = nil
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var currentTitle: String? = nil
    // Current playback speed of the active item. Seeded from the Settings
    // default on each new playback, then cycled by the speed button. Published
    // so the button label updates live.
    @Published private(set) var rate: Double = VoiceRecordConfig.playbackDefaultRateFallback

    private var player: AVAudioPlayer?
    private var tickTimer: Timer?
    private var delegateProxy: Delegate?

    // The Settings default, read fresh each playback so changing it in Settings
    // takes effect on the very next item without an app restart.
    private var defaultRate: Double {
        let d = AppGroupContainer.defaults
        let stored = d.object(forKey: VoiceRecordConfig.SharedKeys.playbackDefaultRate) as? Double
        return stored ?? VoiceRecordConfig.playbackDefaultRateFallback
    }

    func toggle(entry: TranscriptEntry) {
        if currentId == entry.id {
            toggleCurrent()
            return
        }
        stop()
        guard let path = entry.audioPath else { return }
        do {
            // Use a dedicated playback session so it doesn't fight with the
            // recording session if user later hits Record.
            try AVAudioSession.sharedInstance().setCategory(.playback,
                                                            mode: .default,
                                                            options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            let proxy = Delegate { [weak self] in self?.onFinishedPlaying() }
            p.delegate = proxy
            delegateProxy = proxy
            // Seed this playback from the Settings default. enableRate MUST be
            // set before play(), and rate re-applied AFTER play() — AVAudioPlayer
            // resets rate to 1.0 on play() unless it's assigned post-start.
            p.enableRate = true
            rate = defaultRate
            p.prepareToPlay()
            p.play()
            p.rate = Float(rate)
            player = p
            currentId = entry.id
            currentTitle = entry.timestamp.formatted(.dateTime.day().month().hour().minute())
            duration = p.duration
            isPlaying = true
            startTick()
        } catch {
            VRLog.e("Player", "load failed: \(error.localizedDescription)")
        }
    }

    func toggleCurrent() {
        guard let p = player else { return }
        if p.isPlaying {
            p.pause()
            isPlaying = false
        } else {
            p.play()
            // play() resets rate to 1.0 — restore the chosen speed right after.
            p.rate = Float(rate)
            isPlaying = true
        }
    }

    // Cycle the current item's speed by +0.5 on each tap: 1 → 1.5 → 2 → 2.5 →
    // back to 1 (no 3×). Applies live to the running player; the wrap from the
    // top back to 1.0 is the "клик на 2.5x возвращает на 1.0x" the user noted.
    func cycleRate() {
        let rates = VoiceRecordConfig.playbackRates
        let idx = rates.firstIndex(where: { abs($0 - rate) < 0.01 }) ?? 0
        rate = rates[(idx + 1) % rates.count]
        player?.rate = Float(rate)
    }

    func seek(to t: TimeInterval) {
        guard let p = player else { return }
        p.currentTime = max(0, min(t, p.duration))
        currentTime = p.currentTime
    }

    func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        player?.stop()
        player = nil
        delegateProxy = nil
        isPlaying = false
        currentId = nil
        currentTime = 0
        duration = 0
        currentTitle = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startTick() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player else { return }
                self.currentTime = p.currentTime
            }
        }
    }

    private func onFinishedPlaying() {
        currentTime = duration
        isPlaying = false
    }

    private final class Delegate: NSObject, AVAudioPlayerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            Task { @MainActor in self.onFinish() }
        }
    }
}
