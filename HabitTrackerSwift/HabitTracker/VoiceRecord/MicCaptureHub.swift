import AVFoundation
import Foundation

// Shared microphone capture hub. ONE AVAudioEngine + one input tap for the
// whole app, fanning resampled 16 kHz s16le mono PCM out to any number of
// sinks.
//
// WHY a shared hub (extracted from DictationSession): iOS gives a process a
// SINGLE input route at a time — you cannot open two engines on two different
// physical mics simultaneously. So parallel recordings must share ONE capture
// and split the stream, not run two engines. The hub is that shared capture.
//
// Responsibilities lifted out of DictationSession (so sinks never touch audio
// hardware concerns):
//   • AVAudioSession activation — delegated to AudioSessionManager, idempotent.
//   • engine + input tap install / teardown, REF-COUNTED by attached sinks: the
//     engine starts on the first attach and stops only when the LAST sink
//     detaches. The AVAudioSession itself is NOT deactivated here — that stays
//     the always-active pattern (only an intent-stop or reconfigure releases it).
//   • native-rate → 16 kHz linear-interpolation resampling.
//   • rebuilding the tap on a mid-recording route change (AirPods plug/unplug),
//     reading the NEW device's native rate so the resampler never runs stale —
//     the chipmunk/slow-audio class of bug is contained entirely in here.
//
// Sinks therefore receive a clean, rate-normalised stream and are blind to the
// hardware rate, the engine lifecycle, and the session category.

@MainActor
protocol MicPCMSink: AnyObject {
    // A fresh 16 kHz s16le mono frame. Delivered on the main actor. The hub
    // pushes the same Data to every attached sink; each sink decides how to
    // store or stream its own copy.
    func micDidCapture(_ pcm: Data)
}

@MainActor
final class MicCaptureHub {
    static let shared = MicCaptureHub()
    private init() {}

    private let engine = AVAudioEngine()
    private let targetRate: Double = VoiceRecordConfig.targetSampleRate

    // Weakly-held sinks — RecordingCoordinator owns the DictationSessions; the
    // hub must never extend their lifetime. Dead entries are pruned on fan-out
    // and on detach.
    private struct WeakSink { weak var sink: MicPCMSink? }
    private var sinks: [WeakSink] = []

    private enum State { case idle, starting, running }
    private var state: State = .idle
    // Completions waiting on an in-flight activation to resolve — e.g. a second
    // sink that attached while the first was still starting the engine. They
    // all fire together once activation + engine.start() settles.
    private var pendingStarts: [(Result<Void, Error>) -> Void] = []
    // Observer for AVAudioEngine config changes (e.g. the user switches the
    // built-in mic data source Bottom/Front/Back mid-recording, which flips the
    // category mode .measurement→.default and reconfigures the graph; or any
    // hardware route reconfig). When this fires the engine has ALREADY stopped
    // itself — we must rebuild the tap + restart, or capture silently dies.
    private var configChangeObserver: NSObjectProtocol?
    // Re-entrancy guard: rebuildTap stops+starts the engine, which itself posts
    // AVAudioEngineConfigurationChange. Without this the handler would recurse.
    private var isRebuilding = false
    // Safety-net watchdog while capturing. Interruptions do NOT reliably deliver
    // an .ended event (Apple documents this; a coincident route glitch or a
    // backgrounded app can leave us stopped with no notification). The user's
    // rule is absolute — "only the Stop button stops the recording" — so we poll
    // engine.isRunning every 2s and, if it died while we still have an attached
    // sink, run the same reactivate + restart recovery. Cheap (a bool read);
    // invalidated the moment the last sink detaches.
    private var captureWatchdog: Timer?
    private static let captureWatchdogInterval: TimeInterval = 2.0
    // Serialises recovery — see resumeCaptureAfterSessionLoss.
    private var isResuming = false

    // True while the engine is actually capturing (privacy indicator lit). Used
    // by the coordinator to gate "is anything recording right now".
    var isCapturing: Bool { state == .running }
    var activeSinkCount: Int { sinks.reduce(0) { $0 + ($1.sink == nil ? 0 : 1) } }

