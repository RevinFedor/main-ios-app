import Foundation
import SwiftUI

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
    let name: String
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
    let name: String
    let tabType: String
    var commandType: String?
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

    var id: String { tabId ?? name + cwd }
    var isClaudePTY: Bool { commandType == "claude" && tabType != "claude-sdk" }
    var isCodexPTY: Bool { commandType == "codex" && tabType != "claude-sdk" }
    var isSDK: Bool { tabType == "claude-sdk" }
    var isInteractiveAI: Bool { isClaudePTY || isCodexPTY || isSDK }
    var activeSessionId: String? {
        if isCodexPTY { return codexSessionId }
        if commandType == "gemini" { return geminiSessionId }
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

struct CTCompactMetrics: Decodable, Equatable {
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

struct CTHistoryResponse: Decodable {
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

struct CTHistoryEntry: Decodable {
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

enum CTEntryKind: String, Equatable {
    case user, assistant, thinking, tool, slash, compactSummary, error
}

struct CTEntry: Identifiable {
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

    static func getJSON<T: Decodable>(_ path: String) async throws -> T {
        guard let url = TerminalControlConfig.apiURL(path) else { throw VoiceChatError.badURL }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        authed(&req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw VoiceChatError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    @discardableResult
    static func postJSON<T: Decodable>(_ path: String, body: [String: Any] = [:]) async throws -> T {
        guard let url = TerminalControlConfig.apiURL(path) else { throw VoiceChatError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 25
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authed(&req)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw VoiceChatError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(T.self, from: data)
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
            color: r.color ?? agent,
            cwd: r.cwd,
            claudeSessionId: nil,
            codexSessionId: nil,
            geminiSessionId: nil,
            timelineCount: nil,
            sessionStatus: "starting",
            awaiting: false,
            statusId: nil,
            statusColor: nil
        )
    }

    static func createSDKTab(projectId: String) async throws -> CTTabInfo {
        struct Created: Decodable { let tabId: String; let name: String?; let cwd: String?; let projectId: String? }
        let r: Created = try await postJSON("/api/projects/" + vcPathComponent(projectId) + "/sdk-tabs")
        return CTTabInfo(tabId: r.tabId, name: r.name ?? "SDK chat", tabType: "claude-sdk", commandType: "claude", color: "purple", cwd: r.cwd ?? "", claudeSessionId: nil, codexSessionId: nil, geminiSessionId: nil, timelineCount: nil, sessionStatus: "active", awaiting: false, statusId: nil, statusColor: nil)
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

    static func getJSON<T: Decodable>(_ path: String) async throws -> T {
        guard let url = VoiceChatConfig.apiURL(path) else { throw VoiceChatError.badURL }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        authed(&req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw VoiceChatError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    @discardableResult
    static func postJSON<T: Decodable>(_ path: String, body: [String: Any] = [:]) async throws -> T {
        guard let url = VoiceChatConfig.apiURL(path) else { throw VoiceChatError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authed(&req)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw VoiceChatError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(T.self, from: data)
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
    var commandType: String?
    var sessionId: String?
    var cwd: String?
}

struct CTResumeResponse: Decodable {
    var tabId: String?
    var sessionId: String?
    var alreadyRunning: Bool?
}

@MainActor
final class TerminalControlStore: ObservableObject {
    static let shared = TerminalControlStore()

    @Published var projects: [CTProject] = []
    @Published var tabsByProject: [String: [CTTabInfo]] = [:]
    @Published var statusMarkerByProject: [String: CTStatusMarker] = [:]
    @Published var selectedProject: CTProject?
    @Published var selectedTab: CTTabInfo?
    @Published var entriesByTab: [String: [CTEntry]] = [:]
    @Published var statusByTab: [String: String] = [:]
    @Published var runningTabs: Set<String> = []
    @Published var turnStartedAt: [String: Date] = [:]
    @Published var paramsByTab: [String: CTParams] = [:]
    @Published var queueByTab: [String: CTQueueCore] = [:]
    @Published var timelineByTab: [String: [CTTimelineEntry]] = [:]
    @Published var timelineLoading: Set<String> = []
    @Published var timelineErrorByTab: [String: String] = [:]
    @Published var pendingQuestionByTab: [String: CTPendingQuestion] = [:]
    @Published var questionAnsweringTabs: Set<String> = []
    @Published var projectsScrollAnchorId: String?
    @Published var tabsScrollAnchorByProject: [String: String] = [:]
    @Published var loadingProjects = false
    @Published var loadingTabs: Set<String> = []
    @Published var historyLoading: Set<String> = []
    @Published var offline = false
    @Published var sseConnected = false
    @Published var lastError: String?
    @Published var terminalInstallRunning = false
    @Published var terminalInstallJob: CTBuildInstallJob?
    @Published var restoredInputByTab: [String: String] = [:]
    @Published var draftNoticeByTab: [String: String] = [:]
    @Published var interruptAwaitingTabs: Set<String> = []

    private var reducers: [String: CTMessageReducer] = [:]
    private var sseTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var historyReloadTasks: [String: Task<Void, Never>] = [:]
    private var warmCacheTask: Task<Void, Never>?
    private var tabsPrefetchTask: Task<Void, Never>?
    private var activeSSETabId: String?
    private var sseAttemptByTab: [String: Int] = [:]
    private var sseEventSeqByTab: [String: Int] = [:]
    private var lastProjectsRefreshAt: Date?
    private var pendingPromptRecoveryByTab: [String: Date] = [:]
    private var draftRecoveryTasks: [String: Task<Void, Never>] = [:]

    var canStepBack: Bool {
        selectedTab != nil || selectedProject != nil
    }

    func stepBackOneLevel() {
        if selectedTab != nil {
            backToTabs()
        } else if selectedProject != nil {
            backToProjects()
        }
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

    func start() {
        guard warmCacheTask == nil else { return }
        let cold = projects.isEmpty
        if !cold, let lastProjectsRefreshAt, Date().timeIntervalSince(lastProjectsRefreshAt) < 20 {
            return
        }
        warmCacheTask = Task { [weak self] in
            await self?.refreshProjects(showLoader: cold, prefetchTabs: true)
            await MainActor.run { self?.warmCacheTask = nil }
        }
    }

    func refreshProjects(showLoader: Bool = true, prefetchTabs: Bool = false) async {
        if showLoader { loadingProjects = true }
        do {
            let loaded = try await TerminalAPI.projects()
            projects = loaded
            lastProjectsRefreshAt = Date()
            offline = false
            lastError = nil
            if prefetchTabs {
                scheduleTabsPrefetch(for: loaded)
            }
        } catch {
            mark(error)
        }
        if showLoader { loadingProjects = false }
    }

    func terminalBuildInstallBlockers() async throws -> [CTActiveLoader] {
        do {
            let snap = try await TerminalAPI.activeLoaders()
            return snap.loaders.filter(\.blocksMobileInstall)
        } catch {
            if isTerminalUnavailable(error) {
                offline = true
                return []
            }
            throw error
        }
    }

    func runTerminalBuildInstall() async throws -> CTBuildInstallJob? {
        if terminalInstallRunning { return terminalInstallJob }
        terminalInstallRunning = true
        defer { terminalInstallRunning = false }

        var job = try await VoiceRecordTerminalAPI.startBuildInstall()
        terminalInstallJob = job

        while job?.running == true {
            try await Task.sleep(for: .seconds(2))
            job = try await VoiceRecordTerminalAPI.buildInstallStatus()
            terminalInstallJob = job
        }

        if let job, job.ok == false {
            let code = job.exitCode.map { "code \($0)" } ?? "failed"
            let detail = job.error ?? job.logTail ?? "npm run build:install failed"
            throw VoiceChatError.http(job.exitCode ?? 1, code + ": " + detail)
        }

        return job
    }

    func selectProject(_ project: CTProject) {
        selectedProject = project
        selectedTab = nil
        let hasCachedTabs = !(tabsByProject[project.id]?.isEmpty ?? true)
        Task { await loadTabs(projectId: project.id, showLoader: !hasCachedTabs, updateSelectedProject: true) }
    }

    func loadTabs(projectId: String, showLoader: Bool = true, updateSelectedProject: Bool = true) async {
        if showLoader { loadingTabs.insert(projectId) }
        do {
            let r = try await TerminalAPI.tabs(projectId: projectId)
            if updateSelectedProject && selectedProject?.id == projectId {
                selectedProject = r.project
            }
            tabsByProject[projectId] = r.tabs
            statusMarkerByProject[projectId] = r.statusMarker ?? .fallback
            for tab in r.tabs {
                guard let id = tab.tabId else { continue }
                if let status = tab.sessionStatus { statusByTab[id] = status }
                if tab.sessionStatus == "busy" || tab.sessionStatus == "running" {
                    runningTabs.insert(id)
                } else if tab.sessionStatus != nil {
                    runningTabs.remove(id)
                }
            }
            if let selectedId = selectedTab?.tabId,
               let fresh = r.tabs.first(where: { $0.tabId == selectedId }) {
                selectedTab = fresh
            }
            offline = false
            lastError = nil
        } catch {
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
        return tabId
    }

    func activateSelectedTab(tabId: String) async {
        await loadHistory(tabId: tabId)
        await refreshParams(tabId: tabId)
        await refreshStatus(tabId: tabId)
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
        if let id = selectedProject?.id {
            let hasCachedTabs = !(tabsByProject[id]?.isEmpty ?? true)
            Task { await loadTabs(projectId: id, showLoader: !hasCachedTabs, updateSelectedProject: true) }
        }
    }

    func loadHistory(tabId: String) async {
        let started = Date()
        historyLoading.insert(tabId)
        VCLog.log("TerminalSSE", "history load start tab=\(shortID(tabId))")
        do {
            let r = try await TerminalAPI.history(tabId: tabId)
            if let entries = r.entries {
                entriesByTab[tabId] = CTHistoryEntryNormalizer.normalize(entries)
                reducers.removeValue(forKey: tabId)
                VCLog.log(
                    "TerminalSSE",
                    "history load done tab=\(shortID(tabId)) mode=entries returned=\(entries.count) total=\(r.total ?? entries.count) session=\(shortID(r.sessionId)) ms=\(elapsedMs(since: started))"
                )
            } else {
                let reducer = CTMessageReducer()
                reducer.reset()
                for msg in r.messages ?? [] { reducer.apply(msg) }
                reducers[tabId] = reducer
                entriesByTab[tabId] = reducer.snapshot()
                VCLog.log(
                    "TerminalSSE",
                    "history load done tab=\(shortID(tabId)) mode=messages returned=\((r.messages ?? []).count) total=\(r.total ?? (r.messages ?? []).count) session=\(shortID(r.sessionId)) entries=\(entriesByTab[tabId]?.count ?? 0) ms=\(elapsedMs(since: started))"
                )
            }
            offline = false
            lastError = nil
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
            statusByTab[tabId] = status
            if status == "busy" {
                runningTabs.insert(tabId)
                if turnStartedAt[tabId] == nil { turnStartedAt[tabId] = Date() }
            } else {
                runningTabs.remove(tabId)
                turnStartedAt[tabId] = nil
            }
            if let sid = s.sessionId, var tab = selectedTab, tab.tabId == tabId {
                if s.commandType == "codex" {
                    tab.codexSessionId = sid
                } else {
                    tab.claudeSessionId = sid
                }
                selectedTab = tab
                updateTabInfo(tabId: tabId) { current in
                    if s.commandType == "codex" {
                        current.codexSessionId = sid
                    } else {
                        current.claudeSessionId = sid
                    }
                }
            }
            offline = false
        } catch {
            mark(error)
        }
    }

    func refreshParams(tabId: String) async {
        do {
            paramsByTab[tabId] = try await TerminalAPI.params(tabId: tabId)
        } catch {
            VCLog.log("Terminal", "params failed tab=\(tabId.suffix(8)): \(error.localizedDescription)")
        }
    }

    func setParams(tabId: String, partial: [String: Any]) async {
        do {
            _ = try await TerminalAPI.setParams(tabId: tabId, body: partial)
            await refreshParams(tabId: tabId)
        } catch {
            mark(error)
        }
    }

    func send(tabId: String, text: String) async throws {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
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
                statusByTab[tabId] = "inactive"
                runningTabs.remove(tabId)
                turnStartedAt[tabId] = nil
                clearPromptRecovery(tabId: tabId)
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
                    statusByTab[tabId] = "starting"
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
        runningTabs.remove(tabId)
        if statusByTab[tabId] == "busy" { statusByTab[tabId] = "active" }
        turnStartedAt[tabId] = nil
        pendingQuestionByTab.removeValue(forKey: tabId)
        questionAnsweringTabs.remove(tabId)
        VCLog.log("TerminalSSE", "finish turn tab=\(shortID(tabId)) reason=\(reason ?? "-") entries=\(entriesByTab[tabId]?.count ?? 0)")
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
        for key in Array(tabsByProject.keys) {
            guard var tabs = tabsByProject[key],
                  let idx = tabs.firstIndex(where: { $0.tabId == tabId }) else { continue }
            mutate(&tabs[idx])
            tabsByProject[key] = tabs
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
        switch event.type {
        case "snapshot":
            if let status = event.sessionStatus {
                statusByTab[tabId] = status
                if status == "busy" { runningTabs.insert(tabId) } else { runningTabs.remove(tabId) }
            } else if event.busy == true {
                statusByTab[tabId] = "busy"
                runningTabs.insert(tabId)
            }
            if let sid = event.sessionId, var tab = selectedTab, tab.tabId == tabId {
                if event.commandType == "codex" || event.toolType == "codex" {
                    tab.codexSessionId = sid
                } else {
                    tab.claudeSessionId = sid
                }
                selectedTab = tab
                updateTabInfo(tabId: tabId) { current in
                    if event.commandType == "codex" || event.toolType == "codex" {
                        current.codexSessionId = sid
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
        case "message":
            if let msg = event.message {
                let beforeEntries = entriesByTab[tabId]?.count ?? 0
                let beforeTailChars = entriesByTab[tabId]?.last?.text.count ?? 0
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
                let afterTailChars = entriesByTab[tabId]?.last?.text.count ?? 0
                VCLog.log(
                    "TerminalSSE",
                    "event#\(seq) message tab=\(shortID(tabId)) reducer=\(reducerMode) before=\(beforeEntries)/\(beforeTailChars) after=\(afterEntries)/\(afterTailChars) \(messageDebugSummary(msg))"
                )
            } else {
                VCLog.log("TerminalSSE", "event#\(seq) message tab=\(shortID(tabId)) missing payload")
            }
        case "busy":
            if event.busy == true {
                runningTabs.insert(tabId)
                statusByTab[tabId] = "busy"
                if turnStartedAt[tabId] == nil { turnStartedAt[tabId] = Date() }
            } else {
                finishTurn(tabId: tabId, reason: event.reason)
            }
            VCLog.log("TerminalSSE", "event#\(seq) busy tab=\(shortID(tabId)) busy=\(event.busy.map { String($0) } ?? "-") reason=\(event.reason ?? "-") status=\(statusByTab[tabId] ?? "-")")
        case "done":
            finishTurn(tabId: tabId, reason: event.reason)
            VCLog.log("TerminalSSE", "event#\(seq) done tab=\(shortID(tabId)) reason=\(event.reason ?? "-")")
        case "bridge-update":
            if let model = event.model {
                let old = paramsByTab[tabId] ?? CTParams(tabId: tabId, model: model, effort: "?", thinking: "adaptive")
                paramsByTab[tabId] = CTParams(tabId: tabId, model: model, effort: old.effort, thinking: old.thinking)
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
                textLen += obj["text"]?.stringValue?.count ?? 0
            case "thinking":
                thinkingLen += obj["thinking"]?.stringValue?.count ?? 0
            case "tool_use":
                toolUses += 1
            case "tool_result":
                toolResults += 1
                toolResultLen += jsonText(obj["content"])?.count ?? 0
            default:
                break
            }
        }

        let resultLen = jsonText(raw.result)?.count ?? 0
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

    private func scheduleTabsPrefetch(for loadedProjects: [CTProject]) {
        tabsPrefetchTask?.cancel()
        let ids = loadedProjects
            .filter { ($0.tabCount ?? 0) > 0 || $0.isOpen == true }
            .map(\.id)
        guard !ids.isEmpty else { return }

        tabsPrefetchTask = Task { [weak self] in
            for projectId in ids {
                guard !Task.isCancelled else { return }
                let alreadyCached = await MainActor.run {
                    !(self?.tabsByProject[projectId]?.isEmpty ?? true)
                }
                await self?.loadTabs(projectId: projectId, showLoader: false, updateSelectedProject: false)
                if !alreadyCached {
                    try? await Task.sleep(for: .milliseconds(80))
                }
            }
        }
    }

    private func mark(_ error: Error) {
        let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        lastError = msg
        if error is URLError { offline = true }
        if case VoiceChatError.http(let code, _) = error, code == 0 || code == 503 { offline = true }
        VCLog.log("Terminal", msg)
    }

    private func isTerminalUnavailable(_ error: Error) -> Bool {
        if error is URLError { return true }
        if case VoiceChatError.http(let code, _) = error {
            return code == 0 || code == 503
        }
        return false
    }
}
