import SwiftUI
import UIKit

// ─────────────────────────────────────────────────────────────────────────────
// Voice Chat — config + REST API + prompt picker.
//
// The chat TAB is fully native now (VoiceChatUI.swift + VoiceChatStore.swift);
// the WKWebView layer that used to live here is gone. This file keeps the
// pieces shared by the tab, the Voice-page "Chat" button and the history
// cards' chat button:
//   • VoiceChatConfig — host (Prod/Dev), font sizes, API URL builder.
//   • VoiceChatAPI    — fetchPrompts / send (plus JSON helpers in the Store file).
//   • VoiceChatPromptPicker — self-loading picker; groups expand, leaves pick;
//     "Отправить без промпта" is the FIRST row (per user request).
//
// MCP / bash / file tools execute ON THE MAC inside runAgent; the phone never
// runs a tool. Auth: Secrets.remoteWebToken as Authorization: Bearer.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - Config

enum VoiceChatConfig {
    static var prodURL: String { Secrets.voiceChatProdURL }
    static var defaultDevHost: String { Secrets.voiceChatDefaultDevHost }

    enum Keys {
        static let useDev = "voicechat.useDev"
        static let devHost = "voicechat.devHost"
        // Font sizes (pt). uiFont — lists/labels chrome; chatFont — the
        // transcript (messages, tool cards, composer text).
        static let uiFont = "voicechat.uiFont"
        static let chatFont = "voicechat.chatFont"
        // Composer defaults — ONE source for the chat composer AND the prompt
        // picker header: picking a model in either place is the app-wide choice.
        static let model = "voicechat.model"
        static let think = "voicechat.think"
        static let bypass = "voicechat.bypass"
        // Mobile-only preset layer. These keys live in the iOS App Group and
        // only fan into the request body we send to the Mac; they do not share
        // storage with desktop Voice Record settings.
        static let activePreset = "voicechat.mobilePreset.active"
        static let defaultPreset = "voicechat.mobilePreset.default"
        static let preset1Model = "voicechat.mobilePreset.1.model"
        static let preset1Think = "voicechat.mobilePreset.1.think"
        static let preset2Model = "voicechat.mobilePreset.2.model"
        static let preset2Think = "voicechat.mobilePreset.2.think"
        static let developerMode = "voicechat.developerMode"
    }

    private static var defaults: UserDefaults? { UserDefaults(suiteName: VoiceRecordConfig.appGroup) }

    static func normalizedPreset(_ raw: Int) -> Int {
        raw == 2 ? 2 : 1
    }

    static func defaultPresetModel(_ slot: Int) -> String {
        normalizedPreset(slot) == 1 ? "lite" : "pro"
    }

    static func defaultPresetThink(_ slot: Int) -> String {
        normalizedPreset(slot) == 1 ? "LOW" : "HIGH"
    }

    static func presetModelKey(_ slot: Int) -> String {
        normalizedPreset(slot) == 1 ? Keys.preset1Model : Keys.preset2Model
    }

    static func presetThinkKey(_ slot: Int) -> String {
        normalizedPreset(slot) == 1 ? Keys.preset1Think : Keys.preset2Think
    }

    static func storedPresetModel(_ slot: Int) -> String {
        let slot = normalizedPreset(slot)
        return defaults?.string(forKey: presetModelKey(slot)) ?? defaultPresetModel(slot)
    }

    static func storedPresetThink(_ slot: Int) -> String {
        let slot = normalizedPreset(slot)
        return defaults?.string(forKey: presetThinkKey(slot)) ?? defaultPresetThink(slot)
    }

    static func ensureMobileModelPresetDefaults() {
        guard let defaults else { return }
        if defaults.object(forKey: Keys.preset1Model) == nil {
            defaults.set(defaultPresetModel(1), forKey: Keys.preset1Model)
        }
        if defaults.object(forKey: Keys.preset1Think) == nil {
            defaults.set(defaultPresetThink(1), forKey: Keys.preset1Think)
        }
        if defaults.object(forKey: Keys.preset2Model) == nil {
            defaults.set(defaultPresetModel(2), forKey: Keys.preset2Model)
        }
        if defaults.object(forKey: Keys.preset2Think) == nil {
            defaults.set(defaultPresetThink(2), forKey: Keys.preset2Think)
        }
        if defaults.object(forKey: Keys.defaultPreset) == nil {
            defaults.set(1, forKey: Keys.defaultPreset)
        }
        if defaults.object(forKey: Keys.activePreset) == nil {
            let slot = normalizedPreset(defaults.integer(forKey: Keys.defaultPreset))
            defaults.set(slot, forKey: Keys.activePreset)
            defaults.set(storedPresetModel(slot), forKey: Keys.model)
            defaults.set(storedPresetThink(slot), forKey: Keys.think)
        }
        if defaults.object(forKey: Keys.developerMode) == nil {
            defaults.set(true, forKey: Keys.developerMode)
        }
        defaults.synchronize()
    }

