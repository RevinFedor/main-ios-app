import ActivityKit
import AVFoundation
import Foundation
#if canImport(UIKit)
import UIKit
#endif

// Lifecycle wrapper around Activity<RecordingAttributes>.
// All calls run on MainActor — ActivityKit demands the foreground/main actor
// for request and update.
//
// Design contract: every state transition in the app's coordinator must call
// into here so the Lock Screen + Dynamic Island always reflect reality.
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

    // True if user opted into the persistent Live Activity mode. When ON
    // we keep an Activity alive in .idle phase between recordings so that
    // background-launched toggle intents can UPDATE (allowed) instead of
    // REQUEST (forbidden from background) — which is what makes the
    // Dynamic Island pop-out animation possible on toggle.
    // Persistent-idle Activity mode was removed: research (Gemini 3.1 Pro +
    // Apple ActivityKit docs) confirms that LiveActivityIntent.perform() is
    // foreground-equivalent for Activity.request() on iOS 17+, so no idle
    // workaround is needed. Keeping the flag as a permanent false avoids
    // touching every call site and any stale value in App-Group UserDefaults
    // from a previous build never re-enables the mode.
    var keepLiveActivityAlive: Bool { false }

    // Start an "idle" Activity so the user gets a persistent Dynamic Island
    // hook and toggle intents can later update it from background. Cheap:
    // no audio, no Soniox, no timers — just an ActivityContent in .idle
    // phase. Foreground-only by ActivityKit policy (request() forbidden
    // from background), so the call sites are RootTabView.onAppear and
    // the toggle-on action when keep-alive is enabled.
    @discardableResult
    func startIdle(title: String = "Voice Record") -> Activity<RecordingAttributes>? {
        guard keepLiveActivityAlive else { return nil }
        guard areActivitiesEnabled else {
            VRLog.d("LA", "startIdle — activities disabled")
            return nil
        }
        if let existing = Activity<RecordingAttributes>.activities.first {
            current = existing
            VRLog.d("LA", "startIdle — adopted existing \(existing.id)")
            return existing
        }
        let attrs = RecordingAttributes(sessionId: UUID(), title: title)
        let (micKind, micName) = AudioSessionManager.shared.currentMicSource()
        let state = RecordingAttributes.ContentState(
            startedAt: Date(),
            isStreaming: false,
            endedAt: nil,
            previewText: "",
            phase: .idle,
            micSourceKind: micKind,
            micSourceName: micName
        )
        let content = ActivityContent(
            state: state,
            staleDate: Self.freshStaleDate(),
            relevanceScore: Self.pinnedRelevance
        )
        do {
            let act = try Activity.request(attributes: attrs, content: content, pushType: nil)
            current = act
            VRLog.d("LA", "startIdle — created \(act.id)")
            Task { [weak act] in
                guard let act else { return }
                for await s in act.activityStateUpdates {
                    VRLog.d("LA", "activityState → \(s)")
                }
            }
            return act
        } catch {
            VRLog.e("LA", "startIdle — failed: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func start(title: String = "Voice Record", phase: RecordingAttributes.Phase = .starting) throws -> Activity<RecordingAttributes>? {
        if !areActivitiesEnabled {
            VRLog.d("LA", "start — activities disabled, skipping")
            return nil
        }
        let priorOwn = Activity<RecordingAttributes>.activities.count
        VRLog.d("LA", "start — own prior activities=\(priorOwn) sysAuth=\(areActivitiesEnabled)")
        // ADOPT: if widget extension already created an Activity via
        // LiveActivityKickoff (the pop-out workaround), reuse it instead of
        // ending + recreating. Ending the freshly-popped Activity here would
        // cancel the in-flight Dynamic Island animation that the user just
        // saw — they'd see a flash and an empty Island, defeating the whole
        // point of pre-creation. We only ever expect ONE LA for this app at
        // a time, so adopting Activity.activities.first is safe.
        if let pre = Activity<RecordingAttributes>.activities.first {
            current = pre
            lastPreviewUpdate = .distantPast
            VRLog.d("LA", "start — adopted pre-created activity \(pre.id) prev_phase=\(pre.content.state.phase.rawValue)")
            // Reset startedAt and force the requested phase. Otherwise the
            // adopted Activity keeps its old startedAt (set when the idle
            // Activity was first created — possibly tens of minutes ago),
            // and Text(timerInterval:) in the Live Activity UI then shows
            // "27:00" the moment recording begins. Bug observed when toggle
            // fires 27 minutes after the previous session — timer in
            // Notification Center jumped straight to that figure.
            // Use alertConfiguration so the Notification Center / Lock
            // Screen surface re-renders within ~1s instead of Apple's lazy
            // 4-6s lazy-update window — that's the "appears 6s after tap"
            // behaviour the user reported.
            let (micKind, micName) = AudioSessionManager.shared.currentMicSource()
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
                    ActivityContent(
                        state: state,
                        staleDate: Self.freshStaleDate(),
                        relevanceScore: Self.pinnedRelevance
                    ),
                    alertConfiguration: alert
                )
                VRLog.d("LA", "adopt — reset state, phase=\(phase.rawValue) alerted")
            }
            Task { [weak pre] in
                guard let pre else { return }
                for await s in pre.activityStateUpdates {
                    VRLog.d("LA", "activityState → \(s)")
                }
            }
            return pre
        }
        // Clean any orphan activities from a previous crashed session before
        // requesting a fresh one. Note: this branch only runs when no
        // pre-created Activity exists from the extension — i.e., a manual
        // app launch flow rather than the Toggle-from-Shortcuts path.
        for stale in Activity<RecordingAttributes>.activities {
            VRLog.d("LA", "start — ending stale activity \(stale.id)")
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
        let attrs = RecordingAttributes(sessionId: UUID(), title: title)
        let (micKind, micName) = AudioSessionManager.shared.currentMicSource()
        let state = RecordingAttributes.ContentState(
            startedAt: Date(),
            isStreaming: false,
            endedAt: nil,
            previewText: "",
            phase: phase,
            micSourceKind: micKind,
            micSourceName: micName
        )
        let content = ActivityContent(
            state: state,
            staleDate: Self.freshStaleDate(),
            relevanceScore: Self.pinnedRelevance
        )
        let activity = try Activity.request(attributes: attrs, content: content, pushType: nil)
        current = activity
        lastPreviewUpdate = .distantPast
        VRLog.d("LA", "start — activity \(activity.id) phase=\(phase.rawValue) relevance=\(Self.pinnedRelevance) state=\(activity.activityState)")
        // Observe activityState transitions in background. iOS may push our
        // activity into .stale / .dismissed silently if it decides another
        // app's activity wins the compact Island slot. Logging this gives a
        // hard yes/no signal: stayed .active = our problem (state/style), got
        // .stale or .dismissed within 2-3s = system override / another app
        // priority / iCloud Focus mode / battery shaping.
        Task { [weak activity] in
            guard let activity else { return }
            for await s in activity.activityStateUpdates {
                VRLog.d("LA", "activityState → \(s)")
            }
        }
        return activity
    }

    // Snap the activity into a given phase immediately, bypassing any throttle.
    // Cheap to call — Apple's update API is async + budget-aware, but phase
    // transitions are infrequent enough that calling on every coordinator
    // state change is fine.
    //
    // For .recording (start finished) and .stopping (stop initiated) we
    // attach an AlertConfiguration so iOS plays the Dynamic Island pop-out
    // expand-then-collapse animation. This matches Phone / Maps / Uber
    // behavior: a clear visual cue at each phase transition. Without the
    // alert, updates silently mutate the compact view but never expand,
    // and the user feels "did anything happen?".
    func setPhase(_ phase: RecordingAttributes.Phase) async {
        guard let act = current else { return }
        // Same race as end(): an in-flight system dismissal can flip
        // activityState before our update lands; calling update() on a
        // non-active Activity throws and crashes the host. Skip safely.
        if act.activityState != .active { return }
        var state = act.content.state
        guard state.phase != phase else { return }
        state.phase = phase
        if phase == .stopping {
            // Stop the timer "moving" by collapsing the visible interval.
            // (We can't really pause Text(timerInterval:) — but UI hides the
            // timer when phase != .recording.)
            state.isStreaming = false
        }
        // sound: .named("") = silent pop-out — Apple AlertConfiguration
        // requires a sound, but an empty name plays nothing. User wanted
        // the Dynamic Island pop-out without the notification chime.
        let alert: AlertConfiguration?
        switch phase {
        case .recording:
            alert = AlertConfiguration(title: "Voice Record",
                                       body: "Запись идёт",
                                       sound: .named(""))
        case .stopping:
            alert = AlertConfiguration(title: "Voice Record",
                                       body: "Запись остановлена",
                                       sound: .named(""))
        case .idle, .starting, .ended:
            alert = nil
        }
        await act.update(
            ActivityContent(
                state: state,
                staleDate: Self.freshStaleDate(),
                relevanceScore: Self.pinnedRelevance
            ),
            alertConfiguration: alert
        )
        VRLog.d("LA", "setPhase \(phase.rawValue) alert=\(alert != nil)")
    }

    func setStreaming(_ streaming: Bool) async {
        guard let act = current else { return }
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
    // per-app Live Activity update budget. Pass `force: true` to bypass
    // (e.g., on a state transition).
    func setPreviewText(_ text: String, force: Bool = false) async {
        guard let act = current else { return }
        if act.activityState != .active { return }
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
    // alertConfiguration — switching mic shouldn't pop a Dynamic Island banner,
    // it's a quiet status mirror in Lock Screen / NC / Island expanded.
    // Skipped when the Activity isn't active (system dismissed it) — same
    // guard as setPhase / setStreaming.
    func setMicSource(kind: RecordingAttributes.MicSourceKind, name: String) async {
        guard let act = current else { return }
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

    func end(immediate: Bool = true) async {
        guard let act = current else { return }
        // The Activity may have been dismissed by the system or another path
        // already (e.g. an alertConfiguration banner from setPhase(.stopping)
        // can trigger a stale → dismissed transition that races with our
        // explicit end() call). update()/end() on a non-active Activity throws
        // an ActivityKit exception that crashes the host app. Bail safely
        // when we've already lost the Activity.
        if act.activityState != .active {
            VRLog.d("LA", "end — Activity not active (state=\(act.activityState)), skipping")
            if !keepLiveActivityAlive { current = nil }
            return
        }
        // If user opted into persistent Live Activity — don't actually end
        // the Activity; rewind it to .idle. This is what makes background-
        // launched toggle intents (openAppWhenRun=false) able to update the
        // Activity on next start without first having to request() a new
        // one from foreground — request() is forbidden from background by
        // ActivityKit, but update() of an existing Activity is allowed.
        if keepLiveActivityAlive {
            // Two-step rewind: first show an alerted .ended frame so the
            // user gets a clear "done" pop-out (with their copy-to-clipboard
            // hint), THEN after ~1.5s silently slide back to .idle. Without
            // the .ended frame the user sees the .stopping banner vanish
            // into nothing — confusing, because Shortcut runs in background
            // and there is no in-app screen to confirm completion.
            var endedState = act.content.state
            endedState.endedAt = Date()
            endedState.isStreaming = false
            endedState.phase = .ended
            let alert = AlertConfiguration(title: "Voice Record",
                                           body: "Готово — текст скопирован",
                                           sound: .named(""))
            await act.update(
                ActivityContent(
                    state: endedState,
                    staleDate: Self.freshStaleDate(),
                    relevanceScore: Self.pinnedRelevance
                ),
                alertConfiguration: alert
            )
            VRLog.d("LA", "end — kept alive, .ended pop-out fired")
            // Hold the .ended frame visible for ~1.5s before sliding to
            // idle. Inline sleep (not fire-and-forget Task) so the
            // process stays awake long enough — perform() awaits this
            // chain and gives us the foreground assertion window we
            // need. Fire-and-forget would race with iOS suspending the
            // widget extension after perform() returns.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let idleState = RecordingAttributes.ContentState(
                startedAt: Date(),
                isStreaming: false,
                endedAt: nil,
                previewText: "",
                phase: .idle
            )
            await act.update(ActivityContent(
                state: idleState,
                staleDate: Self.freshStaleDate(),
                relevanceScore: Self.pinnedRelevance
            ))
            VRLog.d("LA", "end — rewound to .idle")
            return
        }
        // Show a brief alerted .ended frame ("Готово — скопировано") for
        // ~1.5s BEFORE actually ending the Activity. Without the alerted
        // update the user has no visual confirmation that the stop landed —
        // the .stopping banner just vanishes. With it: Dynamic Island
        // pop-out + Lock Screen banner showing the success state, then a
        // clean dismissal. Inline sleep — the intent's perform() awaits
        // this chain and gives us a foreground assertion window.
        var endedState = act.content.state
        endedState.endedAt = Date()
        endedState.isStreaming = false
        endedState.phase = .ended
        let alert = AlertConfiguration(title: "Voice Record",
                                       body: "Готово — текст скопирован",
                                       sound: .named(""))
        await act.update(
            ActivityContent(
                state: endedState,
                staleDate: Self.freshStaleDate(),
                relevanceScore: Self.pinnedRelevance
            ),
            alertConfiguration: alert
        )
        VRLog.d("LA", "end — .ended pop-out fired")
        // Release the AVAudioSession ONLY when the stop was triggered by a
        // background AppIntent (Action Button / Control Center / Shortcuts).
        // The Coordinator sets stopOriginatedFromIntent at handlePending entry
        // so we can tell apart background-stop (needs deactivation to dodge
        // jetsam 0x8badf00d during suspension) from in-app stop (must NOT
        // deactivate to avoid the ~1s music gap from a hardware audio-graph
        // flush). applicationState is unreliable here — LiveActivityIntent
        // perform() temporarily flips the scene to .active even without UI.
        let fromIntent = RecordingCoordinator.shared.stopOriginatedFromIntent
        if fromIntent {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
            AudioSessionManager.shared.markInactive()
            VRLog.d("LA", "end — session deactivated (intent stop, jetsam protection)")
        } else {
            VRLog.d("LA", "end — in-app stop, keeping session active (no music gap)")
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await act.end(
            ActivityContent(
                state: endedState,
                staleDate: Self.freshStaleDate(),
                relevanceScore: Self.pinnedRelevance
            ),
            dismissalPolicy: immediate ? .immediate : .default
        )
        current = nil
        VRLog.d("LA", "end — dismissed")
    }

    // Best-effort cleanup of any Activity that survived a force-quit /
    // crash. Called from RecordingCoordinator.init on cold start.
    func endAllOrphans() async {
        let acts = Activity<RecordingAttributes>.activities
        guard !acts.isEmpty else { return }
        VRLog.d("LA", "endAllOrphans — found \(acts.count) orphan(s)")
        for a in acts {
            await a.end(nil, dismissalPolicy: .immediate)
        }
        current = nil
    }

    // Keep last ~120 chars — enough for 2-3 visible lines without forcing
    // a trailing truncation. SwiftUI's lineLimit + Text wrapping handles the
    // visual end-truncation, so we never inject our own trailing ellipsis
    // (otherwise we'd see "...тут текст..." with two ellipses).
    private func trim(_ text: String) -> String {
        let cap = 120
        if text.count <= cap { return text }
        return "…" + text.suffix(cap)
    }
}
