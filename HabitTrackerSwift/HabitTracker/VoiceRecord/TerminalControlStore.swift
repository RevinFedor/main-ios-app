import Foundation
import SwiftUI
import os

// Native remote control for Noted Terminal (custom-terminal). This mirrors the
// existing mobile-web protocol but keeps Terminal project/tab state separate
// from VoiceChatStore's flat Voice Record conversations.

enum TerminalControlConfig {
    private static var base: String {
        let raw = RemoteConfig.baseURLString(useDev: RemoteConfig.useDev, devHost: RemoteConfig.devHost)
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    static func apiURL(_ path: String) -> URL? {
        URL(string: base + path)
    }

    static func displayHost() -> String {
        RemoteConfig.displayHost(useDev: RemoteConfig.useDev, devHost: RemoteConfig.devHost)
    }
}

struct CTProject: Identifiable, Decodable, Equatable {
    let id: String
    var name: String   // var: optimistic update on rename
    let path: String
    var icon: String?
    var tabCount: Int?
    var sdkTabCount: Int?
    var liveSdkCount: Int?
    var updatedAt: Double?
    var isOpen: Bool?
    var isActive: Bool?
    var hasAwaiting: Bool?
}

struct CTStatusMarker: Decodable, Equatable {
    var shape: String?
    var sizePx: Double?

    static let fallback = CTStatusMarker(shape: "dot", sizePx: 8)
}

struct CTTabInfo: Identifiable, Decodable, Equatable {
    var tabId: String?
    var name: String   // var: optimistic update on rename
    let tabType: String
    var commandType: String?
    var toolType: String?
    var color: String?
    let cwd: String
    var claudeSessionId: String?
    var codexSessionId: String?
    var geminiSessionId: String?
    var timelineCount: Int?
    var sessionStatus: String?
    var awaiting: Bool?
    var statusId: String?
    var statusColor: String?
    var contextPct: Double?   // last-known context fill %, seed for the header pill

    var id: String { tabId ?? name + cwd }
    static func normalizedAgentType(_ value: String?) -> String? {
        guard let value else { return nil }
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !v.isEmpty else { return nil }
        if v.contains("codex") { return "codex" }
        if v.contains("gemini") { return "gemini" }
        if v.contains("claude") || v.contains("anthropic") { return "claude" }
        return nil
    }

    var effectiveToolType: String? {
        if let normalized = Self.normalizedAgentType(toolType) { return normalized }
        if let normalized = Self.normalizedAgentType(commandType) { return normalized }
        if let normalized = Self.normalizedAgentType(color) { return normalized }
        if tabType == "claude-sdk" { return "claude" }
        if codexSessionId != nil { return "codex" }
        if geminiSessionId != nil { return "gemini" }
        if claudeSessionId != nil { return "claude" }
        if let normalized = Self.normalizedAgentType(name) { return normalized }
        return nil
    }
    var isClaudePTY: Bool { effectiveToolType == "claude" && tabType != "claude-sdk" }
    var isCodexPTY: Bool { effectiveToolType == "codex" && tabType != "claude-sdk" }
    var isSDK: Bool { tabType == "claude-sdk" }
    var isInteractiveAI: Bool { isClaudePTY || isCodexPTY || isSDK }
    var activeSessionId: String? {
        if isCodexPTY { return codexSessionId }
        if effectiveToolType == "gemini" { return geminiSessionId }
        return claudeSessionId
    }
}

struct CTProjectTabsResponse: Decodable {
    let project: CTProject
    let tabs: [CTTabInfo]
    var statusMarker: CTStatusMarker?
}

struct CTProjectsResponse: Decodable {
    let projects: [CTProject]
}

struct CTActiveLoader: Identifiable, Decodable, Equatable {
    var tabId: String?
    var kind: String?
    var status: String?
    var project: String?
    var name: String?
    var cwd: String?
    var command: String?

    var id: String {
        [tabId, kind, status, name].compactMap { $0 }.joined(separator: ":")
    }

    var title: String {
        let projectName = project?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tabName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let projectName, !projectName.isEmpty, let tabName, !tabName.isEmpty {
            return projectName + " · " + tabName
        }
        return tabName?.isEmpty == false ? tabName! : (projectName?.isEmpty == false ? projectName! : "Terminal tab")
    }

    var blocksMobileInstall: Bool {
        status == "busy" || status == "running"
    }
}

struct CTActiveLoadersResponse: Decodable {
    var idle: Bool
    var count: Int?
    var loaders: [CTActiveLoader]
    var ts: Double?
}

struct CTBuildInstallJob: Decodable, Equatable {
    var id: String?
    var command: String?
    var cwd: String?
    var pid: Int?
    var running: Bool
    var startedAt: Double?
    var finishedAt: Double?
    var exitCode: Int?
    var signal: String?
    var ok: Bool?
    var error: String?
    var logTail: String?
}

struct CTBuildInstallResponse: Decodable {
    var ok: Bool?
    var job: CTBuildInstallJob?
    var error: String?
}

struct CTActivitySummary: Equatable {
    var count: Int
    var streaming: Bool
}

struct CTParams: Decodable, Equatable {
    let tabId: String?
    var model: String
    var effort: String
    var thinking: String
    // Context fill % travels in the SAME params bundle as model/effort, so one
    // on-open `/params` fetch seeds the whole runtime snapshot (model + ctx)
    // together instead of ctx arriving ~30s later on the next SSE bridge-update.
    var contextPct: Double?
}

// Live model catalog served by custom-terminal `GET /api/agent-models`. The
// desktop builds the Codex list from `codex debug models` (the bundled catalog
// is fallback-only and can carry hidden/upgrade-only rows the TUI rejects), so
// the phone must read the same source instead of hardcoding a stale subset —
// the symptom this fixes is "у Codex отображаются не все модели". `efforts` is
// per-model (Codex models advertise their own reasoning levels); Claude rows
// omit it. See custom-terminal `fact-codex.md::Модели и effort`.
struct CTModelOption: Decodable, Equatable, Identifiable {
    let id: String
    var label: String
    var efforts: [String]?
}

struct CTAgentModelCatalog: Decodable, Equatable {
    var codex: [CTModelOption]
    var claude: [CTModelOption]
}

struct CTQueueItem: Identifiable, Decodable, Equatable {
    let id: String
    var title: String?
    var text: String
    var images: Int?
    var createdAt: Double?
}

struct CTQueueCore: Decodable, Equatable {
    var items: [CTQueueItem]
    var autoRun: Bool
    var stopAfter: Bool
    var closeAfter: Bool
    var runAfterTabId: String?
    var firstDelaySeconds: Int?
    var postPromptEnabled: Bool?
    var postPromptText: String?
}

struct CTQueueResponse: Decodable {
    var tabId: String?
    var queue: CTQueueCore
}

struct CTTimelineEntry: Identifiable, Decodable {
    let uuid: String
    var kind: String
    var color: String?
    var preview: String
    var full: String?
    var ts: Double?
    var preTokens: Int?
    var id: String { uuid }
}

struct CTTimelineResponse: Decodable {
    var entries: [CTTimelineEntry]
    var sessionId: String?
    var count: Int?
}

struct CTQuestionOption: Identifiable, Decodable {
    var label: String
    var value: String?
    var id: String { value ?? label }
}

struct CTQuestionItem: Identifiable, Decodable {
    var question: String
    var options: [CTQuestionOption]?
    var multiSelect: Bool?
    var id: String { question }
}

struct CTPendingQuestion: Decodable {
    var source: String?
    var toolUseID: String?
    var questions: [CTQuestionItem]

    var isEmpty: Bool { questions.isEmpty }
}

struct CTPendingQuestionResponse: Decodable {
    var pendingQuestion: CTPendingQuestion?
}

struct CTAnswerQuestionResponse: Decodable {
    var success: Bool?
    var error: String?
}

struct CTPromptGroup: Identifiable, Decodable {
    let id: Int
    let name: String
    var position: Int?
}

struct CTPrompt: Identifiable, Decodable {
    let id: Int
    let title: String
    let content: String
    var group_id: Int?
    var position: Int?
    var file_paths: [String]?
}

struct CTPromptsResponse: Decodable {
    var groups: [CTPromptGroup]?
    var prompts: [CTPrompt]?
}

struct CTCompactMetrics: Decodable, Equatable, Sendable {
    var preTokens: Int?
    var postTokens: Int?
    var durationMs: Int?
    var trigger: String?

    enum CodingKeys: String, CodingKey {
        case preTokens, postTokens, durationMs, trigger
        case pre_tokens, post_tokens, duration_ms
    }

    init(preTokens: Int? = nil, postTokens: Int? = nil, durationMs: Int? = nil, trigger: String? = nil) {
        self.preTokens = preTokens
        self.postTokens = postTokens
        self.durationMs = durationMs
        self.trigger = trigger
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preTokens = (try? c.decode(Int.self, forKey: .preTokens)) ?? (try? c.decode(Int.self, forKey: .pre_tokens))
        postTokens = (try? c.decode(Int.self, forKey: .postTokens)) ?? (try? c.decode(Int.self, forKey: .post_tokens))
        durationMs = (try? c.decode(Int.self, forKey: .durationMs)) ?? (try? c.decode(Int.self, forKey: .duration_ms))
        trigger = try? c.decode(String.self, forKey: .trigger)
    }
}

struct CTRawMessage: Decodable {
    var type: String?
    var subtype: String?
    var uuid: String?
    var sessionId: String?
    var message: VCJSON?
    var result: VCJSON?
    var is_error: Bool?
    var isError: Bool?
    var isCompactSummary: Bool?
    var compactMetadata: CTCompactMetrics?
    var compact_metadata: CTCompactMetrics?
    var __webSynthetic: Bool?
    var __wasQueued: Bool?
}

struct CTHistoryResponse: Decodable, Sendable {
    var messages: [CTRawMessage]?
    var entries: [CTHistoryEntry]?
    var total: Int?
    var truncated: Bool?
    var dropped: Int?
    var sessionId: String?
    var toolType: String?
    var commandType: String?
    var firstUuid: String?
    var lastUuid: String?
}

struct CTHistoryEntry: Decodable, Sendable {
    var uuid: String?
    var role: String?
    var timestamp: String?
    var content: String?
    var thinking: String?
    var actions: [VCJSON]?
    var compactSummary: String?
    var preTokens: Int?
    var postTokens: Int?
    var durationMs: Int?
    var isOldHistory: Bool?
}

struct CTSSEPayload: Decodable {
    var type: String
    var tabId: String?
    var sessionId: String?
    var busy: Bool?
    var reason: String?
    var source: String?
    var toolUseID: String?
    var questions: [CTQuestionItem]?
    var sessionStatus: String?
    var toolType: String?
    var commandType: String?
    var inputReady: Bool?
    var message: CTRawMessage?
    var queue: CTQueueCore?
    var model: String?
    var contextPct: Double?
}

enum CTEntryKind: String, Equatable, Sendable {
    case user, assistant, thinking, tool, slash, compactSummary, error
}

// Sendable so a finished [CTEntry] can be built off the main actor (heavy decode
// + normalize of 1000+ msg histories) and handed back to @MainActor for publish.
// Equatable (Phase D) so each transcript row can be `.equatable()` — a streaming
// token mutates only the tail entry, so only that row's value differs and SwiftUI
// skips re-rendering the other ~250 rows instead of rebuilding the whole ForEach.
struct CTEntry: Identifiable, Sendable, Equatable {
    var id: String
    var kind: CTEntryKind
    var text: String = ""
    var entryUuid: String?
    var toolName: String?
    var toolInput: VCJSON?
    var toolResult: String?
    var toolIsError: Bool = false
    var metrics: CTCompactMetrics?
    var wasQueued: Bool = false

    var asToolCall: VCToolCall {
        let result: VCJSON? = toolResult.map {
            .object(["success": .bool(!toolIsError), "content": .string($0)])
        }
        return VCToolCall(id: id, name: toolName ?? "tool", args: toolInput, result: result)
    }

    var payloadUTF16Length: Int {
        text.utf16.count
            + (toolResult?.utf16.count ?? 0)
            + (toolName?.utf16.count ?? 0)
            + (toolInput?.compactDescription.utf16.count ?? 0)
    }
}

private func ctHistoryPayloadSummary(_ entries: [CTEntry]) -> String {
    guard let maxEntry = entries.max(by: { $0.payloadUTF16Length < $1.payloadUTF16Length }) else {
        return "maxEntry=none"
    }
    let top = entries
        .sorted { $0.payloadUTF16Length > $1.payloadUTF16Length }
        .prefix(3)
        .map { "\($0.kind.rawValue):\($0.id.prefix(8)):\($0.payloadUTF16Length)" }
        .joined(separator: ",")
    return "maxEntry=\(maxEntry.kind.rawValue):\(maxEntry.id.prefix(12)):\(maxEntry.payloadUTF16Length) top=[\(top)]"
}

private final class CTMessageReducer {
    private var entries: [CTEntry] = []
    private var toolIndexById: [String: Int] = [:]
    private var assistantIndexById: [String: Int] = [:]
    private var thinkingIndexById: [String: Int] = [:]
    private var pendingCompactMetrics: CTCompactMetrics?
    private var counter = 0

    func reset() {
        entries = []
        toolIndexById = [:]
        assistantIndexById = [:]
        thinkingIndexById = [:]
        pendingCompactMetrics = nil
        counter = 0
    }

    func seed(_ existing: [CTEntry]) {
        entries = existing
        toolIndexById = [:]
        assistantIndexById = [:]
        thinkingIndexById = [:]
        pendingCompactMetrics = nil
        counter = existing.count

        for (idx, entry) in existing.enumerated() {
            switch entry.kind {
            case .tool:
                toolIndexById[entry.id] = idx
            case .assistant:
                assistantIndexById[entry.id] = idx
                if let uuid = entry.entryUuid { assistantIndexById[uuid] = idx }
            case .thinking:
                let key = entry.id.hasPrefix("thinking-") ? String(entry.id.dropFirst("thinking-".count)) : entry.id
                thinkingIndexById[key] = idx
            default:
                break
            }
        }
    }

    func snapshot() -> [CTEntry] { entries }

    @discardableResult
    func addLocalUser(_ text: String) -> [CTEntry] {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return entries }
        entries.append(CTEntry(id: nextId(), kind: .user, text: clean))
        return entries
    }

    @discardableResult
    func apply(_ raw: CTRawMessage) -> [CTEntry] {
        guard raw.__webSynthetic != true else { return entries }
        switch raw.type {
        case "system":
            if raw.subtype == "compact_boundary" {
                pendingCompactMetrics = raw.compactMetadata ?? raw.compact_metadata
            }
        case "user":
            applyUser(raw)
        case "assistant":
            applyAssistant(raw)
        case "result":
            if raw.is_error == true || raw.isError == true || raw.subtype == "error" {
                entries.append(CTEntry(id: nextId(), kind: .error, text: jsonText(raw.result) ?? "error"))
            }
        default:
            break
        }
        return entries
    }

