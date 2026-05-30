import Foundation

struct TranscriptEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let text: String
    // Absolute path under the App-Group container or nil if audio wasn't saved.
    let audioPath: String?
    // User-overridable short title shown as a chip on the history card. nil =
    // derive from the transcript (first few words). Optional + synthesized
    // Codable means entries written by older builds (no `title` key) decode
    // cleanly to nil. Set non-nil only when the user edits the title.
    var title: String?
    // How many original recordings are folded into this entry. A fresh
    // recording is 1; merging two entries sums their counts (2+1→3, 3+4→7).
    // Optional with a nil-default so old JSON (no key) decodes, and existing
    // constructors that don't pass it keep compiling — read via `noteCount`.
    var mergeCount: Int? = nil

    // mergeCount with the nil (legacy / fresh) case normalized to 1.
    var noteCount: Int { max(1, mergeCount ?? 1) }

    // Title shown on the card: the user's override if present, otherwise the
    // first ~28 characters of the transcript trimmed at a word boundary with a
    // trailing ellipsis. Empty-text audio-only entries fall back to a label.
    var displayTitle: String {
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            return t
        }
        return Self.deriveTitle(from: text)
    }

    // First few words of `text`, capped to a character budget that comfortably
    // fits one line on the card next to the date. Cuts on the last whole word
    // inside the budget so we never slice a word in half, and appends "…" when
    // the source text was longer than what we kept.
    static func deriveTitle(from text: String) -> String {
        let budget = 28
        let flat = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if flat.isEmpty { return "Без текста" }
        if flat.count <= budget { return flat }
        // Take the budget window, then back off to the last space so the last
        // word isn't chopped. If there's no space (one very long word) keep the
        // hard cut.
        let windowEnd = flat.index(flat.startIndex, offsetBy: budget)
        let window = flat[flat.startIndex..<windowEnd]
        let cut = window.lastIndex(of: " ").map { window[window.startIndex..<$0] } ?? window
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }
}

// History persistence — port of voice-record/docs/audio-history.md semantics.
// JSON file at <appgroup>/voice-record-history.json + .wav files at
// <appgroup>/voice-record-audio/<ts>.wav. Cap 200 entries with eviction of
// both the JSON entry and its .wav.

final class TranscriptStore {
    static let shared = TranscriptStore()

    private let ioQueue = DispatchQueue(label: "voice-record.transcript-store")

    private init() {}

    func loadAll() -> [TranscriptEntry] {
        guard let url = AppGroupContainer.historyURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([TranscriptEntry].self, from: data) else {
            return []
        }
        return entries.sorted { $0.timestamp > $1.timestamp }
    }

    @discardableResult
    func append(text: String, audioPath: String?) -> TranscriptEntry {
        let entry = TranscriptEntry(
            id: UUID(),
            timestamp: Date(),
            text: text,
            audioPath: audioPath,
            title: nil
        )
        ioQueue.sync {
            var all = self.loadAllUnsorted()
            all.append(entry)
            all.sort { $0.timestamp > $1.timestamp }
            // Evict beyond cap, deleting .wav files of dropped entries.
            if all.count > VoiceRecordConfig.historyCap {
                let dropped = Array(all.suffix(from: VoiceRecordConfig.historyCap))
                all = Array(all.prefix(VoiceRecordConfig.historyCap))
                for d in dropped {
                    if let p = d.audioPath {
                        try? FileManager.default.removeItem(atPath: p)
                    }
                }
            }
            self.writeAll(all)
        }
        return entry
    }

    // Replace the text of an existing entry (used by Reload). Keeps any
    // user-set title — a re-transcribe shouldn't wipe a custom title.
    func updateText(id: UUID, text: String) {
        ioQueue.sync {
            var all = self.loadAllUnsorted()
            if let idx = all.firstIndex(where: { $0.id == id }) {
                let old = all[idx]
                all[idx] = TranscriptEntry(
                    id: old.id,
                    timestamp: old.timestamp,
                    text: text,
                    audioPath: old.audioPath,
                    title: old.title,
                    mergeCount: old.mergeCount
                )
                self.writeAll(all)
            }
        }
    }

