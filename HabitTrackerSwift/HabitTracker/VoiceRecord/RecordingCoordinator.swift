import AVFoundation
import Combine
import Foundation
import UIKit
import WidgetKit

// App-process singleton orchestrating the whole recording pipeline.
// Owns DictationSession, RecordingActivityManager, and TranscriptStore.
// State changes are mirrored into the App Group so the ControlWidget's
// ControlValueProvider can read them.

@MainActor
final class RecordingCoordinator: ObservableObject {
    static let shared = RecordingCoordinator()

    enum Phase: Equatable {
        case idle
        case starting        // user tapped record, transitioning to streaming
        case recording
        case stopping        // user tapped stop, waiting for Soniox finalize
        case finalizing
    }

    @Published private(set) var phase: Phase = .idle {
        didSet {
            if oldValue != phase {
                VRLog.d("Coord", "phase \(oldValue) → \(phase)")
            }
        }
    }
    @Published private(set) var finalText: String = ""
    @Published private(set) var partialText: String = ""
    @Published private(set) var bufferedSeconds: Double = 0
    // Seconds of audio Soniox has NOT yet committed as is_final, refreshed
    // every 250ms while phase is .stopping. Drives the UI "Finalizing · 28s
    // tail" indicator so the user knows finalize is in flight, not hung. 0
    // outside the .stopping window. See DictationSession::stop().
    @Published private(set) var stoppingLagSeconds: Double = 0
    @Published private(set) var lastError: String?
    @Published private(set) var isWSConnected: Bool = false
    @Published private(set) var history: [TranscriptEntry] = []
    @Published private(set) var reloadingId: UUID? = nil
    @Published private(set) var autoCopiedAt: Date? = nil
    // True only while the current stop was triggered by a background AppIntent
    // (Action Button / Control Center / Shortcuts) — read by RecordingActivityManager.end()
    // to decide whether to deactivate AVAudioSession. applicationState is
    // unreliable for this distinction because LiveActivityIntent.perform()
    // temporarily marks the scene as .active even without a visible UI, so a
    // state check would always look "foreground" during a Shortcut stop. An
    // explicit flag set at the entry point of the background path is the only
    // reliable way to tell them apart.
    private(set) var stopOriginatedFromIntent: Bool = false

    private var session: DictationSession?
    private var reloadSession: ReloadSession?
    private var foregroundObserver: NSObjectProtocol?
    private var startingFallbackTask: Task<Void, Never>?
    // Resolved by didStopWith — lets stop() truly await until the engine
    // has finished and App-Group state is consistent. Required so the
    // ControlWidgetToggle's perform() doesn't return early (which would
    // cause the system to re-read currentValue() before our shared state
    // settled and snap the toggle back — WWDC24 10157).
    private var stopContinuation: CheckedContinuation<Void, Never>?

    private init() {
        history = TranscriptStore.shared.loadAll()
        syncSharedState(isRecording: false)
        installForegroundObserver()
        // Mark the cold-launch timestamp so a Shortcut intent fired in the
        // SAME process bootstrap (i.e. the intent that woke the app from
        // killed state) can tell itself apart from intents that re-entered
        // a still-alive backgrounded process. The intent uses this to decide
        // whether it needs to deactivate AVAudioSession before returning —
        // only the cold-launch path is at risk of jetsam 0x8badf00d.
        AppGroupContainer.defaults.set(
            Date().timeIntervalSince1970,
            forKey: VoiceRecordConfig.SharedKeys.lastColdLaunchTs
        )
        AppGroupContainer.defaults.synchronize()
        VRLog.d("Coord", "init — history=\(history.count) entries")
        // Force-quit while recording leaves the Live Activity dangling on the
        // Lock Screen / notification center. Phase is rebuilt as .idle by us
        // here, so any LA still on screen is by definition orphaned — kill it.
        Task { @MainActor in
            await RecordingActivityManager.shared.endAllOrphans()
        }
    }

    // Recording-in-progress for UI gating. Includes transitional states so
    // the big button shows a loader while we wait for connect/finalize.
    var isRecording: Bool {
        phase == .recording || phase == .finalizing || phase == .stopping
    }
    var isStarting: Bool { phase == .starting }
    var isStopping: Bool { phase == .stopping || phase == .finalizing }
    var isBusy: Bool { isStarting || isStopping }

