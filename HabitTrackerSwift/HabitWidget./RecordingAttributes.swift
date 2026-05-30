import ActivityKit
import Foundation

// ActivityAttributes for the Voice Record Live Activity.
//
// IMPORTANT: This file must be a member of BOTH targets (HabitTracker + HabitWidget.Extension).
// The Widget Extension uses PBXFileSystemSynchronizedRootGroup, so its target picks the file
// automatically from the folder. The HabitTracker target adds an explicit reference in project.pbxproj.

struct RecordingAttributes: ActivityAttributes {
    // High-level phase mirrored into the Live Activity content so the user
    // gets immediate visual feedback the moment they tap a toggle, before
    // mic + WS finish handshaking. Phases:
    //   .starting  — app is acquiring mic / connecting to Soniox. Show spinner.
    //   .recording — audio actively streaming. Show pulsing red dot + timer.
    //   .stopping  — finalize in flight (waiting for Soniox final transcript).
    //                Show spinner. Stop button must NOT re-fire.
    //   .ended     — Activity is in its dismissal grace window. Show check.
    public enum Phase: String, Codable, Hashable {
        // Activity is alive but recording isn't happening. Used by the
        // "persistent Live Activity" mode: we keep an Activity around so
        // that background-launched toggle intents can UPDATE it (allowed)
        // instead of REQUEST a fresh one (forbidden from background).
        // Shown in Dynamic Island compact as a dim mic icon.
        case idle
        case starting
        case recording
        case stopping
        case ended
    }

    // Which physical input device is being captured. Surfaced in Lock Screen /
    // Notification Center / Dynamic Island expanded so the user can tell at a
    // glance whether they're on iPhone built-in or AirPods — important because
    // mic choice changes both audio quality AND background-music behaviour
    // (AirPods-as-mic flips A2DP→HFP, see fact-audio-session.md::Category-by-target).
    public enum MicSourceKind: String, Codable, Hashable {
        case iphone        // built-in mic
        case airpods       // any AirPods (Pro, 4, Max, etc.)
        case headphones    // wired / non-AirPods BT (Sony, Bose, …)
        case usb           // USB / Lightning audio interface
        case unknown
    }

    public struct ContentState: Codable, Hashable {
        // Absolute moment recording started — used by Text(timerInterval:) so
        // the system ticks the timer for free, no Activity.update() per second.
        public var startedAt: Date
        // Mirror of the WS connection state — UI shows red dot pulsing vs.
        // an offline indicator depending on this flag.
        public var isStreaming: Bool
        // Final-state flag for the Lock-Screen "Done — N seconds" frame after
        // the activity ends. Optional; not always set.
        public var endedAt: Date?
        // Last 2-3 lines of transcript shown on Lock Screen + expanded Dynamic
        // Island. Capped to ~140 chars to stay well under the 4 KB state limit
        // when combined with everything else. Updated by RecordingCoordinator
        // — throttled to avoid burning the per-app update budget.
        public var previewText: String = ""
        // Drives the spinner / red-dot / check icon picks.
        public var phase: Phase = .recording
        // Active mic source rendered as a small line in Lock Screen / NC /
        // Dynamic Island expanded ("iPhone" / "AirPods Pro" / ...). Default
        // `.unknown` keeps existing persisted ActivityContent decodable when
        // an Activity created by a previous build is rehydrated under a new
        // version of the app — Codable synthesizes the default for missing
        // keys. Name fallback to empty string for the same reason.
        public var micSourceKind: MicSourceKind = .unknown
        public var micSourceName: String = ""
    }
    public var sessionId: UUID
    public var title: String
}
