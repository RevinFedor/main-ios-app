import AppIntents
import SwiftUI
import WidgetKit

// Control Center toggle. Lives in the iOS 18+ Controls Gallery.
//
// The ControlValueProvider reads `isRecording` from the App Group, written by
// RecordingCoordinator on every start/stop. The toggle's `value` parameter is
// flipped automatically by the system; perform() calls into the coordinator.

@available(iOS 18.0, *)
struct VoiceRecordControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: VoiceRecordConfig.controlKind,
            provider: VoiceRecordingValueProvider()
        ) { value in
            ControlWidgetToggle(
                "Voice Record",
                isOn: value,
                action: ToggleVoiceRecordingIntent(value: !value)
            ) { isOn in
                Label(isOn ? "Recording" : "Idle",
                      systemImage: isOn ? "mic.fill" : "mic")
            }
            .tint(.red)
        }
        .displayName("Voice Record")
        .description("Start or stop voice dictation.")
    }
}

@available(iOS 18.0, *)
struct VoiceRecordingValueProvider: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        let d = UserDefaults(suiteName: VoiceRecordConfig.appGroup) ?? .standard
        return d.bool(forKey: VoiceRecordConfig.SharedKeys.isRecording)
    }
}
