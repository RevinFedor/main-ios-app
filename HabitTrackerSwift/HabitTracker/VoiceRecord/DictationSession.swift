import AVFoundation
import Foundation

// Port of voice-record/src/renderer/dictation.ts to Swift.
//
// Two independent state machines:
//   1. Mic capture — AVAudioEngine tap fills `allFrames` (full session
//      audio for the .wav) and `pending` (drained into Soniox WS on open).
//   2. Soniox WS — opens in parallel. ws.onopen drains `pending`. ws.onerror
//      or close does NOT stop mic — user can retry.
//
// Audio format on the wire: s16le @ 16kHz mono. Engine input runs at native
// rate (typically 48kHz, 44.1kHz, or lower) and we downsample with linear
// interpolation in `floatToS16LE16k`.

struct DictationUpdate {
    let final: String
    let partial: String
}

protocol DictationSessionDelegate: AnyObject {
    func dictation(_ session: DictationSession, didUpdate update: DictationUpdate)
    func dictation(_ session: DictationSession, didError message: String)
    // pcm is s16le @ 16kHz mono (full session). Empty if mic never produced data.
    // Always called once on stop (success or failure).
    func dictation(_ session: DictationSession, didStopWith pcm: Data)
    func dictationDidConnect(_ session: DictationSession)
    func dictation(_ session: DictationSession, didDisconnectReason reason: String)
    func dictation(_ session: DictationSession, didUpdateBufferedSeconds seconds: Double)
    // Lag tick while we're waiting for Soniox to commit the tail after the
    // user tapped Stop. lagSec = recordedSec - lastFinalEndMs/1000 — how many
    // seconds of audio Soniox still owes us in is_final tokens. 0 when caught
    // up; positive = still working. Coordinator surfaces this in the UI as
    // "Finalizing · 28s tail" so the user knows finalize is in flight, not
    // hung. Fires only between dictation.stop() and didStopWith.
    func dictation(_ session: DictationSession, didUpdateStoppingLagSeconds seconds: Double)
}

extension DictationSessionDelegate {
    func dictationDidConnect(_ session: DictationSession) {}
    func dictation(_ session: DictationSession, didDisconnectReason reason: String) {}
    func dictation(_ session: DictationSession, didUpdateBufferedSeconds seconds: Double) {}
    func dictation(_ session: DictationSession, didUpdateStoppingLagSeconds seconds: Double) {}
}

@MainActor
final class DictationSession: NSObject {
    weak var delegate: DictationSessionDelegate?

    private let engine = AVAudioEngine()
    private var inputFormat: AVAudioFormat?

    // Disconnect-safe buffers. pending = drained on WS open. allFrames = saved forever.
    private var pending: [Data] = []
    private var allFrames: [Data] = []
    private var bufferedSamples16k: Int = 0
    private var allSamples16k: Int = 0

    private var wsTask: URLSessionWebSocketTask?
    private var wsSession: URLSession?
    private var wsOpen = false
    // Connect watchdog. Was DispatchWorkItem on main queue, which deadlocked
    // when `try await task.send(...)` inside connectSoniox itself stalled
    // the main runloop. Task.sleep is independent of main and fires
    // regardless of who is blocked. Same lesson as in stop()'s hard-cap.
    private var wsOpenWatchdog: Task<Void, Never>?

    private var stopped = false
    private var stoppedFired = false
    private var forceStopTask: Task<Void, Never>?
    private var bufStatsTimer: Timer?

    private var finalText = ""
    private var partialText = ""
    // Max `end_ms` across all is_final tokens received from Soniox so far —
    // the position in the audio stream up to which Soniox has committed final
    // transcription. We use this together with `allSamples16k` (recorded
    // length in 16kHz samples) to measure the live finalize lag:
    //   lagSec = recordedSec − lastFinalEndMs/1000
    // The lag is what the UI surfaces while .stopping is in flight. It's
    // also how we know when Soniox is "caught up" — but we do NOT close the
    // socket ourselves on lag≈0; we wait for the explicit `{finished: true}`
    // message which means Soniox has actually flushed everything, including
    // the post-finalize endpoint detection tail (port of voice-record
    // fix-history-archive.md::Шрам #17).
    private var lastFinalEndMs: Double = 0
    private var stoppingProgressTimer: Timer?
    // Hard cap on the post-Stop wait. Soniox normally drains in 1-10 s after
    // the empty-text finalize signal, but on long dense speech the endpoint-
    // detection tail can be 20-30 s, and the WS can occasionally just stall.
    // 60 s is generous enough to cover real waits while still rescuing the
    // user from a frozen socket. Previously this was 2 s, which silently
    // truncated transcripts on every recording longer than ~30 s.
    private static let stopHardCapSeconds: Double = 60.0
    // How often we emit the lag tick to the UI during the .stopping window.
    private static let stoppingProgressInterval: TimeInterval = 0.25

