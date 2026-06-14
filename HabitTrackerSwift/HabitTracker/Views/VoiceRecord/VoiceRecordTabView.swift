import AVFoundation
import SwiftUI

struct VoiceRecordTabView: View {
    @EnvironmentObject var recorder: RecordingCoordinator
    @State private var showHistory = false
    @State private var showSettings = false
    // Voice Chat — the "Chat" action button seeds the voice-record Mac chat with
    // the just-recorded transcript. Flow: tap → bottom-sheet prompt picker →
    // POST /api/chat/send → switch to the AI Chat tab on the returned chatId.
    // chatTranscript is snapshotted at tap time so it survives the picker.
    @EnvironmentObject private var router: TabRouter
    @ObservedObject private var chatStore = VoiceChatStore.shared
    @State private var chatTranscript = ""
    @State private var showPromptPicker = false
    @State private var copiedFlashAt: Date? = nil
    // Locally-mirrored copy of recorder.notice so the banner can stay up for its
    // own dismiss window and animate out independently of the coordinator. We
    // copy on .onChange (keyed by notice.id so repeats re-trigger) and clear it
    // here after a delay; the coordinator's published value is just the signal.
    @State private var shownNotice: RecordingCoordinator.UserNotice? = nil
    @State private var noticeDismissTask: Task<Void, Never>? = nil
    // Live counter of lines currently in the debug log. Shown next to the
    // copy-log icon when devMode is on, so the user can tell at a glance
    // whether the log has been growing since the last clear. Refreshed on
    // every appear, on copy/clear taps, and once a second while view is on
    // screen so accumulating log lines bump the count without manual reload.
    @State private var logLineCount: Int = 0
    private let logCountTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    // Reactively bound to the same App-Group key VoiceSettingsSheet writes —
    // toggling it in Settings hides/shows the dev icons in the navbar live.
    @AppStorage(VoiceRecordConfig.SharedKeys.devMode, store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var devMode: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "1C1C1E").ignoresSafeArea()

                VStack(spacing: 0) {
                    transcriptArea
                    Spacer(minLength: 0)
                    if recorder.reloadingId != nil {
                        reloadingBadge
                            .padding(.bottom, 8)
                            .transition(.opacity)
                    }
                    HStack(spacing: 16) {
                        if recorder.dictationPhase != .idle {
                            cancelButton
                                .transition(.scale.combined(with: .opacity))
                        } else {
                            Color.clear.frame(width: 56, height: 56)
                        }
                        bigRecordButton
                        // Compact mic source picker — lives to the right of
                        // the big record button so the user can switch input
                        // (built-in / AirPods / USB) without diving into
                        // Settings. Shows the currently-active input port
                        // in real time via AudioSessionManager.
                        MicSourcePicker()
                    }
                    .padding(.bottom, 24)
                    .animation(.easeInOut(duration: 0.2), value: recorder.dictationPhase)
                }