    private func applyUser(_ raw: CTRawMessage) {
        guard let content = object(raw.message)?["content"] else { return }
        if let blocks = array(content) {
            var pushedText = false
            for block in blocks {
                guard let obj = object(block) else { continue }
                let type = obj["type"]?.stringValue
                if type == "tool_result", let toolId = obj["tool_use_id"]?.stringValue {
                    if let idx = toolIndexById[toolId] {
                        entries[idx].toolResult = toolResultText(obj["content"])
                        entries[idx].toolIsError = obj["is_error"]?.boolValue ?? false
                    }
                } else if type == "text", !pushedText, let text = obj["text"]?.stringValue {
                    adoptOrPush(classifyUserText(text, uuid: raw.uuid, wasQueued: raw.__wasQueued == true, isCompactSummary: raw.isCompactSummary == true))
                    pushedText = true
                }
            }
        } else if let text = content.stringValue {
            adoptOrPush(classifyUserText(text, uuid: raw.uuid, wasQueued: raw.__wasQueued == true, isCompactSummary: raw.isCompactSummary == true))
        }
    }

    private func applyAssistant(_ raw: CTRawMessage) {
        let msgObject = object(raw.message)
        let msgId = msgObject?["id"]?.stringValue ?? raw.uuid ?? nextId()
        guard let blocks = msgObject?["content"].flatMap(array) else { return }

        for block in blocks {
            guard let obj = object(block) else { continue }
            switch obj["type"]?.stringValue {
            case "thinking":
                let text = obj["thinking"]?.stringValue ?? ""
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                if let idx = thinkingIndexById[msgId] {
                    entries[idx].text = text
                } else {
                    thinkingIndexById[msgId] = entries.count
                    entries.append(CTEntry(id: "thinking-" + msgId, kind: .thinking, text: text))
                }
            case "text":
                guard let text = obj["text"]?.stringValue else { continue }
                if let idx = assistantIndexById[msgId] {
                    entries[idx].text = text
                    if entries[idx].entryUuid == nil { entries[idx].entryUuid = raw.uuid }
                } else {
                    assistantIndexById[msgId] = entries.count
                    entries.append(CTEntry(id: msgId, kind: .assistant, text: text, entryUuid: raw.uuid))
                }
            case "tool_use":
                guard let id = obj["id"]?.stringValue else { continue }
                if toolIndexById[id] == nil {
                    toolIndexById[id] = entries.count
                    entries.append(CTEntry(
                        id: id,
                        kind: .tool,
                        toolName: obj["name"]?.stringValue ?? "tool",
                        toolInput: obj["input"]
                    ))
                }
            default:
                break
            }
        }
    }

    private func classifyUserText(_ text: String, uuid: String?, wasQueued: Bool, isCompactSummary: Bool) -> CTEntry? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("<command-name>") {
            let name = match(trimmed, #"<command-name>([^<]+)</command-name>"#)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/ ").union(.whitespacesAndNewlines))
            let args = match(trimmed, #"<command-args>([^<]*)"#).trimmingCharacters(in: .whitespacesAndNewlines)
            return CTEntry(id: uuid ?? nextId(), kind: .slash, text: "/" + name + (args.isEmpty ? "" : " " + args), entryUuid: uuid)
        }
        if trimmed.hasPrefix("<local-command-stdout>") ||
            trimmed.hasPrefix("<local-command-caveat>") ||
            trimmed.hasPrefix("<system-reminder>") ||
            trimmed == "[tool_result]" ||
            trimmed.hasPrefix("<tool_result>") {
            return nil
        }

        if isCompactSummary || trimmed.hasPrefix("This session is being continued from a previous conversation") {
            let metrics = pendingCompactMetrics
            pendingCompactMetrics = nil
            return CTEntry(id: uuid ?? nextId(), kind: .compactSummary, text: trimmed, entryUuid: uuid, metrics: metrics)
        }

        return CTEntry(id: uuid ?? nextId(), kind: .user, text: text, entryUuid: uuid, wasQueued: wasQueued)
    }

    private func adoptOrPush(_ entry: CTEntry?) {
        guard let entry else { return }
        if entry.kind == .user,
           let last = entries.last,
           last.kind == .user,
           last.text == entry.text,
           last.entryUuid == nil,
           entry.entryUuid != nil {
            entries[entries.count - 1].entryUuid = entry.entryUuid
            entries[entries.count - 1].wasQueued = entry.wasQueued
            return
        }
        if let uuid = entry.entryUuid,
           (entry.kind == .slash || entry.kind == .compactSummary),
           entries.contains(where: { $0.entryUuid == uuid }) {
            return
        }
        entries.append(entry)
        maybeSwapCompactPair()
    }

    private func maybeSwapCompactPair() {
        guard entries.count >= 2 else { return }
        let a = entries[entries.count - 2]
        let b = entries[entries.count - 1]
        if a.kind == .compactSummary && b.kind == .slash && b.text.hasPrefix("/compact") {
            entries[entries.count - 2] = b
            entries[entries.count - 1] = a
        }
    }

    private func nextId() -> String {
        counter += 1
        return "ct-\(counter)-\(Int(Date().timeIntervalSince1970 * 1000))"
    }
}

private enum CTHistoryEntryNormalizer {
    static func normalize(_ history: [CTHistoryEntry]) -> [CTEntry] {
        var out: [CTEntry] = []
        for (idx, entry) in history.enumerated() {
            let uuid = entry.uuid ?? "history-\(idx)"
            switch entry.role {
            case "user":
                let text = (entry.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    out.append(CTEntry(id: uuid, kind: .user, text: text, entryUuid: entry.uuid))
                }
            case "assistant":
                let thinking = (entry.thinking ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !thinking.isEmpty {
                    out.append(CTEntry(id: uuid + "-thinking", kind: .thinking, text: thinking))
                }
                let text = (entry.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    out.append(CTEntry(id: uuid, kind: .assistant, text: text, entryUuid: entry.uuid))
                }
                for (actionIdx, action) in (entry.actions ?? []).enumerated() {
                    if let tool = normalizeAction(action, id: "\(uuid)-tool-\(actionIdx)") {
                        out.append(tool)
                    }
                }
            case "compact":
                let text = (entry.compactSummary ?? entry.content ?? "Conversation compacted")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                out.append(CTEntry(
                    id: uuid,
                    kind: .compactSummary,
                    text: text,
                    entryUuid: entry.uuid,
                    metrics: CTCompactMetrics(preTokens: entry.preTokens, postTokens: entry.postTokens, durationMs: entry.durationMs, trigger: nil)
                ))
            default:
                let text = (entry.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    out.append(CTEntry(id: uuid, kind: .assistant, text: text, entryUuid: entry.uuid))
                }
            }
        }
        return out
    }

    private static func normalizeAction(_ action: VCJSON, id: String) -> CTEntry? {
        if case .string(let s) = action {
            return CTEntry(id: id, kind: .tool, toolName: "tool", toolResult: s)
        }
        guard let obj = object(action) else { return nil }
        if obj["tool"]?.stringValue == "__raw__", let raw = object(obj["rawTool"]) {
            return CTEntry(
                id: id,
                kind: .tool,
                toolName: raw["toolName"]?.stringValue ?? "tool",
                toolInput: raw["args"],
                toolResult: jsonText(raw["result"]),
                toolIsError: raw["isError"]?.boolValue ?? false
            )
        }
        let name = obj["tool"]?.stringValue ?? obj["name"]?.stringValue ?? obj["toolName"]?.stringValue ?? "tool"
        let input = obj["input"] ?? obj["args"] ?? obj["parameters"]
        let result = jsonText(obj["result"] ?? obj["output"] ?? obj["content"])
        return CTEntry(id: id, kind: .tool, toolName: name, toolInput: input, toolResult: result, toolIsError: obj["isError"]?.boolValue ?? obj["is_error"]?.boolValue ?? false)
    }
}

private func object(_ json: VCJSON?) -> [String: VCJSON]? {
    guard case .object(let o)? = json else { return nil }
    return o
}

private func array(_ json: VCJSON?) -> [VCJSON]? {
    guard case .array(let a)? = json else { return nil }
    return a
}

private func jsonText(_ json: VCJSON?) -> String? {
    guard let json else { return nil }
    if let s = json.stringValue { return s }
    return json.compactDescription
}

private func toolResultText(_ json: VCJSON?) -> String {
    if let s = json?.stringValue { return s }
    if let arr = array(json) {
        return arr.compactMap { object($0)?["text"]?.stringValue ?? $0.stringValue }.joined(separator: "\n")
    }
    return json?.compactDescription ?? ""
}

private func match(_ text: String, _ pattern: String) -> String {
    guard let re = try? NSRegularExpression(pattern: pattern),
          let m = re.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
          m.numberOfRanges > 1,
          let r = Range(m.range(at: 1), in: text) else { return "" }
    return String(text[r])
}

enum TerminalAPI {
    private static func authed(_ req: inout URLRequest) {
        req.setValue("Bearer \(Secrets.remoteWebToken)", forHTTPHeaderField: "Authorization")
    }

    private static func ms(_ started: Date) -> Int {
        Int(Date().timeIntervalSince(started) * 1000)
    }

    private static func safeHost(_ url: URL) -> String {
        (url.scheme ?? "?") + "://" + (url.host ?? "?") + (url.port.map { ":\($0)" } ?? "")
    }

    private static func bodyPreview(_ data: Data) -> String {
        (String(data: data, encoding: .utf8) ?? "\(data.count)b")
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(220)
            .description
    }

    static func getJSON<T: Decodable>(_ path: String) async throws -> T {
        guard let url = TerminalControlConfig.apiURL(path) else {
            VCLog.log("TerminalHTTP", "GET bad-url path=\(path) host=\(TerminalControlConfig.displayHost())")
            throw VoiceChatError.badURL
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        authed(&req)
        let started = Date()
        let opToken = OpsRegistry.shared.begin("url", op: path)
        defer { OpsRegistry.shared.end(opToken) }
        VCLog.log("TerminalHTTP", "GET start path=\(path) host=\(safeHost(url)) timeout=20")
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            VCLog.log("TerminalHTTP", "GET transport-fail path=\(path) ms=\(ms(started)): \(error.localizedDescription)")
            throw error
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        VCLog.log("TerminalHTTP", "GET response path=\(path) status=\(status) bytes=\(data.count) ms=\(ms(started))")
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            VCLog.log("TerminalHTTP", "GET rejected path=\(path) status=\(status) body=\(bodyPreview(data))")
            throw VoiceChatError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            VCLog.log("TerminalHTTP", "GET decode-fail path=\(path) status=\(status) bytes=\(data.count): \(error.localizedDescription)")
            throw error
        }
    }

    @discardableResult
    static func postJSON<T: Decodable>(_ path: String, body: [String: Any] = [:]) async throws -> T {
        guard let url = TerminalControlConfig.apiURL(path) else {
            VCLog.log("TerminalHTTP", "POST bad-url path=\(path) host=\(TerminalControlConfig.displayHost())")
            throw VoiceChatError.badURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 25
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authed(&req)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let started = Date()
        let opToken = OpsRegistry.shared.begin("url", op: "POST " + path)
        defer { OpsRegistry.shared.end(opToken) }
        VCLog.log("TerminalHTTP", "POST start path=\(path) host=\(safeHost(url)) bodyKeys=\(body.keys.sorted().joined(separator: ",")) timeout=25")
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            VCLog.log("TerminalHTTP", "POST transport-fail path=\(path) ms=\(ms(started)): \(error.localizedDescription)")
            throw error
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        VCLog.log("TerminalHTTP", "POST response path=\(path) status=\(status) bytes=\(data.count) ms=\(ms(started))")
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            VCLog.log("TerminalHTTP", "POST rejected path=\(path) status=\(status) body=\(bodyPreview(data))")
            throw VoiceChatError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            VCLog.log("TerminalHTTP", "POST decode-fail path=\(path) status=\(status) bytes=\(data.count): \(error.localizedDescription)")
            throw error
        }
    }

    static func projects() async throws -> [CTProject] {
        let r: CTProjectsResponse = try await getJSON("/api/projects")
        return r.projects
    }

    static func activeLoaders() async throws -> CTActiveLoadersResponse {
        try await getJSON("/api/active-loaders")
    }

    static func tabs(projectId: String) async throws -> CTProjectTabsResponse {
        try await getJSON("/api/projects/" + vcPathComponent(projectId) + "/tabs")
    }

    static func createClaudeTab(projectId: String) async throws -> CTTabInfo {
        try await createAgentTab(projectId: projectId, toolType: "claude")
    }

    static func createAgentTab(projectId: String, toolType: String) async throws -> CTTabInfo {
        struct Created: Decodable {
            let tabId: String
            let name: String
            let cwd: String
            let projectId: String?
            let toolType: String?
            let commandType: String?
            let color: String?
        }
        let agent = toolType == "codex" ? "codex" : "claude"
        let r: Created = try await postJSON(
            "/api/projects/" + vcPathComponent(projectId) + "/agent-tabs",
            body: ["toolType": agent]
        )
        return CTTabInfo(
            tabId: r.tabId,
            name: r.name,
            tabType: "terminal",
            commandType: r.commandType ?? agent,
            toolType: r.toolType ?? agent,
            color: r.color ?? agent,
            cwd: r.cwd,
            claudeSessionId: nil,
            codexSessionId: nil,
            geminiSessionId: nil,
            timelineCount: nil,
            sessionStatus: "starting",
            awaiting: false,
            statusId: nil,
            statusColor: nil,
            contextPct: nil
        )
    }

    static func createSDKTab(projectId: String) async throws -> CTTabInfo {
        struct Created: Decodable { let tabId: String; let name: String?; let cwd: String?; let projectId: String? }
        let r: Created = try await postJSON("/api/projects/" + vcPathComponent(projectId) + "/sdk-tabs")
        return CTTabInfo(tabId: r.tabId, name: r.name ?? "SDK chat", tabType: "claude-sdk", commandType: "claude", toolType: "claude", color: "purple", cwd: r.cwd ?? "", claudeSessionId: nil, codexSessionId: nil, geminiSessionId: nil, timelineCount: nil, sessionStatus: "active", awaiting: false, statusId: nil, statusColor: nil, contextPct: nil)
    }

    static func history(tabId: String, last: Int = 250) async throws -> CTHistoryResponse {
        try await getJSON("/api/sdk-tabs/" + vcPathComponent(tabId) + "/history?view=history&last=\(last)")
    }

    static func status(tabId: String) async throws -> CTParamsStatus {
        try await getJSON("/api/sdk-tabs/" + vcPathComponent(tabId) + "/status")
    }

    static func params(tabId: String) async throws -> CTParams {
        try await getJSON("/api/sdk-tabs/" + vcPathComponent(tabId) + "/params")
    }

    static func setParams(tabId: String, body: [String: Any]) async throws -> CTParamsStatus {
        try await postJSON("/api/sdk-tabs/" + vcPathComponent(tabId) + "/params", body: body)
    }

    // Live codex/claude model catalog. Server-wide (not per-tab) — `{success,
    // codex:[…], claude:[…]}`. The extra `success` key is ignored by the decoder.
    static func agentModels() async throws -> CTAgentModelCatalog {
        try await getJSON("/api/agent-models")
    }

    static func send(tabId: String, prompt: String, params: CTParams?) async throws {
        var body: [String: Any] = ["prompt": prompt]
        if let params {
            body["model"] = params.model
            body["effort"] = params.effort
            body["thinking"] = params.thinking
        }
        let _: CTGenericOK = try await postJSON("/api/sdk-tabs/" + vcPathComponent(tabId) + "/send", body: body)
    }

    static func interrupt(tabId: String) async throws {
        let _: CTGenericOK = try await postJSON("/api/sdk-tabs/" + vcPathComponent(tabId) + "/interrupt")
    }

    static func draft(tabId: String) async throws -> CTDraftResponse {
        try await getJSON("/api/sdk-tabs/" + vcPathComponent(tabId) + "/draft")
    }

