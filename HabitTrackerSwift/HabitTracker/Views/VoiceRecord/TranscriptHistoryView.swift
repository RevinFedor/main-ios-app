import AVFoundation
import SwiftUI

// Top filter for the History list, in segmented-control order so the default
// sits in the middle:
//   • All    — every recording.
//   • Voices — raw voice recordings only: everything EXCEPT curated notes
//              (entries the user hasn't given a custom title). This is the
//              default tab.
//   • Notes  — only the entries the user curated with a custom title (the
//              yellow note-badge ones). An entry leaves Voices and appears
//              here the moment its title is edited.
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

    // The history filtered by the active tab. Voices = everything that is NOT
    // a note; Notes = only notes; All = everything. Note status is the model's
    // single source of truth (explicit +Notes flag OR a custom title).
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
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if player.currentId != nil {
                    PlayerBar(player: player)
                }
            }
        }
        .onAppear { mergeHaptic.prepare() }
        .onDisappear { player.stop() }
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
            onEditTitle: { newTitle in recorder.updateEntryTitle(id: entry.id, title: newTitle) }
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

    // Briefly true right after a copy so the copy button shows a checkmark.
    @State private var isCopiedFlash = false
    @State private var expanded = false
    @State private var showDateEditor = false
    @State private var showTitleEditor = false

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
            } else {
                Text(entry.text)
                    .font(.body)
                    .lineLimit(expanded ? nil : Self.collapsedLineLimit)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        expanded.toggle()
                    }
            }

            // ── Footer: Show more + char count (left) · date (right) ──
            // Date moved here from the header. The char count sits right next
            // to "Show more" (a couple of px gap) instead of at the far edge.
            HStack(spacing: 8) {
                if entry.text.count > 110 {
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
                    Text("\(entry.text.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
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
        .contextMenu {
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
            if entry.audioPath != nil {
                Button(action: onReloadTap) { Label("Return Scribble", systemImage: "arrow.clockwise") }
            }
            Button(role: .destructive, action: onDeleteTap) { Label("Delete", systemImage: "trash") }
        } preview: {
            // Match the card's own shape so the long-press preview doesn't morph
            // the corners.
            previewCard
        }
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
                // Shown only when the user gave this entry a custom title —
                // signals "this is a curated voice NOTE", not a raw transcript.
                // note.text reads as a written note; sized like the old mic
                // glyph (.caption2). The mic icon is intentionally NOT brought
                // back — this badge means something different.
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

    // Clipboard payload for both the copy button and the context-menu copy:
    //   line 1: date: 2026-05-31 07:10:38
    //   line 2: <blank>
    //   line 3: <title>
    //   line 4: <transcript>
    private var copyPayload: String {
        "date: \(Self.copyDateFormatter.string(from: entry.timestamp))\n\n\(entry.displayTitle)\n\(entry.text)"
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
            Text(entry.text.isEmpty ? "(audio only)" : entry.text)
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

    private var player: AVAudioPlayer?
    private var tickTimer: Timer?
    private var delegateProxy: Delegate?

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
            p.prepareToPlay()
            p.play()
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
            isPlaying = true
        }
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
