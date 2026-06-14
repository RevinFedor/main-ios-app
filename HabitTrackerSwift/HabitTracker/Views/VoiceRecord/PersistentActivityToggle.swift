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

    // DEAD UI — the persistent-idle Activity mode was deprecated (keepAlive is
    // permanently false; LiveActivityIntent.perform() is foreground-equivalent
    // for Activity.request() on iOS 17+, so the idle workaround is unneeded).
    // This view is no longer mounted anywhere. Kept compiling against the
    // current RecordingActivityManager API; the startIdle path is gone.
    private func syncActivity() async {
        let mgr = RecordingActivityManager.shared
        if keepAlive { return }
        // Off path: only dismiss if the Activity is idle.
        // Active captures must not be interrupted by an accidental untap.
        if let act = mgr.current,
           act.content.state.phase == .idle {
            await mgr.endAllOrphans()
        }
    }
}
