import Foundation
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// Voice Chat — NATIVE data layer.
//
// The phone is the third client of the Mac's runAgent (after the desktop
// overlay and mobile-web): REST for state, SSE for live turn events. This store
// is a singleton that lives for the app's life — NOT per-view — so loading
// state ("этот чат сейчас крутится") survives any navigation. That was the
// web bug class: per-view loading state died on remount. Here the server's
// inflight registry (`running` on /api/chats) plus one global SSE subscription
// are the only sources of truth.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - Loose JSON (tool args/results are arbitrary shapes)

enum VCJSON: Decodable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), null
    case array([VCJSON]), object([String: VCJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([VCJSON].self) { self = .array(a) }
        else if let o = try? c.decode([String: VCJSON].self) { self = .object(o) }
        else { self = .null }
    }

    subscript(key: String) -> VCJSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
    var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): return String(b)
        default: return nil
        }
    }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var intValue: Int? { if case .number(let n) = self { return Int(n) }; return nil }

    // Compact human dump for generic tool args (MCP etc.).
    var compactDescription: String {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): return String(b)
        case .null: return "null"
        case .array(let a): return "[" + a.prefix(6).map { $0.compactDescription }.joined(separator: ", ") + (a.count > 6 ? ", …]" : "]")
        case .object(let o):
            let pairs = o.prefix(8).map { "\($0.key): \($0.value.compactDescription)" }
            return pairs.joined(separator: "\n")
        }
    }

    func prettyDescription(level: Int = 0) -> String {
        let pad = String(repeating: "  ", count: level)
        switch self {
        case .string(let s):
            return s
        case .number(let n):
            return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b):
            return String(b)
        case .null:
            return "null"
        case .array(let a):
            guard !a.isEmpty else { return "[]" }
            return a.map { item in
                pad + "- " + item.prettyDescription(level: level + 1)
                    .replacingOccurrences(of: "\n", with: "\n" + pad + "  ")
            }.joined(separator: "\n")
        case .object(let o):
            guard !o.isEmpty else { return "{}" }
            return o.keys.sorted().map { key in
                let value = o[key]?.prettyDescription(level: level + 1) ?? "null"
                if value.contains("\n") {
                    return pad + key + ":\n" + value
                }
                return pad + key + ": " + value
            }.joined(separator: "\n")
        }
    }

    func prettyDescription(maxCharacters: Int) -> String {
        var remaining = max(0, maxCharacters)
        return prettyDescription(level: 0, remaining: &remaining)
    }

    private func prettyDescription(level: Int, remaining: inout Int) -> String {
        guard remaining > 0 else { return "…" }
        let pad = String(repeating: "  ", count: level)
        switch self {
        case .string(let s):
            return vcConsumeTextBudget(s, remaining: &remaining)
        case .number(let n):
            return vcConsumeTextBudget(n == n.rounded() ? String(Int(n)) : String(n), remaining: &remaining)
        case .bool(let b):
            return vcConsumeTextBudget(String(b), remaining: &remaining)
        case .null:
            return vcConsumeTextBudget("null", remaining: &remaining)
        case .array(let a):
            guard !a.isEmpty else { return vcConsumeTextBudget("[]", remaining: &remaining) }
            var lines: [String] = []
            for item in a {
                guard remaining > 0 else { break }
                let value = item.prettyDescription(level: level + 1, remaining: &remaining)
                    .replacingOccurrences(of: "\n", with: "\n" + pad + "  ")
                lines.append(pad + "- " + value)
            }
            if lines.count < a.count { lines.append(pad + "…") }
            return lines.joined(separator: "\n")
        case .object(let o):
            guard !o.isEmpty else { return vcConsumeTextBudget("{}", remaining: &remaining) }
            var lines: [String] = []
            let keys = o.keys.sorted()
            for key in keys {
                guard remaining > 0 else { break }
                let value = o[key]?.prettyDescription(level: level + 1, remaining: &remaining) ?? "null"
                if value.contains("\n") {
                    lines.append(pad + key + ":\n" + value)
                } else {
                    lines.append(pad + key + ": " + value)
                }
            }
            if lines.count < keys.count { lines.append(pad + "…") }
            return lines.joined(separator: "\n")
        }
    }
}

func vcTextExceeds(_ text: String, maxCharacters: Int) -> Bool {
    text.utf16.count > maxCharacters
}

func vcClippedText(_ text: String, maxCharacters: Int, ellipsis: Bool = true) -> String {
    guard maxCharacters >= 0 else { return text }
    guard vcTextExceeds(text, maxCharacters: maxCharacters) else { return text }
    return String(text.prefix(maxCharacters)) + (ellipsis ? "…" : "")
}