    static func stop(tabId: String) async throws {
        let _: CTGenericOK = try await postJSON("/api/sdk-tabs/" + vcPathComponent(tabId) + "/stop")
    }

    static func resume(tabId: String) async throws -> CTResumeResponse {
        try await postJSON("/api/sdk-tabs/" + vcPathComponent(tabId) + "/resume")
    }

    // Rename a tab. Server sets nameSetManually=true so the command name can't
    // clobber it later (custom-terminal fix-tab-naming-race.md). Works for any
    // open tab (Claude PTY / Codex PTY / SDK) by id.
    static func renameTab(tabId: String, name: String) async throws {
        let _: CTGenericOK = try await postJSON(
            "/api/sdk-tabs/" + vcPathComponent(tabId) + "/rename", body: ["name": name])
    }

    // Rename a project. Server persists via project:save-metadata (SQLite) and
    // updates the desktop in-memory map the project list reads from.
    static func renameProject(projectId: String, name: String) async throws {
        let _: CTGenericOK = try await postJSON(
            "/api/projects/" + vcPathComponent(projectId) + "/rename", body: ["name": name])
    }

    static func timeline(tabId: String) async throws -> CTTimelineResponse {
        try await getJSON("/api/sdk-tabs/" + vcPathComponent(tabId) + "/timeline")
    }

    static func pendingQuestion(tabId: String) async throws -> CTPendingQuestionResponse {
        try await getJSON("/api/sdk-tabs/" + vcPathComponent(tabId) + "/pending-question")
    }

    static func answerQuestion(tabId: String, question: CTPendingQuestion, answers: [String: Any] = [:], stop: Bool = false) async throws -> CTAnswerQuestionResponse {
        let questionPayload = question.questions.map { q -> [String: Any] in
            var item: [String: Any] = [
                "question": q.question,
                "multiSelect": q.multiSelect ?? false
            ]
            if let options = q.options {
                item["options"] = options.map { opt -> [String: Any] in
                    var out: [String: Any] = ["label": opt.label]
                    if let value = opt.value { out["value"] = value }
                    return out
                }
            }
            return item
        }
        return try await postJSON("/api/sdk-tabs/" + vcPathComponent(tabId) + "/answer-question", body: [
            "source": question.source ?? "pty",
            "toolUseID": question.toolUseID ?? "pty",
            "questions": questionPayload,
            "answers": answers,
            "stop": stop
        ])
    }

    static func queue(tabId: String) async throws -> CTQueueResponse {
        try await getJSON("/api/sdk-tabs/" + vcPathComponent(tabId) + "/queue")
    }

    static func mutateQueue(tabId: String, op: String, args: [String: Any] = [:]) async throws -> CTQueueResponse {
        try await postJSON("/api/sdk-tabs/" + vcPathComponent(tabId) + "/queue", body: ["op": op, "args": args])
    }

    static func prompts() async throws -> CTPromptsResponse {
        try await getJSON("/api/prompts")
    }
}

enum VoiceRecordTerminalAPI {
    private static func authed(_ req: inout URLRequest) {
        req.setValue("Bearer \(Secrets.remoteWebToken)", forHTTPHeaderField: "Authorization")
    }

    private static func ms(_ started: Date) -> Int {
        Int(Date().timeIntervalSince(started) * 1000)
    }

    private static func safeHost(_ url: URL) -> String {
        (url.scheme ?? "?") + "://" + (url.host ?? "?") + (url.port.map { ":\($0)" } ?? "")
    }

    private static func bodyPreview(_ data: Data) -> String {
        (String(data: data, encoding: .utf8) ?? "\(data.count)b")
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(220)
            .description
    }

    static func getJSON<T: Decodable>(_ path: String) async throws -> T {
        guard let url = VoiceChatConfig.apiURL(path) else {
            VCLog.log("TerminalInstallHTTP", "GET bad-url path=\(path)")
            throw VoiceChatError.badURL
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        authed(&req)
        let started = Date()
        VCLog.log("TerminalInstallHTTP", "GET start path=\(path) host=\(safeHost(url)) timeout=15")
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            VCLog.log("TerminalInstallHTTP", "GET transport-fail path=\(path) ms=\(ms(started)): \(error.localizedDescription)")
            throw error
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        VCLog.log("TerminalInstallHTTP", "GET response path=\(path) status=\(status) bytes=\(data.count) ms=\(ms(started))")
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            VCLog.log("TerminalInstallHTTP", "GET rejected path=\(path) status=\(status) body=\(bodyPreview(data))")
            throw VoiceChatError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            VCLog.log("TerminalInstallHTTP", "GET decode-fail path=\(path) status=\(status) bytes=\(data.count): \(error.localizedDescription)")
            throw error
        }
    }

    @discardableResult
    static func postJSON<T: Decodable>(_ path: String, body: [String: Any] = [:]) async throws -> T {
        guard let url = VoiceChatConfig.apiURL(path) else {
            VCLog.log("TerminalInstallHTTP", "POST bad-url path=\(path)")
            throw VoiceChatError.badURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authed(&req)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let started = Date()
        VCLog.log("TerminalInstallHTTP", "POST start path=\(path) host=\(safeHost(url)) bodyKeys=\(body.keys.sorted().joined(separator: ",")) timeout=20")
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            VCLog.log("TerminalInstallHTTP", "POST transport-fail path=\(path) ms=\(ms(started)): \(error.localizedDescription)")
            throw error
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        VCLog.log("TerminalInstallHTTP", "POST response path=\(path) status=\(status) bytes=\(data.count) ms=\(ms(started))")
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            VCLog.log("TerminalInstallHTTP", "POST rejected path=\(path) status=\(status) body=\(bodyPreview(data))")
            throw VoiceChatError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            VCLog.log("TerminalInstallHTTP", "POST decode-fail path=\(path) status=\(status) bytes=\(data.count): \(error.localizedDescription)")
            throw error
        }
    }

    static func startBuildInstall() async throws -> CTBuildInstallJob? {
        let r: CTBuildInstallResponse = try await postJSON("/api/terminal/build-install")
        return r.job
    }

    static func buildInstallStatus() async throws -> CTBuildInstallJob? {
        let r: CTBuildInstallResponse = try await getJSON("/api/terminal/build-install")
        return r.job
    }
}

struct CTGenericOK: Decodable {
    var success: Bool?
    var stopped: Bool?
    var interrupted: Bool?
}

struct CTDraftResponse: Decodable, Equatable {
    var success: Bool?
    var text: String?
    var images: Int?
    var error: String?
}

struct CTParamsStatus: Decodable {
    var tabId: String?
    var status: String?
    var busy: Bool?
    var commandType: String?
    var toolType: String?
    var sessionId: String?
    var cwd: String?
}

struct CTResumeResponse: Decodable {
    var tabId: String?
    var sessionId: String?
    var alreadyRunning: Bool?
}

// PHASE C: migrated from `ObservableObject + @Published` to the iOS 17+
// Observation framework (`@Observable`). Why: with ObservableObject every
// @Published write fires the single object-wide objectWillChange, so ANY view
// holding the store re-rendered on ANY field change — the projects list redrew
// when statusByTab/history/queue mutated, which (over a remote tunnel + during
// the 9-project prefetch) dropped frames. @Observable tracks the EXACT stored
// properties each view reads in its body, so a view only re-renders when a
// property it actually displays changes. Migration is mechanical: drop
// ObservableObject + @Published, add @Observable, and mark non-UI internals
// @ObservationIgnored. Observers updated: @ObservedObject→let, @StateObject→
// @State. Validated June 2026 (WWDC23 Discover Observation; SE-0395; +2 research
// agents, 48+50 sources). The change-equality guards added earlier stay — they
// still cut redundant writes before observation even sees them.
@MainActor
@Observable
final class TerminalControlStore {
    static let shared = TerminalControlStore()

    var projects: [CTProject] = []
    var tabsByProject: [String: [CTTabInfo]] = [:]
    var statusMarkerByProject: [String: CTStatusMarker] = [:]
    var selectedProject: CTProject?
    var selectedTab: CTTabInfo?
    var entriesByTab: [String: [CTEntry]] = [:]
    var statusByTab: [String: String] = [:]
    var runningTabs: Set<String> = []
    var turnStartedAt: [String: Date] = [:]
    var paramsByTab: [String: CTParams] = [:]
    // Context used %, mirrored from the desktop StatusLine bridge (Claude) / Codex
    // rollout token_count via SSE `bridge-update.contextPct`. The number is the
    // source's own value, not recomputed on the phone (same contract as desktop:
    // fact-claude-control-bar.md::Context % bridge). Shown in the header next to
    // the runtime status. Absent until the first bridge frame for the tab.
    var contextPctByTab: [String: Int] = [:]
    // Live agent model catalog (codex/claude) fetched once per warm-cache cycle.
    // nil until the first successful fetch; chips fall back to static literals
    // so the picker is never empty even offline or against an old desktop build.
    var modelCatalog: CTAgentModelCatalog?
    var queueByTab: [String: CTQueueCore] = [:]
    var timelineByTab: [String: [CTTimelineEntry]] = [:]
    var timelineLoading: Set<String> = []
    var timelineErrorByTab: [String: String] = [:]
    var pendingQuestionByTab: [String: CTPendingQuestion] = [:]
    var questionAnsweringTabs: Set<String> = []
    var projectsScrollAnchorId: String?
    var tabsScrollAnchorByProject: [String: String] = [:]
    var loadingProjects = false
    var loadingTabs: Set<String> = []
    // Projects with a /tabs GET in flight. Deferred freshness checks can overlap
    // during rapid navigation; this dedups identical loads so one publish refreshes
    // the shared cache for everyone.
    @ObservationIgnored private var tabsLoadInFlight: Set<String> = []
    @ObservationIgnored private var deferredTabsReloadTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var deferredTabsReloadTokens: [String: UUID] = [:]
    var historyLoading: Set<String> = []
    var offline = false
    var sseConnected = false
    var lastError: String?
    var terminalInstallRunning = false
    var terminalInstallJob: CTBuildInstallJob?
    var restoredInputByTab: [String: String] = [:]
    var draftNoticeByTab: [String: String] = [:]
    var interruptAwaitingTabs: Set<String> = []

    // Non-UI internals: @ObservationIgnored so they don't register as view
    // dependencies (reducers, task handles, bookkeeping — never read in a body).
    @ObservationIgnored private var reducers: [String: CTMessageReducer] = [:]
    @ObservationIgnored private var sseTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var historyReloadTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var warmCacheTask: Task<Void, Never>?
    @ObservationIgnored private var tabsPrefetchTask: Task<Void, Never>?
    @ObservationIgnored private var activeSSETabId: String?
    @ObservationIgnored private var sseAttemptByTab: [String: Int] = [:]
    @ObservationIgnored private var sseEventSeqByTab: [String: Int] = [:]
    @ObservationIgnored private var didResetNavigationForCurrentAppLaunch = false
    @ObservationIgnored private var lastProjectsRefreshAt: Date?
    // Per-project freshness stamp for the tabs cache, so selectProject can skip a
    // redundant /tabs reload on a rapid re-visit (the churn that hitched the slide).
    @ObservationIgnored private var tabsRefreshedAt: [String: Date] = [:]
    @ObservationIgnored private var pendingPromptRecoveryByTab: [String: Date] = [:]
    @ObservationIgnored private var draftRecoveryTasks: [String: Task<Void, Never>] = [:]
    // The model the user just picked, with the moment it was picked. A PTY-Claude
    // `/model` switch lands in `bridgeMetadata.model` only after the next status
    // line, so an in-flight `bridge-update` (or a /params readback) can carry the
    // PREVIOUS model for a second or two. Without this guard the chip flickered
    // opus → haiku → opus (user report). While a pick is pending we refuse any
    // bridge model that disagrees, until the bridge confirms the chosen value or
    // the short window elapses.
    @ObservationIgnored private var pendingModelByTab: [String: (model: String, at: Date)] = [:]

    // True while the user is actively navigating (drag / push / back slide). The
    // tabs prefetch loop PARKS while this is set: the watchdog proved the
    // tabs→projects stutter is a HITCH (no [hang] gap ≥250ms — many sub-frame
    // mutations), caused by background prefetch GETs (one took 1622ms over the
    // tunnel) landing their @Published tabsByProject writes mid-slide and
    // re-rendering the projects back-preview each frame. Pausing prefetch during
    // interaction removes the mutations that drive the hitch. @ObservationIgnored:
    // pure coordination, never read in a view body. Set by the UK gesture layer.
    @ObservationIgnored private(set) var interactionActive = false
    @ObservationIgnored private var interactionEndedAt = Date.distantPast
    @ObservationIgnored private var interactionSources: Set<String> = []

    func setInteractionActive(_ active: Bool, source: String = "term-nav") {
        let wasActive = interactionActive
        if active {
            interactionSources.insert(source)
        } else {
            interactionSources.remove(source)
        }
        interactionActive = !interactionSources.isEmpty
        if wasActive && !interactionActive {
            interactionEndedAt = Date()
        }
    }

    // Prefetch / optional tab refresh waits through the visible settle tail. 250ms
    // was enough to miss the slide, but logs still showed changed=false /tabs GETs
    // starting at phaseAge≈250ms inside FrameMonitor's settle window.
    @ObservationIgnored private let prefetchIdleGraceMs: Double = 1_250
    // History publish is a much heavier visible write than a cached prefetch:
    // assigning 100-250 transcript rows can trigger Text layout in the same settle
    // window as the push animation. Keep it past FrameMonitor's ~1.2s nav window.
    @ObservationIgnored private let historyPublishIdleGraceMs: Double = 1_250

    var canStepBack: Bool {
        selectedTab != nil || selectedProject != nil
    }

    // A turn is in flight for this tab. Single source of truth for "controls
    // that change the running agent must be locked" — model/effort/think pickers
    // read this so they can't fire a live `/model` switch mid-answer. Mirrors the
    // desktop `controlsLocked` (HistoryPanel) and `fact-codex.md::Модели и effort`
    // ("во время активного turn'а controls disabled/ignored без toast"). Same
    // signal the composer Send↔Stop swap already trusts (TerminalControlUI).
    func isTabTurnBusy(_ tabId: String) -> Bool {
        runningTabs.contains(tabId) || statusByTab[tabId] == "busy"
    }

    func stepBackOneLevel() {
        if selectedTab != nil {
            backToTabs()
        } else if selectedProject != nil {
            backToProjects()
        }
    }

    func resetNavigationToProjectsOnFirstOpen() {
        guard !didResetNavigationForCurrentAppLaunch else { return }
        didResetNavigationForCurrentAppLaunch = true
        guard selectedProject != nil || selectedTab != nil else { return }
        VCLog.log("TerminalNav", "reset to projects on first open")
        selectedProject = nil
        selectedTab = nil
        stopLiveChannel()
    }

    func consumeRestoredInput(tabId: String) {
        restoredInputByTab[tabId] = nil
    }

    func consumeDraftNotice(tabId: String) {
        draftNoticeByTab[tabId] = nil
    }

    func activitySummary(projectId: String? = nil) -> CTActivitySummary {
        let projectIds = projectId.map { [$0] } ?? projects.map(\.id)
        var seen = Set<String>()
        var count = 0
        var streaming = false

        for pid in projectIds {
            let tabs = tabsByProject[pid] ?? []
            if tabs.isEmpty,
               let project = projects.first(where: { $0.id == pid }),
               let live = project.liveSdkCount,
               live > 0 {
                count += live
                streaming = true
                continue
            }

            for tab in tabs where tab.isInteractiveAI {
                let rawId = tab.tabId ?? tab.id
                guard seen.insert(rawId).inserted else { continue }
                let status = tab.tabId.flatMap { statusByTab[$0] } ?? tab.sessionStatus ?? "inactive"
                if status == "busy" || status == "running" {
                    count += 1
                }
                if status == "busy" || status == "running" || runningTabs.contains(rawId) {
                    streaming = true
                }
            }
        }

        return CTActivitySummary(count: count, streaming: streaming)
    }

