import ActivityKit
import AVFoundation
import Foundation
#if canImport(UIKit)
import UIKit
#endif

// Lifecycle wrapper around the SINGLE Activity<RecordingAttributes>.
// All calls run on MainActor — ActivityKit demands the foreground/main actor
// for request and update.
//
// Updates are throttled only for the preview-text stream (~1 per 2s); phase
// transitions always go through immediately.

@MainActor
final class RecordingActivityManager {
    static let shared = RecordingActivityManager()
    private(set) var current: Activity<RecordingAttributes>?
    private var lastPreviewUpdate: Date = .distantPast

    // iOS uses relevanceScore to decide which Live Activity gets the compact
    // Dynamic Island slot when multiple activities are active. Apple's default
    // is 0 — if we omit it on update(), our Activity will silently disappear
    // from the Island compact slot the moment a competing app (Яндекс.Доставка,
    // Uber, etc.) has any score. We always want recording to win, so we pin
    // the score to a very large constant on every emission.
    private static let pinnedRelevance: Double = 100.0

    // Tell iOS that updates are still "live" for up to 8 hours from the
    // last emission. Without staleDate the system treats the Activity as
    // possibly-stale at any moment, which can also push it out of the Island.
    private static func freshStaleDate() -> Date {
        Date().addingTimeInterval(8 * 60 * 60)
    }

    private var micSourceObserver: NSObjectProtocol?

    private init() {
        // Subscribe once for process lifetime. AudioSessionManager posts on
        // every effective (kind, name) transition (already deduped at source);
        // we silently update the Activity without alertConfiguration so the
        // user doesn't get a banner just because they switched mics mid-record.
        micSourceObserver = NotificationCenter.default.addObserver(
            forName: AudioSessionManager.micSourceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let info = note.userInfo,
                  let kindRaw = info["kind"] as? String,
                  let kind = RecordingAttributes.MicSourceKind(rawValue: kindRaw) else { return }
            let name = (info["name"] as? String) ?? ""
            Task { @MainActor [weak self] in
                await self?.setMicSource(kind: kind, name: name)
            }
        }
    }

    var areActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    // Persistent-idle Activity mode was removed: research (Gemini 3.1 Pro +
    // Apple ActivityKit docs) confirms that LiveActivityIntent.perform() is
    // foreground-equivalent for Activity.request() on iOS 17+, so no idle
    // workaround is needed. Keeping the flag as a permanent false avoids
    // touching every call site and any stale value in App-Group UserDefaults
    // from a previous build never re-enables the mode.
    var keepLiveActivityAlive: Bool { false }

    // The live Activity for this app, looked up globally — covers the case where
    // the widget-extension kickoff created one before THIS manager set `current`.
    private var liveActivity: Activity<RecordingAttributes>? {
        current ?? Activity<RecordingAttributes>.activities.first
    }