    // Set (or clear) the user-overridable title of an entry. Pass nil/empty to
    // revert to the auto-derived first-words title.
    func updateTitle(id: UUID, title: String?) {
        ioQueue.sync {
            var all = self.loadAllUnsorted()
            if let idx = all.firstIndex(where: { $0.id == id }) {
                let old = all[idx]
                let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
                all[idx] = TranscriptEntry(
                    id: old.id,
                    timestamp: old.timestamp,
                    text: old.text,
                    audioPath: old.audioPath,
                    title: (trimmed?.isEmpty ?? true) ? nil : trimmed,
                    mergeCount: old.mergeCount
                )
                self.writeAll(all)
            }
        }
    }

    // Change just the timestamp of an entry (used by the date editor). The
    // entry keeps its id, text and audio — only its position in the sorted
    // history changes.
    func updateTimestamp(id: UUID, date: Date) {
        ioQueue.sync {
            var all = self.loadAllUnsorted()
            if let idx = all.firstIndex(where: { $0.id == id }) {
                let old = all[idx]
                all[idx] = TranscriptEntry(
                    id: old.id,
                    timestamp: date,
                    text: old.text,
                    audioPath: old.audioPath,
                    title: old.title,
                    mergeCount: old.mergeCount
                )
                self.writeAll(all)
            }
        }
    }

    // Merge two history entries into one. `firstId` and `secondId` are merged
    // in CHRONOLOGICAL order (older timestamp first) regardless of the order
    // they're passed, so the resulting text and audio read naturally forward
    // in time:
    //   • text   — older.text + "\n" + newer.text (blank parts skipped)
    //   • audio  — older.wav PCM ++ newer.wav PCM concatenated into a single
    //              fresh .wav; both source .wav files are deleted afterwards.
    //              If only one side has audio, that audio is reused as-is.
    //   • date   — the AVERAGE of the two timestamps (midpoint), per the
    //              user's spec ("дату просто усреднить").
    // The new merged entry replaces both originals in place (positioned by its
    // averaged date on the next sort). Returns the merged entry, or nil if
    // either id is missing.
    @discardableResult
    func merge(_ firstId: UUID, _ secondId: UUID) -> TranscriptEntry? {
        ioQueue.sync {
            var all = self.loadAllUnsorted()
            guard let i = all.firstIndex(where: { $0.id == firstId }),
                  let j = all.firstIndex(where: { $0.id == secondId }),
                  i != j else { return nil }
            let a = all[i]
            let b = all[j]
            // Order the two by time so concatenation is chronological.
            let older = a.timestamp <= b.timestamp ? a : b
            let newer = a.timestamp <= b.timestamp ? b : a

            // Text — join non-empty parts with a newline.
            let parts = [older.text, newer.text].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let mergedText = parts.joined(separator: "\n")

            // Audio — concat PCM payloads (strip each 44-byte WAV header) in
            // chronological order, write a single new .wav. Reuse a lone side
            // if only one has audio.
            let mergedAudioPath = self.mergeAudio(olderPath: older.audioPath, newerPath: newer.audioPath)

            // Date — midpoint of the two timestamps.
            let midpoint = Date(timeIntervalSince1970:
                (older.timestamp.timeIntervalSince1970 + newer.timestamp.timeIntervalSince1970) / 2)

            // Merged title: if both sides used auto-derived titles, leave nil
            // so the merged entry re-derives from the combined text. If either
            // side had a user-set custom title, keep the older one's so a
            // deliberate label survives the merge.
            let mergedTitle = older.title ?? newer.title

            // Note count — sum the originals folded into each side so the [N]
            // badge reflects total source recordings (3 + 4 → 7).
            let mergedCount = older.noteCount + newer.noteCount

            let merged = TranscriptEntry(
                id: UUID(),
                timestamp: midpoint,
                text: mergedText,
                audioPath: mergedAudioPath,
                title: mergedTitle,
                mergeCount: mergedCount
            )

            // Delete the source .wav files that are no longer referenced. A
            // path is still referenced if mergeAudio reused it verbatim (the
            // single-sided case) — guard against deleting the kept file.
            for src in [older.audioPath, newer.audioPath] {
                if let p = src, p != mergedAudioPath {
                    try? FileManager.default.removeItem(atPath: p)
                }
            }

            // Remove both originals, insert the merged entry, resort.
            all.removeAll { $0.id == older.id || $0.id == newer.id }
            all.append(merged)
            all.sort { $0.timestamp > $1.timestamp }
            self.writeAll(all)
            return merged
        }
    }

