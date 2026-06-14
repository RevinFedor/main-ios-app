import AppIntents
import Foundation
#if canImport(UIKit) && !WIDGET_EXTENSION
import UIKit
import AVFoundation
#endif

// One-tap toggle intent for the iPhone's Action Button (15 Pro+) and the
// Shortcuts app. Same contract as ToggleVoiceRecordingIntent but takes no
// parameters — it reads current state from the App Group and flips it.
//
// Conforms to AudioRecordingIntent so the system runs perform() in the main
// app process and can cold-launch from terminated state (Apple DTS thread
// 761677). No openAppWhenRun — see note in VoiceRecordIntents.swift.

// Conforming to BOTH AudioRecordingIntent and LiveActivityIntent is the
// documented Apple pattern for running an audio-recording AppIntent in the
// HOST APP PROCESS (not the widget extension) with a process-lifetime
// extension covering perform() return → audio session active. Source:
// Apple AppIntents docs ("If you adopt the LiveActivityIntent or
// AudioPlaybackIntent protocol, the system runs the app intent in the
// app's process") + Michael Gorbach (App Intents team, Apple) on Mastodon
// confirming AudioIntent/LiveActivityIntent runs in app, in background.
//
// Why both:
//   • AudioRecordingIntent: signals to the system this action is recording
//   • LiveActivityIntent:   runs in app process; Activity.request() is
//                           permitted from this perform() context EVEN if
//                           the app is not foreground; process is kept
//                           alive while an Activity is live.
// Three-part fix for the 2-3s post-perform process kill + clipboard-from-
// background workaround. Per Gemini 3.1 Pro research + Apple Developer Forums
// + Reddit r/iOSProgramming consensus:
//   1. NO manual beginBackgroundTask. The AppIntents framework provides an
//      execution assertion for the duration of async perform() automatically.
//      Manually invalidating ours right before return races with iOS's process
//      suspension logic.
//   2. AVAudioSession.setActive(false) BEFORE perform() returns on the STOP
//      path. The always-active session pattern is fine while the app is alive,
//      but when an Action-Button intent triggers stop from killed-state cold
//      launch, the process gets suspended immediately on perform return — and
//      iOS watchdog SIGKILLs suspended apps that still hold an active recording
//      session (jetsam reason 0x8badf00d). Releasing the session lets the app
//      suspend safely.
//   3. RETURN the transcript as an IntentResult & ReturnsValue<String>. This
//      is the ONLY iOS-26-safe way to put text on the system clipboard from a
//      background-launched intent: a background AppIntent cannot write
//      UIPasteboard.general directly (silently no-ops without a connected
//      UIScene), but the SHORTCUTS APP itself can. The user binds the Action
//      Button to a Shortcut that runs this intent and pipes the result into
//      the built-in "Copy to Clipboard" action; Shortcuts then writes the
//      pasteboard with elevated system privilege.
@available(iOS 18.0, *)
public struct ToggleVoiceRecordingShortcutIntent: AudioRecordingIntent, LiveActivityIntent {
    public static var title: LocalizedStringResource = "Toggle Voice Record"
    public static var description: IntentDescription = IntentDescription(
        "Start or stop voice dictation. On stop, returns the transcript — pipe it into Shortcuts' Copy to Clipboard action."
    )
    // openAppWhenRun=false so we don't pop the user into the app UI on
    // every toggle — LiveActivityIntent conformance keeps us in-process.
    public static var openAppWhenRun: Bool { false }

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let d = UserDefaults(suiteName: VoiceRecordConfig.appGroup)
        let currentlyRecording = d?.bool(forKey: VoiceRecordConfig.SharedKeys.isRecording) ?? false
        let action = currentlyRecording ? "stop" : "start"
        VRLog.d("Intent", "Shortcut toggle perform() — currentlyRecording=\(currentlyRecording) → \(action)")

