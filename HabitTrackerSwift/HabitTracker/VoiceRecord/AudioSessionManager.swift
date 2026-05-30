import AVFoundation
import Foundation

// Single source of truth for AVAudioSession configuration + route observation.
//
// CATEGORY-BY-TARGET — the core of avoiding AirPods audio degradation.
// Bluetooth exposes a mic ONLY through the HFP profile, which is mono 16–24 kHz
// telephony quality and, crucially, takes over the WHOLE route: the moment
// .allowBluetoothHFP is in the category options, iOS is free to drag AirPods
// playback down to HFP too — even if you're recording from the iPhone mic. That
// is why the user heard "cheap" sound and why switching to the iPhone mic didn't
// recover it (HFP was still allowed). So we pick the category based on which mic
// the user actually targets:
//   • iPhone built-in mic (the DEFAULT, and explicit picks)  → A2DP-only, NO HFP.
//     AirPods stay in high-quality A2DP playback, input falls to the built-in
//     mic, there is NO Bluetooth profile renegotiation → no audio interruption,
//     no degradation, and setActive returns in milliseconds (the multi-second
//     freeze was the HFP handshake — gone on this path).
//   • AirPods as mic (ONLY when the user explicitly picks them in the menu) →
//     HFP (+ .bluetoothHighQualityRecording on iOS 26 H2 AirPods). Playback
//     necessarily drops — a Bluetooth hardware limit the user opts into.
//
// Because A2DP-only enumeration does NOT list AirPods as an input (A2DP has no
// mic), the picker can't find them in availableInputs. We instead DETECT a
// connected BT device via the current OUTPUT route during the A2DP probe and
// surface a synthetic "AirPods" menu entry. Selecting it flips the target to BT.
//
// iOS resets preferredInput to nil on every route change; we re-apply on
// .newDeviceAvailable / .oldDeviceUnavailable / .categoryChange / .wakeFromSleep
// / .override and on interruption end.

@MainActor
final class AudioSessionManager {
    static let shared = AudioSessionManager()

    private let session = AVAudioSession.sharedInstance()
    private var routeObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var mediaResetObserver: NSObjectProtocol?
    private(set) var isActive = false {
        didSet {
            if oldValue != isActive {
                NotificationCenter.default.post(name: Self.activeStateDidChange, object: nil)
            }
        }
    }
    // Posted on every transition of `isActive`. The navbar indicator subscribes
    // to this so its icon flips the moment the session is prewarmed by the
    // first recording start (or any other path) — without it the indicator
    // only updated on the 0.5s poll timer and looked broken for the user.
    static let activeStateDidChange = Notification.Name("AudioSessionManager.activeStateDidChange")
    // Posted whenever the resolved (kind, name) pair changes — covers
    // wantsBluetoothMic flip from picker, route changes (AirPods plugged in
    // mid-record), forceBuiltInMic toggle, BT device replacement. Live
    // Activity manager subscribes and silently updates ContentState so the
    // user sees the new mic name in Lock Screen / NC / Dynamic Island.
    static let micSourceDidChange = Notification.Name("AudioSessionManager.micSourceDidChange")
    // Re-entrancy guard for probeInputs(): probe activate/deactivate themselves
    // post routeChangeNotification, and the picker re-probes on route change —
    // without this flag that's an infinite probe loop (and a flickering orange
    // mic dot). True only for the ~30ms inside a probe.
    private(set) var isProbing = false
    // Probe has a side effect: setActive(true) takes over the audio route, which
    // briefly pauses whatever was playing in AirPods (music etc.) — the user
    // hears a 1-second drop just by switching to the Voice tab. So we only probe
    // ONCE per app launch (to discover wired/USB inputs) and then trust the
    // currentRoute outputs for BT device detection. After the first probe we
    // never trigger another playback interruption from the picker.
    private(set) var hasProbedThisLaunch = false
    // Last input port observed while the session was ACTIVE. currentRoute is
    // empty when the session is inactive (we only activate during recording or
    // a brief probe), so the picker badge would otherwise have nothing to show
    // between recordings. We cache the last real route here.
    private(set) var lastActiveInputPort: AVAudioSession.Port?
    // In-memory, session-scoped manual pick from the picker menu. nil = follow
    // iOS system default (which routes to the newest connected accessory, i.e.
    // AirPods). Not persisted — only the forceBuiltInMic flag survives launches.
    var preferredPortOverride: AVAudioSession.Port?
    // Fired AFTER an active-session route change settles (AirPods connect/
    // disconnect mid-recording). DictationSession subscribes to rebuild its
    // input tap, because the new device's native sample rate differs from the
    // one captured at engine.start() — keeping the old rate makes the resampler
    // produce chipmunk/slow audio and garbled transcripts.
    var onActiveRouteChange: (() -> Void)?

