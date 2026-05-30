import AppIntents
import Foundation
import WidgetKit

// Conforming additionally to AudioRecordingIntent routes perform() into the
// host-app process even when the app is terminated. Apple DTS engineer Ed
// Ford confirmed cold-launch for AudioPlaybackIntent (and AudioRecordingIntent
// inherits the same execution-routing contract) in Developer Forums thread
// 761677 — launch delay equals app launch time, not a bug.
//
// IMPORTANT: We deliberately do NOT set openAppWhenRun = true on a
// SetValueIntent. That combination triggers FB14357691 (LNActionExecutorError
// Domain error 2018) on iOS 18.x and can prevent perform() from running at
// all. AudioRecordingIntent already gives us background-mic entitlement and
// cold-launch into the app process — openAppWhenRun would be additive only
// for the foreground flash, which we don't need.
//
// We also deliberately do NOT pre-write isRecording in perform() — that was
// an attempt to mask visual desync but doesn't actually help: the system
// auto-reloads currentValue() AFTER perform() returns, and as long as
// RecordingCoordinator.start()/stop() completes synchronously before we
// return, currentValue() will read the correct value. The auto-reload also
// makes explicit ControlCenter.shared.reloadControls(ofKind:) inside
// perform() redundant — drop it to avoid burning reload budget.

// On iOS 26 we observed that AudioRecordingIntent alone is NOT sufficient
// to cold-launch the app from a force-quit / killed state — perform() runs
// in the widget extension, pendingAction is written to App Group, but the
// host app process never wakes until the user opens it manually. Logged
// example (12:34): perform() at t+0, app init at t+3s ONLY because the
// user tapped the icon.
//
// To restore cold-start reliability we go back to openAppWhenRun = true
// on every recording intent. This brings a brief foreground flash but it
// is the only way to guarantee the app is alive to handle the action.

@available(iOS 18.0, *)
public struct ToggleVoiceRecordingIntent: SetValueIntent, AudioRecordingIntent {
    public static var title: LocalizedStringResource = "Voice Record"
    public static var description: IntentDescription = IntentDescription("Start or stop voice dictation.")
    public static var openAppWhenRun: Bool { true }

    @Parameter(title: "Recording")
    public var value: Bool

    public init() {}
    public init(value: Bool) { self.value = value }

    public func perform() async throws -> some IntentResult {
        let action = value ? "start" : "stop"
        VRLog.d("Intent", "Toggle perform() entered: value=\(value)")
        if value {
            // Pre-create the Live Activity in the EXTENSION process so iOS
            // plays the Dynamic Island pop-out animation. If we wait for the
            // host app to come to foreground and request it from there, the
            // pop-out is suppressed (foreground-requester rule).
            await MainActor.run { _ = LiveActivityKickoff.requestIfNeeded() }
        }
        postPendingAction(action)
        #if !WIDGET_EXTENSION
        await RecordingCoordinator.shared.handlePendingActionIfNeeded()
        #endif
        return .result()
    }
}

@available(iOS 18.0, *)
public struct StartVoiceRecordingIntent: AudioRecordingIntent {
    public static var title: LocalizedStringResource = "Start Voice Record"
    public static var openAppWhenRun: Bool { true }

    public init() {}

    public func perform() async throws -> some IntentResult {
        VRLog.d("Intent", "Start perform() entered")
        await MainActor.run { _ = LiveActivityKickoff.requestIfNeeded() }
        postPendingAction("start")
        #if !WIDGET_EXTENSION
        await RecordingCoordinator.shared.handlePendingActionIfNeeded()
        #endif
        return .result()
    }
}

@available(iOS 18.0, *)
public struct StopVoiceRecordingIntent: AudioRecordingIntent {
    public static var title: LocalizedStringResource = "Stop Voice Record"
    public static var openAppWhenRun: Bool { true }

    public init() {}

    public func perform() async throws -> some IntentResult {
        VRLog.d("Intent", "Stop perform() entered")
        postPendingAction("stop")
        #if !WIDGET_EXTENSION
        await RecordingCoordinator.shared.handlePendingActionIfNeeded()
        #endif
        return .result()
    }
}

// Hard cancel: tear down session immediately, drop pending audio, dismiss
// the Live Activity. Used from the ✕ button so the user has an escape hatch
// when stop() hangs on a slow Soniox finalize.
@available(iOS 18.0, *)
public struct CancelVoiceRecordingIntent: AudioRecordingIntent {
    public static var title: LocalizedStringResource = "Cancel Voice Record"
    public static var openAppWhenRun: Bool { true }

    public init() {}

    public func perform() async throws -> some IntentResult {
        VRLog.d("Intent", "Cancel perform() entered")
        postPendingAction("cancel")
        #if !WIDGET_EXTENSION
        await RecordingCoordinator.shared.handlePendingActionIfNeeded()
        #endif
        return .result()
    }
}

private func postPendingAction(_ action: String) {
    let d = UserDefaults(suiteName: VoiceRecordConfig.appGroup)
    d?.set(action, forKey: VoiceRecordConfig.SharedKeys.pendingAction)
    d?.set(Date().timeIntervalSince1970, forKey: VoiceRecordConfig.SharedKeys.pendingActionTs)
    // Whenever the user invokes a recording intent, hint the app that next
    // time it foregrounds it should land on the Voice tab (relevant when
    // the user does open the app manually after a CC-driven start).
    d?.set(true, forKey: VoiceRecordConfig.SharedKeys.wantsVoiceTab)
    d?.synchronize()
    VRLog.d("Intent", "pendingAction set to \(action)")
}