    var combinedTranscript: String {
        if partialText.isEmpty { return finalText }
        if finalText.isEmpty { return partialText }
        return finalText + partialText
    }

    func toggle() async {
        VRLog.d("Coord", "toggle() phase=\(phase)")
        switch phase {
        case .idle:                    await start()
        case .recording:               await stop()
        case .starting, .stopping, .finalizing:
            VRLog.d("Coord", "toggle() ignored during phase=\(phase)")
        }
    }

    func start() async {
        guard phase == .idle else {
            VRLog.d("Coord", "start() ignored, phase=\(phase)")
            return
        }
        VRLog.d("Coord", "start() — go")
        finalText = ""
        partialText = ""
        bufferedSeconds = 0
        lastError = nil
        isWSConnected = false
        phase = .starting
        syncSharedState(isRecording: true, startedAt: Date())

        // Live Activity opens in .starting so the notification center / Dynamic
        // Island immediately shows a spinner — instant tactile feedback before
        // mic + Soniox finish handshaking. The user always sees activity on the
        // OS surfaces, never an empty pause.
        do {
            try RecordingActivityManager.shared.start(
                title: VoiceRecordConfig.liveActivityName,
                phase: .starting
            )
            VRLog.d("Coord", "Live Activity started in .starting")
        } catch {
            lastError = "Live Activity: \(error.localizedDescription)"
            VRLog.e("Coord", "Live Activity failed: \(error.localizedDescription)")
        }

        let s = DictationSession()
        s.delegate = self
        session = s
        // Hold .starting until WS is connected — so the big button stays
        // in spinner state instead of flipping to stop-icon before audio is
        // actually flowing.
        await s.start()

        // Fallback: if WS doesn't connect in 5s, flip to .recording anyway
        // (we're buffering locally; user shouldn't see the loader forever).
        startingFallbackTask?.cancel()
        startingFallbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self else { return }
            if self.phase == .starting {
                VRLog.d("Coord", "starting fallback fired — flip to .recording")
                self.phase = .recording
                await RecordingActivityManager.shared.setPhase(.recording)
            }
        }
    }

    func stop() async {
        // Accept stop from both .recording and .starting — user may panic-tap
        // before the WS connected, and they expect the same outcome.
        guard phase == .recording || phase == .starting else {
            VRLog.d("Coord", "stop() ignored, phase=\(phase)")
            return
        }
        VRLog.d("Coord", "stop() — go (awaiting finalize)")
        phase = .stopping
        // Flip the shared flag IMMEDIATELY so ControlValueProvider returns
        // false on the auto-reload that runs the moment perform() returns,
        // even if Soniox is slow to flush.
        syncSharedState(isRecording: false)
        // And flip the LA into .stopping right away — that's what the user
        // sees in the notification center / Dynamic Island and we promised
        // instant feedback.
        await RecordingActivityManager.shared.setPhase(.stopping)

        // Suspend until didStopWith resumes us. DictationSession.stop() now
        // waits up to 60 s for Soniox to drain its is_final tail (was 2 s,
        // which truncated transcripts longer than ~30 s — see voice-record's
        // fix-history-archive.md::Шрам #17). Our safety timer sits just
        // above that at 65 s so DictationSession's own hard-cap is the
        // primary resumer in every realistic case and we only fire on a
        // catastrophic stall in didStopWith itself.
        //
        // CRITICAL: only ONE thing may resume the continuation. session.stop()
        // returns ~immediately (it just sends the empty TEXT finalize frame
        // and arms a long watchdog); the actual finalisation is
        // delegate.didStopWith, fired either when ws closes naturally
        // (preferred) or when DictationSession's 60 s cap trips. So we set
        // the continuation BEFORE kicking session.stop(), and let didStopWith
        // be the SOLE resumer. Our 65 s safety timer atomically nils the
        // stored continuation before resuming, so a slow finalize landing
        // after the timer can't double-resume.
        //
        // Background-intent path note: Action-Button / Control Center wakes
        // are awaited inside `LiveActivityIntent.perform()`, which gets a
        // generous (~30 s nominal, longer in practice) execution assertion
        // from AppIntents — well past Soniox's typical finalize. We deliver
        // the transcript via `ReturnsValue<String>` once the continuation
        // resumes, so the Shortcuts pipeline still gets the full text.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            self.stopContinuation = c
            Task { @MainActor in
                await self.session?.stop()
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 65_000_000_000)
                guard let self else { return }
                if let cc = self.stopContinuation {
                    VRLog.d("Coord", "stop() — 65s safety timeout, resuming")
                    self.stopContinuation = nil
                    cc.resume()
                }
            }
        }
        self.stoppingLagSeconds = 0
        VRLog.d("Coord", "stop() — returned, phase=\(phase)")
    }

    // Hard cancel — drop pending audio, no transcript saved. Wired to the
    // ✕ button in the Live Activity so the user can always escape a stuck
    // Stopping… spinner.
    func cancel() async {
        guard phase != .idle else {
            VRLog.d("Coord", "cancel() ignored, phase=idle")
            return
        }
        VRLog.d("Coord", "cancel() — go from phase=\(phase)")
        phase = .stopping
        syncSharedState(isRecording: false)
        await RecordingActivityManager.shared.setPhase(.stopping)
        await session?.cancel()
        // didStopWith will fire from cancel() with empty pcm and tear down.
        // No transcript saved (handled in didStopWith below by pcm.isEmpty
        // && text.isEmpty branch).
    }

    func retryWS() async {
        await session?.retry()
    }

    func clearError() {
        lastError = nil
    }

    func deleteHistory(id: UUID) {
        TranscriptStore.shared.delete(id: id)
        history = TranscriptStore.shared.loadAll()
    }

    // Which neighbour a merge targets. history is sorted newest-first, so the
    // entry shown ABOVE a row is newer (index−1) and the one BELOW is older
    // (index+1). The arrow icons map to visual direction, not chronology.
    enum MergeDirection { case up, down }

    // Merge an entry with its visual neighbour (up = the card above, down =
    // the card below). No-op at the respective edge of the list. Store.merge
    // handles chronological text/audio concat + averaged date; we just resolve
    // the neighbour by position and refresh.
    func mergeEntry(id: UUID, direction: MergeDirection) {
        guard let idx = history.firstIndex(where: { $0.id == id }) else { return }
        let neighborIdx = direction == .up ? idx - 1 : idx + 1
        guard history.indices.contains(neighborIdx) else {
            VRLog.d("Coord", "merge \(direction) ignored — at edge (idx=\(idx))")
            return
        }
        let neighborId = history[neighborIdx].id
        VRLog.d("Coord", "merge \(direction): \(id) + \(neighborId)")
        TranscriptStore.shared.merge(id, neighborId)
        history = TranscriptStore.shared.loadAll()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    // Change a history entry's timestamp (from the date editor sheet). Resorts.
    func updateEntryDate(id: UUID, date: Date) {
        TranscriptStore.shared.updateTimestamp(id: id, date: date)
        history = TranscriptStore.shared.loadAll()
        VRLog.d("Coord", "updateEntryDate: \(id) → \(date)")
    }

    // Set/clear a history entry's custom title (from the title editor sheet).
    // nil/empty reverts to the auto-derived first-words title.
    func updateEntryTitle(id: UUID, title: String?) {
        TranscriptStore.shared.updateTitle(id: id, title: title)
        history = TranscriptStore.shared.loadAll()
        VRLog.d("Coord", "updateEntryTitle: \(id) → \(title ?? "<auto>")")
    }

    // Called by intent perform() (when in-app process) AND from foreground
    // notification (when intent perform() was routed elsewhere or just didn't
    // run). Both paths converge here.
    func handlePendingActionIfNeeded() async {
        let d = AppGroupContainer.defaults
        guard let action = d.string(forKey: VoiceRecordConfig.SharedKeys.pendingAction) else {
            VRLog.d("Coord", "handlePending: no pending action")
            return
        }
        let ts = d.double(forKey: VoiceRecordConfig.SharedKeys.pendingActionTs)
        let age = Date().timeIntervalSince1970 - ts
        VRLog.d("Coord", "handlePending: action=\(action) age=\(String(format: "%.1f", age))s")
        // Clear before acting so re-entries don't loop.
        d.removeObject(forKey: VoiceRecordConfig.SharedKeys.pendingAction)
        d.removeObject(forKey: VoiceRecordConfig.SharedKeys.pendingActionTs)
        d.synchronize()
        // Drop stale actions (>60s) — don't accidentally re-start something
        // from yesterday's session.
        if age > 60 {
            VRLog.d("Coord", "handlePending: action too old, ignored")
            return
        }
        switch action {
        case "start":
            if phase == .idle { await start() }
        case "stop":
            if phase == .recording || phase == .starting {
                // ANY stop reaching handlePending originated from an AppIntent
                // (Action Button / Control Center / Shortcuts). The in-app
                // record button calls toggle() directly without writing to
                // App-Group pendingAction, so it never lands here. Therefore
                // every code path through this branch needs setActive(false)
                // to dodge jetsam 0x8badf00d — even when the app's scene is
                // currently foregroundActive, because the Action Button
                // tap puts our scene behind the Shortcuts host briefly and
                // iOS still suspends us if we hold an active mic session.
                // The earlier foreground-detection attempts (appState==.active
                // and connectedScenes checks) were unreliable: applicationState
                // can read .active during LiveActivityIntent bootstrapping,
                // and scene.activationState lags by a runloop turn.
                stopOriginatedFromIntent = true
                VRLog.d("Coord", "handlePending stop — fromIntent=true (intent path is always background-equivalent)")
                await stop()
                // Cleared in didStopWith after end() has consumed the flag.
            }
        case "cancel":
            if phase != .idle { await cancel() }
        default:
            VRLog.d("Coord", "handlePending: unknown action=\(action)")
        }
    }

    // Re-transcribe a saved .wav by streaming its PCM into a fresh Soniox WS.
    // Runs in parallel with main recording — does NOT touch AVAudioSession or
    // phase. Only `reloadingId` flips so the UI can show a spinner on the
    // specific history row.
    func reloadTranscript(id: UUID) async {
        guard reloadSession == nil,
              let entry = history.first(where: { $0.id == id }),
              let path = entry.audioPath,
              let pcm = pcmFromWav(at: path) else {
            VRLog.d("Coord", "reload: precondition failed for \(id) (already reloading? \(reloadSession != nil))")
            return
        }
        VRLog.d("Coord", "reload: starting for \(id) (\(pcm.count) bytes)")
        reloadingId = id
        lastError = nil
        let s = ReloadSession()
        reloadSession = s
        let result = await s.run(pcm: pcm)
        reloadSession = nil
        reloadingId = nil
        switch result {
        case .success(let newText):
            TranscriptStore.shared.updateText(id: id, text: newText)
            history = TranscriptStore.shared.loadAll()
            UIPasteboard.general.string = newText
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            VRLog.d("Coord", "reload: ok — \(newText.count) chars")
        case .failure(let err):
            lastError = "reload: \(err.localizedDescription)"
            VRLog.e("Coord", "reload failed: \(err.localizedDescription)")
        }
    }

    private func pcmFromWav(at path: String) -> Data? {
        guard let blob = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        guard blob.count > 44 else { return nil }
        return blob.subdata(in: 44..<blob.count)
    }

    private func syncSharedState(isRecording: Bool, startedAt: Date? = nil) {
        let d = AppGroupContainer.defaults
        d.set(isRecording, forKey: VoiceRecordConfig.SharedKeys.isRecording)
        if let startedAt {
            d.set(startedAt.timeIntervalSince1970, forKey: VoiceRecordConfig.SharedKeys.recordingStartDate)
        } else if !isRecording {
            d.removeObject(forKey: VoiceRecordConfig.SharedKeys.recordingStartDate)
        }
        d.synchronize()
        VRLog.d("Coord", "syncSharedState isRecording=\(isRecording)")
        WidgetCenter.shared.reloadAllTimelines()
        if #available(iOS 18.0, *) {
            // reloadControls(ofKind:) is cheaper than reloadAllControls() —
            // we only need our own kind refreshed (WWDC24 10157 reload-budget
            // guidance).
            ControlCenter.shared.reloadControls(ofKind: VoiceRecordConfig.controlKind)
        }
    }

    // Closes the force-quit-while-recording desync gap. On any foreground or
    // first-launch tick, compare what App Group says vs. what the engine is
    // actually doing. If they disagree (e.g., user killed the app via the
    // switcher while recording, so AVAudioEngine died but isRecording flag is
    // still true), force the flag down and reload the control so Control
    // Center stops showing the red "Recording" state. This is the
    // community-recommended mitigation acknowledged on the Apple Developer
    // Forums ("ControlWidgetToggle state when parent app is terminated") —
    // there's no Apple-blessed terminate hook for Controls.
    func reconcileWithControlAfterForeground() {
        let d = AppGroupContainer.defaults
        let persisted = d.bool(forKey: VoiceRecordConfig.SharedKeys.isRecording)
        // .stopping is EXPLICITLY excluded — stop() already set persisted=false
        // and is about to call didStopWith. If reconcile sees stopping and flips
        // the flag back to true, it races with didStopWith and crashes the app
        // (observed when Action-Button / Control-Center toggles re-foreground
        // the app during a stop-in-progress: 19:06:35 logs showed
        // "persisted=false but engine recording — restoring" landing between
        // stop() at 19:06:33 and didStopWith at 19:06:35, after which the
        // process died and a new one cold-launched).
        let actuallyRunning = phase == .recording || phase == .starting
        if persisted && !actuallyRunning && phase != .stopping {
            VRLog.d("Coord", "reconcile: persisted=true but engine idle — clearing + killing LA")
            syncSharedState(isRecording: false)
            // Any LA visible right now is by definition orphaned (we are
            // .idle but it's still on screen). End it so the user isn't
            // staring at a phantom "Recording" notification forever.
            Task { await RecordingActivityManager.shared.endAllOrphans() }
        } else if !persisted && actuallyRunning {
            // Far less likely path, but possible if someone wiped UserDefaults.
            VRLog.d("Coord", "reconcile: persisted=false but engine recording — restoring")
            syncSharedState(isRecording: true, startedAt: Date())
        }
    }

    private func installForegroundObserver() {
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                VRLog.d("Coord", "willEnterForeground — check pending + reconcile")
                self?.reconcileWithControlAfterForeground()
                self?.flushPendingClipboard()
                // No prewarm here either — the next real recording start
                // will lazily activate the session. Foreground entry must
                // not interrupt background music.
                await self?.handlePendingActionIfNeeded()
            }
        }
    }

    // Drain stashed transcript into UIPasteboard once the scene is active.
    // Stashed by didStopWith when the stop happened with the app in
    // background (Shortcut toggle from Lock Screen / Action Button) — those
    // contexts can't reliably write to UIPasteboard. Foreground flush
    // catches it next time the user opens any app and returns to ours,
    // or any other app and the system later forwards the read.
    func flushPendingClipboard() {
        let d = AppGroupContainer.defaults
        guard let text = d.string(forKey: VoiceRecordConfig.SharedKeys.pendingClipboardText),
              !text.isEmpty else { return }
        UIPasteboard.general.string = text
        self.autoCopiedAt = Date()
        d.removeObject(forKey: VoiceRecordConfig.SharedKeys.pendingClipboardText)
        d.removeObject(forKey: VoiceRecordConfig.SharedKeys.pendingClipboardTs)
        d.synchronize()
        VRLog.d("Coord", "flushPendingClipboard: wrote \(text.count) chars to pasteboard")
    }
}