func vcChunkText(_ text: String, chunkSize: Int = 2_000) -> [String] {
    guard !text.isEmpty else { return [] }
    let step = max(256, chunkSize)
    var chunks: [String] = []
    var idx = text.startIndex
    while idx < text.endIndex {
        let next = text.index(idx, offsetBy: step, limitedBy: text.endIndex) ?? text.endIndex
        chunks.append(String(text[idx..<next]))
        idx = next
    }
    return chunks
}

private func vcConsumeTextBudget(_ text: String, remaining: inout Int) -> String {
    guard remaining > 0 else { return "…" }
    if text.utf16.count <= remaining {
        remaining -= text.utf16.count
        return text
    }
    let out = vcClippedText(text, maxCharacters: remaining)
    remaining = 0
    return out
}

// MARK: - Models (mirror web-server.js shapes)

struct VCToolCall: Identifiable, Decodable, Sendable {
    let id: String
    let name: String
    var args: VCJSON?
    var result: VCJSON?

    var isError: Bool { result?["success"]?.boolValue == false }
    var isRunning: Bool { result == nil }

    // Display name: voice-record tool names → familiar Claude-Code-style labels;
    // MCP names get their server prefix trimmed.
    var displayName: String {
        switch name {
        case "bash": return "Bash"
        case "read_file": return "Read"
        case "edit_file": return "Edit"
        case "write_file": return "Write"
        default:
            if name.hasPrefix("mcp__") {
                let parts = name.split(separator: "_", omittingEmptySubsequences: true)
                return parts.last.map(String.init) ?? name
            }
            return name
        }
    }
    // One-line preview for the collapsed card header.
    var preview: String {
        let a = args
        func clipped(_ value: String) -> String {
            vcClippedText(value, maxCharacters: 180)
        }
        switch name {
        case "bash": return clipped(a?["command"]?.stringValue ?? "")
        case "read_file", "edit_file", "write_file":
            let p = a?["path"]?.stringValue ?? ""
            return (p as NSString).lastPathComponent
        default:
            if let q = a?["query"]?.stringValue { return clipped(q) }
            if let p = a?["pattern"]?.stringValue { return clipped(p) }
            if case .object(let o)? = a, let first = o.first?.value.stringValue { return clipped(first) }
            return ""
        }
    }
    var resultText: String { resultText(maxCharacters: 20_000) }

    func resultText(maxCharacters: Int) -> String {
        guard let r = result else { return "" }
        if isError {
            let raw = r["error"]?.stringValue ?? r["content"]?.stringValue ?? "error"
            return vcClippedText(raw, maxCharacters: maxCharacters)
        }
        if let c = r["content"]?.stringValue { return vcClippedText(c, maxCharacters: maxCharacters) }
        if case .string(let s) = r { return vcClippedText(s, maxCharacters: maxCharacters) }
        return r.prettyDescription(maxCharacters: maxCharacters)
    }

    var detailText: String { detailText(maxCharacters: 20_000) }

    func detailText(maxCharacters: Int) -> String {
        var parts: [String] = []
        var remaining = max(0, maxCharacters)
        if let args {
            let budget = min(remaining, max(1_000, maxCharacters / 3))
            let body = args.prettyDescription(maxCharacters: budget)
            remaining = max(0, remaining - body.utf16.count)
            parts.append("args\n" + body)
        }
        if result != nil, remaining > 0 {
            let body = resultText(maxCharacters: remaining)
            remaining = max(0, remaining - body.utf16.count)
            parts.append("result\n" + body)
        }
        if remaining == 0 { parts.append("…") }
        return parts.joined(separator: "\n\n")
    }
}

struct VCAttachment: Identifiable, Codable, Equatable {
    let id: String
    let kind: String
    let name: String
    var sourceName: String?   // context chips: the source app ("Yandex", "gt-editor")
    var filePath: String?     // gtfile chips: path-only reference, agent reads current file
    var reread: Bool?
    var promptId: String?
    var variationId: String?

    enum CodingKeys: String, CodingKey { case id, kind, name, sourceName, filePath, reread, promptId, variationId }
    init(id: String = UUID().uuidString, kind: String, name: String, sourceName: String? = nil, filePath: String? = nil, reread: Bool? = nil, promptId: String? = nil, variationId: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.sourceName = sourceName
        self.filePath = filePath
        self.reread = reread
        self.promptId = promptId
        self.variationId = variationId
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "paste"
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        sourceName = try? c.decode(String.self, forKey: .sourceName)
        filePath = try? c.decode(String.self, forKey: .filePath)
        reread = try? c.decode(Bool.self, forKey: .reread)
        promptId = try? c.decode(String.self, forKey: .promptId)
        variationId = try? c.decode(String.self, forKey: .variationId)
    }

    // Display label — desktop parity: a context chip shows its SOURCE APP
    // (prompt.tsx: `att.kind === 'context' ? (att.sourceName || 'Selection')`).
    var displayName: String {
        if kind == "context" { return sourceName ?? (name.isEmpty ? "Selection" : name) }
        return name.isEmpty ? kind : name
    }