    // Ensure the Activity exists and stamp the current recording chrome onto it.
    // Adopts a widget-extension kickoff Activity instead of requesting a second,
    // which would cancel the in-flight Dynamic Island pop-out.
    @discardableResult
    func dictationStart(title: String = "Voice Record",
                        phase: RecordingAttributes.Phase = .starting) throws -> Activity<RecordingAttributes>? {
        if !areActivitiesEnabled {
            VRLog.d("LA", "dictationStart — activities disabled, skipping")
            return nil
        }
        let (micKind, micName) = AudioSessionManager.shared.currentMicSource()

        // ADOPT: reuse a pre-created Activity. Ending + recreating would cancel
        // any in-flight Dynamic Island pop-out the kickoff just played. We only
        // ever expect ONE LA for this app, so adopting .first is safe.
        if let pre = liveActivity {
            current = pre
            lastPreviewUpdate = .distantPast
            VRLog.d("LA", "dictationStart — adopted \(pre.id) prev_phase=\(pre.content.state.phase.rawValue)")
            // Reset the recording fields. Otherwise the adopted Activity keeps a
            // stale startedAt and Text(timerInterval:) can jump to an old elapsed
            // value. alertConfiguration forces the NC / Lock Screen to re-render
            // within ~1s instead of Apple's lazy 4-6s window.
            Task { [weak pre] in
                guard let pre else { return }
                var state = pre.content.state
                state.phase = phase
                state.startedAt = Date()
                state.isStreaming = false
                state.previewText = ""
                state.endedAt = nil
                state.micSourceKind = micKind
                state.micSourceName = micName
                let alert = AlertConfiguration(title: "Voice Record",
                                               body: "Запись началась",
                                               sound: .named(""))
                await pre.update(
                    ActivityContent(state: state,
                                    staleDate: Self.freshStaleDate(),
                                    relevanceScore: Self.pinnedRelevance),
                    alertConfiguration: alert
                )
                VRLog.d("LA", "dictationStart — adopt reset, phase=\(phase.rawValue) alerted")
            }
            observeState(pre)
            return pre
        }

        // No Activity yet → request a fresh one.
        let attrs = RecordingAttributes(sessionId: UUID(), title: title)
        let state = RecordingAttributes.ContentState(
            startedAt: Date(),
            isStreaming: false,
            endedAt: nil,
            previewText: "",
            phase: phase,
            micSourceKind: micKind,
            micSourceName: micName
        )
        let content = ActivityContent(state: state,
                                      staleDate: Self.freshStaleDate(),
                                      relevanceScore: Self.pinnedRelevance)
        let activity = try Activity.request(attributes: attrs, content: content, pushType: nil)
        current = activity
        lastPreviewUpdate = .distantPast
        VRLog.d("LA", "dictationStart — created \(activity.id) phase=\(phase.rawValue)")
        observeState(activity)
        return activity
    }

    private func observeState(_ activity: Activity<RecordingAttributes>) {
        Task { [weak activity] in
            guard let activity else { return }
            for await s in activity.activityStateUpdates {
                VRLog.d("LA", "activityState → \(s)")
            }
        }
    }

    // Snap the recording into a given phase immediately, bypassing any throttle.
    // For .recording / .stopping we attach an AlertConfiguration so iOS plays the
    // Dynamic Island pop-out expand-then-collapse animation.
    func setDictationPhase(_ phase: RecordingAttributes.Phase) async {
        guard let act = liveActivity else { return }
        current = act
        // An in-flight system dismissal can flip activityState before our
        // update lands; update() on a non-active Activity throws and crashes
        // the host. Skip safely.
        if act.activityState != .active { return }
        var state = act.content.state
        guard state.phase != phase else { return }
        state.phase = phase
        if phase == .stopping {
            // UI hides the timer when phase != .recording.
            state.isStreaming = false
        }
        // sound: .named("") = silent pop-out — Apple AlertConfiguration
        // requires a sound, but an empty name plays nothing.
        let alert: AlertConfiguration?
        switch phase {
        case .recording:
            alert = AlertConfiguration(title: "Voice Record",
                                       body: "Запись идёт", sound: .named(""))
        case .stopping:
            alert = AlertConfiguration(title: "Voice Record",
                                       body: "Запись остановлена", sound: .named(""))
        case .idle, .starting, .ended:
            alert = nil
        }
        await act.update(
            ActivityContent(state: state,
                            staleDate: Self.freshStaleDate(),
                            relevanceScore: Self.pinnedRelevance),
            alertConfiguration: alert
        )
        VRLog.d("LA", "setDictationPhase \(phase.rawValue) alert=\(alert != nil)")
    }

    func setStreaming(_ streaming: Bool) async {
        guard let act = liveActivity else { return }
        if act.activityState != .active { return }
        var state = act.content.state
        // Don't overwrite phase: streaming flips only while phase == .recording.
        guard state.phase == .recording else { return }
        state.isStreaming = streaming
        await act.update(ActivityContent(
            state: state,
            staleDate: Self.freshStaleDate(),
            relevanceScore: Self.pinnedRelevance
        ))
    }

