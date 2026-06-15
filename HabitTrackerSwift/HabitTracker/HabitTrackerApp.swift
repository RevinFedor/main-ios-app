import SwiftUI
import UIKit

// Channel that carries the measured glass-bar height down to every page. Automatic
// safe-area propagation is BROKEN across the horizontal pager's
// `.frame(width:)` + `.containerRelativeFrame` boundary (the page geometry is
// resolved against the screen, so a `.safeAreaInset` on a page extends off-screen
// and reserves nothing — validated June 2026, ChatGPT-5.5 + Opus 4.8). So we
// measure the bar once at the root and push an explicit inset value into each
// page via the environment; pages reserve with explicit padding / inner-ScrollView
// safeAreaInset using this number.
private struct BottomBarInsetKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
extension EnvironmentValues {
    var bottomBarInset: CGFloat {
        get { self[BottomBarInsetKey.self] }
        set { self[BottomBarInsetKey.self] = newValue }
    }
}

private struct BarHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// Shared geometry of the floating glass bar. The clearance pages reserve is
// derived from these so there is no magic offset duplicated across files: the
// bar dips `floatBelowSafeLine` past the safe-area line (its `.padding(.bottom)`),
// pages reserve `barHeight − floatBelowSafeLine + contentGap` → content lands
// exactly `contentGap` above the bar's top, regardless of device safe area.
// Earlier the clearance was `barHeight + safeArea + 6`, which double-counted the
// home-indicator inset AND the float → ~48pt of dead space (the "слишком большое
// расстояние"). Validated June 2026 (ChatGPT-5.5, 30 sources).
enum RootBar {
    static let sideInset: CGFloat = 22
    static let floatBelowSafeLine: CGFloat = 14
    static let contentGap: CGFloat = 10
}

@main
struct HabitTrackerApp: App {
    @StateObject private var store = HabitStore()
    @StateObject private var recorder = RecordingCoordinator.shared
    @StateObject private var router = TabRouter()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(store)
                .environmentObject(recorder)
                .environmentObject(router)
                .preferredColorScheme(.dark)
                .onOpenURL { url in router.handle(url: url) }
                .task {
                    MainThreadWatchdog.start()
                    router.consumeVoiceTabFlagIfSet()
                    TerminalControlStore.shared.start()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        router.consumeVoiceTabFlagIfSet()
                        TerminalControlStore.shared.start()
                    }
                }
        }
    }
}

// Root shell — Instagram-style: a custom horizontal PAGING container (book-page
// interactive slide between the three tabs, haptic on settle) + a custom Liquid
// Glass bottom bar. We leave the system `TabView` because it cross-dissolves
// by-design and can't slide; a custom pager + custom glass bar is the only way to
// get both the slide AND real glass (validated June 2026: ChatGPT-5.5 + Claude
// Opus 4.8, Apple "Applying Liquid Glass to custom views").
//
// Layout that AVOIDS the earlier clipping bug: the glass bar is drawn ONCE as a
// bottom overlay here, but each tab view reserves matching bottom space via its
// own `.safeAreaInset(.bottom)` (`RootTabBar.height`) — so content scrolls clear
// of the bar instead of under it. The horizontal pager keeps a pristine full-bleed
// frame (no bottom inset on the pager itself — insetting it re-triggers the iOS-26
// non-zero-start offset bug).
//
// `router.selected` is the single source of truth. The pager binds an Int index
// (`scrollPosition(id:)` — the iOS-17 binding, NOT the iOS-26 `ScrollPosition`
// object, which silently no-ops on scrollTo). Start at index 0; the real default
// is also index 0 (.chat), dodging the iOS-26 bug where a non-zero start page
// renders offset under a bottom bar.
struct RootTabView: View {
    @EnvironmentObject var recorder: RecordingCoordinator
    @EnvironmentObject var router: TabRouter
    @Environment(\.verticalSizeClass) private var vSizeClass

    @State private var scrollIndex: Int? = 0
    @State private var barHeight: CGFloat = 0
    // Latch for the [pager-leak] diagnostic: log the leading-overscroll-on-chat-page
    // event once per gesture, re-armed when the offset recovers. Diagnostic only.
    @State private var pagerLeakLatched = false
    // Keyboard visibility drives the bar hide. On the chat page (composer docked
    // at the very bottom), when the keyboard rises the floating glass bar would
    // stack just above it in a messy double-bar (user's Image #3). Instagram /
    // iMessage hide their bottom bar on text focus — we do the same: keep the bar
    // MOUNTED (so its PreferenceKey height never collapses to 0 and feeds back),
    // slide it off + fade + disable hit-testing, and collapse the page clearance
    // to 0 in the SAME keyboard-animation transaction. Research June 2026
    // (ChatGPT-5.5, 30 sources): never `if`-remove the bar, never rely on zIndex
    // (a custom bar can't paint above the system keyboard layer → "faded" look).
    @State private var keyboardAnim: Animation = .easeOut(duration: 0.22)