    var apiObject: [String: Any] {
        var obj: [String: Any] = ["id": id, "kind": kind, "name": name]
        if let sourceName { obj["sourceName"] = sourceName }
        if let filePath { obj["filePath"] = filePath }
        if let reread { obj["reread"] = reread }
        if let promptId { obj["promptId"] = promptId }
        if let variationId { obj["variationId"] = variationId }
        return obj
    }
}

struct VCMessage: Identifiable, Decodable {
    let id: String
    let role: String
    let content: String
    var attachments: [VCAttachment]?
    var toolCalls: [VCToolCall]?
    var thinking: String?
    var stopped: Bool?
    var durationMs: Double?
    var createdAt: Double?

    enum CodingKeys: String, CodingKey { case id, role, content, attachments, toolCalls, thinking, stopped, durationMs, createdAt }

    init(id: String = UUID().uuidString,
         role: String,
         content: String,
         attachments: [VCAttachment]? = nil,
         toolCalls: [VCToolCall]? = nil,
         thinking: String? = nil,
         stopped: Bool? = nil,
         durationMs: Double? = nil,
         createdAt: Double? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.attachments = attachments
        self.toolCalls = toolCalls
        self.thinking = thinking
        self.stopped = stopped
        self.durationMs = durationMs
        self.createdAt = createdAt
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        role = (try? c.decode(String.self, forKey: .role)) ?? "assistant"
        content = (try? c.decode(String.self, forKey: .content)) ?? ""
        attachments = try? c.decode([VCAttachment].self, forKey: .attachments)
        toolCalls = try? c.decode([VCToolCall].self, forKey: .toolCalls)
        thinking = try? c.decode(String.self, forKey: .thinking)
        stopped = try? c.decode(Bool.self, forKey: .stopped)
        durationMs = try? c.decode(Double.self, forKey: .durationMs)
        createdAt = try? c.decode(Double.self, forKey: .createdAt)
    }
}

struct VCConversation: Decodable {
    let id: String
    var title: String?
    var messages: [VCMessage]
    var running: Bool?
    var bypass: Bool?
    var pendingConfirms: [VCConfirmRequest]?

    enum CodingKeys: String, CodingKey { case id, title, messages, running, bypass, pendingConfirms }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try? c.decode(String.self, forKey: .title)
        messages = (try? c.decode([VCMessage].self, forKey: .messages)) ?? []
        running = try? c.decode(Bool.self, forKey: .running)
        bypass = try? c.decode(Bool.self, forKey: .bypass)
        pendingConfirms = try? c.decode([VCConfirmRequest].self, forKey: .pendingConfirms)
    }
}

// A parked tool-approval question (By-pass OFF): the agent paused inside
// edit_file/write_file/bash and waits for Allow/Deny from the phone.
struct VCConfirmRequest: Identifiable, Decodable, Equatable {
    let callId: String
    var chatId: String?
    let action: String          // edit | overwrite | create | bash
    var path: String?
    var command: String?
    var description: String?
    var oldString: String?
    var newString: String?
    var background: Bool?
    var id: String { callId }

    static func == (a: VCConfirmRequest, b: VCConfirmRequest) -> Bool { a.callId == b.callId }
}

struct VCChatMeta: Identifiable, Decodable, Equatable {
    let id: String
    var title: String?
    var userCount: Int?
    var updatedAt: Double?
    var running: Bool?

    static func == (a: VCChatMeta, b: VCChatMeta) -> Bool {
        a.id == b.id && a.title == b.title && a.userCount == b.userCount
            && a.updatedAt == b.updatedAt && a.running == b.running
    }
}

struct VCBackgroundTask: Identifiable, Decodable, Equatable {
    let id: String
    let command: String
    var description: String?
    let startedAt: Double
    let running: Bool
    var exitCode: Int?