    private func projectIdForTab(_ tabId: String) -> String? {
        for (projectId, tabs) in tabsByProject {
            if tabs.contains(where: { ($0.tabId ?? $0.id) == tabId }) {
                return projectId
            }
        }
        if selectedTab?.tabId == tabId { return selectedProject?.id }
        return nil
    }

    private func tabRowStatus(tabId: String) -> String {
        for (_, tabs) in tabsByProject {
            if let tab = tabs.first(where: { ($0.tabId ?? $0.id) == tabId }) {
                return tab.sessionStatus ?? "nil"
            }
        }
        return "missing"
    }

    private func activityDebug(projectId: String?) -> String {
        guard let projectId else {
            return "project=nil runningSet=\(runningTabs.count)"
        }
        let activity = activitySummary(projectId: projectId)
        return "project=\(shortID(projectId)) activityCount=\(activity.count) streaming=\(activity.streaming) runningSet=\(runningTabs.count)"
    }

    private func logRuntimeTransition(tabId: String, reason: String, oldStatus: String?, oldRunning: Bool) {
        let newStatus = statusByTab[tabId] ?? "nil"
        let newRunning = runningTabs.contains(tabId)
        let projectId = projectIdForTab(tabId)
        VCLog.log(
            "TerminalState",
            "runtime tab=\(shortID(tabId)) reason=\(reason) map=\(oldStatus ?? "nil")->\(newStatus) running=\(oldRunning)->\(newRunning) tabRowStatus=\(tabRowStatus(tabId: tabId)) \(activityDebug(projectId: projectId))"
        )
    }

    func start() {
        guard warmCacheTask == nil else {
            VCLog.log("TerminalCache", "start skip warm task already running projects=\(projects.count) offline=\(offline)")
            return
        }
        let cold = projects.isEmpty
        if !cold, let lastProjectsRefreshAt, Date().timeIntervalSince(lastProjectsRefreshAt) < 20 {
            VCLog.log("TerminalCache", "start skip recent projects ageMs=\(elapsedMs(since: lastProjectsRefreshAt)) count=\(projects.count) offline=\(offline)")
            return
        }
        VCLog.log("TerminalCache", "start warm cache cold=\(cold) projects=\(projects.count) host=\(TerminalControlConfig.displayHost()) prefetchTabs=true")
        warmCacheTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshProjects(showLoader: cold, prefetchTabs: true)
            if !self.offline {
                await self.refreshModelCatalog()
            } else {
                VCLog.log("TerminalCache", "model catalog skip offline")
            }
            await MainActor.run { self.warmCacheTask = nil }
        }
    }

    // Pull the live codex/claude model catalog. Best-effort: a failure (offline,
    // old desktop build without the route) leaves `modelCatalog` as-is, so chips
    // keep their static fallback. Only published when the value actually changes,
    // to avoid a redundant @Observable invalidation on every warm-cache cycle.
    func refreshModelCatalog() async {
        do {
            let catalog: CTAgentModelCatalog = try await TerminalAPI.agentModels()
            if modelCatalog != catalog {
                modelCatalog = catalog
                VCLog.log("TerminalCache", "model catalog codex=\(catalog.codex.count) claude=\(catalog.claude.count)")
            }
        } catch {
            VCLog.log("TerminalCache", "model catalog fetch failed (keeping fallback): \(error.localizedDescription)")
        }
    }

    func refreshProjects(showLoader: Bool = true, prefetchTabs: Bool = false) async {
        if showLoader { loadingProjects = true }
        let started = Date()
        VCLog.log("TerminalCache", "projects load start showLoader=\(showLoader) prefetch=\(prefetchTabs) cached=\(projects.count) offline=\(offline)")
        do {
            let loaded = try await TerminalAPI.projects()
            // Only publish when the list actually changed. A reconnect/re-warm
            // every ~2min otherwise re-assigns an identical array, re-rendering the
            // projects list (and bumping objectWillChange for the whole terminal
            // tree) for nothing. CTProject is Equatable, so this is a cheap guard.
            if projects != loaded {
                projects = loaded
            }
            lastProjectsRefreshAt = Date()
            offline = false
            lastError = nil
            let openCount = loaded.filter { $0.isOpen == true }.count
            let activeName = loaded.first(where: { $0.isActive == true })?.name ?? "-"
            VCLog.log("TerminalCache", "projects load done count=\(loaded.count) open=\(openCount) active=\(activeName) ms=\(elapsedMs(since: started))")
            if prefetchTabs {
                scheduleTabsPrefetch(for: loaded)
            }
        } catch {
            VCLog.log("TerminalCache", "projects load failed ms=\(elapsedMs(since: started)): \(error.localizedDescription)")
            mark(error)
        }
        if showLoader { loadingProjects = false }
    }

    func terminalBuildInstallBlockers() async throws -> [CTActiveLoader] {
        let started = Date()
        VCLog.log("TerminalInstall", "preflight start host=\(TerminalControlConfig.displayHost())")
        do {
            let snap = try await TerminalAPI.activeLoaders()
            let blockers = snap.loaders.filter(\.blocksMobileInstall)
            VCLog.log(
                "TerminalInstall",
                "preflight snapshot idle=\(snap.idle) count=\(snap.count ?? snap.loaders.count) raw=[\(activeLoaderSummary(snap.loaders))] blockers=[\(activeLoaderSummary(blockers))] ms=\(elapsedMs(since: started))"
            )
            return blockers
        } catch {
            if isTerminalUnavailable(error) {
                offline = true
                VCLog.log("TerminalInstall", "preflight terminal-unavailable ms=\(elapsedMs(since: started)): \(error.localizedDescription)")
                return []
            }
            VCLog.log("TerminalInstall", "preflight failed ms=\(elapsedMs(since: started)): \(error.localizedDescription)")
            throw error
        }
    }

    func runTerminalBuildInstall() async throws -> CTBuildInstallJob? {
        if terminalInstallRunning {
            VCLog.log("TerminalInstall", "run ignored already-running job=\(terminalInstallJob?.id ?? "-")")
            return terminalInstallJob
        }
        terminalInstallRunning = true
        defer { terminalInstallRunning = false }

        VCLog.log("TerminalInstall", "run start via VoiceRecord host=\(VoiceChatConfig.displayHost())")
        var job = try await VoiceRecordTerminalAPI.startBuildInstall()
        terminalInstallJob = job
        VCLog.log("TerminalInstall", "run job accepted id=\(job?.id ?? "-") running=\(job?.running == true) pid=\(job?.pid.map(String.init) ?? "-") command=\(job?.command ?? "-")")

        var poll = 0
        while job?.running == true {
            try await Task.sleep(for: .seconds(2))
            poll += 1
            job = try await VoiceRecordTerminalAPI.buildInstallStatus()
            terminalInstallJob = job
            VCLog.log("TerminalInstall", "run poll#\(poll) id=\(job?.id ?? "-") running=\(job?.running == true) exit=\(job?.exitCode.map(String.init) ?? "-") ok=\(job?.ok.map(String.init) ?? "-")")
        }

        if let job, job.ok == false {
            let code = job.exitCode.map { "code \($0)" } ?? "failed"
            let detail = job.error ?? job.logTail ?? "npm run build:install failed"
            VCLog.log("TerminalInstall", "run failed id=\(job.id ?? "-") exit=\(job.exitCode.map(String.init) ?? "-") error=\(detail.prefix(180))")
            throw VoiceChatError.http(job.exitCode ?? 1, code + ": " + detail)
        }

        VCLog.log("TerminalInstall", "run done id=\(job?.id ?? "-") exit=\(job?.exitCode.map(String.init) ?? "-") ok=\(job?.ok.map(String.init) ?? "-")")
        return job
    }

    // Rename a tab: optimistic local update across every collection that holds
    // a copy of the name (the per-project tab list + selectedTab), then POST.
    // On failure reload the project's tabs so the UI snaps back to server truth.
    func renameTab(_ tab: CTTabInfo, to newName: String, projectId explicitProjectId: String? = nil) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tabId = tab.tabId, !trimmed.isEmpty, trimmed != tab.name else { return }
        // Prefer the explicit project (from the tab-list surface); fall back to
        // selectedProject (chat-detail surface), then to whichever project's
        // cached list actually contains this tab.
        let projectId = explicitProjectId
            ?? selectedProject?.id
            ?? tabsByProject.first(where: { $0.value.contains(where: { $0.tabId == tabId }) })?.key
        if let projectId, var tabs = tabsByProject[projectId],
           let idx = tabs.firstIndex(where: { $0.tabId == tabId }) {
            tabs[idx].name = trimmed
            tabsByProject[projectId] = tabs
        }
        if selectedTab?.tabId == tabId { selectedTab?.name = trimmed }
        VCLog.log("TerminalRename", "tab id=\(shortID(tabId)) → \(trimmed)")
        Task {
            do {
                try await TerminalAPI.renameTab(tabId: tabId, name: trimmed)
            } catch {
                VCLog.log("TerminalRename", "tab FAILED id=\(shortID(tabId)) err=\(error.localizedDescription)")
                if let projectId { await loadTabs(projectId: projectId, showLoader: false) }
            }
        }
    }

    // Rename a project: optimistic update of the projects list + selectedProject,
    // then POST. Reload on failure.
    func renameProject(_ project: CTProject, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != project.name else { return }
        if let idx = projects.firstIndex(where: { $0.id == project.id }) {
            projects[idx].name = trimmed
        }
        if selectedProject?.id == project.id { selectedProject?.name = trimmed }
        VCLog.log("TerminalRename", "project id=\(shortID(project.id)) → \(trimmed)")
        Task {
            do {
                try await TerminalAPI.renameProject(projectId: project.id, name: trimmed)
            } catch {
                VCLog.log("TerminalRename", "project FAILED id=\(shortID(project.id)) err=\(error.localizedDescription)")
                await refreshProjects(showLoader: false)
            }
        }
    }

    func selectProject(_ project: CTProject) {
        // Tear down the previous tab's live channels. Forward navigation never did
        // this (only back did) — so after chat→tabs→another project, the OLD tab's
        // 4s status poll + SSE stream stayed alive and kept mutating statusByTab /
        // tabsByProject / selectedTab, re-rendering the freshly-shown tabs list for
        // the next 5-10s. That is exactly the "lag right after opening a project
        // that disappears once it settles" the user bisected. The destination tab,
        // if any, re-arms its own channel via the view's .task(id:).
        stopLiveChannel()
        selectedProject = project
        selectedTab = nil
        let hasCachedTabs = !(tabsByProject[project.id]?.isEmpty ?? true)
        // Skip the network reload entirely when the cache is FRESH. The user
        // rapid-taps projects; each tap was firing a redundant /tabs GET even
        // though the tabs were prefetched seconds ago, and the response landed
        // mid-slide rewriting tabsByProject → re-running the live forward view's
        // body every frame (128 dropped frames, no main-thread hang — the
        // AttributeGraph churn the research flagged). Live tab status still arrives
        // via SSE on the OPEN tab; the project-tabs list doesn't need a refresh on
        // every visit. 15s freshness = re-fetch only if genuinely stale.
        let fresh = (tabsRefreshedAt[project.id]).map { Date().timeIntervalSince($0) < 15 } ?? false
        VCLog.log("TerminalNav", "select project id=\(shortID(project.id)) name=\(project.name) cachedTabs=\(hasCachedTabs) fresh=\(fresh) tabCount=\(project.tabCount ?? -1) open=\(project.isOpen == true) nav=\(TerminalPerfContext.shared.snapshot())")
        if hasCachedTabs {
            if fresh {
                VCLog.log("TerminalNav", "skip tabs reload (cache fresh) project=\(shortID(project.id)) nav=\(TerminalPerfContext.shared.snapshot())")
                return
            }
            // Cached but stale: this is a BACKGROUND freshness check, not something
            // the transition should pay for. The first pass fixed mid-slide writes,
            // but logs still showed stale cached projects starting `/tabs` in
            // `settle` ~500ms after the click (`changed=false`), which the user
            // felt as "the second project opens with a small delay". Wait for a
            // longer quiet window; if the user keeps browsing projects, the selected
            // project / selectedTab guards below cancel this stale refresh.
            scheduleDeferredTabsReload(projectId: project.id, reason: "selectProject")
        } else {
            Task { await loadTabs(projectId: project.id, showLoader: true, updateSelectedProject: true) }
        }
    }

