import AVFoundation
import SwiftUI

// Compact mic-source picker that sits next to the big record button on the
// Voice tab. The UI presents TWO controls side by side:
//   1. Mic source dropdown (this view's Menu) — two options: "Микрофон iPhone"
//      and "AirPods" (when connected). The checkmark always sits on the device
//      iOS will ACTUALLY use when recording starts, given the current lock and
//      session-scoped override state. Picks are session-only — not persisted.
//   2. Lock pin (sibling LockMicButton) — sticky across launches. When ON the
//      iPhone built-in mic is used regardless of what's connected and the
//      dropdown's AirPods row is disabled.
//
// Why two controls instead of one menu: the lock is a fundamentally different
// scope ("always vs once") and a different lifecycle ("persisted vs session").
// Lumping them risked the dropdown picking a device while the lock kept it
// elsewhere — confusing. The pin sitting next to the dropdown makes the lock
// state instantly visible without opening a menu.
//
// Audio side effects are documented next to each interaction below. The key
// invariant: NO call from this view ever activates AVAudioSession when the user
// is not yet recording. Anything that would call setActive(.playAndRecord)
// would steal the route from background music for ~1s.

struct MicSourcePicker: View {
    // The mic that will actually be used when recording starts NOW. Derived
    // from manager state + the live route, so the checkmark and the badge
    // always agree with reality.
    enum Effective { case iPhone, airPods }
    @State private var effective: Effective = .iPhone
    // Lock flag mirrored from AppGroup so SwiftUI can observe it.
    @State private var locked: Bool = AudioSessionManager.shared.forceBuiltInMic
    // Connected BT output device (AirPods etc.), read from currentRoute. On the
    // default A2DP path AirPods are NOT in availableInputs (A2DP has no mic),
    // so we detect them via the output route instead.
    @State private var btDevice: (port: AVAudioSession.Port, name: String)? = nil
    // True for the ~1-3s while a BT category flip renegotiates HFP. Drives the
    // loader so the picker shows "switching" instead of looking frozen.
    @State private var switching: Bool = false

    private let routeChange = NotificationCenter.default
        .publisher(for: AVAudioSession.routeChangeNotification)

    var body: some View {
        HStack(spacing: 8) {
            // Mic source dropdown.
            Menu {
                menuContents
            } label: {
                pickerLabel
            }
            .menuStyle(.button)
            .menuOrder(.fixed)
            // Sibling lock pin — toggles forceBuiltInMic. Visually distinct
            // (orange when active) so the lock state reads at a glance.
            lockPin
        }
        .onAppear {
            // Just read the current route — NO prewarm here. Activating the
            // audio session interrupts background music for ~500ms, which the
            // user must not pay just for opening the Voice tab. Prewarm now
            // happens lazily on the FIRST real recording start instead — that
            // first record pays the cost once, every subsequent recording in
            // the same launch is silent.
            refresh()
        }
        .onReceive(routeChange) { note in
            guard !AudioSessionManager.shared.isActive else { return }
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = raw.flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
            switch reason {
            case .newDeviceAvailable, .oldDeviceUnavailable:
                refresh()
            default:
                break
            }
        }
    }

    // MARK: Menu

    @ViewBuilder
    private var menuContents: some View {
        // iPhone built-in — always available.
        Button {
            pick(.iPhone)
        } label: {
            HStack {
                Image(systemName: "iphone")
                Text("Микрофон iPhone")
                if effective == .iPhone { Spacer(); Image(systemName: "checkmark") }
            }
        }
        // AirPods — only when a BT device is connected. Picking it switches the
        // BT link to HFP, which stops any background music in the AirPods (a
        // hardware limit, not a bug). The inline warning makes that visible.
        // Disabled while the lock is on so the lock truly means "always iPhone".
        if let bt = btDevice {
            Button {
                pick(.airPods)
            } label: {
                HStack {
                    Image(systemName: "airpods")
                    VStack(alignment: .leading) {
                        Text(bt.name)
                        Text("музыка остановится").font(.caption2).foregroundStyle(.secondary)
                    }
                    if effective == .airPods { Spacer(); Image(systemName: "checkmark") }
                }
            }
            .disabled(locked)
        }
    }

    private var pickerLabel: some View {
        VStack(spacing: 4) {
            ZStack {
                if switching {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: effective == .airPods ? "airpods" : "iphone")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
            .frame(height: 24)
            Text(switching ? "..." : (effective == .airPods ? "AirPods" : "iPhone"))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
        }
        .frame(width: 64, height: 56)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: Lock pin (sibling button)

    private var lockPin: some View {
        Button {
            // Toggling the lock has zero playback side effect — the setter
            // persists the flag and only reconfigures the session if recording
            // is currently live. The first activation at record-time will pick
            // up the new value. No probe, no setActive here.
            let next = !locked
            AudioSessionManager.shared.forceBuiltInMic = next
            locked = next
            refresh()
            VRLog.d("Picker", "lockPin → \(next)")
        } label: {
            VStack(spacing: 4) {
                Image(systemName: locked ? "lock.fill" : "lock.open")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
                Text(locked ? "Закр." : "Откр.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            .frame(width: 56, height: 56)
            .background(locked ? Color.orange.opacity(0.7) : Color.white.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: State

    private func refresh() {
        btDevice = AudioSessionManager.shared.btOutputDevice()
        locked = AudioSessionManager.shared.forceBuiltInMic
        effective = computeEffective()
        VRLog.d("Picker", "refresh → effective=\(effective) locked=\(locked) btDevice=\(btDevice?.name ?? "none")")
    }

    // The mic iOS will use NOW if recording starts. This is what determines the
    // checkmark and the badge — they must always match what'll really happen.
    //  • lock ON → iPhone, period.
    //  • explicit BT override ON and AirPods connected → AirPods.
    //  • otherwise iOS system default. We treat "BT output connected" as a
    //    strong signal that AirPods are the system default mic too (which they
    //    are on iOS by default), so the checkmark falls on AirPods. This is the
    //    "если AirPods подключены — галочка на AirPods" behaviour the user
    //    explicitly asked for.
    private func computeEffective() -> Effective {
        let mgr = AudioSessionManager.shared
        if mgr.forceBuiltInMic { return .iPhone }
        if mgr.wantsBluetoothMic, btDevice != nil { return .airPods }
        return btDevice != nil ? .airPods : .iPhone
    }

    private func pick(_ choice: Effective) {
        let mgr = AudioSessionManager.shared
        switch choice {
        case .iPhone:
            // Picking iPhone explicitly when AirPods are also connected means
            // "for this session, use iPhone". It is NOT the same as the lock —
            // after a restart we want to go back to the system default. So we
            // set the BT override to .builtInMic which encodes "iPhone for this
            // session only". The override doesn't get persisted; flags do.
            mgr.preferredPortOverride = .builtInMic
            // If the user picked iPhone explicitly the lock should NOT be on.
            // But don't turn it off either if it was already on for some reason
            // (the menu disables the BT row in that case, so we only reach here
            // when lock is off).
            effective = .iPhone
            switching = false
            VRLog.d("Picker", "pick iPhone (session override)")
        case .airPods:
            switching = true
            effective = .airPods
            let port = btDevice?.port ?? .bluetoothHFP
            // selectInput runs the blocking setCategory/setPreferredInput on a
            // serial queue. completion fires on main once the route settles.
            mgr.selectInput(port) {
                switching = false
                refresh()
            }
        }
    }
}
