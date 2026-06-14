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
    // Explicit "this is a note" status, set by the +Notes button. Kept separate
    // from `title` so an entry can be promoted to a note WITHOUT renaming (the
    // title stays auto-derived). Optional + nil-default for clean Codable
    // migration of old JSON. Read via `isNote`.
    var noteFlag: Bool? = nil
    // Manual sort position, set when the user drags rows in History's reorder
    // mode. Optional + nil-default so old JSON decodes AND so the list behaves
    // EXACTLY as before until the first manual reorder: nil everywhere → the
    // sort falls back to timestamp-descending (see loadAll). Once the user
    // reorders, every entry is renumbered densely and the manual order takes
    // priority over the date ("порядок всегда имеет приоритет"). A new recording
    // is given (min existing index − 1) by append so it still lands on top.
    var sortIndex: Int? = nil

    // mergeCount with the nil (legacy / fresh) case normalized to 1.
    var noteCount: Int { max(1, mergeCount ?? 1) }

    // Whether this entry is a "note". True when explicitly promoted via +Notes
    // OR when the user gave it a custom title (the original heuristic, kept so
    // pre-flag entries with titles still count as notes). Drives the Notes tab
    // and the note badge.
    var isNote: Bool {
        if noteFlag == true { return true }
        return !(title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    // ── Merge seam ────────────────────────────────────────────────────────
    // When two entries are merged (mergeDirectional), their texts are joined by
    // this sentinel instead of a plain newline so the join point stays
    // addressable forever. It's the ASCII Group Separator (0x1D) — a control
    // char designed for exactly this (record separation), so it can never
    // collide with anything Soniox transcribes, and it round-trips cleanly
    // through JSON (encoded as ""). It is NEVER shown verbatim:
    //   • the expanded card splits on it and draws a divider in its place,
    //   • every copy/title/preview path flattens it to a blank line (\n\n),
    //   • collapsed previews use the flattened form too.
    // Old entries (merged before this existed) simply contain no marker, so
    // hasMergeSeams is false and plainText == text — fully backward compatible.
    static let mergeMarker = "\u{001D}"

    // The transcript with every merge seam flattened to exactly one blank line.
    // This is the user-facing plain text: what gets copied, titled, counted,
    // and shown when collapsed ("при копировании это будет пробел обычный, одна
    // пустая строка"). For an unmerged entry it returns `text` VERBATIM — no
    // trimming — so existing entries are byte-for-byte unchanged. Only when a
    // seam is present do we normalize: trim each segment's edges and rejoin
    // with a single "\n\n" so the join is one clean empty line, not a ragged
    // pile of the segments' own trailing newlines.
    var plainText: String {
        guard text.contains(Self.mergeMarker) else { return text }
        return textSegments.joined(separator: "\n\n")
    }

    // The transcript split at each merge seam, each segment trimmed of edge
    // whitespace and empty segments dropped. One element for an unmerged entry
    // (the whole text, untrimmed via the plainText guard above); N elements for
    // an entry that folds in N recordings. The expanded card interleaves a
    // visual seam between these.
    var textSegments: [String] {
        text.components(separatedBy: Self.mergeMarker)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // True when this entry carries at least one merge seam (so the expanded
    // card should render the segmented-with-dividers layout).
    var hasMergeSeams: Bool {
        text.contains(Self.mergeMarker)
    }

    // Title shown on the card: the user's override if present, otherwise the
    // first ~28 characters of the transcript trimmed at a word boundary with a
    // trailing ellipsis. Derives from plainText so a merge seam never leaks
    // into the title.
    var displayTitle: String {
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            return t
        }
        return Self.deriveTitle(from: plainText)
    }

    // First few words of `text`, capped to a character budget that comfortably
    // fits one line on the card next to the date. Cuts on the last whole word
    // inside the budget so we never slice a word in half, and appends "…" when
    // the source text was longer than what we kept.
    static func deriveTitle(from text: String) -> String {
        let budget = 28
        let flat = text
            // Merge seams collapse to a space here (defensive — most callers
            // pass plainText, but the title-editor placeholder passes raw text).
            .replacingOccurrences(of: mergeMarker, with: " ")
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
        Self.sortEntries(loadAllUnsorted())
    }

    // The ONE ordering rule for history, used by loadAll and every in-store
    // mutation that re-sorts. Two regimes:
    //   • No entry carries a manual sortIndex (the state of every install until
    //     the first reorder, and of all pre-feature JSON) → pure timestamp-
    //     descending, byte-for-byte the original behaviour.
    //   • Any entry carries a sortIndex → MANUAL order wins ("порядок всегда
    //     имеет приоритет над датой"): sort by sortIndex ascending, with
    //     timestamp-descending only as a tie-break and to place the rare
    //     un-indexed straggler (shouldn't occur — append assigns one in this
    //     regime) just after equally-indexed peers.
    static func sortEntries(_ entries: [TranscriptEntry]) -> [TranscriptEntry] {
        let anyIndexed = entries.contains { $0.sortIndex != nil }
        guard anyIndexed else {
            return entries.sorted { $0.timestamp > $1.timestamp }
        }
        return entries.sorted { a, b in
            switch (a.sortIndex, b.sortIndex) {
            case let (x?, y?): return x != y ? x < y : a.timestamp > b.timestamp
            case (_?, nil):    return true    // indexed before un-indexed
            case (nil, _?):    return false
            case (nil, nil):   return a.timestamp > b.timestamp
            }
        }
    }

    @discardableResult
    func append(text: String,
                audioPath: String?,
                title: String? = nil,
                timestamp: Date = Date()) -> TranscriptEntry {
        return ioQueue.sync {
            var all = self.loadAllUnsorted()
            // If the user has ever manually reordered, the list is in the
            // sortIndex regime — give the new entry an index ABOVE the current
            // minimum so it still appears on top (smallest index = top). When no
            // manual order exists yet, leave it nil so the pure timestamp sort
            // keeps placing it by date, exactly as before.
            let topIndex = all.compactMap { $0.sortIndex }.min().map { $0 - 1 }
            let entry = TranscriptEntry(
                id: UUID(),
                timestamp: timestamp,
                text: text,
                audioPath: audioPath,
                title: title,
                sortIndex: topIndex
            )
            all.append(entry)
            all = Self.sortEntries(all)
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
            return entry
        }
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
                    mergeCount: old.mergeCount,
                    noteFlag: old.noteFlag,
                    sortIndex: old.sortIndex
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
                    mergeCount: old.mergeCount,
                    noteFlag: old.noteFlag,
                    sortIndex: old.sortIndex
                )
                self.writeAll(all)
            }
        }
    }

    // Toggle an entry's note status (the +Notes button). `flag: true` promotes
    // it to a note (explicit flag; title untouched so it stays auto-derived
    // unless renamed). `flag: false` clears the explicit flag — note that an
    // entry with a custom title still reads as a note via `isNote`, so this
    // only un-notes entries that were promoted purely by +Notes.
    func setNoteFlag(id: UUID, flag: Bool) {
        ioQueue.sync {
            var all = self.loadAllUnsorted()
            if let idx = all.firstIndex(where: { $0.id == id }) {
                let old = all[idx]
                all[idx] = TranscriptEntry(
                    id: old.id,
                    timestamp: old.timestamp,
                    text: old.text,
                    audioPath: old.audioPath,
                    title: old.title,
                    mergeCount: old.mergeCount,
                    noteFlag: flag ? true : nil,
                    sortIndex: old.sortIndex
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
                    mergeCount: old.mergeCount,
                    noteFlag: old.noteFlag,
                    sortIndex: old.sortIndex
                )
                self.writeAll(all)
            }
        }
    }

    // Persist a manual reorder. `orderedVisibleIds` is the FULL visible (tab-
    // filtered) list in its NEW top-to-bottom order after a drag. We renumber the
    // entire history densely so the manual order becomes the sort key for
    // everyone: the reordered visible rows take indices in their new sequence,
    // and any entries hidden by the current tab filter are spliced back in at
    // their existing relative position (anchored to the visible row they used to
    // sit just below), so switching tabs never scrambles them. After this runs
    // EVERY entry has a non-nil sortIndex, so the list is permanently in the
    // manual-order regime (timestamp becomes a tie-break only).
    func reorder(orderedVisibleIds: [UUID]) {
        ioQueue.sync {
            let all = self.loadAllUnsorted()
            let current = Self.sortEntries(all)   // current full display order
            let visibleSet = Set(orderedVisibleIds)
            // Walk the current full order; wherever a visible row sits, pull the
            // NEXT id from the user's new visible sequence instead — this keeps
            // hidden rows pinned to their surrounding visible neighbours while
            // the visible rows adopt their new order.
            var newSeq = orderedVisibleIds.makeIterator()
            var finalOrder: [UUID] = []
            for e in current {
                if visibleSet.contains(e.id) {
                    if let next = newSeq.next() { finalOrder.append(next) }
                } else {
                    finalOrder.append(e.id)
                }
            }
            // Renumber densely in the final order.
            let indexById = Dictionary(uniqueKeysWithValues: finalOrder.enumerated().map { ($1, $0) })
            let renumbered = all.map { e -> TranscriptEntry in
                guard let newIndex = indexById[e.id] else { return e }
                return TranscriptEntry(
                    id: e.id,
                    timestamp: e.timestamp,
                    text: e.text,
                    audioPath: e.audioPath,
                    title: e.title,
                    mergeCount: e.mergeCount,
                    noteFlag: e.noteFlag,
                    sortIndex: newIndex
                )
            }
            self.writeAll(Self.sortEntries(renumbered))
        }
    }

    // Directional merge: fold the SOURCE entry (the card whose arrow the user
    // tapped) into the TARGET neighbour, and keep the TARGET's identity. This
    // is the user's mental model: the tapped note is secondary — it appends to
    // the END of the note it merges into, and the target keeps its title, date
    // and list position ("приоритет у той заметки, в которую идёт мердж").
    //   • text   — target.text + seam-marker + source.text (target first, blanks
    //              skipped). The marker renders as a divider in the expanded card
    //              and flattens to a blank line on copy — see TranscriptEntry.mergeMarker.
    //   • audio  — target.wav PCM ++ source.wav PCM (target first), one fresh
    //              .wav; sources deleted unless reused single-sided.
    //   • title  — target's title (source's is dropped).
    //   • date   — target's timestamp (so position is preserved).
    //   • count  — summed.
    // Returns the merged entry, or nil if either id is missing.
    @discardableResult
    func mergeDirectional(source sourceId: UUID, into targetId: UUID) -> TranscriptEntry? {
        ioQueue.sync {
            var all = self.loadAllUnsorted()
            guard let si = all.firstIndex(where: { $0.id == sourceId }),
                  let ti = all.firstIndex(where: { $0.id == targetId }),
                  si != ti else { return nil }
            let source = all[si]
            let target = all[ti]

            // Text — target first, source appended to the end, joined by the
            // merge-seam marker (not a plain newline) so the join point stays
            // addressable: the expanded card draws a divider there, while copy/
            // title/preview flatten it back to a blank line. If either side is
            // itself a prior merge, its own seams are already embedded in its
            // text and survive verbatim — this only adds the ONE new seam
            // between the two bodies.
            let parts = [target.text, source.text]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let mergedText = parts.joined(separator: TranscriptEntry.mergeMarker)

            // Audio — target audio first, then source audio (mergeAudio's
            // "older" slot = whichever plays first, here the target).
            let mergedAudioPath = self.mergeAudio(olderPath: target.audioPath, newerPath: source.audioPath)

            let mergedCount = target.noteCount + source.noteCount
            // The result is a note if either side was — a note status shouldn't
            // be lost by folding a plain recording into it, or vice-versa.
            let mergedNoteFlag = (target.isNote || source.isNote) ? true : nil

            // Keep the target's identity: id, timestamp and title all survive,
            // so the row stays in place and only its body grows.
            let merged = TranscriptEntry(
                id: target.id,
                timestamp: target.timestamp,
                text: mergedText,
                audioPath: mergedAudioPath,
                title: target.title,
                mergeCount: mergedCount,
                noteFlag: mergedNoteFlag,
                sortIndex: target.sortIndex   // target keeps its list position
            )

            for src in [target.audioPath, source.audioPath] {
                if let p = src, p != mergedAudioPath {
                    try? FileManager.default.removeItem(atPath: p)
                }
            }

            all.removeAll { $0.id == source.id || $0.id == target.id }
            all.append(merged)
            all = Self.sortEntries(all)
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

    // 44-byte RIFF header for 16kHz s16le mono. Instance wrapper kept for
    // existing callers; the byte layout lives in the static builder so the
    // streaming writer / recovery patcher produce a byte-identical header.
    private func wavHeader(pcmByteCount: Int) -> Data {
        Self.wavHeaderBytes(pcmByteCount: pcmByteCount)
    }

    // The 44-byte RIFF/WAVE header for our fixed 16kHz s16le mono format. Two
    // length fields depend on the PCM byte count: RIFF chunkSize (offset 4) =
    // 36 + dataSize, and data subchunk size (offset 40) = dataSize.
    static func wavHeaderBytes(pcmByteCount: Int) -> Data {
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