    func loadTabs(projectId: String, showLoader: Bool = true, updateSelectedProject: Bool = true) async {
        // Drop a concurrent reload for the same project: it hits the identical
        // endpoint and would publish the same tabs. Without this, selectProject's
        // deferred reload and backToTabs both ran for the project mid-burst and
        // published as a duplet at window-open (ms=1701 + ms=736 on one frame).
        // The in-flight load refreshes tabsByProject for everyone.
        guard !tabsLoadInFlight.contains(projectId) else {
            VCLog.log("TerminalCache", "tabs load skip (already in flight) project=\(shortID(projectId))")
            return
        }
        tabsLoadInFlight.insert(projectId)
        defer { tabsLoadInFlight.remove(projectId) }
        if showLoader { loadingTabs.insert(projectId) }
        let started = Date()
        let cachedCount = tabsByProject[projectId]?.count ?? 0
        VCLog.log("TerminalCache", "tabs load start project=\(shortID(projectId)) showLoader=\(showLoader) updateSelected=\(updateSelectedProject) cached=\(cachedCount) nav=\(TerminalPerfContext.shared.snapshot())")
        do {
            let r = try await TerminalAPI.tabs(projectId: projectId)
            // If a navigation animation is in flight when this response lands, hold
            // the @Published writes until it settles. A tabs reload that mutates
            // tabsByProject mid-slide re-renders the projects/tabs list each frame
            // → the hitch the watchdog flagged (no hang gap, just dropped frames).
            // This covers prefetch, the deferred selectProject reload, AND
            // pull-to-refresh in one place.
            if interactionActive || Date().timeIntervalSince(interactionEndedAt) * 1000 < prefetchIdleGraceMs {
                await awaitPrefetchWindow()
            }
            if updateSelectedProject && selectedProject?.id == projectId, selectedProject != r.project {
                selectedProject = r.project
            }
            tabsRefreshedAt[projectId] = Date()   // stamp freshness for selectProject skip
            // Publish guard. For the project the user is CURRENTLY viewing, a
            // background reload (deferred selectProject / pull-refresh) lands ~600ms
            // after the list mounted and, over the tunnel, almost always differs in
            // some field (sessionId/timelineCount/status) → the plain `!=` guard
            // passed and re-rendered the whole live list right after it appeared
            // (the post-open lag). Live status for these tabs already arrives via
            // SSE on the OPEN tab, so for the visible project only re-publish on a
            // STRUCTURAL change (tab set differs by id/order), not any field churn.
            // For non-visible projects (prefetch) keep the exact change-guard.
            let isVisibleProject = selectedProject?.id == projectId && selectedTab == nil
            let changed: Bool = {
                guard let existing = tabsByProject[projectId] else { return true }
                if isVisibleProject {
                    return existing.map(\.id) != r.tabs.map(\.id)   // structural only, matching row identity
                }
                return existing != r.tabs
            }()
            if changed {
                MainThreadWatchdog.mark("tabs-publish project=\(shortID(projectId)) n=\(r.tabs.count) visible=\(isVisibleProject)")
                let publishStarted = Date()
                tabsByProject[projectId] = r.tabs
                VCLog.log("TerminalCache", "tabs publish project=\(shortID(projectId)) changed=true visible=\(isVisibleProject) tabs=\(r.tabs.count) publishMs=\(elapsedMs(since: publishStarted)) nav=\(TerminalPerfContext.shared.snapshot())")
            }
            let newMarker = r.statusMarker ?? .fallback
            if statusMarkerByProject[projectId] != newMarker {
                statusMarkerByProject[projectId] = newMarker
            }
            for tab in r.tabs {
                guard let id = tab.tabId else { continue }
                if let status = tab.sessionStatus, statusByTab[id] != status { statusByTab[id] = status }
                if tab.sessionStatus == "busy" || tab.sessionStatus == "running" {
                    runningTabs.insert(id)
                } else if tab.sessionStatus != nil {
                    runningTabs.remove(id)
                }
                // Seed the header context % from the tab list ONLY when we have no
                // value yet — a live bridge-update always wins over this last-known
                // seed. Lets the pill show on open before the first turn.
                if let pct = tab.contextPct, pct > 0, contextPctByTab[id] == nil {
                    contextPctByTab[id] = Int(pct)
                }
            }
            // Refresh the selected tab from the reloaded list ONLY if it actually
            // changed. Unguarded, every prefetch / deferred / pull-to-refresh
            // loadTabs reassigned selectedTab even when identical — and while the
            // chat detail is open that churns its whole subtree (toolbar, status)
            // on each background reload. Change-guarded like the Phase-C writes.
            if let selectedId = selectedTab?.tabId,
               let fresh = r.tabs.first(where: { $0.tabId == selectedId }),
               fresh != selectedTab {
                selectedTab = fresh
            }
            offline = false
            lastError = nil
            let statuses = r.tabs.reduce(into: [String: Int]()) { acc, tab in
                let key = tab.sessionStatus ?? "nil"
                acc[key, default: 0] += 1
            }
            let statusSummary = statuses
                .sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value)" }
                .joined(separator: ",")
            let markerSize = r.statusMarker?.sizePx.map { String(format: "%.0f", $0) } ?? "-"
            VCLog.log(
                "TerminalCache",
                "tabs load done project=\(shortID(projectId)) tabs=\(r.tabs.count) ai=\(r.tabs.filter { $0.isInteractiveAI }.count) statuses=\(statusSummary) changed=\(changed) visible=\(isVisibleProject) \(activityDebug(projectId: projectId)) marker=\(r.statusMarker?.shape ?? "-")/\(markerSize) ms=\(elapsedMs(since: started)) nav=\(TerminalPerfContext.shared.snapshot())"
            )
        } catch {
            VCLog.log("TerminalCache", "tabs load failed project=\(shortID(projectId)) ms=\(elapsedMs(since: started)): \(error.localizedDescription)")
            mark(error)
        }
        if showLoader { loadingTabs.remove(projectId) }
    }

    func createClaudeTab(in project: CTProject) {
        createAgentTab(in: project, toolType: "claude")
    }

    func createAgentTab(in project: CTProject, toolType: String) {
        Task {
            do {
                let tab = try await TerminalAPI.createAgentTab(projectId: project.id, toolType: toolType)
                var tabs = tabsByProject[project.id] ?? []
                tabs.append(tab)
                tabsByProject[project.id] = tabs
                selectedProject = project
                await openTab(tab, project: project)
            } catch {
                mark(error)
            }
        }
    }

    func createSDKTab(in project: CTProject) {
        Task {
            do {
                let tab = try await TerminalAPI.createSDKTab(projectId: project.id)
                var tabs = tabsByProject[project.id] ?? []
                tabs.append(tab)
                tabsByProject[project.id] = tabs
                selectedProject = project
                await openTab(tab, project: project)
            } catch {
                mark(error)
            }
        }
    }

    @discardableResult
    func selectTabForDisplay(_ tab: CTTabInfo, project: CTProject?) -> String? {
        guard let tabId = tab.tabId else { return nil }
        selectedProject = project ?? selectedProject
        selectedTab = tab
        if let status = tab.sessionStatus { statusByTab[tabId] = status }
        // Show the history spinner IMMEDIATELY (before the network GET starts) when
        // there's nothing cached, so opening a chat reads as "loading…" from the
        // first frame instead of a blank/janky pane until the 470KB history lands
        // over the tunnel. activateSelectedTab → loadHistory clears it when done.
        if (entriesByTab[tabId]?.isEmpty ?? true) {
            historyLoading.insert(tabId)
        }
        return tabId
    }

    func activateSelectedTab(tabId: String) async {
        // Guard every step against the user navigating away mid-load. Without
        // this, stepping back (backToTabs → selectedTab=nil + stopLiveChannel)
        // while this chain is awaiting the remote tunnel still ran connectSSE /
        // startStatusPolling for the DEAD tab — reviving a channel that was just
        // stopped and racing the view's teardown (pin/proxy on an unmounted
        // ScrollView). That race is the back-before-load crash. Each guard makes
        // activation abort cleanly the instant the selection changes.
        await loadHistory(tabId: tabId)
        guard selectedTab?.tabId == tabId else {
            VCLog.log("TerminalSSE", "activate ABORT after history (tab changed) tab=\(shortID(tabId))")
            return
        }
        await refreshParams(tabId: tabId)
        guard selectedTab?.tabId == tabId else { return }
        await refreshStatus(tabId: tabId)
        guard selectedTab?.tabId == tabId else {
            VCLog.log("TerminalSSE", "activate ABORT before SSE (tab changed) tab=\(shortID(tabId))")
            return
        }
        connectSSE(tabId: tabId)
        startStatusPolling(tabId: tabId)
    }

    func openTab(_ tab: CTTabInfo, project: CTProject?) async {
        guard let tabId = selectTabForDisplay(tab, project: project) else { return }
        await activateSelectedTab(tabId: tabId)
    }

    func backToProjects() {
        selectedProject = nil
        selectedTab = nil
        stopLiveChannel()
    }

    func backToTabs() {
        selectedTab = nil
        stopLiveChannel()
        guard let id = selectedProject?.id else { return }
        let hasCachedTabs = !(tabsByProject[id]?.isEmpty ?? true)
        guard hasCachedTabs else {
            Task { await loadTabs(projectId: id, showLoader: true, updateSelectedProject: true) }
            return
        }

        let fresh = (tabsRefreshedAt[id]).map { Date().timeIntervalSince($0) < 15 } ?? false
        if fresh {
            VCLog.log("TerminalNav", "backToTabs skip tabs reload (cache fresh) project=\(shortID(id)) nav=\(TerminalPerfContext.shared.snapshot())")
            return
        }

        scheduleDeferredTabsReload(projectId: id, reason: "backToTabs")
    }

    private func scheduleDeferredTabsReload(projectId: String, reason: String) {
        deferredTabsReloadTasks[projectId]?.cancel()
        let token = UUID()
        deferredTabsReloadTokens[projectId] = token
        deferredTabsReloadTasks[projectId] = Task { [weak self] in
            guard let self else { return }
            VCLog.log("TerminalCache", "deferred tabs reload schedule project=\(self.shortID(projectId)) reason=\(reason)")
            await self.awaitStaleTabsReloadWindow()
            guard !Task.isCancelled else { return }
            guard self.deferredTabsReloadTokens[projectId] == token else { return }
            defer {
                if self.deferredTabsReloadTokens[projectId] == token {
                    self.deferredTabsReloadTasks.removeValue(forKey: projectId)
                    self.deferredTabsReloadTokens.removeValue(forKey: projectId)
                }
            }
            guard self.selectedProject?.id == projectId, self.selectedTab == nil else {
                VCLog.log("TerminalNav", "deferred reload skip (left tabs level) project=\(self.shortID(projectId))")
                return
            }
            let stillStale = (self.tabsRefreshedAt[projectId]).map { Date().timeIntervalSince($0) >= 15 } ?? true
            guard stillStale else {
                VCLog.log("TerminalNav", "deferred reload skip (refreshed during quiet) project=\(self.shortID(projectId))")
                return
            }
            await self.loadTabs(projectId: projectId, showLoader: false, updateSelectedProject: true)
        }
    }

    func loadHistory(tabId: String) async {
        let started = Date()
        historyLoading.insert(tabId)
        VCLog.log("TerminalSSE", "history load start tab=\(shortID(tabId)) nav=\(TerminalPerfContext.shared.snapshot())")
        do {
            // Network on the shared session (the GET itself isn't main-bound).
            let netStarted = Date()
            let r = try await TerminalAPI.history(tabId: tabId)
            let netMs = elapsedMs(since: netStarted)

            // PHASE A: build the normalized [CTEntry] OFF the main actor. For a
            // 1183-msg / 470KB history the normalize/reduce loop is the work that
            // used to freeze the UI when it ran inline on @MainActor (our own
            // fix-ios-stability.md §6 pattern). Task.detached runs it on a bg
            // thread; CTEntry is Sendable so the finished array crosses back
            // cleanly. We publish only the result on MainActor below.
            let normStarted = Date()
            let mode = r.entries != nil ? "entries" : "messages"
            let built: [CTEntry] = await Task.detached(priority: .userInitiated) {
                if let entries = r.entries {
                    return CTHistoryEntryNormalizer.normalize(entries)
                } else {
                    let reducer = CTMessageReducer()
                    reducer.reset()
                    for msg in r.messages ?? [] { reducer.apply(msg) }
                    return reducer.snapshot()
                }
            }.value
            let normMs = elapsedMs(since: normStarted)

            // Identity guard. The OLD guard had `|| historyLoading.contains(tabId)`
            // which is ALWAYS true (we inserted it at the top), so it never dropped:
            // a 250-entry publish (~143ms on main, caught by the watchdog) still ran
            // for a tab the user already swiped away from, hitching the back-slide
            // of the NEXT screen. The frame monitor showed 60 dropped frames here.
            // Correct rule: only publish if this tab is STILL selected. If the user
            // left, drop the publish — the data isn't needed on screen now, and a
            // fresh load runs when they return. We still cache it (cheap, no render)
            // so a quick re-entry is instant.
            guard selectedTab?.tabId == tabId else {
                // Don't touch entriesByTab during an active interaction even as a
                // "cache": the array write itself is the 143ms main-thread cost.
                // A re-entry reloads from network anyway (fast for small histories).
                if !interactionActive { entriesByTab[tabId] = built }
                VCLog.log("TerminalSSE", "history publish DROP (tab no longer selected) tab=\(shortID(tabId)) netMs=\(netMs) normMs=\(normMs) built=\(built.count) cached=\(!interactionActive) nav=\(TerminalPerfContext.shared.snapshot())")
                historyLoading.remove(tabId)
                return
            }
            // Even when still selected, if a slide is in flight hold the publish
            // until it settles, so the entries array write doesn't land on the
            // animation (same reason loadTabs defers its publish).
            if interactionActive || Date().timeIntervalSince(interactionEndedAt) * 1000 < historyPublishIdleGraceMs {
                VCLog.log("TerminalSSE", "history publish WAIT interaction tab=\(shortID(tabId)) netMs=\(netMs) normMs=\(normMs) built=\(built.count) nav=\(TerminalPerfContext.shared.snapshot())")
                await awaitHistoryPublishWindow()
                guard selectedTab?.tabId == tabId else {
                    VCLog.log("TerminalSSE", "history publish DROP after wait (tab no longer selected) tab=\(shortID(tabId)) netMs=\(netMs) normMs=\(normMs) built=\(built.count) nav=\(TerminalPerfContext.shared.snapshot())")
                    historyLoading.remove(tabId)
                    return
                }
            }

            // Reducer must live on the actor for subsequent SSE deltas. For the
            // "messages" path rebuild it here (cheap vs the parse) so streaming
            // continues from the same snapshot the bg task produced.
            if r.entries != nil {
                reducers.removeValue(forKey: tabId)
            } else {
                let reducer = CTMessageReducer()
                reducer.reset()
                reducer.seed(built)
                reducers[tabId] = reducer
            }
            MainThreadWatchdog.mark("history-publish tab=\(shortID(tabId)) n=\(built.count)")
            let publishStarted = Date()
            entriesByTab[tabId] = built
            let publishMs = elapsedMs(since: publishStarted)
            offline = false
            lastError = nil
            VCLog.log(
                "TerminalSSE",
                "history load done tab=\(shortID(tabId)) mode=\(mode) entries=\(built.count) total=\(r.total ?? built.count) session=\(shortID(r.sessionId)) netMs=\(netMs) normMs=\(normMs) publishMs=\(publishMs) totalMs=\(elapsedMs(since: started)) \(ctHistoryPayloadSummary(built)) nav=\(TerminalPerfContext.shared.snapshot()) [normalize off-main]"
            )
        } catch {
            VCLog.log("TerminalSSE", "history load failed tab=\(shortID(tabId)) ms=\(elapsedMs(since: started)): \(error.localizedDescription)")
            mark(error)
        }
        historyLoading.remove(tabId)
    }

    func refreshStatus(tabId: String) async {
        do {
            let s = try await TerminalAPI.status(tabId: tabId)
            let status = s.status ?? "inactive"
            let oldStatus = statusByTab[tabId]
            let oldRunning = runningTabs.contains(tabId)
            // Change-guard: the poll fires every few seconds; an unchanged status
            // must not trigger an @Observable mutation (which re-runs views reading
            // statusByTab/runningTabs). Most polls return the SAME status.
            if oldStatus != status { statusByTab[tabId] = status }
            if status == "busy" {
                if !oldRunning { runningTabs.insert(tabId) }
                if turnStartedAt[tabId] == nil { turnStartedAt[tabId] = Date() }
            } else {
                if oldRunning { runningTabs.remove(tabId) }
                if turnStartedAt[tabId] != nil { turnStartedAt[tabId] = nil }
            }
            let statusTool = CTTabInfo.normalizedAgentType(s.toolType ?? s.commandType)
            if let sid = s.sessionId, var tab = selectedTab, tab.tabId == tabId {
                tab.commandType = s.commandType ?? tab.commandType
                tab.toolType = s.toolType ?? tab.toolType
                let resolvedTool = statusTool ?? tab.effectiveToolType
                if resolvedTool == "codex" {
                    tab.codexSessionId = sid
                } else if resolvedTool == "gemini" {
                    tab.geminiSessionId = sid
                } else {
                    tab.claudeSessionId = sid
                }
                selectedTab = tab
                updateTabInfo(tabId: tabId) { current in
                    current.commandType = s.commandType ?? current.commandType
                    current.toolType = s.toolType ?? current.toolType
                    let currentTool = statusTool ?? current.effectiveToolType
                    if currentTool == "codex" {
                        current.codexSessionId = sid
                    } else if currentTool == "gemini" {
                        current.geminiSessionId = sid
                    } else {
                        current.claudeSessionId = sid
                    }
                }
            }
            VCLog.log(
                "TerminalStatus",
                "poll tab=\(shortID(tabId)) status=\(status) session=\(shortID(s.sessionId)) command=\(s.commandType ?? "-") tool=\(s.toolType ?? "-") busyField=\(s.busy.map { String($0) } ?? "-")"
            )
            logRuntimeTransition(tabId: tabId, reason: "poll", oldStatus: oldStatus, oldRunning: oldRunning)
            offline = false
        } catch {
            VCLog.log("TerminalStatus", "poll failed tab=\(shortID(tabId)): \(error.localizedDescription)")
            mark(error)
        }
    }

    func refreshParams(tabId: String) async {
        do {
            let p = try await TerminalAPI.params(tabId: tabId)
            paramsByTab[tabId] = p
            // Seed the header context % from the SAME on-open fetch as model/effort
            // — this is the pull path that makes % appear immediately instead of
            // waiting ~30s for the next live bridge-update. A later live frame
            // overwrites it. Don't clobber an existing value with nil/0.
            if let pct = p.contextPct, pct > 0 {
                let v = Int(pct)
                if contextPctByTab[tabId] != v { contextPctByTab[tabId] = v }
            }
            VCLog.log("Terminal", "params tab=\(shortID(tabId)) model=\(p.model) effort=\(p.effort) think=\(p.thinking) ctx=\(p.contextPct.map { String(format: "%.0f", $0) } ?? "-")")
        } catch {
            VCLog.log("Terminal", "params failed tab=\(tabId.suffix(8)): \(error.localizedDescription)")
        }
    }

    func setParams(tabId: String, partial: [String: Any]) async {
        // Apply the user's choice to the visible chip IMMEDIATELY and keep it.
        // Do NOT read it back via `/params`: for PTY-Claude that returns the
        // lagging `bridgeMetadata.model`, which is still the PREVIOUS model for a
        // beat after `/model`, so the readback bounced the chip to the old value
        // (opus → haiku → opus). The user's selection is authoritative for the UI;
        // the live `/model` apply on the desktop is fire-and-forget.
        let base = paramsByTab[tabId] ?? CTParams(tabId: tabId, model: "default", effort: "high", thinking: "adaptive")
        var next = base
        if let m = partial["model"] as? String {
            next.model = m
            pendingModelByTab[tabId] = (model: m, at: Date())
        }
        if let e = partial["effort"] as? String { next.effort = e }
        if let t = partial["thinking"] as? String { next.thinking = t }
        if next != base { paramsByTab[tabId] = next }
        do {
            _ = try await TerminalAPI.setParams(tabId: tabId, body: partial)
        } catch {
            mark(error)
        }
    }

    func send(tabId: String, text: String) async throws {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let oldStatus = statusByTab[tabId]
        let oldRunning = runningTabs.contains(tabId)
        if let reducer = reducers[tabId] {
            entriesByTab[tabId] = reducer.addLocalUser(clean)
        } else {
            var entries = entriesByTab[tabId] ?? []
            entries.append(CTEntry(id: "local-\(Int(Date().timeIntervalSince1970 * 1000))", kind: .user, text: clean))
            entriesByTab[tabId] = entries
        }
        runningTabs.insert(tabId)
        turnStartedAt[tabId] = Date()
        statusByTab[tabId] = "busy"
        pendingPromptRecoveryByTab[tabId] = Date()
        draftNoticeByTab[tabId] = nil
        logRuntimeTransition(tabId: tabId, reason: "local-send", oldStatus: oldStatus, oldRunning: oldRunning)
        do {
            try await TerminalAPI.send(tabId: tabId, prompt: clean, params: paramsByTab[tabId])
            offline = false
        } catch {
            runningTabs.remove(tabId)
            turnStartedAt[tabId] = nil
            pendingPromptRecoveryByTab.removeValue(forKey: tabId)
            interruptAwaitingTabs.remove(tabId)
            throw error
        }
    }

    func interrupt(tabId: String) {
        if pendingPromptRecoveryByTab[tabId] != nil {
            interruptAwaitingTabs.insert(tabId)
            draftNoticeByTab[tabId] = nil
        }
        Task {
            do {
                try await TerminalAPI.interrupt(tabId: tabId)
                await refreshStatus(tabId: tabId)
            } catch {
                interruptAwaitingTabs.remove(tabId)
                mark(error)
            }
        }
    }

    func stopProcess(tabId: String) {
        Task {
            do {
                try await TerminalAPI.stop(tabId: tabId)
                let oldStatus = statusByTab[tabId]
                let oldRunning = runningTabs.contains(tabId)
                statusByTab[tabId] = "inactive"
                runningTabs.remove(tabId)
                turnStartedAt[tabId] = nil
                clearPromptRecovery(tabId: tabId)
                logRuntimeTransition(tabId: tabId, reason: "local-stop-process", oldStatus: oldStatus, oldRunning: oldRunning)
            } catch { mark(error) }
        }
    }

    func resume(tabId: String) {
        Task {
            do {
                let r = try await TerminalAPI.resume(tabId: tabId)
                if r.alreadyRunning == true {
                    await refreshStatus(tabId: tabId)
                } else {
                    let oldStatus = statusByTab[tabId]
                    let oldRunning = runningTabs.contains(tabId)
                    statusByTab[tabId] = "starting"
                    logRuntimeTransition(tabId: tabId, reason: "local-resume-starting", oldStatus: oldStatus, oldRunning: oldRunning)
                }
            } catch { mark(error) }
        }
    }

    func refreshQueue(tabId: String) async {
        do {
            let r = try await TerminalAPI.queue(tabId: tabId)
            queueByTab[tabId] = r.queue
        } catch {
            VCLog.log("Terminal", "queue failed tab=\(tabId.suffix(8)): \(error.localizedDescription)")
        }
    }

    func mutateQueue(tabId: String, op: String, args: [String: Any] = [:]) async {
        do {
            let r = try await TerminalAPI.mutateQueue(tabId: tabId, op: op, args: args)
            queueByTab[tabId] = r.queue
        } catch {
            mark(error)
        }
    }

    func refreshTimeline(tabId: String) async {
        timelineLoading.insert(tabId)
        timelineErrorByTab[tabId] = nil
        defer { timelineLoading.remove(tabId) }
        do {
            let r = try await TerminalAPI.timeline(tabId: tabId)
            timelineByTab[tabId] = r.entries
            timelineErrorByTab[tabId] = nil
        } catch {
            if timelineByTab[tabId] == nil { timelineByTab[tabId] = [] }
            timelineErrorByTab[tabId] = error.localizedDescription
            mark(error)
        }
    }

    func refreshPendingQuestion(tabId: String) async {
        guard !tabId.isEmpty else { return }
        do {
            let r = try await TerminalAPI.pendingQuestion(tabId: tabId)
            if let question = r.pendingQuestion, !question.isEmpty {
                pendingQuestionByTab[tabId] = question
            } else {
                pendingQuestionByTab.removeValue(forKey: tabId)
            }
        } catch {
            mark(error)
        }
    }

    func answerQuestion(tabId: String, question: CTPendingQuestion, answers: [String: Any] = [:], stop: Bool = false) {
        guard !tabId.isEmpty else { return }
        questionAnsweringTabs.insert(tabId)
        Task { [weak self] in
            do {
                let result = try await TerminalAPI.answerQuestion(tabId: tabId, question: question, answers: answers, stop: stop)
                if result.success == false {
                    throw VoiceChatError.http(200, result.error ?? "question answer failed")
                }
                await MainActor.run {
                    self?.pendingQuestionByTab.removeValue(forKey: tabId)
                    self?.questionAnsweringTabs.remove(tabId)
                }
            } catch {
                await MainActor.run {
                    self?.questionAnsweringTabs.remove(tabId)
                    self?.mark(error)
                }
            }
        }
    }

    private func finishTurn(tabId: String, reason: String?) {
        let oldStatus = statusByTab[tabId]
        let oldRunning = runningTabs.contains(tabId)
        runningTabs.remove(tabId)
        if statusByTab[tabId] == "busy" { statusByTab[tabId] = "active" }
        turnStartedAt[tabId] = nil
        pendingQuestionByTab.removeValue(forKey: tabId)
        questionAnsweringTabs.remove(tabId)
        VCLog.log("TerminalSSE", "finish turn tab=\(shortID(tabId)) reason=\(reason ?? "-") entries=\(entriesByTab[tabId]?.count ?? 0)")
        logRuntimeTransition(tabId: tabId, reason: "finish-turn:\(reason ?? "-")", oldStatus: oldStatus, oldRunning: oldRunning)
        scheduleHistoryReload(tabId: tabId, delayNs: 250_000_000, reason: "finish-turn")

        if isInterruptedTurnReason(reason) {
            startInterruptedDraftRecovery(tabId: tabId)
        } else if pendingPromptRecoveryByTab[tabId] != nil,
                  !interruptAwaitingTabs.contains(tabId),
                  draftRecoveryTasks[tabId] == nil {
            clearPromptRecovery(tabId: tabId)
        }
    }

    private func isInterruptedTurnReason(_ reason: String?) -> Bool {
        guard let reason = reason?.lowercased() else { return false }
        return reason == "interrupt" || reason == "turn_aborted" || reason == "catch-up-turn_aborted"
    }

    private func clearPromptRecovery(tabId: String) {
        pendingPromptRecoveryByTab.removeValue(forKey: tabId)
        interruptAwaitingTabs.remove(tabId)
        draftRecoveryTasks[tabId]?.cancel()
        draftRecoveryTasks[tabId] = nil
    }

    private func startInterruptedDraftRecovery(tabId: String) {
        guard pendingPromptRecoveryByTab[tabId] != nil || interruptAwaitingTabs.contains(tabId) else { return }
        guard draftRecoveryTasks[tabId] == nil else { return }

        interruptAwaitingTabs.insert(tabId)
        draftRecoveryTasks[tabId] = Task { [weak self] in
            let delays: [UInt64] = [0, 160_000_000, 420_000_000, 900_000_000]
            var restored: String?

            for delay in delays {
                if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                guard !Task.isCancelled else { return }

                do {
                    let draft = try await TerminalAPI.draft(tabId: tabId)
                    let text = (draft.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        restored = text
                        break
                    }
                } catch {
                    VCLog.log("Terminal", "draft recovery failed tab=\(tabId.suffix(8)): \(error.localizedDescription)")
                }
            }

            await MainActor.run {
                guard let self else { return }
                if let restored {
                    self.restoredInputByTab[tabId] = restored
                } else {
                    self.draftNoticeByTab[tabId] = "Отмена подтверждена; terminal input пустой"
                }
                self.pendingPromptRecoveryByTab.removeValue(forKey: tabId)
                self.interruptAwaitingTabs.remove(tabId)
                self.draftRecoveryTasks[tabId] = nil
            }
        }
    }

    private func connectSSE(tabId: String) {
        guard activeSSETabId != tabId else {
            VCLog.log("TerminalSSE", "connect skip tab=\(shortID(tabId)) already active connected=\(sseConnected)")
            return
        }
        let previous = activeSSETabId
        VCLog.log("TerminalSSE", "connect start tab=\(shortID(tabId)) prev=\(shortID(previous))")
        sseTask?.cancel()
        activeSSETabId = tabId
        sseConnected = false
        sseTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let attempt = await self.nextSSEAttempt(tabId: tabId)
                await self.runSSEOnce(tabId: tabId, attempt: attempt)
                guard !Task.isCancelled else { break }
                await self.markSSEDisconnected(tabId: tabId, reason: "retry-wait")
                try? await Task.sleep(for: .seconds(2))
            }
            if let self {
                await self.clearSSETaskIfCurrent(tabId: tabId)
            }
        }
    }

    private func runSSEOnce(tabId: String, attempt: Int) async {
        let started = Date()
        let token = Secrets.remoteWebToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? Secrets.remoteWebToken
        guard let url = TerminalControlConfig.apiURL("/api/events?token=\(token)&tabId=\(vcPathComponent(tabId))") else {
            VCLog.log("TerminalSSE", "connect bad-url tab=\(shortID(tabId)) attempt=\(attempt)")
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3600
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        VCLog.log("TerminalSSE", "connect open tab=\(shortID(tabId)) attempt=\(attempt) host=\(url.host ?? "?")")
        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                VCLog.log("TerminalSSE", "connect rejected tab=\(shortID(tabId)) attempt=\(attempt) status=\(status) ms=\(elapsedMs(since: started))")
                return
            }
            sseConnected = true
            offline = false
            VCLog.log("TerminalSSE", "connected tab=\(shortID(tabId)) attempt=\(attempt) ms=\(elapsedMs(since: started))")
            var lineCount = 0
            var eventCount = 0
            for try await line in bytes.lines {
                if Task.isCancelled {
                    VCLog.log("TerminalSSE", "stream cancelled tab=\(shortID(tabId)) attempt=\(attempt) lines=\(lineCount) events=\(eventCount)")
                    return
                }
                lineCount += 1
                if line.hasPrefix("data: ") {
                    eventCount += 1
                    handleEventJSON(String(line.dropFirst(6)), fallbackTabId: tabId)
                } else if line.hasPrefix("data:") {
                    eventCount += 1
                    handleEventJSON(String(line.dropFirst(5)), fallbackTabId: tabId)
                } else if line.isEmpty || line.hasPrefix(":") || line.hasPrefix("retry:") {
                    continue
                } else {
                    VCLog.log("TerminalSSE", "ignored line tab=\(shortID(tabId)) attempt=\(attempt) line=\(String(line.prefix(80)))")
                }
            }
            VCLog.log("TerminalSSE", "stream eof tab=\(shortID(tabId)) attempt=\(attempt) lines=\(lineCount) events=\(eventCount) ms=\(elapsedMs(since: started))")
        } catch {
            if Task.isCancelled {
                VCLog.log("TerminalSSE", "stream cancel error tab=\(shortID(tabId)) attempt=\(attempt)")
            } else {
                VCLog.log("TerminalSSE", "stream error tab=\(shortID(tabId)) attempt=\(attempt) ms=\(elapsedMs(since: started)): \(error.localizedDescription)")
            }
        }
    }

    private func scheduleHistoryReload(tabId: String, delayNs: UInt64 = 350_000_000, reason: String = "event") {
        let replacing = historyReloadTasks[tabId] != nil
        VCLog.log("TerminalSSE", "history reload schedule tab=\(shortID(tabId)) reason=\(reason) delayMs=\(delayNs / 1_000_000) replacing=\(replacing)")
        historyReloadTasks[tabId]?.cancel()
        historyReloadTasks[tabId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNs)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                VCLog.log("TerminalSSE", "history reload fire tab=\(self?.shortID(tabId) ?? String(tabId.suffix(8))) reason=\(reason)")
            }
            await self?.loadHistory(tabId: tabId)
        }
    }

    private func updateTabInfo(tabId: String, mutate: (inout CTTabInfo) -> Void) {
        // Change-guarded + early-exit. This is called by the status poll AND every
        // SSE snapshot, so during the 5-10s after opening a tab it fires
        // repeatedly. The OLD version rewrote the WHOLE tabsByProject[key] array
        // every call even when the mutation changed nothing — and that array write
        // re-runs TerminalProjectTabsView.body (all ~15 rows) each time. That is the
        // "lag right after opening a project that disappears once status settles"
        // the user reported (the slide overlaps these post-nav status writes; once
        // they stop, swiping back is smooth). Now: find the one project, apply,
        // and publish ONLY if the tab actually changed; stop after the first match.
        for key in Array(tabsByProject.keys) {
            guard var tabs = tabsByProject[key],
                  let idx = tabs.firstIndex(where: { $0.tabId == tabId }) else { continue }
            let before = tabs[idx]
            mutate(&tabs[idx])
            if tabs[idx] != before {
                tabsByProject[key] = tabs
            }
            return   // a tabId lives in exactly one project — no need to scan the rest
        }
    }

    private func handleEventJSON(_ json: String, fallbackTabId: String) {
        guard let data = json.data(using: .utf8),
              let event = try? JSONDecoder().decode(CTSSEPayload.self, from: data) else {
            VCLog.log("TerminalSSE", "bad SSE: " + String(json.prefix(180)))
            return
        }
        let tabId = event.tabId ?? fallbackTabId
        let seq = nextSSEEventSeq(tabId: tabId)
        MainThreadWatchdog.mark("sse-event type=\(event.type) tab=\(shortID(tabId))")
        switch event.type {
        case "snapshot":
            let oldStatus = statusByTab[tabId]
            let oldRunning = runningTabs.contains(tabId)
            // Change-guarded (same reason as the poll path): SSE snapshots repeat
            // the current status; an equal write must not churn observers.
            if let status = event.sessionStatus {
                if oldStatus != status { statusByTab[tabId] = status }
                let shouldRun = status == "busy"
                if shouldRun != oldRunning { if shouldRun { runningTabs.insert(tabId) } else { runningTabs.remove(tabId) } }
            } else if event.busy == true {
                if oldStatus != "busy" { statusByTab[tabId] = "busy" }
                if !oldRunning { runningTabs.insert(tabId) }
            }
            let eventTool = CTTabInfo.normalizedAgentType(event.toolType ?? event.commandType)
            if let sid = event.sessionId, var tab = selectedTab, tab.tabId == tabId {
                tab.commandType = event.commandType ?? tab.commandType
                tab.toolType = event.toolType ?? tab.toolType
                let resolvedTool = eventTool ?? tab.effectiveToolType
                if resolvedTool == "codex" {
                    tab.codexSessionId = sid
                } else if resolvedTool == "gemini" {
                    tab.geminiSessionId = sid
                } else {
                    tab.claudeSessionId = sid
                }
                selectedTab = tab
                updateTabInfo(tabId: tabId) { current in
                    current.commandType = event.commandType ?? current.commandType
                    current.toolType = event.toolType ?? current.toolType
                    let currentTool = eventTool ?? current.effectiveToolType
                    if currentTool == "codex" {
                        current.codexSessionId = sid
                    } else if currentTool == "gemini" {
                        current.geminiSessionId = sid
                    } else {
                        current.claudeSessionId = sid
                    }
                }
                if entriesByTab[tabId]?.isEmpty ?? true {
                    scheduleHistoryReload(tabId: tabId, delayNs: 150_000_000, reason: "snapshot-empty")
                }
            }
            if event.busy == true, turnStartedAt[tabId] == nil { turnStartedAt[tabId] = Date() }
            if let questions = event.questions, !questions.isEmpty {
                pendingQuestionByTab[tabId] = CTPendingQuestion(source: event.source, toolUseID: event.toolUseID, questions: questions)
            }
            VCLog.log(
                "TerminalSSE",
                "event#\(seq) snapshot tab=\(shortID(tabId)) status=\(event.sessionStatus ?? "-") busy=\(event.busy.map { String($0) } ?? "-") session=\(shortID(event.sessionId)) tool=\(event.toolType ?? event.commandType ?? "-") entries=\(entriesByTab[tabId]?.count ?? 0) questions=\(event.questions?.count ?? 0)"
            )
            logRuntimeTransition(tabId: tabId, reason: "sse-snapshot#\(seq)", oldStatus: oldStatus, oldRunning: oldRunning)
        case "message":
            if let msg = event.message {
                let beforeEntries = entriesByTab[tabId]?.count ?? 0
                let beforeTailChars = entriesByTab[tabId]?.last?.text.utf16.count ?? 0
                let reducerMode: String
                if let reducer = reducers[tabId] {
                    reducerMode = "existing"
                    entriesByTab[tabId] = reducer.apply(msg)
                } else {
                    let reducer = CTMessageReducer()
                    reducer.seed(entriesByTab[tabId] ?? [])
                    reducers[tabId] = reducer
                    reducerMode = "seeded"
                    entriesByTab[tabId] = reducer.apply(msg)
                }
                let afterEntries = entriesByTab[tabId]?.count ?? 0
                let afterTailChars = entriesByTab[tabId]?.last?.text.utf16.count ?? 0
                VCLog.log(
                    "TerminalSSE",
                    "event#\(seq) message tab=\(shortID(tabId)) reducer=\(reducerMode) before=\(beforeEntries)/\(beforeTailChars) after=\(afterEntries)/\(afterTailChars) \(messageDebugSummary(msg))"
                )
            } else {
                VCLog.log("TerminalSSE", "event#\(seq) message tab=\(shortID(tabId)) missing payload")
            }
        case "busy":
            let oldStatus = statusByTab[tabId]
            let oldRunning = runningTabs.contains(tabId)
            if event.busy == true {
                runningTabs.insert(tabId)
                statusByTab[tabId] = "busy"
                if turnStartedAt[tabId] == nil { turnStartedAt[tabId] = Date() }
            } else {
                finishTurn(tabId: tabId, reason: event.reason)
            }
            VCLog.log("TerminalSSE", "event#\(seq) busy tab=\(shortID(tabId)) busy=\(event.busy.map { String($0) } ?? "-") reason=\(event.reason ?? "-") status=\(statusByTab[tabId] ?? "-")")
            if event.busy == true {
                logRuntimeTransition(tabId: tabId, reason: "sse-busy#\(seq)", oldStatus: oldStatus, oldRunning: oldRunning)
            }
        case "done":
            finishTurn(tabId: tabId, reason: event.reason)
            VCLog.log("TerminalSSE", "event#\(seq) done tab=\(shortID(tabId)) reason=\(event.reason ?? "-")")
        case "bridge-update":
            if let model = event.model {
                // Stale-model guard: right after the user picks a model, the
                // bridge can still emit the PREVIOUS one for a beat. While a pick
                // is pending and unconfirmed, ignore a disagreeing frame (the
                // flicker source). Drop the pending once the bridge confirms the
                // chosen value, or after a short window so a genuine external
                // change isn't blocked forever.
                var accept = true
                if let pending = pendingModelByTab[tabId] {
                    if model == pending.model {
                        pendingModelByTab[tabId] = nil
                    } else if Date().timeIntervalSince(pending.at) < 8 {
                        accept = false
                        VCLog.log("TerminalSSE", "event#\(seq) bridge-update IGNORE stale model=\(model) pending=\(pending.model) tab=\(shortID(tabId))")
                    } else {
                        pendingModelByTab[tabId] = nil
                    }
                }
                if accept {
                    let old = paramsByTab[tabId] ?? CTParams(tabId: tabId, model: model, effort: "?", thinking: "adaptive")
                    let updated = CTParams(tabId: tabId, model: model, effort: old.effort, thinking: old.thinking)
                    if updated != old { paramsByTab[tabId] = updated }
                }
            }
            // Context used %: store the source's own number (floored to int, same
            // as desktop). A live 0 frame doesn't wipe a real last-known value —
            // sub-1% floors to 0 and would blank the header otherwise (mirrors
            // fact-claude-control-bar.md::live-0 не затирает seed).
            if let pct = event.contextPct, pct > 0 {
                let v = Int(pct)
                if contextPctByTab[tabId] != v { contextPctByTab[tabId] = v }
            }
            VCLog.log("TerminalSSE", "event#\(seq) bridge-update tab=\(shortID(tabId)) model=\(event.model ?? "-") context=\(event.contextPct.map { String(format: "%.1f", $0) } ?? "-")")
        case "queue-update":
            if let queue = event.queue { queueByTab[tabId] = queue }
            VCLog.log("TerminalSSE", "event#\(seq) queue-update tab=\(shortID(tabId))")
        case "ask-question":
            let question = CTPendingQuestion(source: event.source, toolUseID: event.toolUseID, questions: event.questions ?? [])
            if !question.isEmpty {
                pendingQuestionByTab[tabId] = question
            }
            VCLog.log("TerminalSSE", "event#\(seq) ask-question tab=\(shortID(tabId)) source=\(event.source ?? "-") questions=\(event.questions?.count ?? 0)")
        case "question-cancelled":
            pendingQuestionByTab.removeValue(forKey: tabId)
            questionAnsweringTabs.remove(tabId)
            VCLog.log("TerminalSSE", "event#\(seq) question-cancelled tab=\(shortID(tabId)) source=\(event.source ?? "-")")
        default:
            VCLog.log("TerminalSSE", "event#\(seq) ignored type=\(event.type) tab=\(shortID(tabId)) bytes=\(data.count)")
            break
        }
    }

    private func nextSSEAttempt(tabId: String) -> Int {
        let next = (sseAttemptByTab[tabId] ?? 0) + 1
        sseAttemptByTab[tabId] = next
        return next
    }

    private func nextSSEEventSeq(tabId: String) -> Int {
        let next = (sseEventSeqByTab[tabId] ?? 0) + 1
        sseEventSeqByTab[tabId] = next
        return next
    }

    private func markSSEDisconnected(tabId: String, reason: String) {
        if activeSSETabId == tabId {
            sseConnected = false
        }
        VCLog.log("TerminalSSE", "disconnected tab=\(shortID(tabId)) reason=\(reason)")
    }

    private func clearSSETaskIfCurrent(tabId: String) {
        if activeSSETabId == tabId {
            activeSSETabId = nil
            sseTask = nil
            sseConnected = false
            VCLog.log("TerminalSSE", "task cleared tab=\(shortID(tabId))")
        } else {
            VCLog.log("TerminalSSE", "task ended stale tab=\(shortID(tabId)) active=\(shortID(activeSSETabId))")
        }
    }

    private func shortID(_ value: String?, length: Int = 8) -> String {
        guard let value, !value.isEmpty else { return "nil" }
        return String(value.suffix(length))
    }

    private func elapsedMs(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }

    private func activeLoaderSummary(_ loaders: [CTActiveLoader]) -> String {
        guard !loaders.isEmpty else { return "none" }
        return loaders.prefix(8).map { loader in
            let kind = loader.kind ?? "?"
            let status = loader.status ?? "?"
            let project = loader.project ?? "-"
            let name = loader.name ?? "-"
            return "\(kind):\(status):\(project)/\(name):\(shortID(loader.tabId))"
        }.joined(separator: " | ") + (loaders.count > 8 ? " | +\(loaders.count - 8)" : "")
    }

    private func messageDebugSummary(_ raw: CTRawMessage) -> String {
        let msgObject = object(raw.message)
        let blocks = msgObject?["content"].flatMap(array) ?? []
        var textLen = 0
        var thinkingLen = 0
        var toolUses = 0
        var toolResults = 0
        var toolResultLen = 0

        for block in blocks {
            guard let obj = object(block) else { continue }
            switch obj["type"]?.stringValue {
            case "text":
                textLen += obj["text"]?.stringValue?.utf16.count ?? 0
            case "thinking":
                thinkingLen += obj["thinking"]?.stringValue?.utf16.count ?? 0
            case "tool_use":
                toolUses += 1
            case "tool_result":
                toolResults += 1
                toolResultLen += jsonText(obj["content"])?.utf16.count ?? 0
            default:
                break
            }
        }

        let resultLen = jsonText(raw.result)?.utf16.count ?? 0
        return "record=\(raw.type ?? "-") subtype=\(raw.subtype ?? "-") uuid=\(shortID(raw.uuid)) msg=\(shortID(msgObject?["id"]?.stringValue)) session=\(shortID(raw.sessionId)) blocks=\(blocks.count) textLen=\(textLen) thinkingLen=\(thinkingLen) tools=\(toolUses) toolResults=\(toolResults) toolResultLen=\(toolResultLen) resultLen=\(resultLen) synthetic=\(raw.__webSynthetic == true) queued=\(raw.__wasQueued == true)"
    }

    private func startStatusPolling(tabId: String) {
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStatus(tabId: tabId)
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private func stopLiveChannel() {
        VCLog.log("TerminalSSE", "stop live active=\(shortID(activeSSETabId))")
        sseTask?.cancel()
        sseTask = nil
        statusTask?.cancel()
        statusTask = nil
        for task in historyReloadTasks.values { task.cancel() }
        historyReloadTasks.removeAll()
        activeSSETabId = nil
        sseConnected = false
    }

    // Suspend the calling prefetch step until the user is NOT interacting and a
    // grace window has passed since the last interaction ended. Polls cheaply
    // (50ms) — this runs on the prefetch task, not main; it only awaits, never
    // blocks main. Do NOT timeout into publishing: the 23:53 trace showed a
    // long-running invisible prefetch hitting the old 4s cap and publishing in
    // `back from=tabs` settle, recreating the exact hitch this gate exists to
    // prevent.
    private func awaitPrefetchWindow() async {
        var waits = 0
        while true {
            if Task.isCancelled { return }
            let blocked = interactionActive
                || Date().timeIntervalSince(interactionEndedAt) * 1000 < prefetchIdleGraceMs
            if !blocked { return }
            if waits == 0 {
                VCLog.log("TerminalCache", "prefetch park (interaction active)")
            } else if waits % 80 == 0 {
                VCLog.log("TerminalCache", "prefetch still parked waits=\(waits)")
            }
            try? await Task.sleep(for: .milliseconds(50))
            waits += 1
        }
    }

    private func awaitHistoryPublishWindow() async {
        var waits = 0
        while true {
            if Task.isCancelled { return }
            let blocked = interactionActive
                || Date().timeIntervalSince(interactionEndedAt) * 1000 < historyPublishIdleGraceMs
            if !blocked { return }
            if waits == 0 {
                VCLog.log("TerminalSSE", "history publish park (nav tail)")
            } else if waits % 80 == 0 {
                VCLog.log("TerminalSSE", "history publish still parked waits=\(waits)")
            }
            try? await Task.sleep(for: .milliseconds(50))
            waits += 1
        }
    }

    func awaitTerminalActivationWindow(tabId: String) async {
        let blockedNow = interactionActive
            || Date().timeIntervalSince(interactionEndedAt) * 1000 < historyPublishIdleGraceMs
        guard blockedNow else { return }
        VCLog.log("TerminalSSE", "activation wait quiet tab=\(shortID(tabId)) nav=\(TerminalPerfContext.shared.snapshot())")
        await awaitHistoryPublishWindow()
        guard !Task.isCancelled else { return }
        VCLog.log("TerminalSSE", "activation quiet tab=\(shortID(tabId)) nav=\(TerminalPerfContext.shared.snapshot())")
    }

    private func awaitStaleTabsReloadWindow() async {
        VCLog.log("TerminalCache", "stale tabs reload wait quiet")
        await awaitPrefetchWindow()
    }

    private func scheduleTabsPrefetch(for loadedProjects: [CTProject]) {
        tabsPrefetchTask?.cancel()
        let ids = loadedProjects
            .filter { ($0.tabCount ?? 0) > 0 || $0.isOpen == true }
            .map(\.id)
        VCLog.log("TerminalCache", "tabs prefetch schedule projects=\(ids.count) cancelledPrevious=true")
        guard !ids.isEmpty else { return }

        tabsPrefetchTask = Task { [weak self] in
            for projectId in ids {
                guard !Task.isCancelled else { return }
                // Park while the user is navigating, then for a short grace after
                // it settles — so this project's tabs write never lands mid-slide.
                await self?.awaitPrefetchWindow()
                guard !Task.isCancelled else { return }
                let alreadyCached = await MainActor.run {
                    !(self?.tabsByProject[projectId]?.isEmpty ?? true)
                }
                // Prefetch is a COLD-cache warmer, not a refresher. If a project's
                // tabs are already cached, re-fetching them over the (possibly
                // remote, 100-1300ms) tunnel re-writes @Published tabsByProject for
                // no new info — and every such write re-renders the whole terminal
                // tree. On a warm reconnect that's 9 redundant GETs landing across
                // ~3s, each able to stutter an in-flight slide/drag. Skip cached;
                // a project the user actually opens still gets a fresh load via
                // selectProject. (Live status stays current via SSE, not prefetch.)
                guard !alreadyCached else {
                    await MainActor.run {
                        VCLog.log("TerminalCache", "tabs prefetch SKIP cached project=\(self?.shortID(projectId) ?? String(projectId.suffix(8)))")
                    }
                    continue
                }
                await MainActor.run {
                    VCLog.log("TerminalCache", "tabs prefetch item project=\(self?.shortID(projectId) ?? String(projectId.suffix(8))) alreadyCached=false")
                }
                await self?.loadTabs(projectId: projectId, showLoader: false, updateSelectedProject: false)
                try? await Task.sleep(for: .milliseconds(80))
            }
            await MainActor.run {
                VCLog.log("TerminalCache", "tabs prefetch done projects=\(ids.count)")
            }
        }
    }

    private func mark(_ error: Error) {
        // A CANCELLED request is NOT the host going offline — it's the normal
        // result of the user navigating away mid-load (Phase B cancels the in-flight
        // history GET on back-swipe). Treating cancellation as offline flipped the
        // store to offline=true on every fast back-swipe (log: "offline false->true:
        // cancelled"), flashing the offline banner and disabling the composer — the
        // "выкинуло" feeling. Ignore cancellation entirely.
        if (error as? URLError)?.code == .cancelled || error is CancellationError {
            VCLog.log("Terminal", "ignore cancelled error (navigation), offline unchanged=\(offline)")
            return
        }
        let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let beforeOffline = offline
        lastError = msg
        if error is URLError { offline = true }
        if case VoiceChatError.http(let code, _) = error, code == 0 || code == 503 { offline = true }
        VCLog.log("Terminal", "error type=\(String(describing: Swift.type(of: error))) offline \(beforeOffline)->\(offline): \(msg)")
    }

    private func isTerminalUnavailable(_ error: Error) -> Bool {
        if (error as? URLError)?.code == .cancelled { return false }
        if error is URLError { return true }
        if case VoiceChatError.http(let code, _) = error {
            return code == 0 || code == 503
        }
        return false
    }
}