    func delete(id: UUID) {
        ioQueue.sync {
            var all = self.loadAllUnsorted()
            if let idx = all.firstIndex(where: { $0.id == id }) {
                if let p = all[idx].audioPath {
                    try? FileManager.default.removeItem(atPath: p)
                }
                all.remove(at: idx)
                self.writeAll(all)
            }
        }
    }

    // Returns absolute path of the saved .wav, or nil on failure.
    @discardableResult
    func saveWav(pcm: Data) -> String? {
        guard let dir = AppGroupContainer.audioDirURL else { return nil }
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let url = dir.appendingPathComponent("\(ts).wav")
        let header = wavHeader(pcmByteCount: pcm.count)
        var blob = Data(capacity: header.count + pcm.count)
        blob.append(header)
        blob.append(pcm)
        do {
            try blob.write(to: url, options: .atomic)
            return url.path
        } catch {
            return nil
        }
    }

    // Concatenate the PCM payloads of two .wav files (chronological order:
    // older first) into a single new .wav and return its path. Each source
    // file's 44-byte RIFF header is stripped before concatenation; one fresh
    // header is written for the combined stream. When only one side has audio
    // the original path is returned verbatim (caller must NOT delete a reused
    // path — merge() guards this). Returns nil only if both sides are nil.
    private func mergeAudio(olderPath: String?, newerPath: String?) -> String? {
        switch (olderPath, newerPath) {
        case (nil, nil):
            return nil
        case (let p?, nil):
            return p                 // reuse — single-sided
        case (nil, let p?):
            return p                 // reuse — single-sided
        case (let oP?, let nP?):
            let olderPcm = Self.pcmPayload(ofWavAt: oP)
            let newerPcm = Self.pcmPayload(ofWavAt: nP)
            // If either read failed, fall back to whichever side we could
            // read so we never lose both — better partial audio than none.
            if olderPcm == nil && newerPcm == nil { return oP }
            var combined = Data()
            if let o = olderPcm { combined.append(o) }
            if let n = newerPcm { combined.append(n) }
            return saveWav(pcm: combined)
        }
    }

    // Read a .wav and return just its PCM data (everything after the 44-byte
    // header). nil if the file is missing or too small to contain a header.
    private static func pcmPayload(ofWavAt path: String) -> Data? {
        guard let blob = try? Data(contentsOf: URL(fileURLWithPath: path)),
              blob.count > 44 else { return nil }
        return blob.subdata(in: 44..<blob.count)
    }

    // MARK: - Private

    private func loadAllUnsorted() -> [TranscriptEntry] {
        guard let url = AppGroupContainer.historyURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([TranscriptEntry].self, from: data) else {
            return []
        }
        return entries
    }

    private func writeAll(_ entries: [TranscriptEntry]) {
        guard let url = AppGroupContainer.historyURL else { return }
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // 44-byte RIFF header for 16kHz s16le mono.
    private func wavHeader(pcmByteCount: Int) -> Data {
        let sampleRate: UInt32 = 16000
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate: UInt32 = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign: UInt16 = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(pcmByteCount)
        let chunkSize = UInt32(36 + Int(dataSize))

        var d = Data(capacity: 44)
        d.append("RIFF".data(using: .ascii)!)
        d.appendLE(uint32: chunkSize)
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!)
        d.appendLE(uint32: 16)               // Subchunk1Size (PCM=16)
        d.appendLE(uint16: 1)                // AudioFormat (PCM=1)
        d.appendLE(uint16: numChannels)
        d.appendLE(uint32: sampleRate)
        d.appendLE(uint32: byteRate)
        d.appendLE(uint16: blockAlign)
        d.appendLE(uint16: bitsPerSample)
        d.append("data".data(using: .ascii)!)
        d.appendLE(uint32: dataSize)
        return d
    }
}

private extension Data {
    mutating func appendLE(uint32 v: UInt32) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { self.append(contentsOf: $0) }
    }
    mutating func appendLE(uint16 v: UInt16) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { self.append(contentsOf: $0) }
    }
}