    var forceBuiltInMic: Bool {
        get { AppGroupContainer.defaults.bool(forKey: VoiceRecordConfig.SharedKeys.forceBuiltInMic) }
        set {
            AppGroupContainer.defaults.set(newValue, forKey: VoiceRecordConfig.SharedKeys.forceBuiltInMic)
            AppGroupContainer.defaults.synchronize()
            // The flag is the explicit control — toggling it (either direction)
            // resets any manual menu pick so semantics stay clean: ON = always
            // iPhone, OFF = system default (AirPods when connected).
            preferredPortOverride = nil
            VRLog.d("Audio", "forceBuiltInMic set → \(newValue), override cleared")
            // When NOT recording: do nothing else. The previous probeInputs()
            // call here was the cause of "первое нажатие лока прерывает музыку"
            // — it activated .playAndRecord which kicks any backgrounded music
            // app off its A2DP route for ~1s. The flag is persisted; the next
            // real recording's activate() will honour it. Re-applying mid-record
            // still works because then isActive is true.
            if isActive {
                let mode = categoryMode
                let options = categoryOptions
                let sess = session
                let forceBI = newValue
                let wantsBT = wantsBluetoothMic
                audioQueue.async { [weak self] in
                    // Both the category and the pinned port can change.
                    try? sess.setCategory(.playAndRecord, mode: mode, options: options)
                    let chosen = Self.pickPort(from: sess.availableInputs ?? [], forceBuiltIn: forceBI, wantsBT: wantsBT)
                    if sess.preferredInput?.uid != chosen?.uid {
                        try? sess.setPreferredInput(chosen)
                    }
                    let settled = sess.currentRoute.inputs.first?.portType
                    Task { @MainActor in
                        if let s = settled { self?.lastActiveInputPort = s }
                        self?.publishMicSource(reason: "forceBuiltInMic-active")
                    }
                }
            } else {
                publishMicSource(reason: "forceBuiltInMic-inactive")
            }
        }
    }

    private init() {}

    // Dedicated serial queue for the BLOCKING AVAudioSession calls
    // (setCategory / setActive / setPreferredInput). Apple's SDK header states
    // setActive is "a synchronous (blocking) operation" — on a Bluetooth route
    // it IPCs to mediaserverd and waits out the HFP handshake (1-3s). Running
    // that on the main thread froze the picker (and made the menu unresponsive,
    // which read as "the iPhone option disappeared"). All session mutation now
    // hops here; only cheap currentRoute reads stay on main.
    private let audioQueue = DispatchQueue(label: "com.habittracker.voice.audio", qos: .userInitiated)

    // Pure selection rule, safe to run off-actor on the audio queue. Given the
    // freshly-read input list, decides which port to pin. nil = system default.
    private nonisolated static func pickPort(
        from inputs: [AVAudioSessionPortDescription],
        forceBuiltIn: Bool,
        wantsBT: Bool
    ) -> AVAudioSessionPortDescription? {
        if forceBuiltIn { return inputs.first { $0.portType == .builtInMic } }
        if wantsBT {
            return inputs.first { $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE }
        }
        return nil
    }