    private let pages = TabRouter.Tab.allCases   // [.chat, .voice, .habits]

    // Hide the bar only where a bottom-docked composer fights it: the chat page,
    // and only while its composer/search is focused. Driven by FOCUS
    // (`router.chatKeyboardUp`), not by keyboard-frame notifications: focus flips
    // in the same runloop as the composer's own collapse, so bar and composer
    // move together. The old notification-driven path un-hid the bar a beat after
    // the composer dropped — the "криво, сначала вниз, потом появляется чат" bug.
    private var barHidden: Bool { router.chatKeyboardUp && router.selected == .chat }

    var body: some View {
        GeometryReader { geo in
            // Bottom clearance pages reserve below their content. Geometry: the bar
            // overlay and every page both bottom-align to the home-indicator safe
            // line. The bar's `.padding(.bottom, -float)` dips it BELOW that line
            // (into the indicator zone, away from content), so its full measured
            // height sits ABOVE the line — pages reserve exactly that height plus a
            // small visible gap. The old formula added `safeArea + 6` on top, which
            // double-counted the indicator inset (~40pt of dead space → the mic row
            // and composer floated too high). When the keyboard hides the bar,
            // clearance collapses to 0 in the same transaction so the composer drops
            // straight to the keyboard with no leftover reservation.
            let clearance = barHidden ? 0 : barHeight + RootBar.contentGap

            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { idx, tab in
                        pageView(tab)
                            .containerRelativeFrame(.horizontal)   // sizes to the pager; no extra .frame(width:)
                            .id(idx)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $scrollIndex, anchor: .center)
            .scrollIndicators(.hidden)
            // DIAGNOSTIC (no behavior change): catch the "1-in-10 black overscroll".
            // AI Chat is the leftmost page (index 0); a rightward swipe there has
            // nowhere to page, so the pager rubber-bands into empty space = black.
            // That ONLY looks like a bug when the user actually meant "go back a
            // Terminal level" (terminal in a sub-level → canStepBack). When the
            // pager develops a LEADING overscroll (contentOffset.x < 0) on page 0
            // while Terminal could have stepped back, the back-swipe leaked to the
            // pager. Pair this [pager-leak] with [term-swipe-miss] next session to
            // confirm the threshold is the cause and tune it. Only logs the first
            // crossing per gesture (latch) so it can't flood.
            .onScrollGeometryChange(for: Double.self) { geo in
                geo.contentOffset.x
            } action: { _, x in
                let leadingOverscroll = x < -8
                let onChatPage = router.selected == .chat
                let terminalCouldGoBack = TerminalControlStore.shared.canStepBack
                if leadingOverscroll && onChatPage && terminalCouldGoBack {
                    if !pagerLeakLatched {
                        pagerLeakLatched = true
                        VCLog.log("pager-leak", "LEADING overscroll on chat page while terminal canStepBack=true — back-swipe leaked to pager (black area) offsetX=\(Int(x))")
                    }
                } else if x >= -1 {
                    pagerLeakLatched = false   // re-arm once the overscroll recovers
                }
            }
            // Paging-offset fix: ignore ONLY horizontal safe area (the bottom
            // region stays intact for the bar clearance). Both research sources.
            .ignoresSafeArea(.container, edges: .horizontal)
            // Swipe-paging yields while a tab owns horizontal motion (chat drawer
            // open/typing, Habits reorder). Programmatic moves (bar tap) ignore it.
            .scrollDisabled(router.pagingLocked)
            // Push the measured clearance into every page. Automatic safe-area
            // propagation is broken across containerRelativeFrame, so pass an
            // explicit number; pages reserve with .padding(.bottom, clearance) /
            // inner-ScrollView safeAreaInset.
            .environment(\.bottomBarInset, clearance)
        }
        .id(vSizeClass)                              // clean re-snap on rotation (iOS-26 gotcha)
        // NB: NO opaque background here. WWDC25: "remove extra backgrounds /
        // darkening behind the bar — they interfere with the [glass/scroll-edge]
        // effect." Each page paints its own background; leaving a flat dark color
        // behind the bar is exactly what made the glass read as a black capsule.
        // One settled-page haptic, like Instagram's page change.
        .sensoryFeedback(.selection, trigger: router.selected)
        // The glass bar drawn ONCE on top (overlay → zero layout reservation, so
        // it stays fixed while pages slide under it). Its height is measured and
        // fed back via preference → environment so pages know how much to reserve.
        .overlay(alignment: .bottom) {
            RootTabBar(selected: barBinding, isRecording: recorder.isRecording)
                .background(
                    GeometryReader { p in
                        Color.clear.preference(key: BarHeightPreferenceKey.self, value: p.size.height)
                    }
                )
                // Slide the bar fully off-screen + fade when the keyboard hides it.
                // Bar stays mounted (height measurement survives); only its
                // presentation changes, so there's no PreferenceKey→clearance
                // feedback loop. allowsHitTesting off so the hidden bar can't eat
                // taps meant for the composer above the keyboard.
                .offset(y: barHidden ? barHeight + 60 : 0)
                .opacity(barHidden ? 0 : 1)
                .allowsHitTesting(!barHidden)
                .accessibilityHidden(barHidden)
                .animation(keyboardAnim, value: barHidden)
        }
        .onPreferenceChange(BarHeightPreferenceKey.self) { h in
            // Cache only a real measured height; ignore the transient 0 a
            // mounted-but-not-laid-out bar can emit, which would otherwise zero
            // the clearance mid keyboard transition.
            if h > 1 { barHeight = h }
        }
        // Animate page clearance collapse/restore with the keyboard's own curve so
        // the composer drop and the bar slide stay in lockstep (no double anim).
        .animation(keyboardAnim, value: barHidden)
        // Capture the live keyboard curve/duration so the bar slide MATCHES the
        // keyboard's motion. The hide DECISION is focus-driven (router.chatKeyboardUp,
        // flips synchronously); these notifications only refresh the animation used
        // for that transition. willChangeFrame covers open/predictive/interactive,
        // willHide covers dismissal — between them we always have the current curve.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            captureKeyboardCurve(note: note, opening: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { note in
            captureKeyboardCurve(note: note, opening: false)
        }
        .onChange(of: router.chatKeyboardUp) { _, up in
            RootBarLog.log("bar", "chatKeyboardUp=\(up) tab=\(router.selected.rawValue) barHidden=\(up && router.selected == .chat)")
        }
        // Chat-creation progress/error at the ROOT so it survives the Voice→Chat
        // page change the "Chat" button triggers.
        .overlay(alignment: .top) {
            if router.chatCreating {
                HStack(spacing: 8) { ProgressView().tint(.white); Text("Создаю чат…").foregroundStyle(.secondary).font(.caption) }
                    .padding(10).background(.ultraThinMaterial).clipShape(Capsule()).padding(.top, 8)
            }
        }
        .alert("Не удалось создать чат", isPresented: Binding(get: { router.chatCreateError != nil }, set: { if !$0 { router.chatCreateError = nil } })) {
            Button("OK", role: .cancel) { router.chatCreateError = nil }
        } message: { Text(router.chatCreateError ?? "") }
        // Unified settings over the WHOLE app (fullScreenCover, not a per-tab
        // sheet): one component, segmented + swipeable AI Chat·Voice·Habits. The
        // gear on each tab's top-left flips router.showSettings; the visible
        // section is router.settingsSection (seeded from the current tab).
        .fullScreenCover(isPresented: $router.showSettings) {
            AppSettingsSheet()
        }
        .onAppear {
            // Jump from the bug-dodging start index (0) to the real default tab.
            if scrollIndex != router.selectedIndex {
                DispatchQueue.main.async { scrollIndex = router.selectedIndex }
            }
        }
        // Swipe settled → router. The scrollPosition binding lands on the page.
        .onChange(of: scrollIndex) { _, newIndex in
            guard let newIndex, let tab = TabRouter.tab(atIndex: newIndex), tab != router.selected else { return }
            router.selected = tab
        }
        // External selection (bar tap, deep link, dictation handoff) → slide.
        .onChange(of: router.selected) { _, _ in
            let target = router.selectedIndex
            if scrollIndex != target { withAnimation(.snappy(duration: 0.28)) { scrollIndex = target } }
        }
    }

    @ViewBuilder
    private func pageView(_ tab: TabRouter.Tab) -> some View {
        switch tab {
        case .chat:   VoiceChatTabView()
        case .voice:  VoiceRecordTabView()
        case .habits: ContentView()
        }
    }

    private var barBinding: Binding<TabRouter.Tab> {
        Binding(get: { router.selected }, set: { router.selected = $0 })
    }

    // Refresh the animation used for the bar-hide transition from the live
    // keyboard notification. Does NOT decide visibility (that's focus-driven) —
    // it only keeps `keyboardAnim` matched to the keyboard's real curve/duration
    // so the focus-triggered slide rides the same motion as the keyboard.
    private func captureKeyboardCurve(note: Notification, opening: Bool) {
        if let isLocal = note.userInfo?[UIResponder.keyboardIsLocalUserInfoKey] as? Bool, !isLocal { return }
        keyboardAnim = rootKeyboardAnimation(note: note, opening: opening)
    }

    // Map the keyboard's duration/curve from userInfo to a SwiftUI animation.
    // Mirrors the chat composer's proven curve handling (private curve 7 on iOS
    // 26 has no faithful SwiftUI mapping → front-loaded open / easeOut close).
    private func rootKeyboardAnimation(note: Notification, opening: Bool) -> Animation {
        let rawDuration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let duration = rawDuration <= 0.01 ? 0.22 : rawDuration
        let rawCurve = note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int ?? -1
        if rawCurve == 7 {
            if opening {
                let adjusted = min(0.28, max(0.18, duration * 0.70))
                return .timingCurve(0.17, 0.84, 0.44, 1.0, duration: adjusted)
            }
            return .easeOut(duration: duration)
        }
        if let curve = UIView.AnimationCurve(rawValue: rawCurve) {
            let t = UICubicTimingParameters(animationCurve: curve)
            return .timingCurve(Double(t.controlPoint1.x), Double(t.controlPoint1.y),
                                Double(t.controlPoint2.x), Double(t.controlPoint2.y), duration: duration)
        }
        return .easeOut(duration: duration)
    }
}