    static func applyMobileModelPreset(_ slot: Int) {
        ensureMobileModelPresetDefaults()
        guard let defaults else { return }
        let slot = normalizedPreset(slot)
        defaults.set(slot, forKey: Keys.activePreset)
        defaults.set(storedPresetModel(slot), forKey: Keys.model)
        defaults.set(storedPresetThink(slot), forKey: Keys.think)
        defaults.synchronize()
    }

    static var useDev: Bool {
        get { defaults?.bool(forKey: Keys.useDev) ?? false }
        set { defaults?.set(newValue, forKey: Keys.useDev); defaults?.synchronize() }
    }
    static var devHost: String {
        get { let v = defaults?.string(forKey: Keys.devHost) ?? ""; return v.isEmpty ? defaultDevHost : v }
        set { defaults?.set(newValue, forKey: Keys.devHost); defaults?.synchronize() }
    }

    // Base "scheme://host[:port]" (no token, no path). ALWAYS prod: the Dev/LAN
    // source was removed from the native client (the toggle UI is gone, so an
    // old persisted useDev=true must not silently strand the app on a LAN IP).
    static func baseURLString() -> String { prodURL }

    // REST base for fetch/POST (token goes in the Authorization header; the SSE
    // GET appends ?token= itself — URLSession streams can't set EventSource-
    // style auth any other way on the server's terms).
    static func apiURL(_ path: String) -> URL? {
        URL(string: baseURLString() + path)
    }

    // Host[:port] for the navbar status chip.
    static func displayHost() -> String {
        guard let comps = URLComponents(string: baseURLString()), let host = comps.host else {
            return useDev ? devHost : prodURL
        }
        if let port = comps.port { return "\(host):\(port)" }
        return host
    }
}

// MARK: - Prompt model (mirrors /api/prompts)

struct VCPrompt: Identifiable, Decodable {
    let id: String
    let title: String
    let description: String
    let variations: [VCVariation]
    enum CodingKeys: String, CodingKey { case id, title, description, variations }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        variations = (try? c.decode([VCVariation].self, forKey: .variations)) ?? []
    }
}
struct VCVariation: Identifiable, Decodable {
    let id: String
    let title: String
    let description: String
    enum CodingKeys: String, CodingKey { case id, title, description }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
    }
}
private struct VCPromptLibrary: Decodable { let prompts: [VCPrompt] }

// MARK: - GT Editor file picker model (proxied by Voice Record)

struct VCGTSource: Identifiable, Decodable {
    let id: String
    let kind: String
    let name: String
    var path: String?
    var projectId: String?
    var open: Bool?
    var tabCount: Int?
    var fileCount: Int?
}

struct VCGTTreeItem: Identifiable, Decodable {
    let type: String
    let name: String
    let path: String
    var isDirectory: Bool?
    var open: Bool?
    var active: Bool?
    var id: String { path }
}

private struct VCGTSourcesResponse: Decodable {
    let sources: [VCGTSource]
}

struct VCGTTreeResponse: Decodable {
    let path: String
    let name: String?
    let parentPath: String?
    let items: [VCGTTreeItem]
}

struct VCGTFile: Identifiable, Decodable {
    let type: String?
    let name: String
    let path: String
    var content: String?
    var id: String { path }
}

private struct VCGTFileResponse: Decodable {
    let file: VCGTFile
}

struct VCGTEmojiShortcut: Identifiable, Decodable {
    let name: String
    var emoji: String?
    var image: String?
    var description: String?
    var id: String { name }
}

private struct VCGTSettingsPayload: Decodable {
    var emojiShortcuts: [VCGTEmojiShortcut]?
}

private struct VCGTSettingsResponse: Decodable {
    var settings: VCGTSettingsPayload?
    var emojiShortcuts: [VCGTEmojiShortcut]?
}

