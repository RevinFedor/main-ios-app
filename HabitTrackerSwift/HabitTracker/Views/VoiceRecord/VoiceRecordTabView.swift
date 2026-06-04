import AVFoundation
import SwiftUI

struct VoiceRecordTabView: View {
    @EnvironmentObject var recorder: RecordingCoordinator
    @State private var showHistory = false
    @State private var showSettings = false
    @State private var copiedFlashAt: Date? = nil
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
                        // ✕ Cancel — slots in next to the big mic button while
                        // a session is active, so the user always has an
                        // escape hatch (e.g. if Stopping… hangs).
                        if recorder.phase != .idle {
                            cancelButton
                                .transition(.scale.combined(with: .opacity))
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
                    .animation(.easeInOut(duration: 0.2), value: recorder.phase)
                }
            }
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
        }
        .task {
            await requestMicPermissionIfNeeded()
            await recorder.handlePendingActionIfNeeded()
            logLineCount = VRLog.lineCount()
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
        switch recorder.phase {
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

                    if combined.isEmpty && !recorder.isRecording {
                        VStack(spacing: 8) {
                            Image(systemName: "waveform")
                                .font(.system(size: 36))
                                .foregroundStyle(.tertiary)
                            Text("Swipe down the Control Center toggle\nor press the big button to dictate.")
                                .multilineTextAlignment(.center)
                                .font(.system(size: 14))
                                .foregroundStyle(Color(hex: "8E8E93"))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    } else if !combined.isEmpty {
                        Text(combined)
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
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

                            ShareLink(item: combined) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.bordered)
                            .tint(.blue)
                        }
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
        Button {
            guard !recorder.isBusy else { return }
            Task {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                await recorder.toggle()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(buttonColor)
                    .frame(width: 96, height: 96)
                    .shadow(color: buttonColor.opacity(0.4), radius: 18, y: 6)
                if recorder.isBusy {
                    ProgressView()
                        .controlSize(.large)
                        .progressViewStyle(.circular)
                        .tint(.white)
                } else {
                    Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(recorder.isBusy)
        .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Start recording")
        .animation(.easeInOut(duration: 0.15), value: recorder.phase)
    }

    private var buttonColor: Color {
        switch recorder.phase {
        case .idle:        return .blue
        case .starting:    return .blue
        case .recording:   return .red
        case .stopping:    return .red
        case .finalizing:  return .red
        }
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
}