// Lightweight logger for the root bar/keyboard transitions — routes into the
// same on-device + Mac ios-chat.log channel the chat uses, so the user can grep
// `[bar]` next to `[Keyboard]` when the bottom layout misbehaves.
enum RootBarLog {
    static func log(_ tag: String, _ msg: String) {
        VCLog.log(tag, msg)
    }
}

extension UIApplication {
    static var vcKeyWindow: UIWindow? {
        shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
}

// Custom bottom bar with real Liquid Glass (iOS 26) / material fallback (iOS 18).
// Floats above the home indicator with a side inset, so the page background shows
// through underneath — Instagram-style. ONE glass surface (capsule); the three
// buttons inside are plain (glass cannot sample glass). Voice shows the REC badge
// + mic.fill only for DICTATION (recorder.isRecording is the dictation slot only).
struct RootTabBar: View {
    @Binding var selected: TabRouter.Tab
    let isRecording: Bool
    // Namespace for the sliding selection pill. The pill is ONE logical view
    // (matchedGeometryEffect) that animates its frame from the old tab slot to
    // the new one — a segmented-control / Instagram feel. It's a PLAIN tinted
    // Capsule, NOT glass: glass-on-glass samples muddy (research June 2026,
    // Opus 4.8 + WWDC25). Attached to exactly one item at a time (the selected
    // one) — rendering it on >1 item triggers the "multiple isSource" jump.
    @Namespace private var pillNS