    var label: String {
        let d = (description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return d.isEmpty ? command : d
    }
}

struct VCBackgroundOutput: Decodable {
    var ok: Bool?
    var missing: Bool?
    var content: String?
    var size: Int?
    var running: Bool?
    var exitCode: Int?
    var error: String?
}

// MARK: - SSE event (server → client)

private struct SSEPayload: Decodable {
    let type: String
    let chatId: String?
    let message: VCMessage?
    let tool: SSETool?
    let error: String?
    let request: VCConfirmRequest?   // type=confirm
    let callId: String?              // type=confirm-resolved
    let bypass: Bool?                // type=bypass — live gate state for the chat
    let text: String?                // type=cancelled — the unwound user text
    let tasks: [VCBackgroundTask]?    // type=bg — background bash snapshots
}
private struct SSETool: Decodable {
    let id: String
    let name: String
    let phase: String
    var args: VCJSON?
    var result: VCJSON?
}

func vcPathComponent(_ s: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
}

// MARK: - Phone-side debug log, shipped to the Mac
//
// Batches lines and POSTs them to /api/log every ~3s; the server appends to
// ~/Library/Logs/voice-record/ios-chat.log — same folder as the Mac app's own
// log, so both sides of "карточка не показалась" are greppable together.
// Fire-and-forget: a dead network just drops the batch (the next one retries
// nothing — logs are diagnostics, not state).

enum VCLog {
    nonisolated(unsafe) private static var buffer: [String] = []
    nonisolated(unsafe) private static var localBuffer: [String] = []
    nonisolated(unsafe) private static var flusher: Task<Void, Never>? = nil
    private static let lock = NSLock()
    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    static func log(_ tag: String, _ msg: String) {
        let line = stamp.string(from: Date()) + " [" + tag + "] " + msg
        lock.lock()
        buffer.append(line)
        if buffer.count > 500 { buffer.removeFirst(buffer.count - 500) }
        localBuffer.append(line)
        if localBuffer.count > 1000 { localBuffer.removeFirst(localBuffer.count - 1000) }
        let needsFlusher = flusher == nil
        lock.unlock()
        if needsFlusher { startFlusher() }
        #if DEBUG
        print("VC " + line)
        #endif
    }

    static func readRecent(maxLines: Int = 500) -> String {
        lock.lock()
        let lines = Array(localBuffer.suffix(maxLines))
        lock.unlock()
        return lines.joined(separator: "\n")
    }

    static func lineCount() -> Int {
        lock.lock()
        let count = localBuffer.count
        lock.unlock()
        return count
    }

    static func clearLocal() {
        lock.lock()
        localBuffer.removeAll()
        buffer.removeAll()
        lock.unlock()
    }

    private static func startFlusher() {
        lock.lock()
        guard flusher == nil else { lock.unlock(); return }
        flusher = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await flushOnce()
            }
        }
        lock.unlock()
    }

    private static func flushOnce() async {
        lock.lock()
        let lines = buffer
        buffer.removeAll()
        lock.unlock()
        guard !lines.isEmpty else { return }
        _ = try? await VoiceChatAPI.postJSON("/api/log", body: ["lines": lines])
    }
}

// MARK: - Store

@MainActor
final class VoiceChatStore: ObservableObject {
    static let shared = VoiceChatStore()

    @Published var chats: [VCChatMeta] = []
    @Published var conversations: [String: VCConversation] = [:]
    // Chats with an in-flight turn RIGHT NOW. Union of the server's `running`
    // flags (truth, survives anything) and live SSE 'user'/'done' events
    // (immediacy between refreshes).
    @Published var running: Set<String> = []
    // Live tool cards for the CURRENT turn of a chat (cleared on assistant/done).
    @Published var liveTools: [String: [VCToolCall]] = [:]
    // Per-chat error from the last turn (cancel is NOT an error — web scar).
    @Published var turnError: [String: String] = [:]
    // Parked tool-approval questions per chat (By-pass OFF). Re-hydrated from
    // GET /api/chats/:id on every load, live-updated by SSE confirm events.
    @Published var confirms: [String: [VCConfirmRequest]] = [:]
    // Live By-pass state is per chat on the Mac server. The UI still stores a
    // global default for drafts, but an existing/running chat must mirror server
    // state so flipping the pill mid-stream affects the current confirm gate.
    @Published var bypassByChat: [String: Bool] = [:]
    // Mac-side background bash tasks started with run_in_background:true. This is
    // global agent state, not per-chat: a watcher/server can outlive the turn
    // and should stay visible while the user changes chats or tabs.
    @Published var bgTasks: [VCBackgroundTask] = []
    // Tombstones: callIds already answered/resolved. GETs race SSE over the
    // tunnel — a response SERIALIZED before a confirm parked arrives AFTER the
    // SSE 'confirm' event and (with naive replace) wipes the freshly-shown
    // card; symmetrically a stale GET could resurrect an answered one. Merge
    // rule everywhere: union(local, server) − tombstones. That's why the
    // "создай файл" card flashed and vanished (the «завис на минуту» bug).
    private var resolvedConfirmIds: Set<String> = []
    // When the running turn started — the elapsed counter derives from this
    // (NOT a local incrementing int, which reset to 0 on every tab switch).
    @Published var turnStartedAt: [String: Date] = [:]
    // Stop before a reply → the server unwinds the turn and returns the typed
    // text here; the open chat view consumes it back into its composer
    // (desktop parity: «на стоп промпт возвращается обратно в инпут»).
    @Published var restoredInput: [String: String] = [:]
    // Dictation → chat composer bridge. Only a visible ChatDetailView registers
    // itself as active, so the history/list screen is deliberately excluded.
    struct ComposerInsert: Equatable {
        let seq: UUID
        let targetKey: String
        let text: String
    }
    static let draftComposerKey = "__draft__"
    @Published var pendingComposerInsert: ComposerInsert?
    private(set) var activeComposerKey: String?
    @Published var sseConnected = false
    @Published var offline = false