struct VCGTGlyph: View {
    var size: CGFloat = 20

    var body: some View {
        Text("GT")
            .font(.system(size: max(8, size * 0.43), weight: .heavy, design: .rounded))
            .foregroundStyle(Color(hex: "67e8f9"))
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(Color(hex: "0f172a")))
            .overlay(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).stroke(Color(hex: "67e8f9").opacity(0.45)))
    }
}

// MARK: - Composer send button with "auto-send arming"
//
// Shared by the Voice (Gemini) chat composer and the Terminal composer. One
// circular trailing button drives a small state machine:
//   • has draft  · tap       → normal send
//   • armed      · tap       → CANCEL arming (NEVER sends — guarded explicitly)
//   • empty      · tap       → nothing (arming is long-press only, by request)
//   • long-press (any state) → haptic buzz + small anchored popover above the
//                              button with one row «Активировать авто-отправку»
//                              → ARM (purple indeterminate loader spins). This is
//                              the ONLY arm path, so it works even with text typed
//                              (a plain tap there would send).
//
// While armed, an incoming dictation insert (Toggle Voice Record stop) is
// auto-submitted by the owner view instead of just landing in the field.
//
// Gesture model (validated June 2026 via ChatGPT-5.5 web research + Claude
// Opus 4.8): a plain tappable shape with SEPARATE `.onTapGesture` +
// `.onLongPressGesture` — the long-press duration gate makes them mutually
// exclusive (quick lift = tap, hold = long-press), avoiding the iOS-26
// `.simultaneousGesture` "both fire" trap. NOT a `Button` (we want full control
// of the empty-tap, no `.disabled`). The button is a sibling of the chat
// ScrollView (composer-dock overlay), so the gesture never arbitrates against
// scroll. `suppressTap` mirrors the proven local pattern in `VoiceChatGTFileRow`.
struct ComposerSendButton: View {
    let hasDraft: Bool
    let armed: Bool
    var accent: Color = Color(hex: "7c3aed")
    let onSend: () -> Void
    let onArm: () -> Void
    let onCancelArm: () -> Void

    @State private var showAutoEnterMenu = false
    @State private var suppressTap = false
    @State private var haptic = UIImpactFeedbackGenerator(style: .medium)