    // True when the user has EXPLICITLY chosen a Bluetooth mic this session.
    // Default (nil override) and the force-iPhone flag both mean false — i.e.
    // AirPods are NOT auto-selected as the mic; the user must pick them.
    var wantsBluetoothMic: Bool {
        if forceBuiltInMic { return false }
        if let o = preferredPortOverride, o != .builtInMic { return true }
        return false
    }

    // Drop both overrides → back to iOS system-default routing. Used by the
    // picker's "System default" menu item.
    func clearOverrides() {
        AppGroupContainer.defaults.set(false, forKey: VoiceRecordConfig.SharedKeys.forceBuiltInMic)
        AppGroupContainer.defaults.synchronize()
        preferredPortOverride = nil
        VRLog.d("Audio", "clearOverrides — back to system default")
        publishMicSource(reason: "clearOverrides")
    }

    // Category options DEPEND ON THE TARGET MIC — see file header. The iPhone
    // path deliberately OMITS .allowBluetoothHFP so AirPods stay in hi-fi A2DP
    // playback and there's no HFP renegotiation (no audio gap, no multi-second
    // freeze). The AirPods-mic path opts into HFP (+ hi-q on iOS 26) knowing
    // playback drops — a Bluetooth hardware limit the user chose.
    private var categoryOptions: AVAudioSession.CategoryOptions {
        if wantsBluetoothMic {
            var opts: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .allowBluetoothA2DP]
            if #available(iOS 26.0, *) {
                opts.insert(.bluetoothHighQualityRecording)
            }
            return opts
        } else {
            // iPhone mic + AirPods A2DP playback. NO .allowBluetoothHFP (would
            // let iOS drag the route to HFP). NO .defaultToSpeaker (research:
            // it can override BT output routing). .mixWithOthers keeps any
            // external music playing untouched.
            return [.allowBluetoothA2DP, .mixWithOthers]
        }
    }

    // .bluetoothHighQualityRecording (iOS 26) is ONLY valid with .default mode.
    // The iPhone path uses .measurement (minimal processing, cleanest capture).
    private var categoryMode: AVAudioSession.Mode {
        wantsBluetoothMic ? .default : .measurement
    }

    // ALWAYS-ACTIVE SESSION pattern (per Apple QA1631 + WWDC lab guidance summarized
    // in Apple Developer Forums threads 663604 and 681989). The route reconfiguration
    // that mediaserverd performs when activating .playAndRecord interrupts the AirPods
    // A2DP stream of any backgrounded music app for ~500ms. That cost is paid ONCE
    // per session lifetime — so we activate the session a single time when the user
    // first opens the Voice tab, and then NEVER deactivate it. Every subsequent
    // recording start/stop is just engine.start()/stop() and an input-tap install —
    // no setActive calls, no route reconfiguration, no music stutter.
    //
    // Privacy: the orange mic indicator only appears while AVAudioEngine is actually
    // reading samples (tap installed + engine running). A merely-active .playAndRecord
    // session with no engine running does NOT light the indicator (verified iOS 17+,
    // confirmed unchanged in iOS 26).
    //
    // The session can survive backgrounding only when UIBackgroundModes includes
    // "audio". If the app is suspended it WILL be deactivated by the system, and
    // we re-prewarm on willEnterForeground (pay the cost once again, then quiet).
    func activate(completion: @escaping (Result<Void, Error>) -> Void) {
        // Already prewarmed with matching config? Skip — this is the whole point
        // of the pattern, no redundant setCategory/setActive that would cause a
        // music stutter for each recording.
        if isActive && session.category == .playAndRecord && session.categoryOptions == categoryOptions {
            completion(.success(()))
            return
        }
        // Snapshot @MainActor-derived config off-actor.
        let mode = categoryMode
        let options = categoryOptions
        let sess = session
        let forceBI = forceBuiltInMic
        let wantsBT = wantsBluetoothMic
        audioQueue.async { [weak self] in
            do {
                try sess.setCategory(.playAndRecord, mode: mode, options: options)
                try sess.setActive(true, options: [.notifyOthersOnDeactivation])
                let chosen = Self.pickPort(from: sess.availableInputs ?? [], forceBuiltIn: forceBI, wantsBT: wantsBT)
                if sess.preferredInput?.uid != chosen?.uid {
                    try? sess.setPreferredInput(chosen)
                }
                let settled = sess.currentRoute.inputs.first?.portType
                Task { @MainActor in
                    guard let self else { completion(.success(())); return }
                    self.isActive = true
                    if let s = settled { self.lastActiveInputPort = s }
                    self.installObservers()
                    self.logRoute("activate")
                    self.publishMicSource(reason: "activate")
                    completion(.success(()))
                }
            } catch {
                Task { @MainActor in completion(.failure(error)) }
            }
        }
    }

    // Convenience: warm the session up the very first time the Voice tab is
    // shown. Subsequent calls are no-ops thanks to activate's guard. The
    // completion is intentionally swallowed — failures here are harmless,
    // the next real recording's activate will retry.
    func prewarm() {
        activate { _ in }
    }

    // Intentionally a no-op in the always-active model. The previous body called
    // setActive(false, .notifyOthersOnDeactivation), which produced the SECOND
    // music stutter the user heard at recording-stop. We now keep the session
    // alive across recordings; the only place that should ever tear the session
    // down is mediaServicesWereReset (handled in its own observer).
    //
    // ONE exception (callers handle this via reconfigureForCurrentTarget()):
    // if the user recorded with AirPods-mic (HFP) and then stops, the AirPods
    // are still pinned to HFP and their music app can't recover A2DP playback.
    // Flipping the category back to A2DP-only does the renegotiation. That is
    // an explicit user-driven cost (they chose AirPods-mic) so the stutter is
    // expected; reconfigureForCurrentTarget triggers it deliberately.
    func deactivate() {
        VRLog.d("Audio", "deactivate() — no-op (always-active session)")
    }

    // Called from a background-triggered Shortcut intent's perform() AFTER it
    // has already called setActive(false) directly. We just mirror the flag
    // and tear down observers so the indicator / next activate see a
    // consistent state. Does NOT call setActive itself — the intent already
    // did so, on the right thread, just before suspend.
    func markInactive() {
        isActive = false
        removeObservers()
        VRLog.d("Audio", "markInactive — flag cleared by intent suspend prep")
    }

    // Explicit user-initiated deactivation. The session indicator button in the
    // navbar calls this when the user wants to release the audio route — e.g.
    // before plugging in another device or before letting the music app fully
    // recover the AirPods radio. Releases observers and flips isActive=false so
    // the next recording's activate() pays the route-reconfig cost again
    // (one music dip), which is the deterministic UX the indicator surfaces.
    func forceDeactivate() {
        isActive = false
        removeObservers()
        let sess = session
        audioQueue.async {
            try? sess.setActive(false, options: [.notifyOthersOnDeactivation])
        }
        VRLog.d("Audio", "forceDeactivate — session released")
    }

    // Re-apply category if the current target (iPhone vs BT) differs from the
    // category currently set. Called after stopping a BT-mic recording so the
    // AirPods can renegotiate back to A2DP for music playback. Idempotent.
    func reconfigureForCurrentTarget() {
        guard isActive else { return }
        let options = categoryOptions
        // Compare — if we're already on the target options skip the flip.
        if session.categoryOptions == options { return }
        let mode = categoryMode
        let sess = session
        let forceBI = forceBuiltInMic
        let wantsBT = wantsBluetoothMic
        audioQueue.async { [weak self] in
            try? sess.setCategory(.playAndRecord, mode: mode, options: options)
            let chosen = Self.pickPort(from: sess.availableInputs ?? [], forceBuiltIn: forceBI, wantsBT: wantsBT)
            if sess.preferredInput?.uid != chosen?.uid {
                try? sess.setPreferredInput(chosen)
            }
            Task { @MainActor in
                self?.logRoute("reconfigure-after-stop")
            }
        }
    }

    // Available inputs filtered to what the user can actually pick. We never
    // surface .bluetoothHFP since we don't allow that option in the category.
    var availableInputs: [AVAudioSessionPortDescription] {
        session.availableInputs ?? []
    }

    var currentInputPortType: AVAudioSession.Port? {
        // When inactive, currentRoute is empty — fall back to the last port we
        // saw while active so the picker badge stays meaningful between records.
        session.currentRoute.inputs.first?.portType ?? lastActiveInputPort
    }

    // Briefly configure the session WITHOUT activating recording so that
    // availableInputs / currentRoute are populated. iOS reports AirPods /
    // BT mic / USB inputs only after the session has a category set —
    // before that everything is empty. Used by MicSourcePicker to show
    // the real current input as soon as the Voice tab appears, not only
    // after recording starts. Cheap: setCategory + setActive(true) +
    // setActive(false) takes ~30 ms and produces no audio.
    // Probe runs its blocking setCategory/setActive on the audio queue so the
    // main thread (and thus the picker UI) never stalls — even on the BT path
    // where the HFP handshake takes 1-3s. `completion` fires back on main once
    // the route has settled, so the picker can refresh its badge/menu.
    //
    // SIDE EFFECT we MUST avoid spamming: setActive on .playAndRecord briefly
    // takes the audio route from any backgrounded music app (a ~1s playback
    // dip in AirPods). So this function early-returns if we've already probed
    // this launch — the picker can use btOutputDevice() forever after for BT
    // detection without touching the session again. Pass `force: true` only
    // when a real hardware enumeration is required (e.g. user just connected
    // a USB mic and we need its name).
    func probeInputs(force: Bool = false, completion: (() -> Void)? = nil) {
        if !force, hasProbedThisLaunch {
            VRLog.d("Audio", "probeInputs skipped — already probed this launch")
            completion?()
            return
        }
        guard !isActive else {
            VRLog.d("Audio", "probeInputs skipped — session already active")
            logRoute("probe(active)")
            completion?()
            return
        }
        guard !isProbing else { completion?(); return }
        isProbing = true
        // Snapshot @MainActor-derived config before hopping off-actor.
        let mode = categoryMode
        let options = categoryOptions
        let sess = session
        audioQueue.async { [weak self] in
            var settledPort: AVAudioSession.Port? = nil
            do {
                try sess.setCategory(.playAndRecord, mode: mode, options: options)
                try sess.setActive(true)
                settledPort = sess.currentRoute.inputs.first?.portType
                try sess.setActive(false, options: [.notifyOthersOnDeactivation])
            } catch {
                VRLog.e("Audio", "probeInputs failed: \(error.localizedDescription)")
            }
            Task { @MainActor in
                guard let self else { return }
                self.isProbing = false
                self.hasProbedThisLaunch = true
                if let p = settledPort { self.lastActiveInputPort = p }
                self.logRoute("probe")
                completion?()
            }
        }
    }

    // A connected Bluetooth OUTPUT device (AirPods etc.) detected from the
    // current route, even when we're on the A2DP-only category where it never
    // appears as an INPUT. Returns (portType, name) so the picker can render a
    // synthetic "use AirPods as mic" entry. nil when no BT output is routed.
    func btOutputDevice() -> (port: AVAudioSession.Port, name: String)? {
        for out in session.currentRoute.outputs {
            switch out.portType {
            case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
                return (out.portType, out.portName)
            default:
                continue
            }
        }
        return nil
    }

    // Resolve the mic source the user effectively records from RIGHT NOW.
    // Order of precedence:
    //   1. The explicit user pick (wantsBluetoothMic → BT port from output
    //      route, since BT input only materialises after HFP is in options).
    //   2. The actually-routed input port (currentRoute.inputs.first).
    //   3. Empty route → fall back to the last port we saw while active.
    // Name is the port description from iOS ("AirPods Pro de Fedor", "iPhone Microphone").
    //
    // Returns (.unknown, "") when there's truly no input wired up — should be
    // rare; only happens right after launch before the first activate() lands.
    func currentMicSource() -> (kind: RecordingAttributes.MicSourceKind, name: String) {
        // Path 1: user explicitly picked BT. The HFP input may not be published
        // yet (category flip still settling), but the BT output device gives us
        // the same name iOS will eventually use for the input.
        if wantsBluetoothMic, let bt = btOutputDevice() {
            return (classifyBluetooth(name: bt.name), bt.name)
        }
        // Path 2: read the live input port.
        if let port = session.currentRoute.inputs.first {
            return (classify(port: port.portType, name: port.portName), port.portName)
        }
        // Path 3: cached last-active port (currentRoute is empty between records).
        if let last = lastActiveInputPort {
            return (classify(port: last, name: ""), portTypeFallbackName(last))
        }
        return (.unknown, "")
    }

    private nonisolated func classify(
        port: AVAudioSession.Port,
        name: String
    ) -> RecordingAttributes.MicSourceKind {
        switch port {
        case .builtInMic:
            return .iphone
        case .bluetoothHFP, .bluetoothLE, .bluetoothA2DP:
            return classifyBluetooth(name: name)
        case .headphones, .headsetMic:
            return .headphones
        case .usbAudio:
            return .usb
        default:
            return .unknown
        }
    }

    // Heuristic — Apple's AirPods always include "AirPods" in the port name.
    // Any other BT device falls under generic "headphones" so the user knows
    // it's not iPhone built-in, without us guessing brand specifics.
    private nonisolated func classifyBluetooth(name: String) -> RecordingAttributes.MicSourceKind {
        name.lowercased().contains("airpods") ? .airpods : .headphones
    }

    private nonisolated func portTypeFallbackName(_ p: AVAudioSession.Port) -> String {
        switch p {
        case .builtInMic:   return "iPhone"
        case .bluetoothHFP, .bluetoothLE, .bluetoothA2DP: return "Bluetooth"
        case .headphones, .headsetMic: return "Наушники"
        case .usbAudio:     return "USB"
        default:            return ""
        }
    }

    // Cache + dedupe layer so we only post the notification + write App Group
    // when (kind, name) ACTUALLY changes. Route change handler fires often
    // (every setCategory/setPreferredInput trips it), so without dedupe the
    // Live Activity would receive a stream of identical updates and burn its
    // per-app update budget.
    private var lastPublishedMicKind: RecordingAttributes.MicSourceKind?
    private var lastPublishedMicName: String?

    func publishMicSource(reason: String = "") {
        let (kind, name) = currentMicSource()
        if kind == lastPublishedMicKind && name == lastPublishedMicName {
            return
        }
        lastPublishedMicKind = kind
        lastPublishedMicName = name
        let d = AppGroupContainer.defaults
        d.set(kind.rawValue, forKey: VoiceRecordConfig.SharedKeys.lastMicSourceKind)
        d.set(name, forKey: VoiceRecordConfig.SharedKeys.lastMicSourceName)
        d.synchronize()
        VRLog.d("Audio", "publishMicSource [\(reason)] → kind=\(kind.rawValue) name=\"\(name)\"")
        NotificationCenter.default.post(
            name: Self.micSourceDidChange,
            object: nil,
            userInfo: ["kind": kind.rawValue, "name": name]
        )
    }

    // Picker calls this when the user taps a device in the menu. Records the
    // session-scoped target. Switching the TARGET may flip the category (iPhone
    // A2DP-only ↔ AirPods HFP), so when recording is live we must re-apply the
    // category, not just preferredInput. The iPhone path is fast (no HFP); the
    // AirPods path carries the inherent BT-handshake delay (picker shows a loader).
    func selectInput(_ port: AVAudioSession.Port, completion: (() -> Void)? = nil) {
        let wasBT = wantsBluetoothMic
        if port == .builtInMic {
            // Choosing iPhone explicitly = force-iPhone semantics. Clears override.
            AppGroupContainer.defaults.set(true, forKey: VoiceRecordConfig.SharedKeys.forceBuiltInMic)
            AppGroupContainer.defaults.synchronize()
            preferredPortOverride = nil
        } else {
            // BT pick: clear force, set override to the BT port.
            if forceBuiltInMic {
                AppGroupContainer.defaults.set(false, forKey: VoiceRecordConfig.SharedKeys.forceBuiltInMic)
                AppGroupContainer.defaults.synchronize()
            }
            preferredPortOverride = port
        }
        let categoryFlipped = (wasBT != wantsBluetoothMic)
        VRLog.d("Audio", "selectInput → \(port.rawValue) wantsBT=\(wantsBluetoothMic) categoryFlipped=\(categoryFlipped)")
        if isActive {
            // Live recording: blocking setCategory/setPreferredInput off-main so
            // the picker doesn't freeze during the HFP handshake on the BT path.
            let mode = categoryMode
            let options = categoryOptions
            let sess = session
            let forceBI = forceBuiltInMic
            let wantsBT = wantsBluetoothMic
            audioQueue.async { [weak self] in
                if categoryFlipped {
                    try? sess.setCategory(.playAndRecord, mode: mode, options: options)
                }
                let chosen = Self.pickPort(from: sess.availableInputs ?? [], forceBuiltIn: forceBI, wantsBT: wantsBT)
                if sess.preferredInput?.uid != chosen?.uid {
                    try? sess.setPreferredInput(chosen)
                }
                let settled = sess.currentRoute.inputs.first?.portType
                Task { @MainActor in
                    if let s = settled { self?.lastActiveInputPort = s }
                    self?.publishMicSource(reason: "selectInput-active")
                    completion?()
                }
            }
        } else {
            // Not recording: DON'T touch the session at all. Just persist the
            // target via the flags above; the next activate() (when the user
            // starts a recording) will pick them up. Touching setCategory/
            // setActive here would steal the route from any background music
            // for ~1s — a wholly avoidable interruption since nothing is being
            // recorded yet.
            //
            // BUT the resolved mic source (kind/name) has changed even without
            // touching the session: wantsBluetoothMic just flipped, so what we
            // SHOW the user (Live Activity, navbar, etc.) must reflect the new
            // pick immediately. publishMicSource reads wantsBluetoothMic +
            // btOutputDevice rather than the live input port, so it's correct
            // even before the next activate() lands.
            publishMicSource(reason: "selectInput-inactive")
            completion?()
        }
    }

    // Dump the full input picture to the cross-process log. Called after every
    // category/route change so we can diagnose "AirPods not in the list" from
    // the device without a debugger. Logs: every available input port (type +
    // name + whether it carries a usable mic), the current active route input,
    // and the forceBuiltInMic flag state.
    func logRoute(_ context: String) {
        let inputs = availableInputs
        let list = inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ", ")
        let current = currentInputPortType?.rawValue ?? "nil"
        VRLog.d("Audio", "[\(context)] availableInputs=[\(list)] current=\(current) forceBuiltIn=\(forceBuiltInMic) active=\(isActive)")
    }

    func applyPreferredInput() throws {
        let inputs = availableInputs
        let chosen: AVAudioSessionPortDescription?
        if forceBuiltInMic {
            // Hard pin to iPhone built-in regardless of what's connected.
            chosen = inputs.first { $0.portType == .builtInMic }
        } else if wantsBluetoothMic {
            // User explicitly picked AirPods. The exact BT subtype iOS lists
            // (bluetoothHFP) may differ from the output subtype we recorded as
            // the override (often bluetoothA2DP), so match ANY bluetooth input.
            chosen = inputs.first { input in
                input.portType == .bluetoothHFP ||
                input.portType == .bluetoothLE
            }
            // If the HFP input isn't published yet (category flip still settling)
            // leave nil = system default; the just-enabled HFP route will win.
        } else {
            // Follow the SYSTEM default: setPreferredInput(nil) lets iOS route to
            // the highest-priority connected accessory. When AirPods connect,
            // iOS makes them the default input — so passing nil is what makes the
            // badge auto-switch to AirPods. Previously we forced builtInMic-first
            // here, which is exactly why AirPods never became default.
            chosen = nil
        }
        // IDEMPOTENCY GUARD — critical. setPreferredInput() itself posts a
        // routeChangeNotification (reason .categoryChange / .override). Our
        // route-change handler calls applyPreferredInput() again → which calls
        // setPreferredInput() → which posts another notification → infinite
        // loop that pegs the main thread and freezes the UI for seconds
        // (observed: a wall of "routeChange categoryChange" log lines). Only
        // write when the target actually differs from the current preferred
        // input. nil==nil (already on system default) is a no-op too.
        if session.preferredInput?.uid == chosen?.uid {
            return
        }
        try session.setPreferredInput(chosen)
        VRLog.d("Audio", "applyPreferredInput → \(chosen?.portType.rawValue ?? "system-default(nil)") (forceBuiltIn=\(forceBuiltInMic) override=\(preferredPortOverride?.rawValue ?? "nil"))")
    }

    private func installObservers() {
        removeObservers()
        let nc = NotificationCenter.default
        routeObserver = nc.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleRouteChange(note) }
        }
        interruptionObserver = nc.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        }
        mediaResetObserver = nc.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.activate { _ in } }
        }
    }

    // Same handler the interruption-ended path uses — moved out of the inline
    // call so it shares the async activate signature.
    private func reactivateAfterInterruption() {
        activate { _ in }
    }

    private func removeObservers() {
        let nc = NotificationCenter.default
        if let o = routeObserver { nc.removeObserver(o) }
        if let o = interruptionObserver { nc.removeObserver(o) }
        if let o = mediaResetObserver { nc.removeObserver(o) }
        routeObserver = nil; interruptionObserver = nil; mediaResetObserver = nil
    }

    private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        VRLog.d("Audio", "routeChange reason=\(routeReasonName(reason))")
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .categoryChange, .wakeFromSleep, .override:
            // iOS may have nilled preferredInput. Re-apply on next runloop turn.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let before = self.currentInputPortType
                try? self.applyPreferredInput()
                let after = self.currentInputPortType
                if self.isActive { self.lastActiveInputPort = after }
                self.logRoute("routeChange:\(self.routeReasonName(reason))")
                // Only ping the recorder when the session is live AND the input
                // port actually changed. Reconnect during recording → rebuild tap
                // at the new device's sample rate.
                if self.isActive, before != after {
                    VRLog.d("Audio", "active route input changed \(before?.rawValue ?? "nil") → \(after?.rawValue ?? "nil") — notifying recorder")
                    self.onActiveRouteChange?()
                }
                self.publishMicSource(reason: "routeChange:\(self.routeReasonName(reason))")
            }
        default:
            break
        }
    }

    private func routeReasonName(_ r: AVAudioSession.RouteChangeReason) -> String {
        switch r {
        case .newDeviceAvailable:       return "newDeviceAvailable"
        case .oldDeviceUnavailable:     return "oldDeviceUnavailable"
        case .categoryChange:           return "categoryChange"
        case .override:                 return "override"
        case .wakeFromSleep:            return "wakeFromSleep"
        case .noSuitableRouteForCategory: return "noSuitableRoute"
        case .routeConfigurationChange: return "routeConfigChange"
        case .unknown:                  return "unknown"
        @unknown default:               return "other(\(r.rawValue))"
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            break
        case .ended:
            if let optsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
               AVAudioSession.InterruptionOptions(rawValue: optsRaw).contains(.shouldResume) {
                reactivateAfterInterruption()
            }
        @unknown default:
            break
        }
    }
}