    // Throttled — at most ~1 update per 2 seconds — so we don't burn the
    // per-app Live Activity update budget. Pass `force: true` to bypass.
    func setPreviewText(_ text: String, force: Bool = false) async {
        guard let act = liveActivity else { return }
        if act.activityState != .active { return }
        // Preview is a dictation concept — don't paint it while dictation idle.
        guard act.content.state.phase != .idle else { return }
        let now = Date()
        if !force, now.timeIntervalSince(lastPreviewUpdate) < 2.0 { return }
        lastPreviewUpdate = now
        var state = act.content.state
        state.previewText = trim(text)
        await act.update(ActivityContent(
            state: state,
            staleDate: Self.freshStaleDate(),
            relevanceScore: Self.pinnedRelevance
        ))
    }

    // Silently push a new mic source into the Activity's ContentState. No
    // alertConfiguration — switching mic shouldn't pop a Dynamic Island banner.
    func setMicSource(kind: RecordingAttributes.MicSourceKind, name: String) async {
        guard let act = liveActivity else { return }
        if act.activityState != .active { return }
        var state = act.content.state
        guard state.micSourceKind != kind || state.micSourceName != name else { return }
        state.micSourceKind = kind
        state.micSourceName = name
        await act.update(ActivityContent(
            state: state,
            staleDate: Self.freshStaleDate(),
            relevanceScore: Self.pinnedRelevance
        ))
        VRLog.d("LA", "setMicSource → \(kind.rawValue) \"\(name)\"")
    }

    // Finish the recording. Shows a brief alerted .ended pop-out, then dismisses.
    func dictationEnd(immediate: Bool = true) async {
        guard let act = liveActivity else { return }
        current = act
        if act.activityState != .active {
            VRLog.d("LA", "dictationEnd — not active (state=\(act.activityState)), clearing ref")
            current = nil
            return
        }
        // Alerted .ended frame (dictation pop-out confirmation) for ~1.5s.
        var endedState = act.content.state
        endedState.endedAt = Date()
        endedState.isStreaming = false
        endedState.phase = .ended
        let alert = AlertConfiguration(title: "Voice Record",
                                       body: "Готово — текст скопирован",
                                       sound: .named(""))
        await act.update(
            ActivityContent(state: endedState,
                            staleDate: Self.freshStaleDate(),
                            relevanceScore: Self.pinnedRelevance),
            alertConfiguration: alert
        )
        VRLog.d("LA", "dictationEnd — .ended pop-out fired")

        // Release the AVAudioSession only when the stop was a background AppIntent.
        // The Coordinator sets stopOriginatedFromIntent at handlePending entry;
        // applicationState is unreliable here.
        let fromIntent = RecordingCoordinator.shared.stopOriginatedFromIntent
        if fromIntent {
            try? AVAudioSession.sharedInstance().setActive(
                false, options: [.notifyOthersOnDeactivation])
            AudioSessionManager.shared.markInactive()
            VRLog.d("LA", "dictationEnd — session deactivated (intent stop, jetsam protection)")
        } else {
            VRLog.d("LA", "dictationEnd — in-app stop, keeping session active (no music gap)")
        }

        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await act.end(
            ActivityContent(state: endedState,
                            staleDate: Self.freshStaleDate(),
                            relevanceScore: Self.pinnedRelevance),
            dismissalPolicy: immediate ? .immediate : .default
        )
        current = nil
        VRLog.d("LA", "dictationEnd — dismissed")
    }

    // Best-effort cleanup of any Activity that survived a force-quit / crash.
    // Called from RecordingCoordinator.init on cold start.
    func endAllOrphans() async {
        let acts = Activity<RecordingAttributes>.activities
        guard !acts.isEmpty else { return }
        VRLog.d("LA", "endAllOrphans — found \(acts.count) orphan(s)")
        for a in acts {
            await a.end(nil, dismissalPolicy: .immediate)
        }
        current = nil
    }

    // Keep last ~120 chars — enough for 2-3 visible lines without forcing a
    // trailing truncation. SwiftUI's lineLimit + Text wrapping handles the
    // visual end-truncation, so we never inject our own trailing ellipsis.
    private func trim(_ text: String) -> String {
        let cap = 120
        if text.count <= cap { return text }
        return "…" + text.suffix(cap)
    }
}