    private var sseTask: Task<Void, Never>?
    private var sseWatchdog: Task<Void, Never>?
    private var started = false
    // Last time ANY line (incl. `: hb` heartbeats every 25s) arrived on the SSE
    // stream. The zombie-socket detector: iOS freezes the socket in background
    // WITHOUT erroring it — the task looks alive, bytes.lines just never yields
    // again. That's why "confirm card не показалась": the broadcast went into a
    // dead pipe. Staleness >40s (heartbeat is 25s) ⇒ the pipe is dead.
    private var lastSSELineAt = Date.distantPast

    private var sseStale: Bool {
        sseTask == nil || sseTask?.isCancelled == true
            || Date().timeIntervalSince(lastSSELineAt) > 40
    }

    static func composerKey(for chatId: String?) -> String {
        chatId ?? draftComposerKey
    }

    static func terminalComposerKey(tabId: String) -> String {
        "__terminal__:" + tabId
    }

    var isComposerVisible: Bool {
        activeComposerKey != nil
    }

    func setActiveComposer(chatId: String?) {
        let key = Self.composerKey(for: chatId)
        setActiveComposerKey(key)
    }

    func setActiveComposerKey(_ key: String) {
        activeComposerKey = key
        VCLog.log("Store", "composer active key=\(key == Self.draftComposerKey ? "draft" : String(key.suffix(8)))")
    }

    func updateActiveComposer(from oldChatId: String?, to newChatId: String?) {
        let oldKey = Self.composerKey(for: oldChatId)
        guard activeComposerKey == oldKey else { return }
        setActiveComposer(chatId: newChatId)
    }

    func clearActiveComposer(chatId: String?) {
        let key = Self.composerKey(for: chatId)
        clearActiveComposerKey(key)
    }

    func clearActiveComposerKey(_ key: String) {
        guard activeComposerKey == key else { return }
        activeComposerKey = nil
        VCLog.log("Store", "composer inactive key=\(key == Self.draftComposerKey ? "draft" : String(key.suffix(8)))")
    }

    @discardableResult
    func enqueueDictationInsert(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let key = activeComposerKey else {
            VCLog.log("Store", "dictation insert skipped (composer not visible)")
            return false
        }
        pendingComposerInsert = ComposerInsert(seq: UUID(), targetKey: key, text: trimmed)
        VCLog.log("Store", "dictation insert queued key=\(key == Self.draftComposerKey ? "draft" : String(key.suffix(8))) len=\(trimmed.count)")
        return true
    }

    func consumeDictationInsert(_ insert: ComposerInsert) {
        guard pendingComposerInsert?.seq == insert.seq else { return }
        pendingComposerInsert = nil
    }

    // Idempotent: (re)connect SSE + refresh. Called on tab appear / tab switch /
    // scene-active. Force-reconnects when the stream is STALE, not only when the
    // task is dead — the zombie case above.
    func start() {
        if !started || sseStale {
            started = true
            VCLog.log("SSE", "start: reconnect (stale=\(sseStale))")
            connectSSE()
        }
        startSSEWatchdog()
        Task {
            await refreshChats()
            await refreshBackgroundTasks()
            // Re-hydrate every active conversation: messages + pendingConfirms
            // may have changed while our pipe was dead (the GET carries both).
            for id in running { await loadConversation(id) }
        }
    }

