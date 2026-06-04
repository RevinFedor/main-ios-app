import SwiftUI

// The Remote tab: a full-screen WKWebView (custom-terminal mobile-web) under a
// slim native navbar. The navbar — not the settings sheet — carries the
// reload and gear buttons, per the requirement that these live "в намбаре, а
// не в настройках". When the site is unreachable the tab paints a native
// offline overlay (icon + message + Reload) instead of WKWebView's blank page.
struct RemoteTabView: View {
    @StateObject private var web = RemoteWebController()

    // Source toggle + dev host, shared via the App-Group suite so the value is
    // identical whether read here or in the settings sheet.
    @AppStorage(RemoteConfig.Keys.useDev,
                store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var useDev: Bool = false
    @AppStorage(RemoteConfig.Keys.devHost,
                store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var devHost: String = RemoteConfig.defaultDevHost

    @State private var showSettings = false
    // TabView fires .onAppear on every switch back to this tab; without this
    // guard the page would reload (losing scroll / composer state) each time.
    // Initial load happens once; later loads are explicit (navbar reload,
    // source/host change, data reset).
    @State private var didInitialLoad = false

    // What is ACTUALLY loaded right now — captured at load time. The navbar and
    // offline screen read these, NOT the @AppStorage props above: @AppStorage
    // refreshes via KVO on the next runloop, and while the settings sheet is
    // covering this view SwiftUI defers the navbar re-render until the tab is
    // shown again — which is why the title only updated after re-entering the
    // tab. Driving the navbar from load-time state makes it change in lockstep
    // with the page.
    @State private var activeIsDev = false
    @State private var activeHost = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Color(white: 0.04).ignoresSafeArea()

                RemoteWebViewContainer(controller: web)
                    .ignoresSafeArea(.container, edges: .bottom)
                    .opacity(web.didFail ? 0 : 1)

                // Thin top progress line during load (anchored under the navbar).
                if web.isLoading && web.estimatedProgress < 1 {
                    VStack(spacing: 0) {
                        GeometryReader { geo in
                            Rectangle()
                                .fill(Color(hex: "8AB4F8"))
                                .frame(width: geo.size.width * max(0.05, web.estimatedProgress))
                                .animation(.easeOut(duration: 0.2), value: web.estimatedProgress)
                        }
                        .frame(height: 2)
                        Spacer()
                    }
                }

                if web.didFail {
                    RemoteOfflineView(
                        host: activeHost,
                        message: web.failureMessage,
                        isDev: activeIsDev,
                        onReload: { web.reload() }
                    )
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(web.didFail ? Color.red : (activeIsDev ? Color.orange : Color.green))
                            .frame(width: 7, height: 7)
                        Text(activeHost)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        web.reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .toolbarBackground(Color(white: 0.06), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .tint(.white)
        .onAppear {
            guard !didInitialLoad else { return }
            didInitialLoad = true
            loadCurrent()
        }
        .sheet(isPresented: $showSettings) {
            RemoteSettingsSheet(web: web, onApply: { loadCurrent() })
        }
    }

    private func loadCurrent() {
        // Read the source straight from the store (RemoteConfig), NOT from the
        // @AppStorage props above. @AppStorage refreshes via KVO on the next
        // runloop, so right after the settings sheet flips the toggle the
        // sibling @AppStorage here still returns the OLD value within the same
        // cycle — which made "switch to Dev" reload Prod. The store read is
        // live and reflects the write immediately.
        let isDev = RemoteConfig.useDev
        let host = RemoteConfig.devHost
        guard let url = RemoteConfig.tokenizedURL(useDev: isDev, devHost: host) else {
            return
        }
        // Capture what we're loading so the navbar / offline screen reflect the
        // page immediately, in lockstep with web.load (see activeIsDev above).
        activeIsDev = isDev
        activeHost = RemoteConfig.displayHost(useDev: isDev, devHost: host)
        web.load(url)
    }
}

// Native offline screen — replaces the white/black blank that WKWebView shows
// when it can't reach the server. Reachable from the main page (no settings
// dive) with a single Reload button.
private struct RemoteOfflineView: View {
    let host: String
    let message: String
    let isDev: Bool
    let onReload: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 46, weight: .regular))
                .foregroundStyle(.white.opacity(0.5))

            VStack(spacing: 6) {
                Text("Сайт недоступен")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Text(host)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if !message.isEmpty {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            if isDev {
                Text("Dev-режим: Mac должен быть в той же сети и запущен на этом адресе.")
                    .font(.footnote)
                    .foregroundStyle(.orange.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Button(action: onReload) {
                Label("Перезагрузить", systemImage: "arrow.clockwise")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(hex: "8AB4F8"))
            .padding(.horizontal, 48)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.04).ignoresSafeArea())
    }
}

// Settings for the Remote tab: source toggle (Prod/Dev), an editable dev host,
// and data-clearing actions. Reload lives in the navbar, but a Reload row is
// also offered here for completeness. Changing the source or host immediately
// re-loads the web view via onApply.
private struct RemoteSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var web: RemoteWebController
    let onApply: () -> Void

    @AppStorage(RemoteConfig.Keys.useDev,
                store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var useDev: Bool = false
    @AppStorage(RemoteConfig.Keys.devHost,
                store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var devHost: String = RemoteConfig.defaultDevHost

    // Local editing buffer so we only re-load when the user commits the field,
    // not on every keystroke.
    @State private var devHostDraft: String = ""
    @State private var clearedFlash = false
    @State private var resetFlash = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Источник", selection: $useDev) {
                        Text("Prod").tag(false)
                        Text("Dev").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: useDev) { _, _ in onApply() }
                } header: {
                    Text("Источник")
                } footer: {
                    Text(useDev
                         ? "Dev — локальный сервер Mac по LAN (http). Mac должен быть в той же сети."
                         : "Prod — публичный адрес, доступен из любой сети.")
                }

                Section("Prod") {
                    HStack {
                        Text(RemoteConfig.prodURL)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if !useDev {
                            Image(systemName: "checkmark").foregroundStyle(.green)
                        }
                    }
                    .font(.footnote)
                }

                Section {
                    TextField(RemoteConfig.defaultDevHost, text: $devHostDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onSubmit { commitDevHost() }
                    if devHostDraft != currentDevHost {
                        Button("Применить адрес") { commitDevHost() }
                    }
                } header: {
                    Text("Dev адрес")
                } footer: {
                    Text("IP и порт dev-сервера (NOTED_WEB_PORT, обычно 7979). Можно с http:// или без.")
                }

                Section {
                    Button {
                        web.reload()
                        dismiss()
                    } label: {
                        Label("Обновить страницу", systemImage: "arrow.clockwise")
                    }

                    Button {
                        web.clearCookiesAndCache {
                            clearedFlash = true
                            web.reload()
                        }
                    } label: {
                        Label(clearedFlash ? "Куки очищены" : "Очистить куки и кэш",
                              systemImage: clearedFlash ? "checkmark.circle.fill" : "trash")
                    }
                    .tint(clearedFlash ? .green : .blue)

                    Button(role: .destructive) {
                        web.resetAllData {
                            resetFlash = true
                            onApply()   // fresh tokenized load → re-login
                        }
                    } label: {
                        Label(resetFlash ? "Сброшено — свежая сессия" : "Сбросить сайт (всё)",
                              systemImage: resetFlash ? "checkmark.circle.fill" : "arrow.counterclockwise.circle")
                    }
                } header: {
                    Text("Данные")
                } footer: {
                    Text("«Очистить куки и кэш» сохраняет вход (токен подставится сам). «Сбросить сайт» стирает всё, включая сохранённый вход, и сразу логинит заново.")
                }
            }
            .navigationTitle("Remote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { devHostDraft = currentDevHost }
        }
        .preferredColorScheme(.dark)
    }

    private var currentDevHost: String {
        devHost.isEmpty ? RemoteConfig.defaultDevHost : devHost
    }

    private func commitDevHost() {
        let trimmed = devHostDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        devHost = trimmed.isEmpty ? RemoteConfig.defaultDevHost : trimmed
        devHostDraft = currentDevHost
        // Read the source from the store, not the sibling @AppStorage, for the
        // same KVO-lag reason as loadCurrent().
        if RemoteConfig.useDev { onApply() }
    }
}
