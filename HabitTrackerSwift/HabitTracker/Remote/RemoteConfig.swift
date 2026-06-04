import Foundation

// Configuration for the Remote tab — a WKWebView that renders the
// custom-terminal mobile-web SPA (see custom-terminal/docs/knowledge/
// fact-remote-access.md). Two sources:
//   • Prod — public HTTPS (reverse SSH tunnel → VPS nginx → Mac Electron).
//     Always reachable over any network.
//   • Dev  — the LAN dev instance http://<ip>:port (NOTED_WEB_PORT). Only
//     reachable on the same Wi-Fi as the Mac; plain HTTP, so the main app's
//     Info.plist carries NSAllowsLocalNetworking.
//
// The actual prod domain and default dev IP live in Secrets.swift (gitignored)
// so neither lands in committed source.
//
// Auth is a single bearer token (no login/password): mobile-web reads
// ?token=... from the URL on first load, stashes it in localStorage, then
// strips it from the address bar. We hold the token natively in Secrets and
// re-supply it on every fresh load, which is what makes the "clear data"
// actions safe — after wiping cookies/localStorage the next load re-bootstraps
// the session automatically.
enum RemoteConfig {
    static var prodURL: String { Secrets.remoteProdURL }
    static var defaultDevHost: String { Secrets.remoteDefaultDevHost }

    enum Keys {
        static let useDev = "remote.useDev"     // Bool — false = Prod, true = Dev
        static let devHost = "remote.devHost"   // String — "ip:port" or full URL
    }

    // Stored in the App-Group suite for consistency with the rest of the app.
    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: VoiceRecordConfig.appGroup)
    }

    static var useDev: Bool {
        get { defaults?.bool(forKey: Keys.useDev) ?? false }
        set { defaults?.set(newValue, forKey: Keys.useDev); defaults?.synchronize() }
    }

    static var devHost: String {
        get {
            let v = defaults?.string(forKey: Keys.devHost) ?? ""
            return v.isEmpty ? defaultDevHost : v
        }
        set { defaults?.set(newValue, forKey: Keys.devHost); defaults?.synchronize() }
    }

    // Effective base URL string (no token), respecting the source toggle.
    // The dev host may be pasted with or without a scheme; bare "ip:port"
    // defaults to http (the dev server is plain HTTP on the LAN).
    static func baseURLString(useDev: Bool, devHost: String) -> String {
        guard useDev else { return prodURL }
        var host = devHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.isEmpty { host = defaultDevHost }
        if host.hasPrefix("http://") || host.hasPrefix("https://") { return host }
        return "http://\(host)"
    }

    // Full URL including the ?token=... bearer query used by mobile-web's
    // bootstrapToken. Returns nil only if the host string can't be parsed.
    static func tokenizedURL(useDev: Bool, devHost: String) -> URL? {
        let base = baseURLString(useDev: useDev, devHost: devHost)
        guard var comps = URLComponents(string: base) else { return nil }
        if comps.path.isEmpty { comps.path = "/" }
        let token = Secrets.remoteWebToken
        if !token.isEmpty {
            var items = comps.queryItems ?? []
            items.append(URLQueryItem(name: "token", value: token))
            comps.queryItems = items
        }
        return comps.url
    }

    // Host[:port] for display in the navigation bar / offline screen.
    static func displayHost(useDev: Bool, devHost: String) -> String {
        guard let url = URLComponents(string: baseURLString(useDev: useDev, devHost: devHost)),
              let host = url.host else { return useDev ? devHost : prodURL }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }
}
