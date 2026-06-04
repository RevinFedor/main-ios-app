import SwiftUI
import WebKit

// Owns the single WKWebView for the Remote tab and surfaces its load state to
// SwiftUI. The web view is created once and reused for the life of the tab so
// the page (and its localStorage-stored bearer token) stays warm; the
// underlying WKWebsiteDataStore.default() is persistent, so cookies and
// localStorage also survive app relaunches.
//
// Failure handling: any provisional-navigation failure (Mac unreachable, dev
// IP wrong, no network) flips `didFail` → the tab paints a native offline
// overlay instead of WKWebView's blank white page. Reachability is inferred
// from navigation outcomes rather than a separate reachability API — the only
// thing we care about is "did the page actually load".
@MainActor
final class RemoteWebController: NSObject, ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var didFail = false
    @Published private(set) var failureMessage = ""
    @Published private(set) var estimatedProgress: Double = 0

    let webView: WKWebView
    private var progressObservation: NSKeyValueObservation?
    private var currentURL: URL?

    override init() {
        let config = WKWebViewConfiguration()
        // Persistent store — cookies + localStorage outlive the process.
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        // Dark canvas so reloads / transitions never flash white.
        webView.isOpaque = false
        webView.backgroundColor = UIColor(white: 0.04, alpha: 1)
        webView.scrollView.backgroundColor = UIColor(white: 0.04, alpha: 1)

        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in self?.estimatedProgress = wv.estimatedProgress }
        }
    }

    // Load the given URL fresh. Records it so a later reload (e.g. from the
    // offline overlay) re-requests the same address with the token query.
    func load(_ url: URL) {
        currentURL = url
        didFail = false
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadRevalidatingCacheData
        webView.load(request)
    }

    // If the page is showing (no failure) do a soft in-page reload; otherwise
    // re-request the last URL we were asked to load (recovers from offline).
    func reload() {
        didFail = false
        if let url = currentURL, webView.url == nil {
            load(url)
        } else if webView.url != nil {
            webView.reloadFromOrigin()
        } else if let url = currentURL {
            load(url)
        }
    }

    // Wipe cookies + on-disk/in-memory cache but KEEP localStorage, so the
    // bearer token survives and the user stays logged in.
    func clearCookiesAndCache(completion: @escaping () -> Void) {
        let types: Set<String> = [
            WKWebsiteDataTypeCookies,
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeFetchCache,
        ]
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) {
            completion()
        }
    }

    // Wipe EVERYTHING (cookies, cache, localStorage, IndexedDB, service
    // workers). The token is gone too — but the caller reloads immediately and
    // RemoteConfig.tokenizedURL re-supplies ?token=..., so mobile-web
    // re-bootstraps a clean session.
    func resetAllData(completion: @escaping () -> Void) {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) {
            completion()
        }
    }
}

extension RemoteWebController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        didFail = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        didFail = false
    }

    // Server unreachable / DNS / TLS / no network — the most common offline case.
    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        handleFailure(error)
    }

    // Failure after content started arriving.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleFailure(error)
    }

    private func handleFailure(_ error: Error) {
        isLoading = false
        // NSURLErrorCancelled (-999) fires on rapid reloads / redirects — not a
        // real failure, so don't surface the offline screen for it.
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        failureMessage = ns.localizedDescription
        didFail = true
    }
}

// Thin host: the controller owns the web view, this just mounts it.
struct RemoteWebViewContainer: UIViewRepresentable {
    let controller: RemoteWebController

    func makeUIView(context: Context) -> WKWebView { controller.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
