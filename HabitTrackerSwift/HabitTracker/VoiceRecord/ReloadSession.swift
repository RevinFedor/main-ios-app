import Foundation

// One-shot helper to re-transcribe an existing .wav file via the same Soniox
// WebSocket transport DictationSession uses. Does NOT capture microphone —
// just streams known PCM bytes (s16le @ 16kHz mono) and collects the final
// transcript.

@MainActor
final class ReloadSession {
    func run(pcm: Data) async -> Result<String, Error> {
        let bytes = pcm.count
        let approxSec = Double(bytes / 2) / 16000.0
        VRLog.d("Reload", "begin: pcm=\(bytes) bytes (~\(String(format: "%.1f", approxSec))s)")

        let apiKey: String
        do {
            apiKey = try await SonioxTokenMint.mintTemporaryKey()
            VRLog.d("Reload", "token minted")
        } catch {
            VRLog.e("Reload", "token mint failed: \(error.localizedDescription)")
            return .failure(error)
        }

        // 5-min total timeout per request. Soniox transcribes near-realtime
        // (~10s of audio per 1s wall), so 5 min covers up to ~30 min of audio
        // — plenty of buffer for slow connections.
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = 300
        cfg.waitsForConnectivity = true
        let session = URLSession(configuration: cfg)
        let task = session.webSocketTask(with: URL(string: VoiceRecordConfig.sonioxWSURL)!)
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }
        task.resume()
        VRLog.d("Reload", "ws task resumed")

        let config: [String: Any] = [
            "api_key": apiKey,
            "model": VoiceRecordConfig.sonioxModel,
            "audio_format": "s16le",
            "sample_rate": Int(VoiceRecordConfig.targetSampleRate),
            "num_channels": 1,
            "language_hints": ["en", "ru"],
            "enable_endpoint_detection": true,
        ]
        do {
            let configData = try JSONSerialization.data(withJSONObject: config)
            let configStr = String(data: configData, encoding: .utf8) ?? "{}"
            try await task.send(.string(configStr))
            VRLog.d("Reload", "config sent")
        } catch {
            VRLog.e("Reload", "config send failed: \(error.localizedDescription)")
            return .failure(error)
        }

        // Stream PCM in ~64 KB chunks. Yield each iteration so the receive
        // loop can drain server frames in parallel; without yields, we'd
        // buffer the whole 2 MB before any token arrives.
        let chunkSize = 64 * 1024
        var offset = 0
        var chunkN = 0
        while offset < pcm.count {
            let end = min(offset + chunkSize, pcm.count)
            let slice = pcm.subdata(in: offset..<end)
            do {
                try await task.send(.data(slice))
                chunkN += 1
                if chunkN % 10 == 0 {
                    VRLog.d("Reload", "sent \(chunkN) chunks (\(end)/\(bytes) bytes)")
                }
            } catch {
                VRLog.e("Reload", "send chunk \(chunkN) failed: \(error.localizedDescription)")
                return .failure(error)
            }
            offset = end
            // Tiny pause so receive() can interleave.
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        do {
            // CRITICAL: Soniox stt-rt-v4 listens for an empty TEXT frame ("") as
            // the end-of-stream signal, NOT an empty BINARY frame (Data()). They
            // are different WebSocket opcodes (0x1 vs 0x2); the binary variant is
            // SILENTLY IGNORED — no {finished:true}, no socket close, so the
            // receive loop below spins until the 300 s resource timeout. THAT is
            // the "retranscribe крутится бесконечно" bug: this finalize was a
            // binary frame while the live DictationSession.stop() (which works)
            // sends .string(""). Same root cause + fix as
            // fix-history-archive.md::Шрам #17 — it was ported to DictationSession
            // but this one-shot reload kept the old binary finalize.
            try await task.send(.string(""))
            VRLog.d("Reload", "finalize TEXT frame sent — chunks total=\(chunkN)")
        } catch {
            VRLog.e("Reload", "finalize failed: \(error.localizedDescription)")
            return .failure(error)
        }

        // Defense-in-depth watchdog: the empty-TEXT finalize above is the real
        // cure, but if Soniox ever stalls mid-drain (network split after we've
        // sent everything), `task.receive()` would otherwise block until the
        // 300 s resource timeout. Cancelling the task makes the pending
        // receive() throw, which breaks the loop and returns whatever final
        // text we have. 60 s mirrors DictationSession.stopHardCapSeconds (the
        // worst real finalize tail is ~30 s).
        let stallWatchdog = Task { [weak task] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled else { return }
            VRLog.e("Reload", "stall watchdog FIRED (60s) — cancelling receive")
            task?.cancel()
        }
        defer { stallWatchdog.cancel() }

        // Receive until socket closes or `finished:true` arrives. Soniox
        // sends final tokens then closes the socket.
        var finalText = ""
        let tagRegex = try? NSRegularExpression(pattern: "^<[a-z_]+>$", options: .caseInsensitive)
        var msgN = 0
        while true {
            do {
                let msg = try await task.receive()
                msgN += 1
                let text: String?
                switch msg {
                case .string(let s): text = s
                case .data(let d):   text = String(data: d, encoding: .utf8)
                @unknown default:    text = nil
                }
                guard let raw = text, let data = raw.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if obj["error_code"] != nil {
                    let m = obj["error_message"] as? String ?? "unknown"
                    VRLog.e("Reload", "server error: \(m)")
                    return .failure(NSError(domain: "ReloadSession", code: 0,
                                            userInfo: [NSLocalizedDescriptionKey: m]))
                }
                if let tokens = obj["tokens"] as? [[String: Any]] {
                    for t in tokens {
                        guard let txt = t["text"] as? String,
                              let isFinal = t["is_final"] as? Bool, isFinal else { continue }
                        if let regex = tagRegex {
                            let range = NSRange(location: 0, length: txt.utf16.count)
                            if regex.firstMatch(in: txt, range: range) != nil { continue }
                        }
                        finalText += txt
                    }
                }
                if let finished = obj["finished"] as? Bool, finished {
                    VRLog.d("Reload", "server signalled finished (msg=\(msgN))")
                    break
                }
            } catch {
                VRLog.d("Reload", "ws receive ended: \(error.localizedDescription) (msg=\(msgN))")
                break
            }
        }
        let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        VRLog.d("Reload", "done: \(trimmed.count) chars")
        return .success(trimmed)
    }
}