                // Top verdict banner — green on a successful recording /
                // retranscribe, red on failure (no internet, token/WS error,
                // empty result). Anchored to the top so it reads as a system-
                // style notification dropping in, above all the content. Auto-
                // dismisses; tappable to dismiss early. Driven by recorder.notice.
                if let notice = activeNotice {
                    noticeBanner(notice)
                        .padding(.horizontal, 12)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: activeNotice)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(toolbarTitle)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(.white)
                    }
                }
                // Trailing trio (dev-mode shows two extra icons before History).
                // Adding items here shifts the centered principal title slightly
                // left, which is what we want when dev mode is on.
                if devMode {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            UIPasteboard.general.string = VRLog.readRecent(maxLines: 400)
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            logLineCount = VRLog.lineCount()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "doc.on.doc")
                                // Bare number, no parens — at-a-glance counter
                                // of lines accumulated since last clear. 0
                                // means "freshly cleared". Hidden until view
                                // first appears so we don't flash a stale
                                // value from a previous session.
                                Text("\(logLineCount)")
                                    .font(.caption.monospacedDigit())
                            }
                            .foregroundStyle(.white)
                        }
                        .accessibilityLabel("Copy debug log, \(logLineCount) lines")
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            VRLog.clear()
                            logLineCount = 0
                            UINotificationFeedbackGenerator().notificationOccurred(.warning)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .accessibilityLabel("Clear debug log")
                    }
                }
                // Audio session state — visible control over the one-time
                // music dip. Tap once to prewarm (deterministic, before the
                // first record) or to release back to the music app.
                ToolbarItem(placement: .navigationBarTrailing) {
                    AudioSessionIndicator()
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showHistory = true } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.white)
                    }
                }
            }
            .sheet(isPresented: $showHistory) {
                TranscriptHistoryView()
                    .environmentObject(recorder)
            }
            .sheet(isPresented: $showSettings) {
                VoiceSettingsSheet()
            }
            // Prompt picker as a BOTTOM SHEET (not fullscreen). Pick → send →
            // jump to the AI Chat tab. "Отправить без промпта" sends bare text.
            .sheet(isPresented: $showPromptPicker) {
                VoiceChatPromptPicker(
                    onPick: { pid, vid, _ in showPromptPicker = false; Task { await sendChat(promptId: pid, variationId: vid) } },
                    onSkip: { showPromptPicker = false; Task { await sendChat(promptId: nil, variationId: nil) } }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            // Progress + error for chat creation are presented at the ROOT
            // (RootTabView, via router) so they survive the tab switch to AI Chat.
        }
        .task {
            await requestMicPermissionIfNeeded()
            VoiceChatStore.shared.start()
            await recorder.handlePendingActionIfNeeded()
            logLineCount = VRLog.lineCount()
        }
        // Drive the verdict banner from the coordinator. Keyed on the notice
        // identity (a fresh UUID per post) so even an identical message repeats
        // the show+auto-dismiss. Error banners linger longer than success so the
        // user has time to read what went wrong.
        .onChange(of: recorder.notice) { _, newValue in
            guard let n = newValue else { return }
            noticeDismissTask?.cancel()
            shownNotice = n
            UINotificationFeedbackGenerator().notificationOccurred(
                n.kind == .success ? .success : .error
            )
            let lingerNs: UInt64 = n.kind == .success ? 2_200_000_000 : 4_000_000_000
            noticeDismissTask = Task {
                try? await Task.sleep(nanoseconds: lingerNs)
                if !Task.isCancelled, shownNotice?.id == n.id {
                    shownNotice = nil
                    recorder.clearNotice()
                }
            }
        }
        .onReceive(logCountTimer) { _ in
            // Polling once a second is cheap (a single Data load + byte scan
            // of a 200 KB rolling log) and avoids wiring a NotificationCenter
            // observer through VRLog. Only runs while view is on screen —
            // autoconnect's Publisher releases when the view disappears.
            guard devMode else { return }
            let n = VRLog.lineCount()
            if n != logLineCount { logLineCount = n }
        }
        .onChange(of: recorder.autoCopiedAt) { _, newValue in
            // Coordinator flips this when autoCopy kicks in. Mirror it as
            // a UI flash so the Copy button briefly says "Copied".
            if newValue != nil {
                copiedFlashAt = Date()
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if let stamp = copiedFlashAt, Date().timeIntervalSince(stamp) >= 1.4 {
                        copiedFlashAt = nil
                    }
                }
            }
        }
    }

    private var toolbarTitle: String {
        // The navbar reflects the DICTATION slot only — a long capture is
        // self-contained in its panel icon and must NOT show "Recording…" /
        // "Finalizing…" here. With parallel slots the navbar simply follows
        // dictationPhase; long never touches it.
        switch recorder.dictationPhase {
        case .idle:        return "Voice Record"
        case .starting:    return "Starting…"
        case .recording:   return "Recording…"
        case .stopping:
            // Surface the live finalize lag so the user knows we're still
            // waiting for Soniox to commit the tail of their speech, not
            // hung. Lag refreshed every 250ms from DictationSession; 0 in
            // the first quarter-second after Stop and once Soniox catches
            // up. See fact-voice-record.md::Stop & finalize lag.
            let lag = recorder.stoppingLagSeconds
            return lag >= 1 ? "Finalizing · \(Int(lag.rounded()))s tail" : "Finalizing…"
        case .finalizing:  return "Finalizing…"
        }
    }

    @ViewBuilder
    private var transcriptArea: some View {
        let combined = recorder.combinedTranscript
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let err = recorder.lastError, !err.isEmpty {
                        errorBanner(err)
                    }

                    if !combined.isEmpty {
                        // Dictation transcript (live or just-finished).
                        Text(combined)
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    } else if !recorder.isRecording {
                        // Truly idle (not recording, no transcript) → empty state.
                        VStack(spacing: 8) {
                            Image(systemName: "waveform")
                                .font(.system(size: 36))
                                .foregroundStyle(.tertiary)
                            Text("Swipe down the Control Center toggle\nor press the big button to dictate.")
                                .multilineTextAlignment(.center)
                                .font(.system(size: 14))
                                .foregroundStyle(Color(hex: "8E8E93"))

                            // Primary affordance for the empty state. Standard
                            // iOS neutral capsule (.bordered + grey tint) — same
                            // idiom as the PlayerBar stop button in History, not
                            // the loud filled-blue accent. Keeps the iOS pill
                            // background + shape the user wants, just not blue.
                            // Same icon as the toolbar History button so it's
                            // recognisably the same destination (past notes).
                            Button { showHistory = true } label: {
                                Label("Open History", systemImage: "clock.arrow.circlepath")
                                    .font(.system(size: 16, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .tint(.gray)
                            .padding(.top, 12)

                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    }

                    if recorder.isRecording {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(recorder.isWSConnected ? Color.green : Color.orange)
                                .frame(width: 8, height: 8)
                            Text(recorder.isWSConnected
                                 ? "Streaming to Soniox"
                                 : (recorder.bufferedSeconds > 0
                                    ? String(format: "Buffered %.1fs (offline)", recorder.bufferedSeconds)
                                    : "Connecting…"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if !recorder.isWSConnected {
                                Button("Retry") {
                                    Task { await recorder.retryWS() }
                                }
                                .font(.caption.bold())
                                .buttonStyle(.bordered)
                                .tint(.orange)
                            }
                        }
                    }

                    if !recorder.isRecording && !combined.isEmpty {
                        // Row 1: Copy / Notes / Share (left-aligned). Row 2: Chat,
                        // also left, normal size (not full-width). The trailing
                        // Spacer()s push the rows left inside the leading VStack.
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Button {
                                    UIPasteboard.general.string = combined
                                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                                    copiedFlashAt = Date()
                                    Task {
                                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                                        if let stamp = copiedFlashAt, Date().timeIntervalSince(stamp) >= 1.4 {
                                            copiedFlashAt = nil
                                        }
                                    }
                                } label: {
                                    if isCopiedFlash {
                                        Label("Copied", systemImage: "checkmark.circle.fill")
                                    } else {
                                        Label("Copy", systemImage: "doc.on.doc")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .tint(isCopiedFlash ? .green : .blue)
                                .animation(.easeInOut(duration: 0.15), value: isCopiedFlash)

                                // +Notes: promote the just-recorded entry to a note
                                // (its auto-derived title is kept). It's a toggle —
                                // once added it shows a filled/checked state, and a
                                // second tap removes it from Notes.
                                let isNote = recorder.lastEntryIsNote
                                Button {
                                    recorder.toggleLastEntryNote()
                                } label: {
                                    if isNote {
                                        Label("In Notes", systemImage: "checkmark.circle.fill")
                                    } else {
                                        Label("Notes", systemImage: "note.text.badge.plus")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .tint(isNote ? .yellow : .blue)
                                .animation(.easeInOut(duration: 0.15), value: isNote)

                                ShareLink(item: combined) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                                .buttonStyle(.bordered)
                                .tint(.blue)

                                Spacer(minLength: 0)   // keep Copy/Notes/Share left
                            }

                            // Chat — its own row, last, LEFT-aligned, normal size
                            // (not full-width). Snapshot `combined` NOW so it
                            // survives even if a new recording starts. Opens the
                            // prompt picker as a bottom sheet (not a fullscreen).
                            Button {
                                guard !chatStore.offline, !router.chatCreating else { return }
                                chatTranscript = combined
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                showPromptPicker = true
                            } label: {
                                Label("Chat", systemImage: "bubble.left.and.bubble.right")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color(hex: "7C3AED"))
                            .disabled(chatStore.offline || router.chatCreating)
                            .opacity(chatStore.offline || router.chatCreating ? 0.45 : 1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Color.clear.frame(height: 1).id("bottomAnchor")
                }
                .padding(16)
            }
            .onChange(of: combined) { _, _ in
                guard recorder.isRecording else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottomAnchor", anchor: .bottom)
                }
            }
            // When recording ends, the Copy / +Notes / Share row appears below
            // the transcript, making the content taller. Without this the view
            // stays scrolled where it was and those buttons end up clipped off
            // the bottom (the user had to scroll further by hand). Scroll to the
            // bottom anchor once the action row has laid out.
            .onChange(of: recorder.isRecording) { _, recording in
                guard !recording, !combined.isEmpty else { return }
                Task {
                    try? await Task.sleep(for: .seconds(0.05))
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("bottomAnchor", anchor: .bottom)
                    }
                }
            }
        }
    }

    private var isCopiedFlash: Bool {
        guard let stamp = copiedFlashAt else { return false }
        return Date().timeIntervalSince(stamp) < 1.5
    }

    // The notice currently being shown (local mirror, drives the banner).
    private var activeNotice: RecordingCoordinator.UserNotice? { shownNotice }

    // Top verdict banner. Green capsule for success, red for failure — same
    // visual family as the inline errorBanner but compact and self-dismissing.
    // Tap anywhere on it to dismiss early.
    private func noticeBanner(_ notice: RecordingCoordinator.UserNotice) -> some View {
        let ok = notice.kind == .success
        let tint: Color = ok ? .green : .red
        return HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .bold))
            Text(notice.message)
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.16))
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(tint.opacity(0.45), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            noticeDismissTask?.cancel()
            shownNotice = nil
            recorder.clearNotice()
        }
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel((ok ? "Успех: " : "Ошибка: ") + notice.message)
    }

    private var reloadingBadge: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini).tint(.orange)
            Text("Re-transcribing a history entry…")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(Color.orange.opacity(0.15))
                .overlay(Capsule().strokeBorder(Color.orange.opacity(0.4), lineWidth: 1))
        )
    }

    private func errorBanner(_ err: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption.bold())
                Text("Error")
                    .font(.caption.bold())
                Spacer()
                Button {
                    UIPasteboard.general.string = err
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .font(.caption2.bold())
                .buttonStyle(.bordered)
                .tint(.orange)
                Button {
                    recorder.clearError()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Text(err)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
                )
        )
        .foregroundStyle(.orange)
        .contextMenu {
            Button {
                UIPasteboard.general.string = err
            } label: { Label("Copy full error", systemImage: "doc.on.doc") }
        }
    }

    private var cancelButton: some View {
        Button {
            Task {
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                await recorder.cancel()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 56, height: 56)
                    .overlay(
                        Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                    )
                Image(systemName: "xmark")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cancel recording")
    }

    private var bigRecordButton: some View {
        // The big centre button starts/stops dictation.
        let dictationActive = recorder.isRecording
        return Button {
            guard !recorder.isBusy else { return }
            Task {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                await recorder.toggle()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(dictationActive ? Color.red : Color.blue)
                    .frame(width: 96, height: 96)
                    .shadow(color: (dictationActive ? Color.red : Color.blue).opacity(0.4), radius: 18, y: 6)
                if recorder.isBusy {
                    ProgressView()
                        .controlSize(.large)
                        .progressViewStyle(.circular)
                        .tint(.white)
                } else {
                    Image(systemName: dictationActive ? "stop.fill" : "mic.fill")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(recorder.isBusy)
        .accessibilityLabel(dictationActive ? "Stop recording" : "Start recording")
        .animation(.easeInOut(duration: 0.15), value: recorder.dictationPhase)
    }

    private func requestMicPermissionIfNeeded() async {
        if #available(iOS 17.0, *) {
            let status = AVAudioApplication.shared.recordPermission
            VRLog.d("UI", "mic permission status=\(status.rawValue)")
            guard status == .undetermined else { return }
            _ = await AVAudioApplication.requestRecordPermission()
            let newStatus = AVAudioApplication.shared.recordPermission
            VRLog.d("UI", "mic permission after request=\(newStatus.rawValue)")
        }
    }

    // ── Voice Chat ──
    // Pick (or skip) → POST the transcript + prompt → switch to the AI Chat tab on
    // the new conversation. Progress/error live on the router (presented at root)
    // so they survive the tab switch. Guarded against double-send: two fast taps
    // on the picker would otherwise fire two POSTs → two chats.
    private func sendChat(promptId: String?, variationId: String?) async {
        guard !chatStore.offline, !router.chatCreating else { return }
        router.chatCreating = true
        defer { router.chatCreating = false }
        do {
            let id = try await VoiceChatAPI.send(text: chatTranscript, promptId: promptId, variationId: variationId)
            router.openChat(id)
        } catch {
            router.chatCreateError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