    // Attach a sink and ensure capture is live. If the engine is already
    // running the sink just joins the fan-out and `completion` fires success
    // immediately (it starts receiving frames from the next buffer); otherwise
    // the session is activated + the engine started first, and `completion`
    // fires when that settles. Re-attaching an already-attached sink is a no-op.
    func attach(_ sink: MicPCMSink, completion: @escaping (Result<Void, Error>) -> Void) {
        if !sinks.contains(where: { $0.sink === sink }) {
            sinks.append(WeakSink(sink: sink))
        }
        switch state {
        case .running:
            VRLog.d("MicHub", "attach — engine already running, sinks=\(activeSinkCount)")
            completion(.success(()))
        case .starting:
            VRLog.d("MicHub", "attach — joining in-flight start, sinks=\(activeSinkCount)")
            pendingStarts.append(completion)
        case .idle:
            VRLog.d("MicHub", "attach — first sink, starting engine")
            state = .starting
            pendingStarts.append(completion)
            startEngine()
        }
    }

    // Detach a sink. When the LAST one leaves, stop the engine + remove the tap.
    // The AVAudioSession stays active (always-active pattern). Idempotent — a
    // sink that was never attached, or detached twice, is harmless.
    func detach(_ sink: MicPCMSink) {
        sinks.removeAll { $0.sink === sink || $0.sink == nil }
        VRLog.d("MicHub", "detach — remaining sinks=\(activeSinkCount)")
        if activeSinkCount == 0 { stopEngine() }
    }

    // MARK: - Engine lifecycle

