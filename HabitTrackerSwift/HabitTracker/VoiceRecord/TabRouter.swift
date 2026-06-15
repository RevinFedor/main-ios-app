import Combine
import Foundation
import SwiftUI
import UIKit

// Drives the root TabView selection. Updated by deep-link handlers (widget
// taps via URL scheme) and by intents that set the wantsVoiceTab flag in
// the App-Group container.
//
// Default tab is .voice: this app's most-used entry point is voice
// dictation; the habits tracker is a secondary view that the user explicitly
// navigates to (either via the habit Home Screen widget, which deep-links
// straight there, or by tapping the Habits tab).

@MainActor
final class TabRouter: ObservableObject {
    enum Tab: String, CaseIterable { case chat, voice, habits }

    @Published var selected: Tab = .voice

    // Custom horizontal pager (RootTabView): the visual order is `Tab.allCases`
    // (chat · voice · habits). The pager binds its `scrollPosition(id:)` to this
    // index; a bar tap / deep-link sets `selected` and the pager animates to it.
    var selectedIndex: Int { Tab.allCases.firstIndex(of: selected) ?? 0 }
    static func tab(atIndex i: Int) -> Tab? {
        guard i >= 0, i < Tab.allCases.count else { return nil }
        return Tab.allCases[i]
    }

    // Coarse paging lock. RootTabView's horizontal pager reads this to disable
    // swipe-paging while the AI Chat surface owns horizontal motion (history
    // drawer open/dragging, composer/search focused, Terminal back-swipe) or the
    // Habits surface is mid-reorder. Only the user swipe is gated; a bar tap /
    // deep-link still pages programmatically.
    @Published var pagingLocked: Bool = false

    // The AI Chat surface raised its keyboard (composer or search focused). The
    // root shell reads this to slide the floating glass bar away so it doesn't
    // stack on the keyboard-lifted composer. Driven by FOCUS, not by keyboard
    // notifications: focus is app-synchronous, so the bar slides in the SAME
    // frame the composer collapses — the keyboard-notification path lagged and
    // produced the "composer drops, THEN the bar reappears" two-step the user saw.
    @Published var chatKeyboardUp: Bool = false

    // AI Chat navigation request — a UUID-stamped token so the chat tab can tell
    // "load this conversation" from "no request" even when chatId is nil (open the
    // list). The chat tab loads on whichever signal lands and clears `seq` once
    // handled, so the load can't be dropped by @Published delivery ordering.
    struct ChatRequest: Equatable { let seq: UUID; let chatId: String? }
    @Published var pendingChatRequest: ChatRequest? = nil

    /// Switch to the AI Chat tab and open a conversation (nil = the chat list).
    /// Order matters: set the request BEFORE switching tabs so the chat tab sees
    /// it whether it reacts to the request change or to becoming the active tab.
    func openChat(_ chatId: String?) {
        pendingChatRequest = ChatRequest(seq: UUID(), chatId: chatId)
        selected = .chat
    }

    // Chat-creation status, presented at the ROOT (above the TabView) so it
    // survives the Voice→AI Chat tab switch. The Voice "Chat" button's POST runs
    // detached; if it fails after we've already left the Voice tab, an alert bound
    // to that tab would never show. These live on the router instead.
    @Published var chatCreating: Bool = false
    @Published var chatCreateError: String? = nil

    func handle(url: URL) {
        guard url.scheme == "habittracker" else { return }
        switch url.host {
        // Both "habits" (new) and "home" (legacy, kept for any old widget
        // builds still installed) route to the habits tab.
        case "habits", "home": selected = .habits
        case "voice":          selected = .voice
        case "remote":         selected = .chat
        case "chat":           selected = .chat
        default:               break
        }
    }

    // Consume the wantsVoiceTab flag set by recording intents — switch the
    // user to Voice on next foreground/init, then clear so we don't keep
    // hijacking later opens.
    func consumeVoiceTabFlagIfSet() {
        let d = UserDefaults(suiteName: VoiceRecordConfig.appGroup)
        guard d?.bool(forKey: VoiceRecordConfig.SharedKeys.wantsVoiceTab) == true else { return }
        d?.removeObject(forKey: VoiceRecordConfig.SharedKeys.wantsVoiceTab)
        d?.synchronize()
        if selected == .chat && VoiceChatStore.shared.isComposerVisible {
            VRLog.d("Router", "consumeVoiceTabFlag → staying in Chat (composer visible)")
            return
        }
        VRLog.d("Router", "consumeVoiceTabFlag → switching to Voice")
        selected = .voice
    }
}