    var body: some View {
        ZStack {
            // Dark circle while armed (so the purple spinner reads clearly) or
            // empty; filled accent only when there is a draft ready to send.
            Circle().fill(!armed && hasDraft ? accent : Color(white: 0.18))
            if armed {
                ProgressView()
                    .controlSize(.small)
                    .tint(accent)
                    .allowsHitTesting(false)
            } else {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: 38, height: 38)
        // Fast arrow↔loader swap (0.15s) — arming should feel instant.
        .animation(.easeInOut(duration: 0.15), value: armed)
        // Whole circle is the hit area — the spinner's transparent gaps must not
        // create dead spots, otherwise tap-to-cancel could miss.
        .contentShape(Circle())
        .onTapGesture {
            if suppressTap { suppressTap = false; return }
            if armed {
                onCancelArm()           // armed → cancel, never falls through to send
            } else if hasDraft {
                onSend()
            }
            // empty + not armed → no-op (arming is long-press only, by request)
        }
        .onLongPressGesture(minimumDuration: 0.4, maximumDistance: 16) {
            suppressTap = true
            haptic.impactOccurred()
            haptic.prepare()
            showAutoEnterMenu = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { suppressTap = false }
        } onPressingChanged: { pressing in
            if pressing { haptic.prepare() }
        }
        .popover(isPresented: $showAutoEnterMenu, attachmentAnchor: .point(.top), arrowEdge: .bottom) {
            autoEnterMenu
        }
    }

    private var autoEnterMenu: some View {
        Button {
            showAutoEnterMenu = false
            onArm()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accent)
                Text("Активировать авто-отправку")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(width: 252, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Keep it a small floating bubble on compact iPhone instead of adapting
        // to a sheet (iOS 16.4+). arrowEdge is ignored on iOS — the button sits
        // at the bottom, so the system places the popover above it pointing down.
        .presentationCompactAdaptation(.popover)
        .preferredColorScheme(.dark)
    }
}

// MARK: - API

enum VoiceChatError: LocalizedError {
    case badURL
    case http(Int, String)
    case decode(String)
    var errorDescription: String? {
        switch self {
        case .badURL: return "Не удалось собрать URL Voice Chat."
        case .http(let s, let b): return "Ошибка \(s): \(b)"
        case .decode(let m): return "Ошибка ответа: \(m)"
        }
    }
}

enum VoiceChatAPI {
    private static func authed(_ req: inout URLRequest) {
        req.setValue("Bearer \(Secrets.remoteWebToken)", forHTTPHeaderField: "Authorization")
    }

    static func fetchPrompts() async throws -> [VCPrompt] {
        guard let url = VoiceChatConfig.apiURL("/api/prompts") else { throw VoiceChatError.badURL }
        var req = URLRequest(url: url); req.timeoutInterval = 10; authed(&req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw VoiceChatError.decode("non-HTTP") }
        guard (200..<300).contains(http.statusCode) else {
            throw VoiceChatError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(VCPromptLibrary.self, from: data).prompts
    }

    // Returns the chatId so the caller can open the native chat on it.
    // model/think/bypass ride from the persisted composer defaults — the same
    // values the picker header shows, so what you see is what gets sent.
    static func send(text: String, promptId: String?, variationId: String?, attachments: [VCAttachment] = []) async throws -> String {
        VoiceChatConfig.ensureMobileModelPresetDefaults()
        guard let url = VoiceChatConfig.apiURL("/api/chat/send") else { throw VoiceChatError.badURL }
        var req = URLRequest(url: url); req.httpMethod = "POST"; req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authed(&req)
        let d = UserDefaults(suiteName: VoiceRecordConfig.appGroup)
        var body: [String: Any] = [
            "model": d?.string(forKey: VoiceChatConfig.Keys.model) ?? "flash",
            "thinkingLevel": d?.string(forKey: VoiceChatConfig.Keys.think) ?? "NONE",
            "bypass": (d?.object(forKey: VoiceChatConfig.Keys.bypass) as? Bool) ?? true,
        ]
        if !text.isEmpty { body["text"] = text }
        if let p = promptId { body["promptId"] = p }
        if let v = variationId { body["variationId"] = v }
        if !attachments.isEmpty { body["attachments"] = attachments.map(\.apiObject) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw VoiceChatError.decode("non-HTTP") }
        guard (200..<300).contains(http.statusCode) else {
            throw VoiceChatError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chatId = obj["chatId"] as? String else {
            throw VoiceChatError.decode("chatId missing")
        }
        return chatId
    }

    static func fetchGTSources() async throws -> [VCGTSource] {
        let r: VCGTSourcesResponse = try await getJSON("/api/gt/sources")
        return r.sources
    }

    static func fetchGTTree(sourceId: String, path: String? = nil) async throws -> VCGTTreeResponse {
        var q = "?sourceId=" + sourceId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        if let path {
            q += "&path=" + path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        }
        return try await getJSON("/api/gt/tree" + q)
    }

    static func fetchGTFile(path: String) async throws -> VCGTFile {
        let q = "?path=" + path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)! + "&includeContent=1"
        let r: VCGTFileResponse = try await getJSON("/api/gt/file" + q)
        return r.file
    }

    static func fetchGTSettings() async throws -> [VCGTEmojiShortcut] {
        let r: VCGTSettingsResponse = try await getJSON("/api/gt/settings")
        return r.settings?.emojiShortcuts ?? r.emojiShortcuts ?? []
    }
}

// MARK: - Prompt picker (click-based; group expands, leaf sends; skip on TOP)
//
// Header row = model + think chips (the SAME persisted defaults the chat
// composer uses — one @AppStorage key set), replacing the old "Отмена /
// Выбери промпт" title which carried no information. Picking an option opens
// a Menu inline — the sheet stays up. Closing = swipe down (system standard).
struct VoiceChatPromptPicker: View {
    let onPick: (_ promptId: String, _ variationId: String?, _ label: String) -> Void
    /// Send with no prompt at all — rendered as the FIRST row.
    var onSkip: (() -> Void)? = nil
    var showsModelHeader = true
    @State private var expanded: String? = nil
    // Self-loading: the sheet presents instantly with a spinner, then fetches
    // /api/prompts in .task — kills the presenter-race that showed an empty
    // picker on first open.
    @State private var prompts: [VCPrompt] = []
    @State private var loading = true
    @State private var loadError: String? = nil

    @AppStorage(VoiceChatConfig.Keys.model, store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var model = "flash"
    @AppStorage(VoiceChatConfig.Keys.think, store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var think = "NONE"
    @AppStorage(VoiceChatConfig.Keys.activePreset, store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var activePreset = 1
    @AppStorage(VoiceChatConfig.Keys.defaultPreset, store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var defaultPreset = 1

    var body: some View {
        VStack(spacing: 0) {
            // Grip + optional header chips (model · think · preset switch).
            Capsule().fill(Color(white: 0.28)).frame(width: 36, height: 4).padding(.top, 8)
            if showsModelHeader {
                HStack(spacing: 8) {
                    VCOptionChip(icon: "cpu", options: VC_MODELS, value: $model)
                    VCOptionChip(icon: "brain", options: VC_THINKING, value: $think, activeWhenNot: "NONE")
                    Spacer()
                    VCPresetSwitchButton(activePreset: $activePreset, model: $model, think: $think)
                }
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
            }

            Group {
                if loading {
                    VStack(spacing: 12) { ProgressView().tint(.white); Text("Загрузка промптов…").foregroundStyle(.secondary).font(.caption) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    VStack(spacing: 12) {
                        Text("Не удалось загрузить промпты").foregroundStyle(.white)
                        Text(loadError).foregroundStyle(.secondary).font(.caption).multilineTextAlignment(.center)
                        Button("Повторить") { Task { await loadPrompts() } }.tint(Color(hex: "8AB4F8"))
                        if let onSkip { Button("Отправить без промпта") { onSkip() }.tint(.secondary) }
                    }
                    .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    promptList
                }
            }
        }
        .background(Color(white: 0.04).ignoresSafeArea())
        .onAppear {
            if showsModelHeader { applyDefaultPreset() }
        }
        .task { await loadPrompts() }
    }

    private func applyDefaultPreset() {
        let slot = VoiceChatConfig.normalizedPreset(defaultPreset)
        activePreset = slot
        model = VoiceChatConfig.storedPresetModel(slot)
        think = VoiceChatConfig.storedPresetThink(slot)
        VoiceChatConfig.applyMobileModelPreset(slot)
    }

    private func loadPrompts() async {
        loading = true; loadError = nil
        do { prompts = try await VoiceChatAPI.fetchPrompts(); loading = false }
        catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            loading = false
        }
    }

    private var promptList: some View {
        List {
                // "Без промпта" FIRST (was pinned at the bottom; the user asked
                // for it on top — it's the most common action).
                if let onSkip {
                    Button { onSkip() } label: {
                        Label("Отправить без промпта", systemImage: "paperplane")
                            .foregroundStyle(.white)
                    }.listRowBackground(Color(white: 0.14))
                }

                ForEach(prompts) { p in
                    let hasVars = !p.variations.isEmpty
                    Button {
                        if hasVars { withAnimation { expanded = (expanded == p.id) ? nil : p.id } }
                        else { onPick(p.id, nil, promptLabel(p)) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.title).foregroundStyle(.white).font(.body.weight(.medium))
                                if !p.description.isEmpty {
                                    Text(p.description).foregroundStyle(.secondary).font(.caption)
                                }
                            }
                            Spacer()
                            if hasVars {
                                Image(systemName: expanded == p.id ? "chevron.down" : "chevron.right")
                                    .foregroundStyle(.secondary).font(.caption)
                            }
                        }
                    }
                    .listRowBackground(Color(white: 0.12))

                    if hasVars && expanded == p.id {
                        Button { onPick(p.id, nil, promptLabel(p)) } label: {
                            Text("Базовый").foregroundStyle(.secondary)
                        }.listRowBackground(Color(white: 0.09)).padding(.leading, 12)
                        ForEach(p.variations) { v in
                            Button { onPick(p.id, v.id, promptLabel(p, variation: v)) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(v.title).foregroundStyle(.white)
                                    if !v.description.isEmpty {
                                        Text(v.description).foregroundStyle(.secondary).font(.caption)
                                    }
                                }
                            }.listRowBackground(Color(white: 0.09)).padding(.leading, 12)
                        }
                    }
                }
        }
        .scrollContentBackground(.hidden)
        .background(Color(white: 0.04))
    }

    private func promptLabel(_ prompt: VCPrompt, variation: VCVariation? = nil) -> String {
        let title = prompt.title.isEmpty ? "Промпт" : prompt.title
        guard let variation else { return title }
        return title + " · " + (variation.title.isEmpty ? "Вариант" : variation.title)
    }
}

// MARK: - GT Editor file picker

private struct VCGTVisibleTreeRow: Identifiable {
    let item: VCGTTreeItem
    let depth: Int
    var id: String { item.path }
}

struct VoiceChatGTFilePicker: View {
    let onPick: (_ attachment: VCAttachment, _ closeAfterPick: Bool) -> Void
    @State private var sources: [VCGTSource] = []
    @State private var source: VCGTSource? = nil
    @State private var items: [VCGTTreeItem] = []
    @State private var childrenByPath: [String: [VCGTTreeItem]] = [:]
    @State private var expandedFolders: Set<String> = []
    @State private var loadingFolders: Set<String> = []
    @State private var currentPath = ""
    @State private var parentPath: String? = nil
    @State private var loading = true
    @State private var error: String? = nil
    @State private var added: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color(white: 0.28)).frame(width: 36, height: 4).padding(.top, 8).padding(.bottom, 8)
            header
            Group {
                if loading {
                    VStack(spacing: 12) {
                        ProgressView().tint(.white)
                        Text("Загрузка GT Editor…").foregroundStyle(.secondary).font(.caption)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    VStack(spacing: 12) {
                        Text("GT Editor недоступен").foregroundStyle(.white)
                        Text(error).foregroundStyle(.secondary).font(.caption).multilineTextAlignment(.center)
                        Button("Повторить") { Task { await reloadCurrent() } }.tint(Color(hex: "8AB4F8"))
                    }
                    .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if source == nil {
                    sourcesList
                } else {
                    treeList
                }
            }
        }
        .background(Color(white: 0.04).ignoresSafeArea())
        .task { await loadSources() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if source != nil {
                Button { Task { await goBack() } } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(source == nil ? "GT Editor" : ((currentPath as NSString).lastPathComponent.isEmpty ? (source?.name ?? "GT Editor") : (currentPath as NSString).lastPathComponent))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(source == nil ? "Выбери директорию или проект" : currentPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.bottom, 6)
    }

    private var sourcesList: some View {
        List {
            ForEach(sources) { s in
                Button { Task { await loadTree(s, path: s.path) } } label: {
                    HStack(spacing: 12) {
                        Image(systemName: s.kind == "project" ? "rectangle.3.group" : "folder")
                            .foregroundStyle(s.kind == "project" ? Color(hex: "c4b5fd") : Color(hex: "67e8f9"))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name).foregroundStyle(.white).font(.body.weight(.semibold))
                            Text(s.kind == "project" ? "проект · \(s.fileCount ?? 0) файлов" : "директория")
                                .foregroundStyle(.secondary).font(.caption)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary).font(.caption)
                    }
                }
                .listRowBackground(Color(white: 0.12))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(white: 0.04))
    }

    private var treeList: some View {
        List {
            ForEach(visibleTreeRows) { row in
                GTFilePickerMobileRow(
                    item: row.item,
                    depth: row.depth,
                    expanded: expandedFolders.contains(row.item.path),
                    loading: loadingFolders.contains(row.item.path),
                    added: added.contains(row.item.path),
                    onToggleFolder: { toggleFolder(row.item) },
                    onPick: { pick(row.item, closeAfter: true) },
                    onMultiPick: { pick(row.item, closeAfter: false) }
                )
                .listRowBackground(added.contains(row.item.path) ? Color(hex: "67e8f9").opacity(0.13) : Color(white: 0.12))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(white: 0.04))
    }

    private var visibleTreeRows: [VCGTVisibleTreeRow] {
        flattenTree(items, depth: 0)
    }

    private func flattenTree(_ sourceItems: [VCGTTreeItem], depth: Int) -> [VCGTVisibleTreeRow] {
        var rows: [VCGTVisibleTreeRow] = []
        for item in sourceItems {
            rows.append(VCGTVisibleTreeRow(item: item, depth: depth))
            if isFolder(item), expandedFolders.contains(item.path) {
                rows.append(contentsOf: flattenTree(childrenByPath[item.path] ?? [], depth: depth + 1))
            }
        }
        return rows
    }

    private func isFolder(_ item: VCGTTreeItem) -> Bool {
        item.isDirectory ?? (item.type == "folder")
    }

    private func makeAttachment(_ item: VCGTTreeItem) -> VCAttachment {
        VCAttachment(kind: "gtfile", name: item.name, filePath: item.path, reread: true)
    }

    private func pick(_ item: VCGTTreeItem, closeAfter: Bool) {
        guard !isFolder(item) else { return }
        added.insert(item.path)
        onPick(makeAttachment(item), closeAfter)
    }

    private func toggleFolder(_ item: VCGTTreeItem) {
        guard isFolder(item) else { return }
        if expandedFolders.contains(item.path) {
            expandedFolders.remove(item.path)
            return
        }

        expandedFolders.insert(item.path)
        guard childrenByPath[item.path] == nil, let src = source else { return }
        loadingFolders.insert(item.path)

        Task {
            do {
                let r = try await VoiceChatAPI.fetchGTTree(sourceId: src.id, path: item.path)
                await MainActor.run {
                    childrenByPath[item.path] = r.items
                    loadingFolders.remove(item.path)
                }
            } catch {
                await MainActor.run {
                    loadingFolders.remove(item.path)
                    self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    private func goBack() async {
        await loadSources()
    }

    private func reloadCurrent() async {
        if let source { await loadTree(source, path: currentPath.isEmpty ? source.path : currentPath) }
        else { await loadSources() }
    }

    private func loadSources() async {
        loading = true; error = nil; source = nil; items = []; childrenByPath = [:]; expandedFolders = []; loadingFolders = []; currentPath = ""; parentPath = nil
        do {
            sources = try await VoiceChatAPI.fetchGTSources().sorted { a, b in
                if a.kind == "project", b.kind != "project" { return true }
                if a.kind != "project", b.kind == "project" { return false }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            loading = false
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            loading = false
        }
    }

    private func loadTree(_ src: VCGTSource, path: String?) async {
        loading = true; error = nil
        do {
            let r = try await VoiceChatAPI.fetchGTTree(sourceId: src.id, path: path)
            source = src
            items = r.items
            childrenByPath = [:]
            expandedFolders = []
            loadingFolders = []
            currentPath = r.path
            parentPath = r.parentPath
            loading = false
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            loading = false
        }
    }
}

private struct GTFilePickerMobileRow: View {
    let item: VCGTTreeItem
    let depth: Int
    let expanded: Bool
    let loading: Bool
    let added: Bool
    let onToggleFolder: () -> Void
    let onPick: () -> Void
    let onMultiPick: () -> Void
    @State private var suppressTap = false
    @State private var isPressing = false
    @State private var haptic = UIImpactFeedbackGenerator(style: .medium)

    private var isFolder: Bool { item.isDirectory ?? (item.type == "folder") }

    var body: some View {
        HStack(spacing: 12) {
            if isFolder {
                Image(systemName: "folder").foregroundStyle(Color(hex: "fbbf24"))
            } else {
                VCGTGlyph(size: 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .foregroundStyle(.white)
                    .font(.body.weight(item.active == true ? .bold : .medium))
                    .lineLimit(1)
                if item.active == true || item.open == true {
                    Text(item.active == true ? "активен" : "открыт")
                        .foregroundStyle(item.active == true ? Color(hex: "67e8f9") : .secondary)
                        .font(.caption2)
                }
            }
            Spacer()
            if isFolder {
                if loading {
                    ProgressView().controlSize(.small).tint(.secondary)
                } else {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .foregroundStyle(.secondary).font(.caption)
                }
            } else if added {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(hex: "67e8f9"))
            }
        }
        .padding(.leading, CGFloat(depth) * 18)
        .contentShape(Rectangle())
        .scaleEffect(isPressing ? 0.985 : 1)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isPressing ? Color.white.opacity(0.055) : Color.clear)
        )
        .animation(.easeOut(duration: 0.12), value: isPressing)
        .onTapGesture {
            if suppressTap {
                suppressTap = false
                return
            }
            isFolder ? onToggleFolder() : onPick()
        }
        .onLongPressGesture(minimumDuration: 0.38, maximumDistance: 18) {
            guard !isFolder else { return }
            suppressTap = true
            haptic.impactOccurred()
            haptic.prepare()
            onMultiPick()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { suppressTap = false }
        } onPressingChanged: { pressing in
            guard !isFolder else { return }
            isPressing = pressing
            if pressing { haptic.prepare() }
        }
    }
}