    private func startSSEWatchdog() {
        guard sseWatchdog == nil || sseWatchdog?.isCancelled == true else { return }
        sseWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let store = self else { break }
                if store.started && store.sseStale {
                    VCLog.log("SSE", "watchdog: stream stale → reconnect")
                    store.connectSSE()
                    await store.refreshChats()
                    await store.refreshBackgroundTasks()
                    for id in store.running { await store.loadConversation(id) }
                }
            }
        }
    }

    func shutdown() {
        sseTask?.cancel()
        sseTask = nil
        sseConnected = false
    }

    // ── REST ──

    func refreshChats() async {
        do {
            let metas: [VCChatMeta] = try await VoiceChatAPI.getJSON("/api/chats?limit=50")
            chats = metas
            offline = false
            // Server inflight registry is the truth for spinners.
            running = Set(metas.filter { $0.running == true }.map(\.id))
        } catch {
            // GLOBAL offline: ANY failed refresh flips the whole tab to the
            // "Хост недоступен" screen (per design — no tiny dot indicators).
            // An auto-retry loop brings it back without user action.
            offline = true
            startOfflineRetry()
        }
    }

    func refreshBackgroundTasks() async {
        do {
            let tasks: [VCBackgroundTask] = try await VoiceChatAPI.getJSON("/api/agent/bg")
            bgTasks = tasks
            offline = false
        } catch {
            VCLog.log("Store", "refresh bg FAILED: \(error.localizedDescription)")
            markOfflineIfConnectionError(error)
        }
    }

    func killBackgroundTask(_ id: String) {
        Task {
            do {
                _ = try await VoiceChatAPI.postJSON("/api/agent/bg/" + vcPathComponent(id) + "/kill", body: [:])
                VCLog.log("Store", "bg kill ok id=\(id)")
                await refreshBackgroundTasks()
            } catch {
                VCLog.log("Store", "bg kill FAILED id=\(id): \(error.localizedDescription)")
                markOfflineIfConnectionError(error)
            }
        }
    }

    private var retryTask: Task<Void, Never>?
    private func startOfflineRetry() {
        guard retryTask == nil || retryTask?.isCancelled == true else { return }
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let store = self, store.offline else { break }
                await store.refreshChats()
                if !store.offline { break }
            }
            self?.retryTask = nil
        }
    }

    private func markOfflineIfConnectionError(_ error: Error) {
        let isOffline: Bool = {
            if error is URLError { return true }
            guard let voiceError = error as? VoiceChatError else { return false }
            switch voiceError {
            case .badURL:
                return true
            case .http(let code, _):
                return code == 0 || code == 503
            case .decode:
                return false
            }
        }()
        guard isOffline else { return }
        offline = true
        startOfflineRetry()
    }

    @discardableResult
    func loadConversation(_ id: String) async -> VCConversation? {
        do {
            let conv: VCConversation = try await VoiceChatAPI.getJSON("/api/chats/" + id)
            conversations[id] = conv
            if let b = conv.bypass { bypassByChat[id] = b }
            if conv.running == true {
                running.insert(id)
                // Approximate the turn start from the last user message when we
                // didn't witness the start (app re-open) — keeps the elapsed
                // counter truthful instead of restarting at 0.
                if turnStartedAt[id] == nil {
                    if let lastUser = conv.messages.last(where: { $0.role == "user" }),
                       let ts = lastUser.createdAt {
                        turnStartedAt[id] = Date(timeIntervalSince1970: ts / 1000)
                    } else {
                        turnStartedAt[id] = Date()
                    }
                }
            } else {
                running.remove(id)
                turnStartedAt[id] = nil
            }
            mergeConfirms(chatId: id, fromServer: conv.pendingConfirms ?? [])
            offline = false
            return conv
        } catch {
            // 404 = the chat no longer exists (e.g. a first-message Stop unwound
            // it server-side). Drop the local copy so the view empties instead
            // of showing the rolled-back message forever.
            if case VoiceChatError.http(404, _) = error {
                conversations[id] = nil
                running.remove(id)
                confirms[id] = []
                return nil
            }
            VCLog.log("Store", "loadConversation FAILED id=\(id.suffix(8)): \(error.localizedDescription)")
            markOfflineIfConnectionError(error)
            return nil
        }
    }

    func answerConfirm(_ req: VCConfirmRequest, ok: Bool) {
        VCLog.log("Confirm", "answer \(ok ? "ALLOW" : "DENY") callId=\(req.callId.suffix(10))")
        resolvedConfirmIds.insert(req.callId)
        for (cid, arr) in confirms where arr.contains(where: { $0.callId == req.callId }) {
            confirms[cid] = arr.filter { $0.callId != req.callId }
        }
        Task { _ = try? await VoiceChatAPI.postJSON("/api/chat/confirm", body: ["callId": req.callId, "ok": ok]) }
    }

    // union(local, server) − tombstones; ordered by callId suffix (parking order).
    private func mergeConfirms(chatId: String, fromServer server: [VCConfirmRequest]) {
        var byId: [String: VCConfirmRequest] = [:]
        for var r in (confirms[chatId] ?? []) { r.chatId = chatId; byId[r.callId] = r }
        for var r in server where byId[r.callId] == nil { r.chatId = chatId; byId[r.callId] = r }
        let merged = byId.values
            .filter { !resolvedConfirmIds.contains($0.callId) }
            .sorted { $0.callId < $1.callId }
        if merged.map(\.callId) != (confirms[chatId] ?? []).map(\.callId) {
            VCLog.log("Confirm", "merge chat=\(chatId.suffix(8)) → \(merged.count) pending")
        }
        confirms[chatId] = merged
    }

    /// Send a turn. nil chatId → server mints a new conversation; returns its id.
    /// bypass=false → edit/write/bash pause on confirm cards in this chat.
    func send(chatId: String?, text: String, promptId: String?, variationId: String?,
              model: String, thinkingLevel: String, bypass: Bool = true,
              attachments: [VCAttachment] = []) async throws -> String {
        var body: [String: Any] = ["model": model, "thinkingLevel": thinkingLevel, "bypass": bypass]
        if let chatId { body["chatId"] = chatId }
        if !text.isEmpty { body["text"] = text }
        if let promptId { body["promptId"] = promptId }
        if let variationId { body["variationId"] = variationId }
        if !attachments.isEmpty { body["attachments"] = attachments.map(\.apiObject) }
        let resp: [String: Any]
        do {
            resp = try await VoiceChatAPI.postJSON("/api/chat/send", body: body)
            offline = false
        } catch {
            markOfflineIfConnectionError(error)
            throw error
        }
        guard let id = resp["chatId"] as? String else { throw VoiceChatError.decode("chatId missing") }
        running.insert(id)
        turnStartedAt[id] = Date()
        turnError[id] = nil
        VCLog.log("Store", "send ok chat=\(id.suffix(8)) bypass=\(bypass) model=\(model)")
        await loadConversation(id)
        await refreshChats()
        return id
    }

    func stopTurn(_ chatId: String) {
        Task { _ = try? await VoiceChatAPI.postJSON("/api/chat/stop", body: ["chatId": chatId]) }
    }

    func deleteChat(_ id: String) {
        chats.removeAll { $0.id == id }
        conversations[id] = nil
        running.remove(id)
        bypassByChat[id] = nil
        Task { _ = try? await VoiceChatAPI.deleteRequest("/api/chats/" + id); await refreshChats() }
    }

    func updateChatTitle(_ id: String, title: String?) {
        let normalized = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = (normalized?.isEmpty == false) ? normalized : nil
        if var conv = conversations[id] {
            conv.title = finalTitle
            conversations[id] = conv
        }
        if let i = chats.firstIndex(where: { $0.id == id }) {
            chats[i].title = finalTitle
        }
        Task {
            do {
                _ = try await VoiceChatAPI.patchJSON("/api/chats/" + id, body: ["title": finalTitle ?? ""])
                VCLog.log("Store", "rename chat=\(id.suffix(8)) title=\(finalTitle ?? "<auto>")")
                await loadConversation(id)
                await refreshChats()
            } catch {
                VCLog.log("Store", "rename FAILED chat=\(id.suffix(8)): \(error.localizedDescription)")
                await loadConversation(id)
                await refreshChats()
            }
        }
    }

    func setBypass(chatId: String, bypass: Bool) {
        bypassByChat[chatId] = bypass
        if bypass {
            for r in confirms[chatId] ?? [] { resolvedConfirmIds.insert(r.callId) }
            confirms[chatId] = []
        }
        VCLog.log("Confirm", "bypass local chat=\(chatId.suffix(8)) → \(bypass)")
        Task {
            do {
                _ = try await VoiceChatAPI.postJSON("/api/chat/bypass", body: ["chatId": chatId, "bypass": bypass])
                VCLog.log("Confirm", "bypass POST ok chat=\(chatId.suffix(8)) → \(bypass)")
            } catch {
                VCLog.log("Confirm", "bypass POST FAILED chat=\(chatId.suffix(8)): \(error.localizedDescription)")
                await loadConversation(chatId)
            }
        }
    }

    // ── SSE ──

    private func connectSSE() {
        sseTask?.cancel()
        lastSSELineAt = Date()   // fresh grace period for the new connection
        sseTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runSSEOnce()
                guard !Task.isCancelled else { break }
                await MainActor.run { self?.sseConnected = false }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func runSSEOnce() async {
        guard let url = VoiceChatConfig.apiURL("/api/events?token=" + Secrets.remoteWebToken) else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3600
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                VCLog.log("SSE", "connect rejected status=\((resp as? HTTPURLResponse)?.statusCode ?? -1)")
                return
            }
            sseConnected = true
            offline = false
            lastSSELineAt = Date()
            VCLog.log("SSE", "connected")
            // Our server emits exactly ONE `data: <json>` line per event (JSON
            // has no raw newlines), so dispatch per line — no dependence on how
            // AsyncLineSequence treats the blank separator. `: hb` heartbeats
            // and `retry:` lines fall through but still feed the staleness
            // clock — they're proof the pipe is alive.
            for try await line in bytes.lines {
                if Task.isCancelled { return }
                lastSSELineAt = Date()
                if line.hasPrefix("data: ") { handleEventJSON(String(line.dropFirst(6))) }
            }
            VCLog.log("SSE", "stream ended (EOF)")
        } catch { /* drop → reconnect loop */ }
    }

    private func handleEventJSON(_ json: String) {
        guard let d = json.data(using: .utf8),
              let e = try? JSONDecoder().decode(SSEPayload.self, from: d) else {
            VCLog.log("SSE", "UNPARSEABLE event: " + String(json.prefix(180)))
            return
        }
        if e.type == "bg" {
            bgTasks = e.tasks ?? []
            VCLog.log("SSE", "bg tasks=\(bgTasks.filter { $0.running }.count)")
            return
        }
        guard let chatId = e.chatId else { return }   // 'hello' has no chatId
        if e.type != "tool" { VCLog.log("SSE", "\(e.type) chat=\(chatId.suffix(8))") }

        switch e.type {
        case "user":
            running.insert(chatId)
            turnStartedAt[chatId] = Date()
            liveTools[chatId] = []
            turnError[chatId] = nil
            Task { await loadConversation(chatId) }
        case "tool":
            guard let t = e.tool else { break }
            running.insert(chatId)
            var arr = liveTools[chatId] ?? []
            if t.phase == "start" {
                if !arr.contains(where: { $0.id == t.id }) {
                    arr.append(VCToolCall(id: t.id, name: t.name, args: t.args, result: nil))
                }
            } else if let idx = arr.firstIndex(where: { $0.id == t.id }) {
                arr[idx].result = t.result
            }
            liveTools[chatId] = arr
        case "assistant":
            liveTools[chatId] = []
            Task { await loadConversation(chatId) }
        case "done":
            running.remove(chatId)
            turnStartedAt[chatId] = nil
            liveTools[chatId] = []
            for r in confirms[chatId] ?? [] { resolvedConfirmIds.insert(r.callId) }
            confirms[chatId] = []
            Task { await loadConversation(chatId); await refreshChats() }
        case "error":
            running.remove(chatId)
            turnStartedAt[chatId] = nil
            liveTools[chatId] = []
            // Turn ended → its parked questions are moot. Tombstone them so a
            // stale in-flight GET can't resurrect the cards.
            for r in confirms[chatId] ?? [] { resolvedConfirmIds.insert(r.callId) }
            confirms[chatId] = []
            // Cancellation is not an error — the "⚠️ cancelled" stub already
            // lands in the transcript (mobile-web scar, same rule).
            if let err = e.error, err != "cancelled" { turnError[chatId] = err }
        case "cancelled":
            // Quiet unwind: server already rolled the user message back (and
            // deleted the chat if it became empty). Hand the text to the open
            // view's composer; clear all turn state without any error UI.
            running.remove(chatId)
            turnStartedAt[chatId] = nil
            liveTools[chatId] = []
            for r in confirms[chatId] ?? [] { resolvedConfirmIds.insert(r.callId) }
            confirms[chatId] = []
            if let t = e.text, !t.isEmpty { restoredInput[chatId] = t }
            Task { await loadConversation(chatId); await refreshChats() }
        case "confirm":
            if var req = e.request, !resolvedConfirmIds.contains(req.callId) {
                req.chatId = chatId
                var arr = confirms[chatId] ?? []
                if !arr.contains(where: { $0.callId == req.callId }) { arr.append(req) }
                confirms[chatId] = arr
            }
        case "confirm-resolved":
            if let cid = e.callId {
                resolvedConfirmIds.insert(cid)
                if resolvedConfirmIds.count > 500 { resolvedConfirmIds.removeAll() }
                confirms[chatId] = (confirms[chatId] ?? []).filter { $0.callId != cid }
            }
        case "chat-updated":
            Task { await refreshChats() }
        case "bypass":
            if let b = e.bypass {
                bypassByChat[chatId] = b
                if b {
                    for r in confirms[chatId] ?? [] { resolvedConfirmIds.insert(r.callId) }
                    confirms[chatId] = []
                }
            }
        default: break
        }
    }
}

