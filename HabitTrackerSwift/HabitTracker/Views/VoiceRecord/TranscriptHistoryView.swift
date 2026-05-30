import AVFoundation
import SwiftUI

struct TranscriptHistoryView: View {
    @EnvironmentObject var recorder: RecordingCoordinator
    @Environment(\.dismiss) var dismiss
    @StateObject private var player = AudioPlayerController()

    var body: some View {
        NavigationStack {
            List {
                if recorder.history.isEmpty {
                    ContentUnavailableView(
                        "No recordings yet",
                        systemImage: "waveform",
                        description: Text("Recordings will appear here.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    let entries = recorder.history
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        EntryRow(
                            entry: entry,
                            isCurrentlyPlaying: player.currentId == entry.id,
                            isReloading: recorder.reloadingId == entry.id,
                            // newest-first list: a card can merge "up" with the
                            // one above it (index>0) and "down" with the one
                            // below it (index<last).
                            canMergeUp: index > 0,
                            canMergeDown: index < entries.count - 1,
                            onPlayTap: { player.toggle(entry: entry) },
                            onReloadTap: {
                                Task { await recorder.reloadTranscript(id: entry.id) }
                            },
                            onDeleteTap: {
                                if player.currentId == entry.id { player.stop() }
                                recorder.deleteHistory(id: entry.id)
                            },
                            onMergeUp: {
                                if player.currentId == entry.id { player.stop() }
                                recorder.mergeEntry(id: entry.id, direction: .up)
                            },
                            onMergeDown: {
                                if player.currentId == entry.id { player.stop() }
                                recorder.mergeEntry(id: entry.id, direction: .down)
                            },
                            onEditDate: { newDate in
                                recorder.updateEntryDate(id: entry.id, date: newDate)
                            },
                            onEditTitle: { newTitle in
                                recorder.updateEntryTitle(id: entry.id, title: newTitle)
                            }
                        )
                    }
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
        .onDisappear { player.stop() }
    }
}

// ─── One history row ────────────────────────────────────────────────────

private struct EntryRow: View {
    let entry: TranscriptEntry
    let isCurrentlyPlaying: Bool
    let isReloading: Bool
    let canMergeUp: Bool
    let canMergeDown: Bool
    let onPlayTap: () -> Void
    let onReloadTap: () -> Void
    let onDeleteTap: () -> Void
    let onMergeUp: () -> Void
    let onMergeDown: () -> Void
    let onEditDate: (Date) -> Void
    let onEditTitle: (String?) -> Void

    @State private var copiedFlashAt: Date? = nil
    @State private var expanded = false
    @State private var showDateEditor = false
    @State private var showTitleEditor = false

    // Collapsed preview line count. Was 6; the user asked for 3 so more
    // entries fit on screen at once. Tap the text (or the chevron) to expand
    // to the full transcript.
    private static let collapsedLineLimit = 3

    private var isCopiedFlash: Bool {
        guard let stamp = copiedFlashAt else { return false }
        return Date().timeIntervalSince(stamp) < 1.5
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // ── Header: editable title chip (left) · date chip (right) ──
            HStack(spacing: 6) {
                titleChip
                Spacer(minLength: 8)
                if isReloading {
                    ProgressView().controlSize(.mini).tint(.orange)
                }
                dateChip
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
                if entry.text.count > 110 {
                    HStack(spacing: 3) {
                        Button {
                            expanded.toggle()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                    .font(.caption2.bold())
                                Text(expanded ? "Show less" : "Show more")
                                    .font(.caption.bold())
                            }
                            // Brighter than the old .blue but not pure white —
                            // a light tint that reads as interactive without
                            // competing with the transcript.
                            .foregroundStyle(Color(hex: "8AB4F8"))
                        }
                        .buttonStyle(.plain)
                        Spacer(minLength: 8)
                        // Total character count, pushed to the trailing edge.
                        // Same colour family as the body text, just slightly
                        // dimmed so it's secondary but clearly readable.
                        Text("\(entry.text.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
            }

            // ── Action row: Play (left) · merge arrows (right) ──
            // Copy / Re-transcribe / Delete moved to the long-press context
            // menu (the user found the duplicated on-card buttons redundant).
            HStack(spacing: 10) {
                if entry.audioPath != nil {
                    iconButton(
                        systemName: isCurrentlyPlaying ? "pause.fill" : "play.fill",
                        tint: .blue,
                        action: onPlayTap
                    )
                }
                Spacer()
                // Merge with the card above (chronologically newer) / below
                // (older). Disabled at the list edges. Audio + text collapse
                // into one entry, date averaged. See Coordinator.mergeEntry.
                iconButton(
                    systemName: "arrow.up.to.line",
                    tint: .gray,
                    disabled: !canMergeUp,
                    action: onMergeUp
                )
                iconButton(
                    systemName: "arrow.down.to.line",
                    tint: .gray,
                    disabled: !canMergeDown,
                    action: onMergeDown
                )
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if !entry.text.isEmpty {
                Button {
                    UIPasteboard.general.string = entry.text
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } label: { Label("Copy Text", systemImage: "doc.on.doc") }
            }
            if entry.audioPath != nil {
                Button(action: onReloadTap) { Label("Return Scribble", systemImage: "arrow.clockwise") }
            }
            Button(role: .destructive, action: onDeleteTap) { Label("Delete", systemImage: "trash") }
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

    @ViewBuilder
    private func iconButton(systemName: String, tint: Color, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 36, height: 32)
        }
        .buttonStyle(.bordered)
        .tint(tint)
        .disabled(disabled)
    }
}

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