    private func startEngine() {
        // activate() runs the blocking setCategory/setActive on its own serial
        // queue and calls back on main. Mirrors DictationSession's old start().
        AudioSessionManager.shared.activate { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                self.state = .idle
                VRLog.e("MicHub", "activate failed: \(err.localizedDescription)")
                self.flushPendingStarts(.failure(err))
            case .success:
                // Own the route-change hook for the engine's lifetime — a
                // device swap rebuilds the SHARED tap at the new rate for all
                // sinks at once.
                AudioSessionManager.shared.onActiveRouteChange = { [weak self] in
                    self?.rebuildTap(reason: "route-change")
                }
                // Own the interruption hook too: when the system deactivates the
                // session (a phone call, Siri, an alarm, another app grabbing the
                // route) it ALSO stops our engine. `.began` is just logged; on
                // `.ended` (and on media-services reset) we reactivate the session
                // and restart capture so the recording survives — the user's rule
                // is "only the Stop button stops the recording".
                AudioSessionManager.shared.onInterruption = { [weak self] began in
                    guard let self else { return }
                    if began {
                        VRLog.d("MicHub", "session interruption began — engine paused by system")
                    } else {
                        self.resumeCaptureAfterSessionLoss()
                    }
                }
                do {
                    try self.tryStartEngine()
                    self.state = .running
                    self.installConfigChangeObserver()
                    VRLog.d("MicHub", "engine started — sinks=\(self.activeSinkCount)")
                    self.flushPendingStarts(.success(()))
                } catch {
                    // engine.start() failed — overwhelmingly this is -50 from a
                    // session our flag THINKS is active but the system silently
                    // deactivated (a missed interruption). Force a hard
                    // reactivation (drops the stale flag so setActive(true) really
                    // runs) and retry ONCE, so it self-heals instead of needing an
                    // app relaunch.
                    VRLog.e("MicHub", "engine start failed: \(error.localizedDescription) — hard-reactivate + retry")
                    AudioSessionManager.shared.reactivateHard { [weak self] r in
                        guard let self else { return }
                        if case .failure(let e) = r { self.failStart(e); return }
                        do {
                            try self.tryStartEngine()
                            self.state = .running
                            self.installConfigChangeObserver()
                            VRLog.d("MicHub", "engine started after hard-reactivate — sinks=\(self.activeSinkCount)")
                            self.flushPendingStarts(.success(()))
                        } catch {
                            self.failStart(error)
                        }
                    }
                }
            }
        }
    }

    // Install the input tap and start the engine. removeTap first so it's safe
    // to call on a fresh engine (no tap yet) AND on resume after an interruption
    // (a stale tap may still be registered — installing a second on the same bus
    // would assert). Throws whatever engine.start() throws. Arms the capture
    // watchdog on success so a later silent death is caught.
    private func tryStartEngine() throws {
        engine.inputNode.removeTap(onBus: 0)
        installTap()
        engine.prepare()
        try engine.start()
        armCaptureWatchdog()
    }

    // Poll engine.isRunning while we should be capturing. If the engine died
    // (an interruption that never delivered .ended, a route glitch) but a sink
    // is still attached, recover. The reactivate+restart path itself is guarded
    // (reactivateHard hops the audio queue), and resumeCaptureAfterSessionLoss
    // re-checks state, so a spurious tick during a legitimate rebuild is safe.
    private func armCaptureWatchdog() {
        captureWatchdog?.invalidate()
        captureWatchdog = Timer.scheduledTimer(
            withTimeInterval: Self.captureWatchdogInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.state == .running, self.activeSinkCount > 0, !self.isRebuilding else { return }
                if !self.engine.isRunning {
                    VRLog.e("MicHub", "watchdog — engine not running while capturing, recovering")
                    self.resumeCaptureAfterSessionLoss()
                }
            }
        }
    }

    // Terminal failure of an initial start (after the one hard-reactivate retry).
    // Tear everything down and report failure to the awaiting attach() callers.
    private func failStart(_ error: Error) {
        teardownTap()
        AudioSessionManager.shared.onActiveRouteChange = nil
        AudioSessionManager.shared.onInterruption = nil
        state = .idle
        VRLog.e("MicHub", "engine start ultimately failed: \(error.localizedDescription)")
        flushPendingStarts(.failure(error))
    }

    // Resume capture after the audio session was lost (interruption ended, or
    // mediaServicesWereReset). The system stopped our engine; reactivate the
    // session and restart it so frames flow into the live recording again. Gated
    // on "we should be capturing" (running state + an attached sink) so an
    // interruption that ends while idle, or after the user already stopped,
    // doesn't spuriously re-light the mic. On failure we deliberately KEEP
    // state=.running (the sink is still attached and the UI still shows
    // recording) so a later route/config change or the next user action can
    // retry — flipping to idle here would desync the UI from a live sink.
    func resumeCaptureAfterSessionLoss() {
        guard state == .running, activeSinkCount > 0 else { return }
        // Re-entrancy guard: the .ended interruption event and the 2s watchdog
        // can both decide to recover at once, and each reactivateHard hops the
        // audio queue async — two overlapping reactivations would race on
        // engine.start(). isResuming serialises them; the loser no-ops.
        guard !isResuming else { VRLog.d("MicHub", "resume — already in flight, skip"); return }
        isResuming = true
        VRLog.d("MicHub", "resume after session loss — reactivate + restart engine")
        AudioSessionManager.shared.reactivateHard { [weak self] r in
            guard let self else { return }
            defer { self.isResuming = false }
            guard self.state == .running else { return }
            switch r {
            case .failure(let e):
                VRLog.e("MicHub", "resume — reactivate failed: \(e.localizedDescription)")
            case .success:
                do {
                    try self.tryStartEngine()
                    self.installConfigChangeObserver()
                    VRLog.d("MicHub", "resume — engine restarted, capture live again")
                } catch {
                    VRLog.e("MicHub", "resume — engine restart failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func stopEngine() {
        guard state != .idle else { return }
        captureWatchdog?.invalidate()
        captureWatchdog = nil
        teardownTap()
        AudioSessionManager.shared.onActiveRouteChange = nil
        AudioSessionManager.shared.onInterruption = nil
        removeConfigChangeObserver()
        state = .idle
        VRLog.d("MicHub", "engine stopped — no sinks left")
    }

    // AVAudioEngineConfigurationChange fires when the audio graph is
    // reconfigured out from under us — notably when the user switches the
    // built-in mic data source (Bottom/Front/Back) mid-recording (the category
    // mode flips .measurement→.default and the input reconfigures). By the time
    // it fires the engine has ALREADY stopped; if we don't rebuild the tap and
    // restart, capture silently dies. Same rebuild path as a route change.
    private func installConfigChangeObserver() {
        removeConfigChangeObserver()
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .running, !self.isRebuilding else { return }
                VRLog.d("MicHub", "AVAudioEngineConfigurationChange — rebuilding tap")
                self.rebuildTap(reason: "config-change")
            }
        }
    }

    private func removeConfigChangeObserver() {
        if let o = configChangeObserver {
            NotificationCenter.default.removeObserver(o)
            configChangeObserver = nil
        }
    }

    private func flushPendingStarts(_ result: Result<Void, Error>) {
        let cbs = pendingStarts
        pendingStarts.removeAll()
        for cb in cbs { cb(result) }
    }

    // MARK: - Tap

    // Installs the input tap, reading the CURRENT input format fresh each time
    // so a device swap is captured correctly (sourceRate is per-tap, never
    // cached across the session).
    private func installTap() {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let sourceRate = format.sampleRate
        VRLog.d("MicHub", "installTap — sourceRate=\(Int(sourceRate))Hz ch=\(format.channelCount)")
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let pcm = self.floatToS16LE16k(buffer: buffer, sourceRate: sourceRate)
            guard !pcm.isEmpty else { return }
            Task { @MainActor in self.fanOut(pcm) }
        }
    }

    private func teardownTap() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
    }

    // The engine must be stopped before swapping a tap, then restarted. The new
    // device's native rate is read fresh inside installTap, so the resampler
    // always runs at the live rate (built-in 48k ↔ AirPods HFP 16/24k swaps stay
    // correct). Sinks need no notification — they only ever see clean 16 kHz.
    private func rebuildTap(reason: String) {
        guard state == .running else { return }
        // Guard against re-entrancy: engine.stop()/start() below themselves post
        // AVAudioEngineConfigurationChange, which would call us again.
        guard !isRebuilding else { return }
        isRebuilding = true
        defer { isRebuilding = false }
        VRLog.d("MicHub", "rebuildTap — reason=\(reason) engineRunning=\(engine.isRunning)")
        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        installTap()
        if wasRunning {
            engine.prepare()
            do {
                try engine.start()
                VRLog.d("MicHub", "rebuildTap — engine restarted ok")
            } catch {
                VRLog.e("MicHub", "rebuildTap — engine restart failed: \(error.localizedDescription)")
            }
        }
    }

    private func fanOut(_ pcm: Data) {
        var hasDead = false
        for entry in sinks {
            if let s = entry.sink {
                s.micDidCapture(pcm)
            } else {
                hasDead = true
            }
        }
        if hasDead { sinks.removeAll { $0.sink == nil } }
    }

    // MARK: - PCM convert (Float32 mono → s16le @ 16 kHz)

    // Pure; runs on the audio render thread. Touches only the passed buffer and
    // the immutable `targetRate` (no AVAudioSession calls — per QA1715). Lifted
    // verbatim from DictationSession.floatToS16LE16k.
    private nonisolated func floatToS16LE16k(buffer: AVAudioPCMBuffer, sourceRate: Double) -> Data {
        guard let channelData = buffer.floatChannelData?[0] else { return Data() }
        let inputCount = Int(buffer.frameLength)
        if inputCount <= 0 { return Data() }
        let outputCount = Int(Double(inputCount) * targetRate / sourceRate)
        if outputCount <= 0 { return Data() }

        var bytes = Data(count: outputCount * 2)
        let ratio = sourceRate / targetRate
        bytes.withUnsafeMutableBytes { (rawPtr: UnsafeMutableRawBufferPointer) in
            let p = rawPtr.bindMemory(to: Int16.self)
            for i in 0..<outputCount {
                let idx = Double(i) * ratio
                let i0 = Int(idx)
                let i1 = min(i0 + 1, inputCount - 1)
                let frac = Float(idx - Double(i0))
                let s = channelData[i0] * (1 - frac) + channelData[i1] * frac
                let clamped = max(-1.0, min(1.0, s))
                p[i] = clamped < 0 ? Int16(clamped * 32768) : Int16(clamped * 32767)
            }
        }
        return bytes
    }
}