// MARK: - In-flight ops registry (channel attribution)
//
// Per диагностика-логами.flow.md: "activeOps=0 in a gap log doesn't mean nothing
// ran" — you need both what's in-flight NOW and what just completed. This is the
// iOS analog of the flow's ipcAgg5s/recentOps5s: a thread-safe counter per channel
// (url / sse / poll) plus the last completed op, snapshotted when the watchdog
// fires so a hang can be ATTRIBUTED to a subsystem instead of "logged nearby".
final class OpsRegistry: @unchecked Sendable {
    static let shared = OpsRegistry()
    private let lock = NSLock()
    private var inFlight: [String: Int] = [:]
    private var liveOps: [Int: (channel: String, op: String, started: Date)] = [:]
    private var nextToken = 0
    private var lastCompleted = "—"
    private var lastCompletedAt = Date()

    func begin(_ channel: String, op: String = "") -> Int {
        lock.lock()
        nextToken += 1
        let token = nextToken
        liveOps[token] = (channel, op.isEmpty ? channel : op, Date())
        inFlight[channel, default: 0] += 1
        lock.unlock()
        return token
    }

    func end(_ token: Int) {
        lock.lock()
        guard let live = liveOps.removeValue(forKey: token) else {
            lock.unlock()
            return
        }
        let channel = live.channel
        inFlight[channel, default: 1] -= 1
        if inFlight[channel, default: 0] <= 0 { inFlight[channel] = nil }
        lastCompleted = "\(channel):\(live.op)"
        lastCompletedAt = Date()
        lock.unlock()
    }