    private let targetRate: Double = VoiceRecordConfig.targetSampleRate
    private let languageHints: [String]
    private let modelName: String

    init(languageHints: [String] = ["en", "ru"],
         modelName: String = VoiceRecordConfig.sonioxModel) {
        self.languageHints = languageHints
        self.modelName = modelName
    }

    func start() async {
        // Activate runs blocking AVAudioSession calls on a dedicated serial
        // queue and resumes on main when the session is live. Without this,
        // every recording start blocked the main thread for ~600ms-2s.
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                AudioSessionManager.shared.activate { result in
                    cont.resume(with: result)
                }
            }
        } catch {
            delegate?.dictation(self, didError: "audio session: \(error.localizedDescription)")
            fireStopped()
            return
        }

        // Rebuild the tap whenever the active input device changes mid-recording
        // (AirPods plugged/unplugged). The new device's native sample rate is
        // almost always different (built-in 48k ↔ AirPods HFP 16k/24k); reusing
        // the old rate in the resampler yields pitch-shifted, garbled audio.
        AudioSessionManager.shared.onActiveRouteChange = { [weak self] in
            self?.rebuildInputTap(reason: "route-change")
        }

        installInputTap()

        engine.prepare()
        do {
            try engine.start()
        } catch {
            delegate?.dictation(self, didError: "engine start: \(error.localizedDescription)")
            cleanup()
            fireStopped()
            return
        }

        bufStatsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.emitBufStats() }
        }

        VRLog.d("Dict", "start — scheduling connectSoniox()")
        Task { await connectSoniox() }
    }

    // Installs (or re-installs) the input tap, reading the CURRENT input format
    // fresh each time. sourceRate is captured per-tap, never cached across the
    // session, so a device swap is handled correctly.
    private func installInputTap() {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        inputFormat = format
        let sourceRate = format.sampleRate
        VRLog.d("Dict", "installTap — sourceRate=\(Int(sourceRate))Hz ch=\(format.channelCount)")
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let pcm = self.floatToS16LE16k(buffer: buffer, sourceRate: sourceRate)
            guard !pcm.isEmpty else { return }
            Task { @MainActor in self.handleCapturedFrame(pcm) }
        }
    }

    // Called when AudioSessionManager reports a live input-device change. The
    // AVAudioEngine must be stopped before removing/re-adding a tap, then
    // restarted — hot-swapping a tap on a running engine throws. PCM already
    // captured stays in allFrames/pending, so the transcript is continuous
    // across the swap (a brief ~100ms gap during restart is acceptable).
    private func rebuildInputTap(reason: String) {
        guard !stopped else { return }
        VRLog.d("Dict", "rebuildInputTap — reason=\(reason) engineRunning=\(engine.isRunning)")
        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        installInputTap()
        if wasRunning {
            engine.prepare()
            do {
                try engine.start()
                VRLog.d("Dict", "rebuildInputTap — engine restarted ok")
            } catch {
                // If restart fails the user can still stop and retry; surface it.
                delegate?.dictation(self, didError: "mic switch failed: \(error.localizedDescription)")
                VRLog.e("Dict", "rebuildInputTap — engine restart failed: \(error.localizedDescription)")
            }
        }
    }

    func stop() async {
        VRLog.d("Dict", "stop() — entered, stopped=\(stopped) wsOpen=\(wsOpen) recorded=\(String(format: "%.1f", Double(allSamples16k)/targetRate))s lastFinalEnd=\(String(format: "%.1f", lastFinalEndMs/1000))s lag=\(String(format: "%.1f", lagSeconds))s")
        if stopped {
            cleanup()
            fireStopped()
            return
        }
        stopped = true

        // CRITICAL: stop the mic immediately — we don't want to record (or
        // send to Soniox) anything captured AFTER the user pressed Stop.
        // The PCM history (collectedPCM → .wav) also freezes here. Soniox
        // already has everything we want transcribed; we're just waiting
        // for it to commit final tokens for the audio we already sent.
        // Without this, `handleCapturedFrame` would keep appending to
        // `allFrames` and emitting to the WS during the entire finalize
        // wait — both wrong (extra audio shipped post-Stop) and wasteful.
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        bufStatsTimer?.invalidate()
        bufStatsTimer = nil

        if !wsOpen || wsTask == nil {
            // WS never connected (cold-start failure, immediate Stop) or
            // already closed. fireStopped will emit whatever PCM we have so
            // the caller can still save the .wav and offer a retranscribe.
            wsTask?.cancel()
            cleanup()
            fireStopped()
            return
        }

        // WS is open. Send Soniox's end-of-stream signal, then wait for it
        // to drain remaining is_final tokens and close the socket. We rely
        // on `recvLoop` catching that close and calling `fireStopped()`.
        //
        // CRITICAL: Soniox listens for an empty TEXT frame (`""`), not an
        // empty BINARY frame (`Data()`). The two are different WebSocket
        // opcodes (0x1 vs 0x2); Soniox `stt-rt-v4` silently ignores the
        // binary variant — no `{finished:true}`, no close, the hard cap
        // eventually fires and ships a truncated transcript. This is the
        // root cause of "stop cuts off the tail of long recordings"; the
        // fix is the empty-string text frame.
        // Reference: voice-record/docs/knowledge/fix-history-archive.md::Шрам #17 Re-fix.
        let task = wsTask!
        task.send(.string("")) { error in
            if let error {
                VRLog.e("Dict", "stop() — finalize text frame send err: \(error.localizedDescription)")
            } else {
                VRLog.d("Dict", "stop() — finalize TEXT frame sent")
            }
        }

        // Live lag indicator. is_final tokens keep arriving during the wait
        // and shrink the lag — the UI shows "Finalizing · 23s tail" ticking
        // down so the user knows it's working, not hung.
        emitStoppingProgress()
        stoppingProgressTimer = Timer.scheduledTimer(
            withTimeInterval: Self.stoppingProgressInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.emitStoppingProgress() }
        }

        // Hard cap — Soniox normally finalises within a few seconds of the
        // empty signal, but on a frozen WS (network split mid-drain, app
        // suspended past system patience) we don't want the user stuck on
        // "Finalizing…" forever. 60 s is comfortably above the worst
        // observed real finalize tail (~30 s) and below the Apple AppIntent
        // budget on which this method is awaited from a Shortcut path.
        // fireStopped() ships whatever finalText we had by that moment.
        forceStopTask?.cancel()
        forceStopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.stopHardCapSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                guard !self.stoppedFired else { return }
                VRLog.d("Dict", "stop() — hard-cap watchdog fired (\(Int(Self.stopHardCapSeconds))s) lag=\(String(format: "%.1f", self.lagSeconds))s")
                self.wsTask?.cancel()
                self.cleanup()
                self.fireStopped()
            }
        }
    }

    private func emitStoppingProgress() {
        guard !stoppedFired else { return }
        delegate?.dictation(self, didUpdateStoppingLagSeconds: lagSeconds)
    }

    // Hard cancel — drop everything, do NOT wait for Soniox finalize, do NOT
    // emit collected PCM. Used by the ✕ button in the Live Activity.
    func cancel() async {
        VRLog.d("Dict", "cancel() — entered")
        stopped = true
        wsTask?.cancel()
        cleanup()
        // Synthesize an empty fireStopped so the delegate's didStopWith
        // path still runs and clears UI state. Coordinator then knows to
        // suppress the save because pcm is empty.
        guard !stoppedFired else { return }
        stoppedFired = true
        forceStopTask?.cancel()
        forceStopTask = nil
        bufStatsTimer?.invalidate()
        bufStatsTimer = nil
        stoppingProgressTimer?.invalidate()
        stoppingProgressTimer = nil
        delegate?.dictation(self, didStopWith: Data())
    }

    func retry() async {
        guard !stopped else { return }
        await connectSoniox()
    }

    var bufferedSeconds: Double {
        Double(bufferedSamples16k) / targetRate
    }

    var collectedPCM: Data {
        var total = 0
        for f in allFrames { total += f.count }
        var out = Data(capacity: total)
        for f in allFrames { out.append(f) }
        return out
    }

    // MARK: - Internal

    private func handleCapturedFrame(_ pcm: Data) {
        allFrames.append(pcm)
        allSamples16k += pcm.count / 2
        if wsOpen, let task = wsTask {
            task.send(.data(pcm)) { _ in /* swallow per-frame errors; ws.onclose handles disconnect */ }
        } else {
            pending.append(pcm)
            bufferedSamples16k += pcm.count / 2
        }
    }

    private func emitBufStats() {
        delegate?.dictation(self, didUpdateBufferedSeconds: bufferedSeconds)
    }

    private func fireStopped() {
        guard !stoppedFired else { return }
        stoppedFired = true
        forceStopTask?.cancel()
        forceStopTask = nil
        bufStatsTimer?.invalidate()
        bufStatsTimer = nil
        stoppingProgressTimer?.invalidate()
        stoppingProgressTimer = nil
        VRLog.d("Dict", "fireStopped — emitting pcm=\(collectedPCM.count) bytes lag=\(String(format: "%.1f", lagSeconds))s")
        delegate?.dictation(self, didStopWith: collectedPCM)
    }

    private func cleanup() {
        AudioSessionManager.shared.onActiveRouteChange = nil
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        wsTask?.cancel()
        wsTask = nil
        wsSession?.invalidateAndCancel()
        wsSession = nil
        wsOpen = false
        wsOpenWatchdog?.cancel()
        wsOpenWatchdog = nil
        stoppingProgressTimer?.invalidate()
        stoppingProgressTimer = nil
        pending.removeAll()
        bufferedSamples16k = 0
    }

    // MARK: - Soniox WS

    private func connectSoniox() async {
        VRLog.d("Dict", "connectSoniox — begin stopped=\(stopped)")
        if stopped { VRLog.d("Dict", "connectSoniox — abort (stopped)"); return }
        // Tear down any prior socket.
        wsTask?.cancel()
        wsTask = nil
        wsSession?.invalidateAndCancel()
        wsSession = nil
        wsOpen = false
        wsOpenWatchdog?.cancel()
        wsOpenWatchdog = nil

        // Arm the connect watchdog BEFORE the network calls so a hung mint /
        // hung ws.send still resolves to a visible error within 10s. Previous
        // version armed it AFTER `task.resume()`, which meant a stalled token
        // fetch (>10s) silently kept the user in `.starting` forever with no
        // diagnostic. Task-based, not DispatchQueue.main.asyncAfter — main can
        // be blocked by the very `try await task.send(...)` we're racing
        // against, but Task.sleep is independent of main and fires regardless.
        let watchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            await MainActor.run {
                guard let self else { return }
                if Task.isCancelled { return }
                if !self.wsOpen {
                    VRLog.e("Dict", "connect watchdog FIRED (10s) — wsOpen=false")
                    self.delegate?.dictation(self, didError: "socket: connection timeout")
                    self.wsTask?.cancel()
                }
            }
        }
        wsOpenWatchdog = watchdogTask

        let apiKey: String
        do {
            VRLog.d("Dict", "mintTemporaryKey — calling")
            apiKey = try await SonioxTokenMint.mintTemporaryKey()
            VRLog.d("Dict", "mintTemporaryKey — ok keyLen=\(apiKey.count)")
        } catch {
            VRLog.e("Dict", "mintTemporaryKey — failed: \(error.localizedDescription)")
            watchdogTask.cancel()
            wsOpenWatchdog = nil
            delegate?.dictation(self, didError: "token: \(error.localizedDescription)")
            return
        }
        if stopped {
            VRLog.d("Dict", "connectSoniox — stopped during mint, abort")
            watchdogTask.cancel()
            wsOpenWatchdog = nil
            return
        }

        VRLog.d("Dict", "ws create — url=\(VoiceRecordConfig.sonioxWSURL)")
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 10
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg)
        let task = session.webSocketTask(with: URL(string: VoiceRecordConfig.sonioxWSURL)!)
        wsSession = session
        wsTask = task
        task.resume()
        VRLog.d("Dict", "ws task.resume() — state=\(task.state.rawValue)")

        // Send config + flush pending right away — Soniox accepts JSON config as
        // first frame, then binary PCM frames.
        let config: [String: Any] = [
            "api_key": apiKey,
            "model": modelName,
            "audio_format": "s16le",
            "sample_rate": Int(targetRate),
            "num_channels": 1,
            "language_hints": languageHints,
            "enable_endpoint_detection": true,
        ]
        do {
            let configData = try JSONSerialization.data(withJSONObject: config)
            let configStr = String(data: configData, encoding: .utf8) ?? "{}"
            VRLog.d("Dict", "ws config — sending (len=\(configStr.count))")
            try await task.send(.string(configStr))
            VRLog.d("Dict", "ws config — sent")
        } catch {
            VRLog.e("Dict", "ws config — failed: \(error.localizedDescription)")
            watchdogTask.cancel()
            wsOpenWatchdog = nil
            delegate?.dictation(self, didError: "ws config: \(error.localizedDescription)")
            return
        }

        // Flush pending PCM frames.
        let pendingCount = pending.count
        if pendingCount > 0 {
            VRLog.d("Dict", "ws flush — \(pendingCount) buffered PCM frames")
        }
        for buf in pending {
            try? await task.send(.data(buf))
        }
        pending.removeAll()
        bufferedSamples16k = 0
        emitBufStats()

        wsOpen = true
        watchdogTask.cancel()
        wsOpenWatchdog = nil
        VRLog.d("Dict", "ws OPEN — dictationDidConnect")
        delegate?.dictationDidConnect(self)

        // Receive loop.
        Task { [weak self] in await self?.recvLoop(task: task) }
    }

    private func recvLoop(task: URLSessionWebSocketTask) async {
        // Loop runs until the socket actually closes — NOT until we set
        // `stopped`. After the user taps Stop and we send the empty TEXT
        // frame, Soniox still emits its remaining is_final tokens (which we
        // MUST collect — that's the whole point of waiting), then a final
        // `{finished:true}` message, then closes the socket. If we bailed
        // on `stopped` we'd miss those tokens and ship a truncated
        // transcript. The throw on socket close is what ends the loop.
        while true {
            do {
                let msg = try await task.receive()
                handleWSMessage(msg)
            } catch {
                wsOpen = false
                let reason = error.localizedDescription
                if stopped {
                    cleanup()
                    fireStopped()
                } else {
                    delegate?.dictation(self, didDisconnectReason: reason)
                }
                return
            }
        }
    }

    private func handleWSMessage(_ msg: URLSessionWebSocketTask.Message) {
        let text: String?
        switch msg {
        case .string(let s): text = s
        case .data(let d):   text = String(data: d, encoding: .utf8)
        @unknown default:    text = nil
        }
        guard let raw = text, let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let errCode = obj["error_code"] {
            let errMsg = obj["error_message"] as? String ?? ""
            delegate?.dictation(self, didError: "soniox \(errCode): \(errMsg)")
            return
        }
        // Soniox emits `{finished: true, final_audio_proc_ms, total_audio_proc_ms}`
        // as the LAST message before closing the socket — it means every
        // is_final token for the audio we've sent has been delivered. We log
        // and let the natural ws.onclose path (recvLoop catches a normal
        // close) drive cleanup. We do NOT preemptively close on lag≈0 — the
        // server keeps a small post-finalize buffer for endpoint detection
        // and `finished:true` is the authoritative signal.
        if let finished = obj["finished"] as? Bool, finished {
            let procMs = (obj["final_audio_proc_ms"] as? Double) ?? -1
            let totalMs = (obj["total_audio_proc_ms"] as? Double) ?? -1
            VRLog.d("Dict", "soniox finished:true (final_audio_proc_ms=\(procMs) total=\(totalMs)ms lag=\(String(format: "%.1f", lagSeconds))s)")
        }
        guard let tokens = obj["tokens"] as? [[String: Any]] else { return }
        var newFinal = ""
        var newPartial = ""
        var maxFinalEndMs = lastFinalEndMs
        let tagRegex = try? NSRegularExpression(pattern: "^<[a-z_]+>$", options: .caseInsensitive)
        for t in tokens {
            guard let txt = t["text"] as? String else { continue }
            if let regex = tagRegex {
                let range = NSRange(location: 0, length: txt.utf16.count)
                if regex.firstMatch(in: txt, range: range) != nil { continue }
            }
            let isFinal = (t["is_final"] as? Bool) ?? false
            if isFinal {
                newFinal += txt
                // Track the farthest committed-final boundary for lag accounting.
                if let endMs = t["end_ms"] as? Double, endMs > maxFinalEndMs {
                    maxFinalEndMs = endMs
                }
            } else {
                newPartial += txt
            }
        }
        if !newFinal.isEmpty { finalText += newFinal }
        lastFinalEndMs = maxFinalEndMs
        partialText = newPartial
        delegate?.dictation(self, didUpdate: DictationUpdate(final: finalText, partial: partialText))
    }

    // Seconds of audio Soniox has NOT yet committed as is_final (i.e. how far
    // behind the finalisation pipeline is). Drives the live "Finalizing · Xs
    // tail" indicator during .stopping. Clamps at 0 so we never display a
    // negative lag when last_end_ms briefly overshoots recordedSec (rounding
    // can give microsecond mismatches).
    var lagSeconds: Double {
        let recordedSec = Double(allSamples16k) / targetRate
        let finalSec = lastFinalEndMs / 1000.0
        let lag = recordedSec - finalSec
        return lag > 0 ? lag : 0
    }

    // MARK: - PCM convert (Float32 mono → s16le @ 16kHz)

    private func floatToS16LE16k(buffer: AVAudioPCMBuffer, sourceRate: Double) -> Data {
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