extension RecordingCoordinator: DictationSessionDelegate {
    nonisolated func dictation(_ session: DictationSession, didUpdate update: DictationUpdate) {
        Task { @MainActor in
            self.finalText = update.final
            self.partialText = update.partial
            await RecordingActivityManager.shared.setPreviewText(self.combinedTranscript)
        }
    }

    nonisolated func dictation(_ session: DictationSession, didError message: String) {
        Task { @MainActor in
            self.lastError = message
            VRLog.e("Coord", "dictation error: \(message)")
        }
    }

    nonisolated func dictation(_ session: DictationSession, didStopWith pcm: Data) {
        Task { @MainActor in
            VRLog.d("Coord", "didStopWith pcm=\(pcm.count) bytes")
            let text = (self.finalText + self.partialText).trimmingCharacters(in: .whitespacesAndNewlines)
            var savedAudioPath: String? = nil
            if !pcm.isEmpty {
                savedAudioPath = TranscriptStore.shared.saveWav(pcm: pcm)
            }
            // Auto-copy is gated by user setting. Default ON for first launches.
            let d = AppGroupContainer.defaults
            let autoCopyKey = VoiceRecordConfig.SharedKeys.autoCopyAfterStop
            let autoCopy: Bool = (d.object(forKey: autoCopyKey) as? Bool) ?? true
            if !text.isEmpty && autoCopy {
                // Always stash — even when the foreground pasteboard write
                // succeeds, having a stash means we can re-flush if the
                // user pulls down NC and copies something else before
                // returning to the app. Cheap.
                d.set(text, forKey: VoiceRecordConfig.SharedKeys.pendingClipboardText)
                d.set(Date().timeIntervalSince1970, forKey: VoiceRecordConfig.SharedKeys.pendingClipboardTs)
                d.synchronize()
                let appState = UIApplication.shared.applicationState
                if appState == .active {
                    UIPasteboard.general.string = text
                    self.autoCopiedAt = Date()
                    VRLog.d("Coord", "autoCopy: wrote pasteboard (foreground), \(text.count) chars")
                } else {
                    // Background / inactive: UIPasteboard writes from a
                    // LiveActivityIntent perform() context are unreliable.
                    // Leave the text in the stash — flushPendingClipboard()
                    // on next willEnterForeground will write it.
                    VRLog.d("Coord", "autoCopy: stashed for foreground flush (state=\(appState.rawValue)), \(text.count) chars")
                }
            }
            if !text.isEmpty || savedAudioPath != nil {
                TranscriptStore.shared.append(text: text, audioPath: savedAudioPath)
                self.history = TranscriptStore.shared.loadAll()
            }
            // Always-active session pattern: never deactivate. Only re-apply
            // category if the user recorded with AirPods-mic (HFP) — that flip
            // releases the AirPods radio link back to A2DP for music. For the
            // iPhone-mic case it's a no-op (already on A2DP-only).
            AudioSessionManager.shared.reconfigureForCurrentTarget()
            await RecordingActivityManager.shared.end(immediate: true)
            // Flag consumed by end() — clear before any later stops can
            // accidentally inherit it.
            self.stopOriginatedFromIntent = false
            self.session = nil
            self.phase = .idle
            self.isWSConnected = false
            self.syncSharedState(isRecording: false)
            // Resume stop() — it was awaiting on us so the toggle's
            // perform() can now return with App-Group state already
            // consistent.
            if let c = self.stopContinuation {
                self.stopContinuation = nil
                c.resume()
            }
        }
    }

    nonisolated func dictationDidConnect(_ session: DictationSession) {
        Task { @MainActor in
            self.isWSConnected = true
            self.startingFallbackTask?.cancel()
            self.startingFallbackTask = nil
            if self.phase == .starting {
                self.phase = .recording
            }
            VRLog.d("Coord", "WS connected — phase=\(self.phase)")
            await RecordingActivityManager.shared.setPhase(.recording)
            await RecordingActivityManager.shared.setStreaming(true)
        }
    }

    nonisolated func dictation(_ session: DictationSession, didDisconnectReason reason: String) {
        Task { @MainActor in
            self.isWSConnected = false
            self.lastError = "disconnected: \(reason)"
            VRLog.d("Coord", "WS disconnected: \(reason)")
            await RecordingActivityManager.shared.setStreaming(false)
        }
    }

    nonisolated func dictation(_ session: DictationSession, didUpdateBufferedSeconds seconds: Double) {
        Task { @MainActor in self.bufferedSeconds = seconds }
    }

    nonisolated func dictation(_ session: DictationSession, didUpdateStoppingLagSeconds seconds: Double) {
        Task { @MainActor in self.stoppingLagSeconds = seconds }
    }
}
