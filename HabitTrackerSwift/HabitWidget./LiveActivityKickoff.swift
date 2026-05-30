import ActivityKit
import Foundation

// Kicks off a Voice Record Live Activity from the widget extension process.
//
// Why this exists: when ToggleVoiceRecordingShortcutIntent.perform() runs,
// it runs in the WIDGET EXTENSION process. iOS will then launch the host
// app (openAppWhenRun=true) and route into RecordingCoordinator. By the
// time the coordinator's start() reaches Activity.request(), the host app
// is already in foreground — and Apple does NOT play the Dynamic Island
// pop-out animation if the requester is foreground. Result: users never
// see the satisfying "Island expands to a big banner for 2 seconds" cue
// that other apps (calls, Uber, Yandex Delivery) all show.
//
// Workaround: have the intent itself call Activity.request() BEFORE the
// app gets focus. The widget extension is considered background by the
// system, so the pop-out plays. When RecordingCoordinator boots, it looks
// up Activity<RecordingAttributes>.activities and adopts the one we
// pre-created instead of requesting a second.

@MainActor
enum LiveActivityKickoff {
    // Same constants as RecordingActivityManager — kept duplicated rather
    // than imported because this file must be widget-callable (no main-app
    // imports). They MUST agree.
    private static let pinnedRelevance: Double = 100.0
    private static func freshStaleDate() -> Date {
        Date().addingTimeInterval(8 * 60 * 60)
    }

    // Read the last mic source persisted by AudioSessionManager into App Group.
    // The widget extension process has no live AVAudioSession context — by the
    // time it calls Activity.request(), the host app might not have woken up
    // yet. Without this we'd seed ContentState.micSourceKind = .unknown and
    // the user would see a generic mic icon for the first ~1s until the host
    // app's manager subscribed and pushed the real value. Reading the App
    // Group mirror lets us render the correct source from the very first
    // frame of the Dynamic Island pop-out.
    private static func cachedMicSource() -> (RecordingAttributes.MicSourceKind, String) {
        let d = UserDefaults(suiteName: VoiceRecordConfig.appGroup)
        let raw = d?.string(forKey: VoiceRecordConfig.SharedKeys.lastMicSourceKind) ?? ""
        let kind = RecordingAttributes.MicSourceKind(rawValue: raw) ?? .unknown
        let name = d?.string(forKey: VoiceRecordConfig.SharedKeys.lastMicSourceName) ?? ""
        return (kind, name)
    }

    // Request an Activity unless one is already live for this app. Returns
    // the Activity ID on success, nil if activities are off / request
    // failed. Idempotent: safe to call multiple times — second call no-ops
    // if one is already running.
    @discardableResult
    static func requestIfNeeded(title: String = "Voice Record") -> String? {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            VRLog.d("Kickoff", "activities disabled, skip")
            return nil
        }
        if let existing = Activity<RecordingAttributes>.activities.first {
            VRLog.d("Kickoff", "existing activity \(existing.id) — update to .starting")
            // Persistent-Activity workaround: the Activity was created
            // earlier (foreground) in .idle phase precisely so that we can
            // update it from background here. ActivityKit allows update()
            // from background; only request() is forbidden. update() with
            // alertConfiguration triggers the Dynamic Island pop-out
            // animation even when called from a background-launched intent.
            Task {
                let alert = AlertConfiguration(
                    title: "Voice Record",
                    body: "Запись началась",
                    sound: .named("")
                )
                // Build a fresh ContentState rather than mutating the old
                // one. The adopted Activity may have lived for tens of
                // minutes in .idle — its old startedAt would make the
                // recording timer in Lock-Screen / Island jump to e.g.
                // "27:00" the moment the user toggles. Reset every field
                // that conveys session identity.
                let (micKind, micName) = cachedMicSource()
                let state = RecordingAttributes.ContentState(
                    startedAt: Date(),
                    isStreaming: false,
                    endedAt: nil,
                    previewText: "",
                    phase: .starting,
                    micSourceKind: micKind,
                    micSourceName: micName
                )
                await existing.update(
                    ActivityContent(
                        state: state,
                        staleDate: freshStaleDate(),
                        relevanceScore: pinnedRelevance
                    ),
                    alertConfiguration: alert
                )
                VRLog.d("Kickoff", "existing-activity alerted update sent (state reset)")
            }
            return existing.id
        }
        let attrs = RecordingAttributes(sessionId: UUID(), title: title)
        let (micKind, micName) = cachedMicSource()
        let state = RecordingAttributes.ContentState(
            startedAt: Date(),
            isStreaming: false,
            endedAt: nil,
            previewText: "",
            phase: .starting,
            micSourceKind: micKind,
            micSourceName: micName
        )
        let content = ActivityContent(
            state: state,
            staleDate: freshStaleDate(),
            relevanceScore: pinnedRelevance
        )
        do {
            let act = try Activity.request(attributes: attrs, content: content, pushType: nil)
            VRLog.d("Kickoff", "Activity.request OK id=\(act.id)")
            // Activity.request() alone does NOT trigger the Dynamic Island
            // pop-out (leading-edge expand) animation — iOS deliberately
            // silences it unless the developer explicitly opts in. The opt-in
            // mechanism is Activity.update(content:alertConfiguration:) with
            // a non-nil AlertConfiguration; that's the same banner Phone /
            // Maps / Uber show on their LA starts. We fire the alerted
            // update immediately after request so the user sees:
            //    pop-out banner (2-3s) → collapses into compact Island
            Task {
                // sound: .named("") (empty string) suppresses the alert
                // sound while still triggering the Dynamic Island pop-out
                // animation. Apple's API does not allow nil sound; the
                // empty-name init avoids the audible chime the user found
                // intrusive — silent pop-out is what they want.
                let alert = AlertConfiguration(
                    title: "Voice Record",
                    body: "Запись началась",
                    sound: .named("")
                )
                await act.update(
                    ActivityContent(
                        state: state,
                        staleDate: freshStaleDate(),
                        relevanceScore: pinnedRelevance
                    ),
                    alertConfiguration: alert
                )
                VRLog.d("Kickoff", "alerted update sent (pop-out trigger)")
            }
            return act.id
        } catch {
            VRLog.e("Kickoff", "Activity.request failed: \(error.localizedDescription)")
            return nil
        }
    }
}
