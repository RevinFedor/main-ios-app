import Foundation

enum VoiceRecordConfig {
    static let appGroup = "group.com.fedor277.habittracker"

    // Shared keys in App-Group UserDefaults — used by the toggle ControlValueProvider
    // and the main app to know recording state.
    enum SharedKeys {
        static let isRecording = "voiceRecord.isRecording"
        static let recordingStartDate = "voiceRecord.recordingStartDate"
        static let forceBuiltInMic = "voiceRecord.forceBuiltInMic"
        // Pending action posted by the widget process when iOS hasn't (yet)
        // routed perform() into the app. App handler picks this up on launch
        // / foreground and dispatches start/stop accordingly.
        // Values: "start" | "stop" | nil
        static let pendingAction = "voiceRecord.pendingAction"
        static let pendingActionTs = "voiceRecord.pendingActionTs"
        // Set by intents whenever they fire — RootTabView checks this on
        // foreground/init and switches to the Voice tab if true.
        static let wantsVoiceTab = "voiceRecord.wantsVoiceTab"
        // User preferences shared via App Group (so the Live Activity widget
        // reads the same value the app's @AppStorage writes).
        static let autoCopyAfterStop = "voiceRecord.autoCopy"
        static let liveActivityTrailingPadding = "voiceRecord.laTrailingPad"
        // When true, surface developer affordances in the main UI (e.g.
        // copy-log / clear-log icons in the Voice tab navbar).
        static let devMode = "voiceRecord.devMode"
        // When true, show the copy-log / clear-log icons in the HABITS tab
        // navbar. Separate from devMode (which gates the Voice tab) so each tab's
        // log shortcuts toggle independently. Off by default — keeps the Habits
        // navbar clean. See Settings → Диагностика toggle "Показывать лог-кнопки".
        static let showHabitLogButtons = "habit.showLogButtons"
        // When true, keep a Live Activity alive in an .idle phase even when
        // no recording is in progress. This is the workaround that lets
        // background-launched ToggleVoiceRecordingShortcutIntent UPDATE an
        // existing Activity (allowed by ActivityKit) instead of REQUEST a
        // new one (forbidden from background). Result: Dynamic Island pop-out
        // animation plays on toggle even when the app is suspended.
        static let keepLiveActivityAlive = "voiceRecord.keepLiveActivityAlive"
        // Last finalized transcript stashed for clipboard on next foreground.
        // Background UIPasteboard writes from a LiveActivityIntent perform()
        // context are flaky (iOS sometimes silently drops them when the app
        // scene isn't connected). Stashing here + flushing on
        // willEnterForegroundNotification guarantees the user finds the text
        // ready to paste the moment they open any app.
        static let pendingClipboardText = "voiceRecord.pendingClipboardText"
        static let pendingClipboardTs = "voiceRecord.pendingClipboardTs"
        // Timestamp written by RecordingCoordinator.init on every process
        // bootstrap. The Shortcut intent compares this to its own start time
        // — if init landed within the last ~5s, the intent triggered a true
        // cold launch and needs AVAudioSession deactivation on return to
        // avoid jetsam SIGKILL. If init is older, we re-entered a live
        // background process and deactivation would just cut the music.
        static let lastColdLaunchTs = "voiceRecord.lastColdLaunchTs"
        // Mic source mirror, written by AudioSessionManager on every route /
        // preference change, read by LiveActivityKickoff in the widget-extension
        // process (which has no access to AVAudioSession.currentRoute until it
        // activates its own session — too expensive for a brief pre-launch
        // glance). Kind = raw value of RecordingAttributes.MicSourceKind,
        // Name = human-readable port name ("AirPods Pro de Fedor").
        static let lastMicSourceKind = "voiceRecord.lastMicSourceKind"
        static let lastMicSourceName = "voiceRecord.lastMicSourceName"
    }

    // App-Group container subdirectory for saved .wav files.
    static let audioDirName = "voice-record-audio"
    // History JSON lives in the same container, single file.
    static let historyFileName = "voice-record-history.json"
    // Cap of saved entries (older are evicted with their .wav).
    static let historyCap = 200

    // Soniox transport
    static let sonioxWSURL = "wss://stt-rt.soniox.com/transcribe-websocket"
    static let sonioxTokenURL = "https://api.soniox.com/v1/auth/temporary-api-key"
    static let sonioxModel = "stt-rt-v4"
    static let targetSampleRate: Double = 16000

    // Live Activity / Dynamic Island
    static let liveActivityName = "Voice Record"

    // ControlWidget identifiers
    static let controlKind = "com.fedor277.habittracker.voice.recordControl"
}