// MARK: - Low-level HTTP helpers (shared by store + the Voice-page button)

extension VoiceChatAPI {
    static func getJSON<T: Decodable>(_ path: String) async throws -> T {
        guard let url = VoiceChatConfig.apiURL(path) else { throw VoiceChatError.badURL }
        var req = URLRequest(url: url); req.timeoutInterval = 15
        req.setValue("Bearer \(Secrets.remoteWebToken)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw VoiceChatError.http((resp as? HTTPURLResponse)?.statusCode ?? 0,
                                      String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    @discardableResult
    static func postJSON(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        guard let url = VoiceChatConfig.apiURL(path) else { throw VoiceChatError.badURL }
        var req = URLRequest(url: url); req.httpMethod = "POST"; req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(Secrets.remoteWebToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw VoiceChatError.http((resp as? HTTPURLResponse)?.statusCode ?? 0,
                                      String(data: data, encoding: .utf8) ?? "")
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    @discardableResult
    static func patchJSON(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        guard let url = VoiceChatConfig.apiURL(path) else { throw VoiceChatError.badURL }
        var req = URLRequest(url: url); req.httpMethod = "PATCH"; req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(Secrets.remoteWebToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw VoiceChatError.http((resp as? HTTPURLResponse)?.statusCode ?? 0,
                                      String(data: data, encoding: .utf8) ?? "")
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    @discardableResult
    static func deleteRequest(_ path: String) async throws -> Bool {
        guard let url = VoiceChatConfig.apiURL(path) else { throw VoiceChatError.badURL }
        var req = URLRequest(url: url); req.httpMethod = "DELETE"; req.timeoutInterval = 15
        req.setValue("Bearer \(Secrets.remoteWebToken)", forHTTPHeaderField: "Authorization")
        let (_, resp) = try await URLSession.shared.data(for: req)
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
}
