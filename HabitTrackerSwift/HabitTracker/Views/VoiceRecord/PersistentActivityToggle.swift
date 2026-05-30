import SwiftUI

// Compact toggle that controls the "keep Live Activity alive" mode. Sits in
// the bottom action row of the Voice tab, mirroring MicSourcePicker's shape.
// When ON:
//   • RootTabView.onAppear creates an .idle Activity if none exists.
//   • RecordingActivityManager.end() rewinds to .idle instead of dismissing.
//   • ToggleVoiceRecordingShortcutIntent (openAppWhenRun=false) can update
//     this Activity from background → Dynamic Island pop-out animation
//     plays on each toggle from a suspended app.
// When OFF:
//   • Activity is created only at recording start (foreground) and ended
//     fully when recording stops. No persistent Island slot. Shortcut
//     toggles fail-soft to "open app then start" flow.

struct PersistentActivityToggle: View {
    @AppStorage(VoiceRecordConfig.SharedKeys.keepLiveActivityAlive,
                store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var keepAlive: Bool = false

    var body: some View {
        Button {
            keepAlive.toggle()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            Task { await syncActivity() }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: keepAlive ? "pin.fill" : "pin.slash")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(keepAlive ? .yellow : .white)
                Text(keepAlive ? "Закреп." : "Откреп.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            .frame(width: 64, height: 56)
            .background(Color.white.opacity(keepAlive ? 0.15 : 0.08),
                        in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(keepAlive ? Color.yellow.opacity(0.5)
                                            : Color.white.opacity(0.15),
                                  lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(keepAlive ? "Закреплено в Dynamic Island" : "Не закреплено")
    }

    // Sync the on-screen toggle change with the actual Activity state:
    //   ON: ensure an .idle Activity exists.
    //   OFF: tear down the Activity if it's currently in .idle (don't
    //        kill an active recording — let the running recording finish).
    private func syncActivity() async {
        let mgr = RecordingActivityManager.shared
        if keepAlive {
            mgr.startIdle()
            return
        }
        // Off path: only dismiss if Activity is idle. Active recordings
        // (.recording / .starting / .stopping) should not be interrupted
        // by accidental untap of this toggle.
        if let act = mgr.current, act.content.state.phase == .idle {
            await mgr.end(immediate: true)
        }
    }
}