    var body: some View {
        let row = HStack(spacing: 0) {
            item(.chat, "AI Chat", "bubble.left.and.bubble.right")
            item(.voice, "Voice", isRecording ? "mic.fill" : "mic", recording: isRecording)
            item(.habits, "Habits", "checklist")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)      // ~10% smaller than before (was 9)
        // Animate the sliding pill for EVERY selection change — bar tap AND
        // swipe-paging (which sets router.selected outside a withAnimation, so the
        // pill would otherwise jump). This is the "небольшая анимация" requested.
        .animation(.snappy(duration: 0.3, extraBounce: 0.06), value: selected)
        .animation(.easeInOut(duration: 0.2), value: isRecording)

        Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 12) {
                    row.glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
                }
            } else {
                row
                    .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                    .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
            }
        }
        .padding(.horizontal, RootBar.sideInset)   // slightly narrower bar (more side inset)
        // Lower the bar: sit it closer to the bottom edge. The overlay respects
        // the home-indicator safe area (~34pt); dipping `floatBelowSafeLine` past
        // it halves the visible gap. This EXACT value is subtracted back in the
        // page clearance formula, so content lands `contentGap` above the bar top.
        .padding(.bottom, -RootBar.floatBelowSafeLine)
    }

    private func item(_ tab: TabRouter.Tab, _ title: String, _ symbol: String, recording: Bool = false) -> some View {
        let isSelected = selected == tab
        return Button {
            selected = tab   // pill animates via .animation(value: selected) above
        } label: {
            VStack(spacing: 2) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: symbol)
                        .font(.system(size: 20))
                        .frame(height: 24)
                    if recording {
                        Text("REC")
                            .font(.system(size: 8, weight: .heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(Color(hex: "ef4444")))
                            .offset(x: 16, y: -6)
                    }
                }
                Text(title)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.5))
            .background {
                if isSelected {
                    // Sliding selection pill — one logical view via matchedGeometry.
                    // PLAIN tinted capsule (not glass) to avoid glass-on-glass.
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.16))
                        .matchedGeometryEffect(id: "tabSelectionPill", in: pillNS)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
