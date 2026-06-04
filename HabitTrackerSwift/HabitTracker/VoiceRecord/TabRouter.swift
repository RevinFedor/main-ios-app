import Combine
import Foundation

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
    enum Tab: String { case voice, remote, habits }

    @Published var selected: Tab = .voice

    func handle(url: URL) {
        guard url.scheme == "habittracker" else { return }
        switch url.host {
        // Both "habits" (new) and "home" (legacy, kept for any old widget
        // builds still installed) route to the habits tab.
        case "habits", "home": selected = .habits
        case "voice":          selected = .voice
        case "remote":         selected = .remote
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
        VRLog.d("Router", "consumeVoiceTabFlag → switching to Voice")
        selected = .voice
    }
}