    func snapshot() -> (inFlight: String, last: String, lastAgeMs: Int) {
        lock.lock(); defer { lock.unlock() }
        let live: String
        if liveOps.isEmpty {
            live = "none"
        } else {
            live = liveOps
                .sorted { $0.key < $1.key }
                .map { pair in
                    let op = pair.value
                    let ageMs = Int(Date().timeIntervalSince(op.started) * 1000)
                    return "\(op.channel):\(op.op)@\(ageMs)ms"
                }
                .joined(separator: ",")
        }
        return (live, lastCompleted, Int(Date().timeIntervalSince(lastCompletedAt) * 1000))
    }
}

final class TerminalPerfContext: @unchecked Sendable {
    static let shared = TerminalPerfContext()
    private let lock = NSLock()
    private var navId = 0
    private var label = "idle"
    private var phase = "idle"
    private var startedAt = Date()
    private var phaseAt = Date()

    func begin(id: Int, label: String, phase: String) {
        lock.lock()
        navId = id
        self.label = label
        self.phase = phase
        let now = Date()
        startedAt = now
        phaseAt = now
        lock.unlock()
    }

    func setPhase(_ phase: String) {
        lock.lock()
        self.phase = phase
        phaseAt = Date()
        lock.unlock()
    }

    func end(id: Int, note: String) {
        lock.lock()
        if navId == id {
            label = label + " ended=\(note)"
            phase = "idle"
            phaseAt = Date()
        }
        lock.unlock()
    }