        // Persist the action immediately so the Coordinator can pick it up
        // regardless of what happens to perform() execution context.
        d?.set(action, forKey: VoiceRecordConfig.SharedKeys.pendingAction)
        d?.set(Date().timeIntervalSince1970, forKey: VoiceRecordConfig.SharedKeys.pendingActionTs)
        d?.set(true, forKey: VoiceRecordConfig.SharedKeys.wantsVoiceTab)
        d?.synchronize()

        #if !WIDGET_EXTENSION
        // We're guaranteed to be in the host app's process here because of
        // LiveActivityIntent conformance — Apple routes the intent into the
        // app rather than the widget extension. From a killed start this
        // means a cold launch already happened by the time we hit this line.

        await RecordingCoordinator.shared.handlePendingActionIfNeeded()

        if action == "start" {
            // Wait for the full start sequence so the audio session and
            // recording are actually live BEFORE perform returns. The
            // AppIntents framework's own assertion covers us here.
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                // The Shortcut/Action-Button toggle drives the DICTATION slot
                // (long has no intent entry point), so we wait on dictationPhase.
                let phase = await RecordingCoordinator.shared.dictationPhase
                if phase == .recording { break }
                if phase == .idle { break } // user-cancel mid-await
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            VRLog.d("Intent", "perform() wait-for-recording done")
            return .result(value: "")
        } else {
            // Wait for engine + Live Activity to fully finalise.
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                let phase = await RecordingCoordinator.shared.dictationPhase
                if phase == .idle { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            VRLog.d("Intent", "perform() wait-for-idle done")

            // Pull the just-finalised transcript out of the App-Group stash
            // that didStopWith populated. This is the value Shortcuts will
            // pipe to its "Copy to Clipboard" action.
            let transcript = d?.string(forKey: VoiceRecordConfig.SharedKeys.pendingClipboardText) ?? ""
            // The Shortcut pipeline takes over from here — we can clear the
            // stash so a later foreground flush doesn't redundantly rewrite
            // the same clipboard value.
            if !transcript.isEmpty {
                d?.removeObject(forKey: VoiceRecordConfig.SharedKeys.pendingClipboardText)
                d?.removeObject(forKey: VoiceRecordConfig.SharedKeys.pendingClipboardTs)
                d?.synchronize()
            }
            VRLog.d("Intent", "perform() — returning transcript len=\(transcript.count) for Shortcuts pipeline")

            // Note: NO setActive(false) here. The session is now released
            // INSIDE RecordingActivityManager.end() — but conditionally,
            // only when applicationState != .active. This is the
            // single-point-of-truth deactivation:
            //   • Shortcut stop (app backgrounded/suspended): end() sees
            //     non-active state → deactivates → no jetsam kill, music
            //     gap is hidden under the LA "Готово" pop-out animation.
            //   • In-app stop (app foreground/active): end() sees active
            //     state → does NOT deactivate → zero music interruption.
            // Putting the gate inside end() also synchronises the gap with
            // the visible Live Activity .ended pop-out, so the user
            // experiences the audio dropout as part of the success
            // animation rather than an unexplained pause after the fact.
            VRLog.d("Intent", "perform() — session release delegated to end() (state-gated)")
            // No dialog — Shortcuts' own "Copy to Clipboard" action shows a
            // short native toast that we'd otherwise stack our own Siri-style
            // banner on top of (with a "Done" button the user disliked).
            return .result(value: transcript)
        }
        #else
        return .result(value: "")
        #endif
    }
}

@available(iOS 18.0, *)
public struct VoiceRecordShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleVoiceRecordingShortcutIntent(),
            phrases: [
                "Toggle voice record in \(.applicationName)",
                "Start dictating in \(.applicationName)",
                "Record voice in \(.applicationName)",
            ],
            shortTitle: "Toggle Recording",
            systemImageName: "mic.circle.fill"
        )
        AppShortcut(
            intent: StartVoiceRecordingIntent(),
            phrases: [
                "Start voice recording in \(.applicationName)",
            ],
            shortTitle: "Start Recording",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: StopVoiceRecordingIntent(),
            phrases: [
                "Stop voice recording in \(.applicationName)",
            ],
            shortTitle: "Stop Recording",
            systemImageName: "stop.fill"
        )
    }
}
