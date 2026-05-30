import AVFoundation
import SwiftUI

// Navbar indicator/button that surfaces the AudioSession lifecycle. The audio
// session is what causes a one-time ~500ms music dip when first activated
// (Apple QA1631) — making that lifecycle visible and controllable in the UI
// turns an invisible side effect into a deterministic action the user owns.
//
// States:
//   • OFF (icon: speaker.slash) — session inactive. First Record press will
//     activate and pay the one music dip.
//   • ON  (icon: speaker.wave.2.fill, green tint) — session is alive, prewarmed.
//     Every Record press from now on is silent — no setActive, no route flush.
//
// Tap → toggle. Activation produces the expected one-time dip; deactivation is
// instant (no music side effect, since the session merely releases its hold —
// any background music app re-engages on the freed A2DP route within ~100ms).
//
// AudioSessionManager.isActive is not @Published (the manager is not an
// ObservableObject), so we sample it via a 0.5s timer plus reactive updates on
// route-change notifications. Cheap — just reading a stored Bool on main.

struct AudioSessionIndicator: View {
    @State private var isActive: Bool = AudioSessionManager.shared.isActive
    @State private var switching: Bool = false
    private let routeChange = NotificationCenter.default
        .publisher(for: AVAudioSession.routeChangeNotification)
    private let activeStateChange = NotificationCenter.default
        .publisher(for: AudioSessionManager.activeStateDidChange)
    private let pollTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Button {
            toggle()
        } label: {
            if switching {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else {
                Image(systemName: isActive ? "speaker.wave.2.fill" : "speaker.slash")
                    .foregroundStyle(isActive ? Color.green : Color.white.opacity(0.55))
            }
        }
        .accessibilityLabel(isActive ? "Аудиосессия активна" : "Аудиосессия выключена")
        .onAppear { isActive = AudioSessionManager.shared.isActive }
        .onReceive(activeStateChange) { _ in isActive = AudioSessionManager.shared.isActive }
        .onReceive(routeChange) { _ in isActive = AudioSessionManager.shared.isActive }
        .onReceive(pollTimer) { _ in
            // Catch transitions we missed (e.g. first activate from a recording
            // start) without forcing ObservableObject on the manager.
            let live = AudioSessionManager.shared.isActive
            if live != isActive { isActive = live }
        }
    }

    private func toggle() {
        if isActive {
            // Deactivate is a no-op in the always-active model — but the user
            // explicitly asked for a "turn it off" button, so use the lower
            // level path here. Once off, the next recording will reactivate
            // (paying the one dip again — which is the whole point of this
            // visible control).
            AudioSessionManager.shared.forceDeactivate()
            isActive = false
            VRLog.d("Indicator", "manual deactivate")
        } else {
            switching = true
            AudioSessionManager.shared.activate { [self] _ in
                isActive = AudioSessionManager.shared.isActive
                switching = false
                VRLog.d("Indicator", "manual activate → isActive=\(isActive)")
            }
        }
    }
}