    func snapshot() -> String {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        let ageMs = Int(now.timeIntervalSince(startedAt) * 1000)
        let phaseAgeMs = Int(now.timeIntervalSince(phaseAt) * 1000)
        return "nav#\(navId) label=\"\(label)\" phase=\(phase) age=\(ageMs)ms phaseAge=\(phaseAgeMs)ms"
    }
}

// MARK: - Main-thread hang watchdog
//
// Per диагностика-логами.flow.md: "for a real freeze the in-process logger is
// blind at the moment of the problem — a watchdog is a different CLASS of
// observation: a separate scheduler sees the silence from outside." A background
// DispatchQueue (NOT the frozen main thread) pings main via a semaphore; if the
// round-trip exceeds the threshold the main thread is wedged RIGHT NOW, so we
// log immediately via os.Logger.fault (writes off-main, survives the wedge →
// Console.app / sysdiagnose), snapshot the in-flight channel registry + last
// main-actor activity marker for attribution, then wait out the rest to measure
// the REAL gap and flush a copy into VCLog (→ the user's ios-chat.log pipeline).
// Implementation validated June 2026 (ChatGPT-5.5 + verification agent, 18
// sources: Jesse Squires watchdog, Apple hang docs, WWDC23 10248).
//
// Two log channels on purpose: `[hang]` via os.Logger fires DURING the freeze
// (grep in Console.app / `log stream`); the VCLog copy lands AFTER recovery in
// ios-chat.log with the real duration. Also: enable Settings → Developer → Hang
// Detection on the device for a symbolicated main-thread stack with no Xcode.
final class MainThreadWatchdog: @unchecked Sendable {
    static let shared = MainThreadWatchdog()

    private let oslog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "habittracker", category: "hang")
    private let queue = DispatchQueue(label: "main-thread-watchdog", qos: .utility)
    // Bands: 80ms catches even short render stalls (a couple dropped 60fps frames
    // = ~33ms; 80ms = ~5 frames, the floor where a slide visibly hitches), 250ms
    // is Apple's HANG floor. The 120ms band left the tabs/projects slide silent,
    // so it's render work in even smaller bursts — drop the floor to see it. Ping
    // faster (60ms) so a brief stall isn't missed between pings. band= in the log
    // says which tier tripped.
    private let hitchMs: Double = 80
    private let thresholdMs: Double = 250
    private let pingEvery: TimeInterval = 0.06
    private var timer: DispatchSourceTimer?
    private var started = false

    // Last main-actor activity (set by mark()). Plain lock — touched from main
    // (mark) and the watchdog queue (snapshot on hang).
    private let actLock = NSLock()
    private var lastActivityLabel = "idle"
    private var lastActivityAt = Date()

    nonisolated static func mark(_ label: String) { shared.mark(label) }
    func mark(_ label: String) {
        actLock.lock(); lastActivityLabel = label; lastActivityAt = Date(); actLock.unlock()
    }
    private func activitySnapshot() -> (String, Int) {
        actLock.lock(); defer { actLock.unlock() }
        return (lastActivityLabel, Int(Date().timeIntervalSince(lastActivityAt) * 1000))
    }

    static func start() { shared.start() }
    func start() {
        guard !started else { return }
        started = true
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + pingEvery, repeating: pingEvery)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let sem = DispatchSemaphore(value: 0)
            let sent = DispatchTime.now()
            DispatchQueue.main.async { sem.signal() }
            // Trip at the HITCH band (120ms) so animation frame-drops are caught,
            // not just ≥250ms hangs. The recovered-gap value tells which it was.
            if sem.wait(timeout: .now() + self.hitchMs / 1000) == .timedOut {
                // Main is blocked NOW — capture before it recovers.
                let ops = OpsRegistry.shared.snapshot()
                let nav = TerminalPerfContext.shared.snapshot()
                let (actLabel, actAge) = self.activitySnapshot()
                self.oslog.fault("STALL ≥\(Int(self.hitchMs))ms inFlight=\(ops.inFlight, privacy: .public) lastOp=\(ops.last, privacy: .public) lastActivity=\(actLabel, privacy: .public) nav=\(nav, privacy: .public)")
                // Wait out the rest to measure the true duration.
                sem.wait()
                let gapMs = Int(Double(DispatchTime.now().uptimeNanoseconds - sent.uptimeNanoseconds) / 1e6)
                let band = Double(gapMs) >= self.thresholdMs ? "hang" : "hitch"
                self.oslog.fault("STALL recovered band=\(band, privacy: .public) gap=\(gapMs)ms")
                // Flush a copy into the user's pipeline (after recovery, so main is
                // free again). Grep [hang] in ios-chat.log; band= distinguishes them.
                DispatchQueue.main.async {
                    VCLog.log("hang", "band=\(band) gap=\(gapMs)ms inFlight=\(ops.inFlight) lastOp=\(ops.last) lastOpAge=\(ops.lastAgeMs)ms lastActivity=\(actLabel) activityAge=\(actAge)ms nav=\(nav)")
                }
            }
        }
        t.resume()
        timer = t
        VCLog.log("hang", "watchdog started hitch=\(Int(hitchMs))ms hang=\(Int(thresholdMs))ms ping=\(Int(pingEvery * 1000))ms")
    }
}

// MARK: - Frame-drop monitor (CADisplayLink)
//
// The main-thread watchdog stayed SILENT through the tabs/projects slide even at
// 80ms — and the render probe showed no re-render storm — which proves the jank
// is NOT main-thread blocking and NOT excessive body eval. That leaves the
// GPU/compositing pass: a frame that's expensive to RENDER (heavy shadow, blur,
// offscreen pass) drops even though main is idle. The only instrument that sees
// that is CADisplayLink, which fires per VSYNC and lets us measure the gap
// between presented frames. A healthy 60/120fps frame is 16.6/8.3ms; a gap of
// 2+ frames during a slide is a visible hitch. We only watch during an active
// terminal interaction (armed by the gesture layer) so it's silent at rest.
// Grep [frame]. Validated against the research's hitch (33ms) thresholds.
@MainActor
final class FrameMonitor {
    static let shared = FrameMonitor()
    private var link: CADisplayLink?
    private var lastTs: CFTimeInterval = 0
    private var armedUntil: CFTimeInterval = 0
    private var worstMs: Double = 0
    private var dropped = 0
    private var sampled = 0
    private var windowStart: CFTimeInterval = 0
    private var expectedFrameMs: Double = 16.6
    private var windowSerial = 0
    private var currentWindowId = 0
    private var currentReason = "idle"
    private var currentLabel = "idle"

    // PHASE ATTRIBUTION (verification before the UIKit-snapshot rewrite). The
    // research says the dropped frame is the destination view-tree's FIRST COMMIT,
    // not the motion. To prove it on-device we tag which phase each dropped frame
    // lands in: "commit" = the window between mounting the destination subtree and
    // the animation starting; "animate" = the offset actually moving. If drops
    // cluster in commit → first-commit cost confirmed → snapshot fix is right. If
    // they cluster in animate → it's the moving tree and a different fix applies.
    private var phase = "idle"
    private var droppedByPhase: [String: Int] = [:]
    private var worstByPhase: [String: Double] = [:]

    func setPhase(_ p: String) {
        phase = p
        TerminalPerfContext.shared.setPhase(p)
    }

    // Arm for the duration of a navigation interaction (+ a tail). Cheap: the
    // CADisplayLink runs only while armed.
    @discardableResult
    func arm(reason: String, label: String = "nav", phase initialPhase: String = "commit") -> Int {
        let now = CACurrentMediaTime()
        if link != nil, currentWindowId != 0 {
            flushWindow(status: "interrupted")
        }
        windowSerial += 1
        let id = windowSerial
        currentWindowId = id
        currentReason = reason
        currentLabel = label
        armedUntil = now + 1.2
        lastTs = 0
        worstMs = 0
        dropped = 0
        sampled = 0
        windowStart = now
        droppedByPhase = [:]
        worstByPhase = [:]
        phase = initialPhase
        TerminalPerfContext.shared.begin(id: id, label: "\(reason) \(label)", phase: initialPhase)
        if link == nil {
            let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
        VCLog.log("frame", "monitor armed id=\(id) reason=\(reason) label=\"\(label)\" phase=\(initialPhase)")
        return id
    }

    @objc private func tick(_ link: CADisplayLink) {
        let ts = link.timestamp
        // Use the device's actual refresh target for the dropped-frame math.
        let target = link.targetTimestamp - link.timestamp
        if target > 0.001 { expectedFrameMs = target * 1000 }
        if lastTs != 0 {
            let deltaMs = (ts - lastTs) * 1000
            sampled += 1
            if deltaMs > worstMs { worstMs = deltaMs }
            if deltaMs > (worstByPhase[phase] ?? 0) { worstByPhase[phase] = deltaMs }
            // A frame that took >1.5× the expected interval = at least one dropped.
            if deltaMs > expectedFrameMs * 1.5 {
                let n = Int((deltaMs / expectedFrameMs).rounded()) - 1
                dropped += n
                droppedByPhase[phase, default: 0] += n
            }
        }
        lastTs = ts

        if ts >= armedUntil {
            // Flush the window summary and stop until next arm.
            flushWindow(status: "done")
            link.invalidate()
            self.link = nil
            lastTs = 0
            phase = "idle"
            currentWindowId = 0
        }
    }

    private func flushWindow(status: String) {
        guard currentWindowId != 0 else { return }
        let phaseBreak = droppedByPhase.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)/\(Int(worstByPhase[$0.key] ?? 0))ms" }
            .joined(separator: " ")
        let durationMs = Int((CACurrentMediaTime() - windowStart) * 1000)
        VCLog.log(
            "frame",
            "window id=\(currentWindowId) status=\(status) reason=\(currentReason) label=\"\(currentLabel)\" frames=\(sampled) dropped=\(dropped) worst=\(String(format: "%.0f", worstMs))ms expected=\(String(format: "%.1f", expectedFrameMs))ms duration=\(durationMs)ms byPhase[\(phaseBreak.isEmpty ? "none" : phaseBreak)] nav=\(TerminalPerfContext.shared.snapshot())"
        )
        TerminalPerfContext.shared.end(id: currentWindowId, note: status)
    }
}
