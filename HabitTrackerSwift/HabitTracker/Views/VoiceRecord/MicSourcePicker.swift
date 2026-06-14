import AVFoundation
import SwiftUI

// Compact mic-source picker that sits next to the big record button on the
// Voice tab. ONE control — a dropdown (this view's Menu) with:
//   • Device rows: "Микрофон iPhone" and "AirPods" (when connected). The
//     checkmark sits on the device iOS will ACTUALLY use — during recording it
//     mirrors the live route, idle it anticipates the next start. Picks are
//     session-only (not persisted).
//   • A separated "Закрепить iPhone" toggle row (below a Divider) — the sticky,
//     cross-launch lock (forceBuiltInMic). When ON, the iPhone built-in mic is
//     used regardless of what's connected and the AirPods row is disabled.
//
// The lock used to be a sibling pin button beside the dropdown; it moved INTO
// the menu as a modifier row so there's a single tap-target. Its state still
// reads at a glance WITHOUT opening the menu via a small orange lock badge in
// the card's top-right corner (+ orange border).
//
// Audio side effects are documented next to each interaction below. The key
// invariant: NO call from this view ever activates AVAudioSession when the user
// is not yet recording. Anything that would call setActive(.playAndRecord)
// would steal the route from background music for ~1s. (The lock toggle's setter
// only touches the session when a recording is already live.)

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
    // Which built-in mic (Bottom/Front/Back) the user picked, and the list iOS
    // actually offers. The data-source card is shown only on the iPhone-mic path
    // (AirPods/USB have no data sources). `selectedDS` is the live truth from the
    // route; `dataSources` drives which rows the menu shows.
    @State private var selectedDS: AudioSessionManager.MicDataSource? = nil
    @State private var dataSources: [AudioSessionManager.MicDataSource] = []

    private let routeChange = NotificationCenter.default
        .publisher(for: AVAudioSession.routeChangeNotification)
    // The manager re-publishes the RESOLVED (kind, name) every time the real
    // route settles — on activate, on a live mic switch, and on a mid-record
    // connect/disconnect. Subscribing here is what lets the badge update DURING
    // recording (the routeChange handler below intentionally ignores the active
    // session to avoid reacting to our own category flips). This is the single
    // signal that keeps the displayed device equal to the device actually in use.
    private let micSourceChange = NotificationCenter.default
        .publisher(for: AudioSessionManager.micSourceDidChange)
    // Built-in data-source (Bottom/Front/Back) is a SINGLE shared setting — one
    // mic, one route for every concurrent recording. Both picker instances (the
    // bottom row and the one mirrored in the long panel) subscribe so a pick in
    // one instantly re-reads in the other; otherwise the second shows a stale
    // value and it looks (falsely) like each recording has its own mic capsule.
    private let micDataSourceChange = NotificationCenter.default
        .publisher(for: AudioSessionManager.micDataSourceDidChange)

    var body: some View {
        HStack(spacing: 8) {
            // Mic source dropdown. The iPhone-lock moved INTO this menu as a
            // toggle row (corner badge on the card reflects its state).
            Menu {
                menuContents
            } label: {
                pickerLabel
            }
            .menuStyle(.button)
            .menuOrder(.fixed)

            // Built-in mic picker (Bottom/Front/Back) — only on the iPhone-mic
            // path and only when iOS actually offers >1 data source (AirPods/USB
            // have none). With AirPods there's nothing to pick.
            if effective == .iPhone, dataSources.count > 1 {
                micSourceCard
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: effective)
        .animation(.easeInOut(duration: 0.18), value: dataSources)
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
        .onReceive(micSourceChange) { _ in
            // Manager settled on a real route (live switch, or AirPods dropped
            // mid-record and the OS fell back to the iPhone). Re-read so the
            // badge/checkmark track reality even while recording. Also drop the
            // "switching" loader — the route has settled by definition.
            switching = false
            refresh()
        }
        .onReceive(micDataSourceChange) { _ in
            // The shared built-in data source changed (in THIS picker or the
            // other instance). Re-read so both always show the one true pick.
            refresh()
        }
    }

    // MARK: Menu

    @ViewBuilder
    private var menuContents: some View {
        // ── Device choices ────────────────────────────────────────────────
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
        // NOT disabled when the pin is on: the pin is a DEFAULT, not a jail.
        // Picking AirPods here clears the pin (selectInput drops forceBuiltInMic)
        // and switches to AirPods — the user can always override the default.
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
        }

        // ── Modifier: pin to iPhone ───────────────────────────────────────
        // The lock used to be a separate sibling button; it now lives in this
        // menu as a toggle. Divider separates it from the device rows so it
        // reads as a MODIFIER ("always iPhone, ignore connected accessories"),
        // not a third device. Checkmark on the right reflects the persisted
        // forceBuiltInMic flag. The setter already handles the live-recording
        // case (flips category to A2DP-only + re-pins built-in mid-record), so
        // this single call covers both idle and recording.
        Divider()
        Button {
            let next = !locked
            AudioSessionManager.shared.forceBuiltInMic = next
            locked = next
            refresh()
            VRLog.d("Picker", "lock(menu) → \(next)")
        } label: {
            HStack {
                Image(systemName: locked ? "lock.fill" : "lock.open")
                Text("Закрепить iPhone")
                if locked { Spacer(); Image(systemName: "checkmark") }
            }
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
                .strokeBorder(locked ? Color.orange.opacity(0.7) : Color.white.opacity(0.15),
                              lineWidth: locked ? 1.5 : 1)
        )
        // Pinned badge: a small lock in the top-right corner when the iPhone mic
        // is locked. Sits in the corner (not in the icon row) so the card keeps
        // its size and the lock state reads at a glance without opening the menu.
        // Orange matches the old sibling-pin colour so the meaning carries over.
        .overlay(alignment: .topTrailing) {
            if locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(Color.orange, in: Circle())
                    .offset(x: 5, y: -5)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: locked)
    }

    // MARK: Built-in mic source card (Bottom / Front / Back)

    // Mirrors the mic-device card's footprint. Lets the user pick WHICH physical
    // built-in mic records — Bottom (near the dock), Front (top/earpiece), Back
    // (near the rear camera). Shows the user's sticky pick (intent), which equals
    // what the next start / the live recording uses.
    //
    // ENABLED during recording too. Switching the built-in data source mid-record
    // is the SAME physical port (builtInMic) at the SAME sample rate — only the
    // capsule changes — so the resampler is never at risk. The category-mode flip
    // (.measurement→.default when a source gets pinned) reconfigures the graph and
    // makes the engine stop itself; MicCaptureHub catches AVAudioEngineConfiguration
    // Change and rebuilds the tap, so capture continues after a ~100ms gap. The
    // old "disabled while recording" rule (from when DictationSession owned the
    // engine and had no config-change recovery) is lifted.
    private var micSourceCard: some View {
        Menu {
            ForEach(dataSources, id: \.self) { ds in
                Button {
                    pickDataSource(ds)
                } label: {
                    HStack {
                        Image(systemName: dsIcon(ds))
                        Text(dsTitle(ds))
                        if selectedDS == ds { Spacer(); Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: dsIcon(selectedDS ?? .bottom))
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(height: 24)
                Text(dsShort(selectedDS))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            .frame(width: 64, height: 56)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(selectedDS != nil ? Color.blue.opacity(0.6) : Color.white.opacity(0.15),
                                  lineWidth: selectedDS != nil ? 1.5 : 1)
            )
        }
        .menuStyle(.button)
        .menuOrder(.fixed)
    }

    // Icons evoke physical position on the phone. Bottom = mic at the dock,
    // Front = top/earpiece, Back = rear camera mic.
    private func dsIcon(_ ds: AudioSessionManager.MicDataSource) -> String {
        switch ds {
        case .bottom: return "arrow.down.to.line.compact"
        case .front:  return "arrow.up.to.line.compact"
        case .back:   return "camera.fill"
        }
    }
    private func dsTitle(_ ds: AudioSessionManager.MicDataSource) -> String {
        switch ds {
        case .bottom: return "Нижний (у разъёма)"
        case .front:  return "Верхний (фронт)"
        case .back:   return "Задний (у камеры)"
        }
    }
    private func dsShort(_ ds: AudioSessionManager.MicDataSource?) -> String {
        switch ds {
        case .bottom: return "Низ"
        case .front:  return "Верх"
        case .back:   return "Зад"
        case .none:   return "Авто"
        }
    }

    private func pickDataSource(_ ds: AudioSessionManager.MicDataSource) {
        // Optimistic; refresh() in the completion confirms from the real route.
        selectedDS = ds
        AudioSessionManager.shared.selectMicDataSource(ds) {
            refresh()
        }
        VRLog.d("Picker", "pickDataSource \(ds.rawValue)")
    }

    // MARK: State

    private func refresh() {
        let mgr = AudioSessionManager.shared
        btDevice = mgr.btOutputDevice()
        locked = mgr.forceBuiltInMic
        effective = computeEffective()
        dataSources = mgr.availableMicDataSources()
        // Display the user's STICKY pick (preferredMicDataSource), NOT the live
        // route's selectedDataSource. A built-in data source only APPLIES to the
        // hardware while audio I/O is actually running — when idle, or between
        // recordings with the engine stopped, setPreferredDataSource does not
        // reflect into currentRoute, so reading the route snaps the checkmark
        // back to the default (bottom) and every pick looks like it did nothing.
        // That was the headline bug ("выделение не происходит" / "после старта
        // записи вдруг отобразилось" — because only then is I/O live). The
        // INTENT is the truth for the badge: it's what the user chose and what
        // the next start (or the live apply during recording) will use. Fall
        // back to the live route only when no explicit pick exists yet (Авто).
        if let raw = mgr.preferredMicDataSource,
           let ds = AudioSessionManager.MicDataSource(rawValue: raw) {
            selectedDS = ds
        } else {
            selectedDS = mgr.currentMicDataSource()
        }
        VRLog.d("Picker", "refresh → effective=\(effective) locked=\(locked) btDevice=\(btDevice?.name ?? "none") dataSources=[\(dataSources.map{$0.rawValue}.joined(separator: "/"))] selectedDS=\(selectedDS?.rawValue ?? "nil") prefDS=\(mgr.preferredMicDataSource ?? "nil")")
    }

    // The mic that is / will be ACTUALLY used — the checkmark and badge must
    // equal the real route, never a guess. Source of truth, in order:
    //
    //  1. RECORDING (session active): mirror the manager's resolved source,
    //     which reads currentRoute.inputs.first — the canonical truth (Apple:
    //     "to see the actual current input port, use currentRoute"; preferredInput
    //     is only a hint). This is the fix for the headline bug: on the default
    //     A2DP-only path the iPhone mic records even with AirPods connected for
    //     music, so we must show iPhone, NOT assume AirPods from "BT connected".
    //  2. IDLE: anticipate what the next start will use from the target flags:
    //       • lock ON → iPhone, period.
    //       • explicit BT override ON and AirPods connected → AirPods.
    //       • otherwise iPhone. We deliberately do NOT pre-check AirPods just
    //         because they're connected for music: the default category can't
    //         record from them, so claiming AirPods would be the same lie. The
    //         user picks AirPods explicitly (which flips the category to HFP).
    private func computeEffective() -> Effective {
        let mgr = AudioSessionManager.shared
        if mgr.isActive {
            // Live truth from the actual input route.
            return mgr.currentMicSource().kind == .airpods ? .airPods : .iPhone
        }
        if mgr.forceBuiltInMic { return .iPhone }
        if mgr.wantsBluetoothMic, btDevice != nil { return .airPods }
        return .iPhone
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
            if mgr.isActive {
                // Live recording with AirPods (HFP): flip the category back to
                // A2DP-only and re-pin the iPhone mic NOW, mirroring the AirPods
                // branch. Without this the badge would say iPhone while HFP kept
                // the AirPods mic — the same display-vs-reality split, reversed.
                // The input port change (HFP → builtInMic) trips onActiveRouteChange
                // and the tap rebuilds at the iPhone's sample rate.
                switching = true
                mgr.reapplyLiveTarget {
                    switching = false
                    refresh()
                }
            } else {
                effective = .iPhone
                switching = false
            }
            VRLog.d("Picker", "pick iPhone (session override) active=\(mgr.isActive)")
        case .airPods:
            switching = true
            effective = .airPods
            let port = btDevice?.port ?? .bluetoothHFP
            // selectInput runs the blocking setCategory/setPreferredInput on a
            // serial queue. completion fires on main once the route settles;
            // refresh() then confirms from the REAL route (if the HFP handshake
            // failed and it stayed on iPhone, the badge shows iPhone — truthful).
            mgr.selectInput(port) {
                switching = false
                refresh()
            }
        }
    }
}
