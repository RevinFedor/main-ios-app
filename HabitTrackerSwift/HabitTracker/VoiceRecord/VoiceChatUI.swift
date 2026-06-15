import SwiftUI
import UIKit

// ─────────────────────────────────────────────────────────────────────────────
// Voice Chat — NATIVE UI (replaces the WKWebView tab).
//
// Why native: instant open (no site load over the tunnel), native scroll.
// Architecture follows the researched 2026 consensus for our scale (50-200
// messages, NO token streaming — answers arrive whole): SwiftUI ScrollView +
// LazyVStack is sufficient; the heavy-chat escalation path (UICollectionView +
// ChatLayout) is not needed yet. Two scars ported from mobile-web on day one:
//   • follow-bottom is an INTENT (disarmed only by the user's own drag-up,
//     never by content growth) — here the intent signal is native:
//     onScrollPhaseChange(.interacting) instead of scroll-delta heuristics;
//   • markdown is parsed ONCE per message id (cached), never on every render.
// ─────────────────────────────────────────────────────────────────────────────

private let VCAccent = Color(hex: "7c3aed")
private let VCPageBackground = Color(white: 0.055)
private let VCHeaderBackground = Color(white: 0.055)

private final class VCWeakViewBox: ObservableObject {
    weak var view: UIView?
}

private struct VCHostingUIViewReader: UIViewRepresentable {
    let onResolve: (UIView) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async { onResolve(view) }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async { onResolve(uiView) }
    }
}

// Chat titles are auto-derived from the first assistant text and often carry
// raw markdown ("**Жирный**…"). Strip inline syntax for clean display in lists
// and navbars (the transcript itself renders markdown properly).
func vcCleanTitle(_ s: String?) -> String {
    guard var t = s, !t.isEmpty else { return "Без названия" }
    t = t.replacingOccurrences(of: "**", with: "")
    t = t.replacingOccurrences(of: "__", with: "")
    t = t.replacingOccurrences(of: "`", with: "")
    t = t.replacingOccurrences(of: "#", with: "")
    while t.hasPrefix("*") || t.hasPrefix("_") || t.hasPrefix(" ") { t.removeFirst() }
    return t.isEmpty ? "Без названия" : t
}

// "31.05 14:22" — compact list/date stamp.
let vcDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "dd.MM HH:mm"
    return f
}()

// MARK: - Composer option sets (mirror desktop prompt.tsx; shared with the
// prompt picker header in VoiceChat.swift)

struct VCModelOpt: Identifiable { let key: String; let label: String; var id: String { key } }
let VC_MODELS: [VCModelOpt] = [
    .init(key: "flash", label: "Flash 3.5"),
    .init(key: "lite", label: "Flash-Lite 3.1"),
    .init(key: "pro", label: "Pro 3.1"),
    .init(key: "flash3", label: "Flash 3"),
]
let VC_THINKING: [VCModelOpt] = [
    .init(key: "NONE", label: "Off"), .init(key: "LOW", label: "Low"),
    .init(key: "MEDIUM", label: "Med"), .init(key: "HIGH", label: "High"),
]

func vcCompactModelLabel(_ key: String) -> String {
    switch key {
    case "pro": return "P3.1"
    case "lite": return "L3.1"
    case "flash3": return "F3"
    default: return "F3.5"
    }
}

func vcCompactThinkLabel(_ key: String) -> String {
    switch key {
    case "HIGH": return "H"
    case "MEDIUM": return "M"
    case "LOW": return "L"
    default: return "O"
    }
}

// Compact chip with a dropdown Menu — the composer's model/think control,
// reused by the prompt picker header (selection must NOT close the sheet,
// which Menu guarantees: it presents inline over the current context).
struct VCOptionChip: View {
    let icon: String
    let options: [VCModelOpt]
    @Binding var value: String
    var activeWhenNot: String? = nil   // e.g. think ≠ NONE → accent tint

    private var label: String { options.first { $0.key == value }?.label ?? options.first?.label ?? "" }
    private var selectedLabel: String {
        if options.contains(where: { $0.key == "NONE" }) { return vcCompactThinkLabel(value) }
        return vcCompactModelLabel(value)
    }
    private var isActive: Bool { activeWhenNot.map { value != $0 } ?? false }

    var body: some View {
        Menu {
            ForEach(options) { o in
                Button { value = o.key } label: {
                    if value == o.key { Label(o.label, systemImage: "checkmark") } else { Text(o.label) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11))
                Text(selectedLabel).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.6)
            }
            .foregroundStyle(isActive ? VCAccent : Color(hex: "c9c9cf"))
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color(white: 0.12)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(isActive ? VCAccent : Color(white: 0.17)))
        }
    }
}

struct VCPresetSwitchButton: View {
    @Binding var activePreset: Int
    @Binding var model: String
    @Binding var think: String
    var showsText = true

    var body: some View {
        Button {
            let current = VoiceChatConfig.normalizedPreset(activePreset)
            let next = current == 1 ? 2 : 1
            activePreset = next
            model = VoiceChatConfig.storedPresetModel(next)
            think = VoiceChatConfig.storedPresetThink(next)
            VoiceChatConfig.applyMobileModelPreset(next)
        } label: {
            HStack(spacing: showsText ? 5 : 0) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: showsText ? 10 : 12, weight: .bold))
                if showsText {
                    Text("Switch")
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                }
            }
            .frame(width: showsText ? nil : 34, height: showsText ? nil : 31)
            .foregroundStyle(Color(hex: "111111"))
            .padding(.horizontal, showsText ? 10 : 0).padding(.vertical, showsText ? 7 : 0)
            .background(Capsule(style: .continuous).fill(Color.white.opacity(0.92)))
            .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Switch model preset")
    }
}

private enum HistoryDrawerTarget: Equatable {
    case closed
    case open

    func offset(width: CGFloat) -> CGFloat {
        switch self {
        case .closed: return 0
        case .open: return width
        }
    }
}

private enum HistoryDrawerPhase: Equatable {
    case closed
    case draggingOpen
    case open
    case draggingClosed
    case settling(to: HistoryDrawerTarget)
}

private struct HistoryDrawerPanEnd {
    let startOffset: CGFloat
    let currentOffset: CGFloat
    let velocityX: CGFloat
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}

private final class HistoryDrawerPanRecognizer: UIPanGestureRecognizer {
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        if preventedGestureRecognizer.isScrollViewPanGesture { return true }
        return super.canPrevent(preventedGestureRecognizer)
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        if preventingGestureRecognizer.isScrollViewPanGesture { return false }
        return super.canBePrevented(by: preventingGestureRecognizer)
    }
}

private extension UIGestureRecognizer {
    var isScrollViewPanGesture: Bool {
        guard let scrollView = view as? UIScrollView else { return false }
        return scrollView.panGestureRecognizer === self
    }
}

@available(iOS 18.0, *)
private struct HistoryDrawerPanGesture: UIGestureRecognizerRepresentable {
    let drawerWidth: CGFloat
    let currentOffset: CGFloat
    let isEnabled: Bool
    let fullScreenOpenEnabled: Bool
    let navigationCanGoBack: Bool
    let textInputActive: Bool
    let edgeActivationWidth: CGFloat
    let onBegan: (CGFloat) -> Void
    let onChanged: (CGFloat) -> Void
    let onEnded: (HistoryDrawerPanEnd) -> Void
    let onCancelled: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> HistoryDrawerPanRecognizer {
        let recognizer = HistoryDrawerPanRecognizer()
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = true
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = context.coordinator
        context.coordinator.configuration = self
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: HistoryDrawerPanRecognizer, context: Context) {
        context.coordinator.configuration = self
    }

    func handleUIGestureRecognizerAction(_ recognizer: HistoryDrawerPanRecognizer, context: Context) {
        context.coordinator.handle(recognizer)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var configuration: HistoryDrawerPanGesture?
        private var startOffset: CGFloat = 0

        func handle(_ recognizer: HistoryDrawerPanRecognizer) {
            guard let configuration,
                  let view = recognizer.view,
                  configuration.drawerWidth > 0 else { return }

            let width = configuration.drawerWidth

            switch recognizer.state {
            case .began:
                startOffset = configuration.currentOffset.clamped(to: 0...width)
                configuration.onBegan(startOffset)
            case .changed:
                let translationX = recognizer.translation(in: view).x
                configuration.onChanged(rubberBand(startOffset + translationX, width: width))
            case .ended:
                let translationX = recognizer.translation(in: view).x
                configuration.onEnded(
                    HistoryDrawerPanEnd(
                        startOffset: startOffset,
                        currentOffset: (startOffset + translationX).clamped(to: 0...width),
                        velocityX: recognizer.velocity(in: view).x
                    )
                )
            case .cancelled, .failed:
                configuration.onCancelled()
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let configuration,
                  configuration.isEnabled,
                  configuration.drawerWidth > 1,
                  let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = gestureRecognizer.view else { return false }

            let width = configuration.drawerWidth
            let offset = configuration.currentOffset.clamped(to: 0...width)
            let translation = pan.translation(in: view)
            let velocity = pan.velocity(in: view)

            let translationLooksHorizontal =
                abs(translation.x) >= 8 &&
                abs(translation.x) >= abs(translation.y) * 0.75
            let velocityLooksHorizontal =
                abs(velocity.x) >= 220 &&
                abs(velocity.x) >= abs(velocity.y) * 0.80

            guard translationLooksHorizontal || velocityLooksHorizontal else { return false }

            let isClosed = offset <= 1
            let isOpen = offset >= width - 1
            let isPartiallyOpen = !isClosed && !isOpen

            if isPartiallyOpen { return true }

            if isClosed {
                guard !configuration.navigationCanGoBack else { return false }
                // Rightward → open the drawer. Leftward-when-closed is declined so
                // the ROOT pager (RootTabView) owns the chat→Voice page slide.
                guard translation.x > 0 || velocity.x > 0 else { return false }

                if !configuration.fullScreenOpenEnabled {
                    return pan.location(in: view).x <= configuration.edgeActivationWidth
                }
                return true
            }

            if isOpen {
                return translation.x < 0 || velocity.x < -120
            }

            return false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            guard let configuration else { return false }

            if viewChainContains(touch.view, where: { view in
                view is UITextField ||
                view is UITextView ||
                String(describing: type(of: view)).contains("UISearchTextField")
            }) {
                return false
            }

            if configuration.currentOffset <= 1,
               viewChainContains(touch.view, where: { $0 is UIControl }) {
                return false
            }

            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            false
        }

        private func viewChainContains(_ view: UIView?, where predicate: (UIView) -> Bool) -> Bool {
            var current = view
            while let view = current {
                if predicate(view) { return true }
                current = view.superview
            }
            return false
        }

        private func rubberBand(_ proposed: CGFloat, width: CGFloat) -> CGFloat {
            let limit: CGFloat = 28
            if proposed < 0 {
                return -min(limit, rubberDistance(-proposed, dimension: width))
            }
            if proposed > width {
                return width + min(limit, rubberDistance(proposed - width, dimension: width))
            }
            return proposed
        }

        private func rubberDistance(_ distance: CGFloat, dimension: CGFloat) -> CGFloat {
            let dimension = max(dimension, 1)
            let constant: CGFloat = 0.55
            return (1 - (1 / ((distance * constant / dimension) + 1))) * dimension
        }
    }
}

// MARK: - Tab root: chat detail + side history drawer

struct VoiceChatTabView: View {
    @EnvironmentObject var router: TabRouter
    @ObservedObject private var store = VoiceChatStore.shared
    private let terminal = TerminalControlStore.shared   // @Observable singleton (Phase C)
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.bottomBarInset) private var bottomBarInset

    @State private var selectedChatId: String? = nil
    @State private var draftToken = UUID()
    @State private var handledSeq: UUID? = nil
    @State private var drawerPhase: HistoryDrawerPhase = .closed
    @State private var drawerOffset: CGFloat = 0
    @State private var scrollLockedByDrawer = false
    @State private var drawerAnimationToken = UUID()
    @State private var showingAllChats = false
    @State private var renameTarget: VCChatMeta? = nil
    @State private var chatComposerFocused = false
    @State private var terminalMode = false
    @State private var terminalComposerFocused = false
    @State private var allChatsSearchActive = false

    @AppStorage(VoiceChatConfig.Keys.uiFont,
                store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var uiFont: Double = 14

    private var textInputActive: Bool {
        chatComposerFocused || terminalComposerFocused || allChatsSearchActive
    }

    // Coarse lock for the root pager: only while the user types or the history
    // drawer is open/dragging. NOT for the Terminal back-swipe.
    //
    // Terminal back-swipe is handled by a UIKit recognizer (TerminalBackPanGesture)
    // that arbitrates directionally with the root pager via canPrevent: rightward
    // → it claims the gesture and prevents the pager's scroll pan (back a level);
    // leftward → it declines so the pager pages to Voice. Locking the pager on
    // `canStepBack` (an earlier attempt) was wrong twice over: it killed
    // leftward→Voice on the tabs/chat level, and toggling .scrollDisabled as
    // canStepBack flipped at the projects boundary re-laid-out the ScrollView
    // mid-animation — the jerk the user saw "именно на проектах".
    private var pagingShouldLock: Bool {
        textInputActive || drawerPhase != .closed
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularSplitLayout
            } else {
                compactDrawerLayout
            }
        }
        .tint(.white)
        .background(VCPageBackground.ignoresSafeArea())
        // NB: no outer .safeAreaInset here — the page is inside the pager's
        // containerRelativeFrame so it'd extend off-screen, and the ignoresSafeArea
        // background above would reset it anyway. The chat reserves bar space
        // internally: composer dock lifted by bottomBarInset + transcript bottom
        // sentinel grown by it.
        // Drive the root pager's coarse lock: the history drawer (rightward-open),
        // composer/search typing, and Terminal back-swipe own horizontal motion on
        // this surface, so the page-swipe must yield while any is active.
        .onChange(of: pagingShouldLock) { _, lock in
            router.pagingLocked = lock
            VCLog.log("bar", "pagingLocked=\(lock) reason[input=\(textInputActive) drawer=\(drawerPhase != .closed)]")
        }
        // Focus-driven bar hide: the moment the composer/search is focused, tell
        // the root shell to slide its glass bar away (and back on blur). Synchronous
        // with focus so the bar and the keyboard-lifted composer move together — no
        // notification lag. Mirrors textInputActive; terminal composer included.
        .onChange(of: textInputActive) { _, active in
            router.chatKeyboardUp = active
            VCLog.log("bar", "textInputActive=\(active) chatFocus=\(chatComposerFocused) termFocus=\(terminalComposerFocused) search=\(allChatsSearchActive)")
        }
        .onAppear {
            store.start()
            terminal.start()
            consumePending()
            router.pagingLocked = pagingShouldLock
            router.chatKeyboardUp = textInputActive
        }
        .onDisappear {
            router.pagingLocked = false
            router.chatKeyboardUp = false
        }
        .onChange(of: router.pendingChatRequest) { _, _ in consumePending() }
        .onChange(of: router.selected) { _, sel in
            if sel == .chat {
                store.start()
                terminal.start()
                consumePending()
                router.pagingLocked = pagingShouldLock
                router.chatKeyboardUp = textInputActive
            } else {
                router.pagingLocked = false   // never freeze paging on another tab
                router.chatKeyboardUp = false // and always restore the bar off-chat
            }
        }
        .onChange(of: scenePhase) { _, p in
            if p == .active {
                store.start()
                terminal.start()
            }
        }
        .sheet(item: $renameTarget) { chat in
            VoiceChatTitleEditorSheet(
                initialTitle: chat.title ?? "",
                placeholder: vcCleanTitle(chat.title)
            ) { title in
                store.updateChatTitle(chat.id, title: title)
            }
        }
    }

    private var compactDrawerLayout: some View {
        GeometryReader { geo in
            let drawerWidth = preferredDrawerWidth(in: geo.size)
            let visualOffset = drawerOffset.clamped(to: -28...(drawerWidth + 28))
            let clampedOffset = visualOffset.clamped(to: 0...drawerWidth)
            let progress = drawerWidth == 0 ? 0 : clampedOffset / drawerWidth

            ZStack(alignment: .leading) {
                VCPageBackground.ignoresSafeArea()

                NavigationStack {
                    chatContent(
                        onShowSidebar: { openHistory(width: drawerWidth) },
                        onSelectChat: { id in selectChat(id, closeWidth: drawerWidth) },
                        onNewChat: { startNewChat(closeWidth: drawerWidth) }
                    )
                }
                .offset(x: visualOffset)
                .background(VCPageBackground.ignoresSafeArea())
                .overlay {
                    if progress > 0 {
                        Color.black.opacity(0.2 * progress)
                            .ignoresSafeArea(.container, edges: [.top, .horizontal])
                            .contentShape(Rectangle())
                            .onTapGesture { closeHistory(width: drawerWidth) }
                            .accessibilityLabel("Close chat history")
                            .accessibilityAddTraits(.isButton)
                    }
                }
                .accessibilityHidden(progress > 0.5)

                historyDrawer(width: drawerWidth)
                    .frame(width: drawerWidth)
                    .offset(x: -drawerWidth + visualOffset)
                    .accessibilityHidden(progress < 0.02)
            }
            .clipped()
            .contentShape(Rectangle())
            .scrollDisabled(scrollLockedByDrawer)
            .gesture(
                HistoryDrawerPanGesture(
                    drawerWidth: drawerWidth,
                    currentOffset: clampedOffset,
                    isEnabled: true,
                    fullScreenOpenEnabled: true,
                    navigationCanGoBack: terminalMode && terminal.canStepBack,
                    textInputActive: textInputActive,
                    edgeActivationWidth: 28,
                    onBegan: { startOffset in beginDrawerDrag(startOffset: startOffset, width: drawerWidth) },
                    onChanged: { newOffset in updateDrawerDrag(to: newOffset, width: drawerWidth) },
                    onEnded: { end in endDrawerDrag(end, width: drawerWidth) },
                    onCancelled: { cancelDrawerDrag(width: drawerWidth) }
                )
            )
            .onChange(of: drawerWidth) { _, newWidth in
                normalizeDrawerForWidthChange(newWidth)
            }
        }
    }

    private var regularSplitLayout: some View {
        NavigationSplitView {
            historyDrawer(width: 340)
                .frame(minWidth: 280, idealWidth: 340, maxWidth: 420)
        } detail: {
            NavigationStack {
                chatContent(
                    onShowSidebar: {},
                    onSelectChat: { id in selectChat(id, closeWidth: nil) },
                    onNewChat: { startNewChat(closeWidth: nil) }
                )
            }
        }
    }

    @ViewBuilder
    private func chatContent(onShowSidebar: @escaping () -> Void,
                             onSelectChat: @escaping (String) -> Void,
                             onNewChat: @escaping () -> Void) -> some View {
        if terminalMode {
            TerminalControlRootView(
                onShowHistory: onShowSidebar,
                onComposerFocusChange: { focused in terminalComposerFocused = focused },
                swipeBackEnabled: !terminalComposerFocused
            )
        } else if showingAllChats {
            AllChatsView(
                selectedChatId: selectedChatId,
                onShowSidebar: onShowSidebar,
                onSelectChat: onSelectChat,
                onNewChat: onNewChat,
                onRename: { chat in renameTarget = chat },
                onSearchActiveChange: { active in allChatsSearchActive = active }
            )
        } else {
            ChatDetailView(
                initialChatId: selectedChatId,
                onChatIdChange: { id in selectedChatId = id },
                onShowHistory: onShowSidebar,
                onComposerFocusChange: { focused in chatComposerFocused = focused }
            )
            .id(chatIdentity)
        }
    }

    private var chatIdentity: String {
        "detail-" + draftToken.uuidString
    }

    private func preferredDrawerWidth(in size: CGSize) -> CGFloat {
        let desired = size.width * 0.90
        let maxAllowed = max(0, size.width - 44)
        return min(max(280, desired), maxAllowed)
    }

    private func beginDrawerDrag(startOffset: CGFloat, width: CGFloat) {
        if startOffset < width * 0.5 {
            dismissChatKeyboard()
        }
        drawerAnimationToken = UUID()
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            drawerOffset = startOffset.clamped(to: 0...width)
            drawerPhase = startOffset < width * 0.5 ? .draggingOpen : .draggingClosed
            scrollLockedByDrawer = true
        }
    }

    private func updateDrawerDrag(to newOffset: CGFloat, width: CGFloat) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            drawerOffset = newOffset
            let clamped = newOffset.clamped(to: 0...width)
            drawerPhase = clamped < width * 0.5 ? .draggingOpen : .draggingClosed
        }
    }

    private func endDrawerDrag(_ end: HistoryDrawerPanEnd, width: CGFloat) {
        settleDrawer(to: drawerTarget(for: end, width: width), velocityX: end.velocityX, width: width)
    }

    private func cancelDrawerDrag(width: CGFloat) {
        let target: HistoryDrawerTarget = drawerOffset > width * 0.5 ? .open : .closed
        settleDrawer(to: target, velocityX: 0, width: width)
    }

    private func openHistory(width: CGFloat) {
        dismissChatKeyboard()
        Task { await store.refreshChats() }
        settleDrawer(to: .open, velocityX: 0, width: width)
    }

    private func closeHistory(width: CGFloat) {
        settleDrawer(to: .closed, velocityX: 0, width: width)
    }

    private func resetDrawerClosed() {
        drawerAnimationToken = UUID()
        scrollLockedByDrawer = false
        drawerPhase = .closed
        drawerOffset = 0
    }

    private func drawerTarget(for end: HistoryDrawerPanEnd, width: CGFloat) -> HistoryDrawerTarget {
        guard width > 0 else { return .closed }

        let velocity = end.velocityX
        let current = end.currentOffset.clamped(to: 0...width)
        let projected = (current + velocity * 0.18).clamped(to: 0...width)
        let flingThreshold: CGFloat = 650

        if abs(velocity) >= flingThreshold {
            return velocity > 0 ? .open : .closed
        }

        if end.startOffset < width * 0.5 {
            return projected > width * 0.32 ? .open : .closed
        } else {
            return projected > width * 0.68 ? .open : .closed
        }
    }

    private func settleDrawer(to target: HistoryDrawerTarget, velocityX: CGFloat, width: CGFloat) {
        let token = UUID()
        drawerAnimationToken = token
        let destination = target.offset(width: width)
        let duration: UInt64 = reduceMotion ? 140_000_000 : 340_000_000
        let animation: Animation = reduceMotion
            ? .easeOut(duration: 0.12)
            : .interpolatingSpring(mass: 1.0, stiffness: 420, damping: 38,
                                   initialVelocity: velocityX / max(width, 1))

        scrollLockedByDrawer = true
        withAnimation(animation) {
            drawerPhase = .settling(to: target)
            drawerOffset = destination
        }

        Task {
            try? await Task.sleep(nanoseconds: duration)
            await MainActor.run {
                guard drawerAnimationToken == token else { return }
                drawerPhase = target == .open ? .open : .closed
                drawerOffset = destination
                scrollLockedByDrawer = false
            }
        }
    }

    private func normalizeDrawerForWidthChange(_ newWidth: CGFloat) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            switch drawerPhase {
            case .open:
                drawerOffset = newWidth
            case .closed:
                drawerOffset = 0
            case .settling(let target):
                drawerOffset = target.offset(width: newWidth)
            case .draggingOpen, .draggingClosed:
                drawerOffset = drawerOffset.clamped(to: 0...newWidth)
            }
        }
    }

    private func dismissChatKeyboard() {
        chatComposerFocused = false
        terminalComposerFocused = false
        allChatsSearchActive = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func startNewChat(closeWidth width: CGFloat?) {
        selectedChatId = nil
        draftToken = UUID()
        showingAllChats = false
        terminalMode = false
        terminalComposerFocused = false
        if let width { closeHistory(width: width) } else { resetDrawerClosed() }
    }

    private func selectChat(_ id: String, closeWidth width: CGFloat?) {
        selectedChatId = id
        draftToken = UUID()
        showingAllChats = false
        terminalMode = false
        terminalComposerFocused = false
        if let width { closeHistory(width: width) } else { resetDrawerClosed() }
    }

    private func showAllChats(closeWidth width: CGFloat?) {
        showingAllChats = true
        terminalMode = false
        terminalComposerFocused = false
        if let width { closeHistory(width: width) } else { resetDrawerClosed() }
    }

    private func openTerminal(closeWidth width: CGFloat?) {
        dismissChatKeyboard()
        showingAllChats = false
        terminalMode = true
        terminal.start()
        if let width { closeHistory(width: width) } else { resetDrawerClosed() }
    }

    // Drawer Terminal row tap. Toggle: in Terminal → back to the chat surface
    // (selectedChatId is preserved, so we land on the last open chat / new chat);
    // otherwise enter Terminal mode.
    private func toggleTerminal(closeWidth width: CGFloat?) {
        if terminalMode {
            dismissChatKeyboard()
            terminalComposerFocused = false
            terminalMode = false
            if let width { closeHistory(width: width) } else { resetDrawerClosed() }
        } else {
            openTerminal(closeWidth: width)
        }
    }

    private func consumePending() {
        guard let req = router.pendingChatRequest, handledSeq != req.seq else { return }
        handledSeq = req.seq
        selectedChatId = req.chatId
        draftToken = UUID()
        showingAllChats = false
        terminalMode = false
        terminalComposerFocused = false
        resetDrawerClosed()
    }

    private func historyDrawer(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("AI Chat")
                    .font(.system(size: uiFont + 2, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                // Settings moved out of the drawer to the tab's top-left gear
                // (unified app-wide settings). Drawer header is title-only now.
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(VCHeaderBackground)

            ScrollView {
                LazyVStack(spacing: 8) {
                    sidebarActionRow(
                        title: "Chats",
                        subtitle: "\(store.chats.count)",
                        icon: "bubble.left.and.bubble.right",
                        action: { showAllChats(closeWidth: width) }
                    )

                    // Terminal row is a toggle: off → enter Terminal mode; on
                    // (purple) → tapping again returns to the chat surface. Same
                    // single entry point the user already knows, now bidirectional.
                    sidebarActionRow(
                        title: "Terminal",
                        subtitle: terminal.loadingProjects ? "…" : "\(terminal.projects.count)",
                        icon: "terminal",
                        active: terminalMode,
                        action: { toggleTerminal(closeWidth: width) }
                    )

                    Text("Recent")
                        .font(.system(size: uiFont - 2, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .padding(.top, 6)
                        .padding(.bottom, 2)

                    if store.offline {
                        offlineView
                            .frame(height: 260)
                    } else if store.chats.isEmpty {
                        Text("Пока нет чатов.")
                            .foregroundStyle(.secondary)
                            .font(.system(size: uiFont))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    } else {
                        ForEach(Array(store.chats.prefix(14))) { chat in
                            VCChatListRow(
                                chat: chat,
                                selected: chat.id == selectedChatId,
                                uiFont: uiFont,
                                running: store.running.contains(chat.id),
                                onTap: { selectChat(chat.id, closeWidth: width) },
                                onRename: { renameTarget = chat },
                                onDelete: { store.deleteChat(chat.id) }
                            )
                        }
                    }

                    sidebarActionRow(title: "All chats", icon: "rectangle.stack",
                                     action: { showAllChats(closeWidth: width) })
                        .padding(.top, 8)
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 20)
            }
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
        }
        .background(VCPageBackground.ignoresSafeArea())
        .overlay(alignment: .bottomTrailing) {
            floatingNewChatButton(action: { startNewChat(closeWidth: width) })
                .padding(.trailing, 14)
                // Lift above the root glass bar (user: "New Chat в выдвижной
                // панели повыше поднять"). bottomBarInset already carries the gap.
                .padding(.bottom, bottomBarInset)
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.white.opacity(0.12)).frame(width: 0.5)
        }
    }


    private func floatingNewChatButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .bold))
                Text("New Chat")
                    .font(.system(size: uiFont, weight: .semibold))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Capsule(style: .continuous).fill(.white))
            .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
        }
        .buttonStyle(.plain)
    }

    // `active` paints the row in the accent (used by the Terminal row when Terminal
    // mode is on — it's a toggle: tap again to return to chat). Inactive rows keep
    // the neutral translucent surface.
    private func sidebarActionRow(title: String, subtitle: String? = nil, icon: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 20)
                    .foregroundStyle(active ? VCAccent : .white)
                Text(title)
                    .font(.system(size: uiFont, weight: .semibold))
                Spacer()
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: uiFont - 2).monospacedDigit())
                        .foregroundStyle(active ? VCAccent.opacity(0.9) : .secondary)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(active ? VCAccent.opacity(0.22) : Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(active ? VCAccent.opacity(0.55) : Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }

    private var offlineView: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.slash").font(.system(size: 44)).foregroundStyle(.white.opacity(0.5))
            Text("Хост недоступен").font(.title3.weight(.semibold)).foregroundStyle(.white)
            Text("Mac не отвечает — приложение не запущено или нет связи.")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 36)
            Button { Task { await store.refreshChats() } } label: {
                Label("Повторить", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(Color(hex: "8AB4F8"))
            .padding(.horizontal, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct VCChatListRow: View {
    let chat: VCChatMeta
    let selected: Bool
    let uiFont: Double
    let running: Bool
    let onTap: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(vcCleanTitle(chat.title))
                        .font(.system(size: uiFont, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if running {
                        ProgressView().controlSize(.small).tint(VCAccent)
                    }
                }
                HStack(spacing: 6) {
                    if let ts = chat.updatedAt {
                        Text(vcDateFormatter.string(from: Date(timeIntervalSince1970: ts / 1000)))
                    }
                    if let n = chat.userCount, n > 0 {
                        Text("·")
                        Text("\(n) итер.")
                    }
                }
                .font(.system(size: uiFont - 3).monospacedDigit())
                .foregroundStyle(.secondary.opacity(0.85))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? VCAccent.opacity(0.22) : Color.white.opacity(0.065))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? VCAccent.opacity(0.55) : Color.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(action: onRename) {
                Label("Rename", systemImage: "pencil")
            }
            Button { UIPasteboard.general.string = chat.id } label: {
                Label("Copy ID", systemImage: "number")
            }
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

private struct AllChatsView: View {
    let selectedChatId: String?
    let onShowSidebar: () -> Void
    let onSelectChat: (String) -> Void
    let onNewChat: () -> Void
    let onRename: (VCChatMeta) -> Void
    var onSearchActiveChange: (Bool) -> Void = { _ in }

    @ObservedObject private var store = VoiceChatStore.shared
    @EnvironmentObject private var router: TabRouter
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @Environment(\.bottomBarInset) private var bottomBarInset

    @AppStorage(VoiceChatConfig.Keys.uiFont,
                store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var uiFont: Double = 14

    private var searchEngaged: Bool {
        searchFocused || !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filteredChats: [VCChatMeta] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return store.chats }
        return store.chats.filter { chat in
            vcCleanTitle(chat.title).localizedCaseInsensitiveContains(q) ||
            chat.id.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        ZStack {
            VCPageBackground.ignoresSafeArea()

            if store.offline {
                VStack(spacing: 14) {
                    Image(systemName: "wifi.slash").font(.system(size: 44)).foregroundStyle(.white.opacity(0.5))
                    Text("Хост недоступен").font(.title3.weight(.semibold)).foregroundStyle(.white)
                    Text("Mac не отвечает — приложение не запущено или нет связи.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 36)
                    Button { Task { await store.refreshChats() } } label: {
                        Label("Повторить", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(Color(hex: "8AB4F8"))
                    .padding(.horizontal, 48)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if filteredChats.isEmpty {
                            Text(search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Пока нет чатов." : "Ничего не найдено.")
                                .foregroundStyle(.secondary)
                                .font(.system(size: uiFont))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 12)
                        }
                        ForEach(filteredChats) { chat in
                            VCChatListRow(
                                chat: chat,
                                selected: chat.id == selectedChatId,
                                uiFont: uiFont,
                                running: store.running.contains(chat.id),
                                onTap: { onSelectChat(chat.id) },
                                onRename: { onRename(chat) },
                                onDelete: { store.deleteChat(chat.id) }
                            )
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    // Clear the floating New Chat + search dock AND the root bar.
                    .padding(.bottom, bottomBarInset + 92)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .overlay(alignment: .bottom) {
            VStack(alignment: .trailing, spacing: 10) {
                if !searchEngaged {
                    allChatsNewButton
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
                }
                allChatsSearchField
            }
            .padding(.horizontal, 16)
            // Lift the New Chat + search dock above the root glass bar; when the
            // search keyboard is up the bar hides, so drop to a small constant.
            .padding(.bottom, searchFocused ? 16 : bottomBarInset)
            .contentShape(Rectangle())
            .background(Color.black.opacity(0.001))
            .onTapGesture { }
            .animation(.easeInOut(duration: 0.16), value: searchEngaged)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                // Settings gear (was the drawer hamburger). Drawer = swipe-only.
                Button { router.openSettings() } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 16, weight: .semibold))
                }
            }
            ToolbarItem(placement: .principal) {
                Text("Chats")
                    .font(.system(size: uiFont, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .toolbarBackground(VCHeaderBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .onAppear { Task { await store.refreshChats() } }
        .onChange(of: searchFocused) { _, _ in onSearchActiveChange(searchEngaged) }
        .onChange(of: search) { _, _ in onSearchActiveChange(searchEngaged) }
        .onDisappear { onSearchActiveChange(false) }
    }

    private var allChatsNewButton: some View {
        Button(action: onNewChat) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .bold))
                Text("New Chat")
                    .font(.system(size: uiFont, weight: .semibold))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Capsule(style: .continuous).fill(.white))
            .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var allChatsSearchField: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 10) {
                allChatsSearchFieldBody
            }
        } else {
            allChatsSearchFieldBody
        }
    }

    private var allChatsSearchFieldBody: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.secondary)

                TextField("Search", text: $search)
                    .font(.system(size: max(15, uiFont + 1)))
                    .foregroundStyle(.primary)
                    .tint(.white)
                    .focused($searchFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .frame(maxWidth: .infinity)
            .vcLiquidGlassCapsuleSurface()
            .shadow(color: .black.opacity(0.20), radius: 12, y: 5)

            if searchEngaged {
                Button {
                    if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        searchFocused = false
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    } else {
                        search = ""
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: 48, height: 48)
                        .vcLiquidGlassCircleSurface()
                        .shadow(color: .black.opacity(0.20), radius: 12, y: 5)
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
                .accessibilityLabel(search.isEmpty ? "Dismiss search" : "Clear search")
                .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .trailing)))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Chat detail (transcript + composer)

struct ChatDetailView: View {
    let initialChatId: String?          // nil → draft, id minted on first send
    let onChatIdChange: (String?) -> Void
    let onShowHistory: () -> Void
    let onComposerFocusChange: (Bool) -> Void
    @ObservedObject private var store = VoiceChatStore.shared
    @EnvironmentObject var router: TabRouter
    @Environment(\.bottomBarInset) private var bottomBarInset

    @State private var chatId: String? = nil
    @State private var input = ""
    @State private var showPicker = false
    @State private var showGTPicker = false
    @State private var promptAttachments: [VCAttachment] = []
    @State private var gtAttachments: [VCAttachment] = []
    @State private var gtPreviewTarget: GTFilePreviewTarget? = nil
    @State private var showRename = false
    @State private var secs = 0
    // Follow-bottom INTENT: only the user's own drag can disarm it; content
    // growth can't (it never produces an .interacting phase).
    @State private var followBottom = true
    @State private var userTouching = false
    @State private var distFromBottom: CGFloat = 0
    @StateObject private var hostViewBox = VCWeakViewBox()
    @State private var keyboardVisible = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var baseBottomInset: CGFloat = 0
    // Set when the app drives its OWN keyboard dismissal (Send / hide button /
    // offline). The proactive collapse already animated the composer down; the
    // system willChangeFrame/willHide that follows must NOT re-animate the same
    // value with a different curve, or the composer bobbles "down→up→down". The
    // flag swallows that redundant second animation for a short window.
    @State private var suppressSystemKeyboardHideUntil: Date = .distantPast
    // Measured height of the docked composer (input + tool row + any attachment/
    // confirm strips). The bottom scroll sentinel is sized to THIS instead of a
    // fixed 142, so the gap between the last message and the input is exact — no
    // oversized dead space (the "слишком большой отступ" the user noticed).
    @State private var composerDockHeight: CGFloat = 0
    @State private var optimisticMessages: [VCMessage] = []
    @State private var localSending = false
    // Auto-send arming: when true the trailing send button is a purple spinner
    // and the next dictation insert auto-submits instead of just landing in the
    // field. Armed by tap-on-empty or the long-press popover; cleared on send,
    // cancel-tap, leaving the chat, or going offline.
    @State private var autoSendArmed = false
    @FocusState private var composerFocused: Bool

    @AppStorage(VoiceChatConfig.Keys.model, store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var model = "flash"
    @AppStorage(VoiceChatConfig.Keys.think, store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var think = "NONE"
    @AppStorage(VoiceChatConfig.Keys.activePreset, store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var activePreset = 1
    @AppStorage(VoiceChatConfig.Keys.bypass, store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var bypass = true
    @AppStorage(VoiceChatConfig.Keys.chatFont,
                store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var chatFont: Double = 15
    @AppStorage(VoiceChatConfig.Keys.uiFont,
                store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var uiFont: Double = 14

    private var conv: VCConversation? { chatId.flatMap { store.conversations[$0] } }
    private var isRunning: Bool { chatId.map { store.running.contains($0) } ?? false }
    private var effectiveRunning: Bool { isRunning || localSending }
    private var liveTools: [VCToolCall] { chatId.flatMap { store.liveTools[$0] } ?? [] }
    private var turnError: String? { chatId.flatMap { store.turnError[$0] } }
    private var pendingConfirms: [VCConfirmRequest] { chatId.flatMap { store.confirms[$0] } ?? [] }
    private var runningBgTasks: [VCBackgroundTask] { store.bgTasks.filter { $0.running } }
    private var displayedMessages: [VCMessage] {
        let real = conv?.messages ?? []
        let pending = optimisticMessages.filter { local in
            !real.contains { isSameUserEcho(real: $0, local: local) }
        }
        return real + pending
    }

    private func isSameUserEcho(real: VCMessage, local: VCMessage) -> Bool {
        guard real.role == "user", local.role == "user", real.content == local.content else { return false }
        return attachmentSignature(real.attachments) == attachmentSignature(local.attachments)
    }

    private func attachmentSignature(_ atts: [VCAttachment]?) -> String {
        (atts ?? []).map { [$0.kind, $0.name, $0.filePath ?? "", $0.promptId ?? "", $0.variationId ?? ""].joined(separator: "|") }
            .joined(separator: ";;")
    }

    init(initialChatId: String?,
         onChatIdChange: @escaping (String?) -> Void = { _ in },
         onShowHistory: @escaping () -> Void = {},
         onComposerFocusChange: @escaping (Bool) -> Void = { _ in }) {
        self.initialChatId = initialChatId
        self.onChatIdChange = onChatIdChange
        self.onShowHistory = onShowHistory
        self.onComposerFocusChange = onComposerFocusChange
        _chatId = State(initialValue: initialChatId)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                VCPageBackground.ignoresSafeArea()
                ScrollViewReader { proxy in
                    ZStack {
                        if store.offline {
                            chatOfflineBlock
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 10) {
                                    if displayedMessages.isEmpty && conv == nil && chatId == nil {
                                        draftHint
                                    }
                                    ForEach(displayedMessages) { msg in
                                        MessageView(msg: msg, chatFont: chatFont, onPreviewAttachment: openGtPreview)
                                            .id(msg.id)
                                    }
                                    // Live tool cards of the in-flight turn.
                                    ForEach(liveTools) { tc in
                                        ToolCardView(tool: tc, chatFont: chatFont, defaultOpen: tc.isRunning || tc.isError)
                                    }
                                    if let err = turnError {
                                        Text(err)
                                            .font(.system(size: chatFont - 2))
                                            .foregroundStyle(Color(hex: "f87171"))
                                            .padding(.horizontal, 10)
                                    }
                                    if effectiveRunning {
                                        HStack(spacing: 8) {
                                            ProgressView().controlSize(.small).tint(VCAccent)
                                            Text(localSending && liveTools.isEmpty ? "отправляю…" : (liveTools.isEmpty ? "думаю…" : "агент работает…"))
                                                .font(.system(size: chatFont - 2)).foregroundStyle(.secondary)
                                            // Elapsed derives from the store's turn START time,
                                            // not a local counter — surviving tab switches and
                                            // remounts (the "секундомер сбрасывается" bug).
                                            // `secs` is only the 1Hz re-render tick.
                                            if let t0 = chatId.flatMap({ store.turnStartedAt[$0] }) {
                                                let _ = secs
                                                Text("\(max(0, Int(Date().timeIntervalSince(t0))))s")
                                                    .font(.system(size: chatFont - 3).monospacedDigit())
                                                    .foregroundStyle(.secondary.opacity(0.7))
                                            }
                                        }
                                        .padding(.horizontal, 10).padding(.vertical, 4)
                                    }
                                    // Sentinel = real composer height (measured) +
                                    // a small gap, so the last message sits just
                                    // above the input. The composer is lifted by
                                    // bottomBarInset when the keyboard is down, so
                                    // include that; fall back to 132 until measured.
                                    Color.clear
                                        .frame(height: (composerDockHeight > 1 ? composerDockHeight : 132) + bottomBarInset + 12)
                                        .id("BOTTOM")
                                }
                                .padding(.horizontal, 8)
                                .padding(.top, 10)
                            }
                            .defaultScrollAnchor(.bottom)
                            .scrollDismissesKeyboard(.interactively)
                            .onScrollPhaseChange { _, newPhase in
                                userTouching = (newPhase == .tracking || newPhase == .interacting)
                                // Disarm only from the user's own gesture, away from bottom.
                                if userTouching && distFromBottom > 120 { followBottom = false }
                            }
                            .onScrollGeometryChange(for: CGFloat.self) { geo in
                                geo.contentSize.height - geo.containerSize.height - geo.contentOffset.y
                            } action: { _, dist in
                                distFromBottom = dist
                                if userTouching {
                                    if dist > 120 { followBottom = false }
                                    else if dist <= 60 { followBottom = true }
                                }
                            }
                            .onChange(of: displayedMessages.count) { _, _ in pin(proxy) }
                            .onChange(of: liveTools.count) { _, _ in pin(proxy) }
                            .onChange(of: effectiveRunning) { _, _ in pin(proxy) }
                            .onChange(of: pendingConfirms.count) { _, _ in pin(proxy) }
                        }
                    }
                    .overlay(alignment: .bottom) {
                        composerDock(proxy: proxy, keyboardLift: keyboardLift(in: geo))
                            .background(
                                GeometryReader { p in
                                    Color.clear.preference(key: ComposerDockHeightKey.self, value: p.size.height)
                                }
                            )
                    }
                    .onPreferenceChange(ComposerDockHeightKey.self) { h in
                        if h > 1 { composerDockHeight = h }
                    }
                }
            }
            .background {
                VCHostingUIViewReader { view in
                    hostViewBox.view = view
                }
            }
            .onAppear {
                rememberBaseBottomInset(geo.safeAreaInsets.bottom)
            }
            .onChange(of: geo.safeAreaInsets.bottom) { _, inset in
                rememberBaseBottomInset(inset)
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                // Top-left is the unified Settings gear now (was the drawer
                // hamburger). The history drawer opens ONLY by left→right swipe
                // (see VoiceChatTabView pan) — the button slot is reused for the
                // app-wide settings present on every tab.
                Button { router.openSettings() } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 16, weight: .semibold))
                }
            }
            // Title + (iterations) subtitle. Width-capped so it can't collide
            // with the trailing By-pass control.
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(chatId == nil ? "Новый чат" : vcCleanTitle(conv?.title))
                        .font(.system(size: uiFont, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1).truncationMode(.tail)
                    if let conv, !conv.messages.isEmpty {
                        let users = conv.messages.filter { $0.role == "user" }.count
                        Text("\(users) итер.")
                            .font(.system(size: max(9, uiFont - 4)))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 190)
                .contentShape(Rectangle())
                // Long-press on the title — lightweight chat actions without
                // entering a separate edit mode.
                .contextMenu {
                    if let id = chatId {
                        Button { showRename = true } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button { UIPasteboard.general.string = id } label: {
                            Label("Copy ID", systemImage: "number")
                        }
                        Button { UIPasteboard.general.string = fullChatText() } label: {
                            Label("Copy Full Chat", systemImage: "doc.on.doc")
                        }
                    }
                }
            }
            // By-pass lives in the navbar (the composer row had no room — model/
            // think labels were truncating). Custom compact 2-row control: a
            // small toggle over a "By-pass" caption — NOT a system Toggle (iOS
            // wraps that in a bordered circle in toolbars). On iOS 26 the
            // toolbar additionally wraps EVERY item in a Liquid-Glass circle —
            // sharedBackgroundVisibility(.hidden) opts this item out (the pill
            // already has its own visual, the glass ring was double chrome).
            if #available(iOS 26.0, *) {
                ToolbarItem(placement: .navigationBarTrailing) {
                    BypassPill(on: $bypass)
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigationBarTrailing) {
                    BypassPill(on: $bypass)
                }
            }
        }
        .toolbarBackground(VCHeaderBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .onAppear {
            VoiceChatConfig.ensureMobileModelPresetDefaults()
            store.setActiveComposer(chatId: chatId)
            consumePendingDictationInsert()
        }
        .onDisappear {
            onComposerFocusChange(false)
            store.clearActiveComposer(chatId: chatId)
            autoSendArmed = false   // arming is ephemeral to this composer surface
        }
        .task {
            if let id = initialChatId, let conv = await store.loadConversation(id), let b = conv.bypass {
                bypass = b
            }
        }
        .onChange(of: chatId) { oldValue, newValue in
            store.updateActiveComposer(from: oldValue, to: newValue)
            onChatIdChange(newValue)
            consumePendingDictationInsert()
        }
        // Existing chats carry live server-side By-pass state. A draft uses the
        // global AppStorage default until the first send creates its chat id.
        .onChange(of: chatId.flatMap { store.bypassByChat[$0] }) { _, serverValue in
            guard let serverValue, bypass != serverValue else { return }
            bypass = serverValue
        }
        .onChange(of: bypass) { _, value in
            guard let id = chatId else { return }
            store.setBypass(chatId: id, bypass: value)
        }
        // Stop-before-reply → the server unwound the turn and sent the typed
        // text back; put it into the composer (don't clobber anything the user
        // already started typing).
        .onChange(of: chatId.flatMap { store.restoredInput[$0] }) { _, restored in
            guard let restored, let id = chatId else { return }
            if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { input = restored }
            store.restoredInput[id] = nil
        }
        .onChange(of: store.pendingComposerInsert) { _, _ in
            consumePendingDictationInsert()
        }
        .onChange(of: composerFocused) { _, focused in
            VCLog.log("Keyboard", "composer focus=\(focused)")
            onComposerFocusChange(focused)
        }
        .onChange(of: store.offline) { _, offline in
            if offline { dismissKeyboard(); autoSendArmed = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            updateKeyboard(from: note)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { note in
            beginKeyboardHide(from: note)
        }
        // 1Hz tick while the turn runs: re-renders the elapsed label (which
        // derives from store.turnStartedAt, so it survives tab switches), and
        // every 8th tick re-fetches the conversation — belt-and-braces against
        // a lost SSE event (zombie pipe): pendingConfirms / messages / running
        // all ride on that GET, so the UI self-heals within seconds.
        .task(id: effectiveRunning) {
            secs = 0
            guard effectiveRunning else { return }
            while !Task.isCancelled && effectiveRunning {
                try? await Task.sleep(for: .seconds(1))
                secs += 1
                if secs % 8 == 0, let id = chatId {
                    await store.loadConversation(id)
                }
            }
        }
        .sheet(isPresented: $showPicker) {
            VoiceChatPromptPicker(
                onPick: { pid, vid, label in
                    showPicker = false
                    addPromptAttachment(promptId: pid, variationId: vid, label: label)
                },
                onSkip: nil,
                showsModelHeader: false
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showGTPicker) {
            VoiceChatGTFilePicker { att, closeAfterPick in
                addGtAttachment(att)
                if closeAfterPick { showGTPicker = false }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $gtPreviewTarget) { target in
            GTFilePreviewSheet(attachment: target.attachment)
                .presentationDetents([.large])
                .presentationContentInteraction(.scrolls)
        }
        .sheet(isPresented: $showRename) {
            VoiceChatTitleEditorSheet(
                initialTitle: conv?.title ?? "",
                placeholder: vcCleanTitle(conv?.title)
            ) { title in
                if let id = chatId { store.updateChatTitle(id, title: title) }
            }
        }
    }

    private func pin(_ proxy: ScrollViewProxy) {
        guard followBottom else { return }
        // Instant exact landing (scar: animated/eased scrolls undershoot).
        // Pin in the SAME runloop for the common case, then once more after a
        // yield: a row appended in this update isn't measured yet, so the first
        // scrollTo can resolve against stale geometry (DTS: "can't scroll to an
        // item added in the same update"). The deferred re-pin lands against the
        // materialized row. Both no-animation. followBottom re-checked after the
        // yield so a user who grabbed the scroll mid-flight isn't yanked back.
        proxy.scrollTo("BOTTOM", anchor: .bottom)
        Task { @MainActor in
            await Task.yield()
            guard followBottom else { return }
            proxy.scrollTo("BOTTOM", anchor: .bottom)
        }
    }

    private var draftHint: some View {
        VStack(spacing: 6) {
            Text("💬").font(.system(size: 30))
            Text("Новый чат").font(.system(size: uiFont + 1)).foregroundStyle(.secondary)
            Text("Напиши сообщение или выбери промпт ниже.")
                .font(.system(size: uiFont - 2)).foregroundStyle(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }

    private var chatOfflineBlock: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.5))
            Text("Mac недоступен")
                .font(.system(size: uiFont + 4, weight: .semibold))
                .foregroundStyle(.white)
            Text("Voice Record на Mac не отвечает. Сообщения нельзя отправлять, пока связь не восстановится.")
                .font(.system(size: uiFont - 1))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34)
            Button { Task { await store.refreshChats() } } label: {
                Label("Повторить", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(hex: "8AB4F8"))
            .padding(.horizontal, 52)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 80)
    }

    private func composerDock(proxy: ScrollViewProxy, keyboardLift: CGFloat) -> some View {
        VStack(spacing: 8) {
            ForEach(pendingConfirms) { req in
                ConfirmCardView(req: req, chatFont: chatFont) { approve in
                    store.answerConfirm(req, ok: approve)
                }
            }
            if !runningBgTasks.isEmpty {
                BackgroundTaskTrayView(tasks: runningBgTasks, chatFont: chatFont)
            }
            ZStack {
                if shouldShowScrollToBottomButton {
                    keyboardActionButton(systemName: "arrow.down.to.line") {
                        scrollToBottom(proxy)
                    }
                    .accessibilityLabel("Scroll to bottom")
                    .transition(.opacity.combined(with: .scale(scale: CGFloat(0.92))))
                }
                keyboardDismissButton
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            // Collapse to zero height when the keyboard is DOWN: these buttons only
            // act while typing, but a constant 36pt row reserved dead space between
            // the last message and the input even when invisible — the persistent
            // "слишком большой отступ". Now it occupies layout only when keyboard up.
            .frame(height: keyboardVisible ? 36 : 0)
            .padding(.horizontal, 10)
            .opacity(keyboardVisible ? 1 : 0)
            .allowsHitTesting(keyboardVisible)
            .clipped()
            composer
                .disabled(store.offline)
                .opacity(store.offline ? 0.45 : 1)
        }
        // Lift the composer above the root glass bar when the keyboard is DOWN
        // (when it's up, the keyboard lift already clears the bar). Without this
        // the composer sat at the screen edge, fully under the bar.
        .offset(y: -(keyboardLift + (keyboardVisible ? 0 : bottomBarInset)))
        .animation(.easeInOut(duration: 0.16), value: shouldShowScrollToBottomButton)
    }

    private func keyboardLift(in geo: GeometryProxy) -> CGFloat {
        let baseline = baseBottomInset > 0 ? baseBottomInset : geo.safeAreaInsets.bottom
        return keyboardVisible ? max(0, keyboardHeight - baseline) : 0
    }

    private func rememberBaseBottomInset(_ inset: CGFloat) {
        guard !keyboardVisible else { return }
        baseBottomInset = inset
        VCLog.log("Keyboard", "baseBottomInset=\(Int(inset))")
    }

    private var shouldShowScrollToBottomButton: Bool {
        keyboardVisible && distFromBottom > 180
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        followBottom = true
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo("BOTTOM", anchor: .bottom)
        }
    }

    private func updateKeyboard(from note: Notification) {
        guard let view = hostViewBox.view, let window = view.window else { return }
        if let screen = note.object as? UIScreen, screen != window.screen { return }
        guard let endFrame = note.vcKeyboardEndFrame else { return }

        let sourceScreen = (note.object as? UIScreen) ?? window.screen
        let keyboardFrameInWindow = window.convert(endFrame, from: sourceScreen.coordinateSpace)
        let intersection = window.bounds.intersection(keyboardFrameInWindow)
        let height = intersection.isNull || intersection.isEmpty ? 0 : intersection.height
        let visible = height > 0.5
        // App-owned dismiss already animated the collapse: swallow the redundant
        // system HIDE frame (a SHOW must always pass through so opening animates).
        if !visible, Date() < suppressSystemKeyboardHideUntil {
            keyboardHeight = 0
            keyboardVisible = false
            VCLog.log("Keyboard", "willChangeFrame HIDE suppressed (app-owned collapse owns it)")
            return
        }
        let animation = note.vcKeyboardAnimation(opening: visible)
        var transaction = Transaction(animation: animation)
        transaction.disablesAnimations = false
        withTransaction(transaction) {
            keyboardHeight = visible ? height : 0
            keyboardVisible = visible
        }
        let baseline = baseBottomInset
        let lift = visible ? max(0, height - baseline) : 0
        VCLog.log(
            "Keyboard",
            "frameEnd=\(endFrame.vcDebug) inWindow=\(keyboardFrameInWindow.vcDebug) window=\(window.bounds.vcDebug) reader=\(view.bounds.vcDebug) safeBase=\(Int(baseline)) height=\(Int(height)) lift=\(Int(lift)) visible=\(visible) curve=\(note.vcKeyboardCurveDebug)"
            + " anim=\(note.vcKeyboardAnimationDebug(opening: visible))"
        )
    }

    private func beginKeyboardHide(from note: Notification) {
        // App-owned dismiss already ran its collapse animation — don't re-animate.
        if Date() < suppressSystemKeyboardHideUntil {
            keyboardHeight = 0
            keyboardVisible = false
            VCLog.log("Keyboard", "willHide suppressed (app-owned collapse owns it)")
            return
        }
        let priorHeight = keyboardHeight
        let priorLift = max(0, priorHeight - baseBottomInset)
        let animation = note.vcKeyboardAnimation(opening: false, zeroDurationFallback: 0.22)
        var transaction = Transaction(animation: animation)
        transaction.disablesAnimations = false
        withTransaction(transaction) {
            keyboardHeight = 0
            keyboardVisible = false
        }
        VCLog.log(
            "Keyboard",
            "willHide priorHeight=\(Int(priorHeight)) priorLift=\(Int(priorLift)) safeBase=\(Int(baseBottomInset)) curve=\(note.vcKeyboardCurveDebug)"
            + " anim=\(note.vcKeyboardAnimationDebug(opening: false, zeroDurationFallback: 0.22))"
        )
    }

    private func collapseKeyboardDock(reason: String, duration: Double = 0.16) {
        guard keyboardVisible || keyboardHeight > 0 else { return }
        // Own this dismissal: swallow the system willChangeFrame/willHide that
        // arrives in the next ~0.35s so the composer animates down exactly once.
        suppressSystemKeyboardHideUntil = Date().addingTimeInterval(0.35)
        let priorHeight = keyboardHeight
        let priorLift = max(0, priorHeight - baseBottomInset)
        var transaction = Transaction(animation: .easeOut(duration: duration))
        transaction.disablesAnimations = false
        withTransaction(transaction) {
            keyboardHeight = 0
            keyboardVisible = false
        }
        VCLog.log(
            "Keyboard",
            "collapse reason=\(reason) priorHeight=\(Int(priorHeight)) priorLift=\(Int(priorLift)) safeBase=\(Int(baseBottomInset)) anim=proactive/easeOut/\(String(format: "%.3f", duration))"
        )
    }

    // ── Composer: input row + tool row (model · think · switch · prompt · send/stop) ──
    private var composer: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if !composerAttachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(composerAttachments) { att in
                                ComposerAttachmentChip(
                                    attachment: att,
                                    onPreview: { openGtPreview(att) },
                                    onRemove: { removeComposerAttachment(att) }
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 30)
                }

                TextField("Спроси что-нибудь…", text: $input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .font(.system(size: max(15, chatFont)))   // ≥15 чтобы iOS не зумил поле
                    .foregroundStyle(.white)
                    .focused($composerFocused)
                    .frame(minHeight: 32, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            VCLog.log("Keyboard", "input tap focused=\(composerFocused) visible=\(keyboardVisible) height=\(Int(keyboardHeight))")
                            if !composerFocused { composerFocused = true }
                        }
                    )

                HStack(spacing: 6) {
                    VCOptionChip(icon: "cpu", options: VC_MODELS, value: $model)
                    VCOptionChip(icon: "brain", options: VC_THINKING, value: $think, activeWhenNot: "NONE")
                    VCPresetSwitchButton(activePreset: $activePreset, model: $model, think: $think, showsText: false)
                    Button { showPicker = true } label: {
                        composerIconButton(active: !promptAttachments.isEmpty) {
                            Image(systemName: "text.quote")
                                .font(.system(size: 14, weight: .semibold))
                        }
                    }
                    Button { showGTPicker = true } label: {
                        composerIconButton(active: !gtAttachments.isEmpty) {
                            VCGTGlyph(size: 20)
                        }
                    }
                    Spacer(minLength: 0)
                    if effectiveRunning {
                        Button { if let id = chatId { store.stopTurn(id) } } label: {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 38, height: 38)
                                .background(Circle().fill(Color(hex: "ef4444")))
                        }
                        .disabled(chatId == nil)
                    } else {
                        ComposerSendButton(
                            hasDraft: hasDraftPayload,
                            armed: autoSendArmed,
                            accent: VCAccent,
                            onSend: { send(promptId: nil, variationId: nil) },
                            onArm: { autoSendArmed = true },
                            onCancelArm: { autoSendArmed = false }
                        )
                    }
                }
            }
            .padding(.horizontal, 13)
            .padding(.top, composerAttachments.isEmpty ? 14 : 12)
            .padding(.bottom, 10)
            .vcLiquidGlassRoundedSurface(cornerRadius: 28)
        }
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 8)
    }

    private var keyboardDismissButton: some View {
        keyboardActionButton(systemName: "keyboard.chevron.compact.down") {
            dismissKeyboard()
        }
        .accessibilityLabel("Hide keyboard")
    }

    private func keyboardActionButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .frame(width: 36, height: 32)
                .vcLiquidGlassRoundedSurface(cornerRadius: 12)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func composerIconButton<Content: View>(active: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        content()
            .foregroundStyle(active ? VCAccent : Color(hex: "c9c9cf"))
            .frame(width: 34, height: 34)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(white: 0.12)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(active ? VCAccent : Color(white: 0.17)))
    }

    private var composerAttachments: [VCAttachment] {
        promptAttachments + gtAttachments
    }

    private var hasDraftPayload: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !promptAttachments.isEmpty ||
        !gtAttachments.isEmpty
    }

    private func consumePendingDictationInsert() {
        guard let insert = store.pendingComposerInsert,
              insert.targetKey == VoiceChatStore.composerKey(for: chatId) else { return }
        appendToComposer(insert.text)
        // consume nils out pendingComposerInsert (seq-guarded) → idempotent even
        // if a view rebuild re-runs this handler before the send completes.
        store.consumeDictationInsert(insert)
        // Armed → auto-submit the freshly-appended draft. Disarm FIRST so a
        // second insert during the send round-trip can't re-fire (research E).
        if autoSendArmed {
            autoSendArmed = false
            send(promptId: nil, variationId: nil)
        }
    }

    private func appendToComposer(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let current = input.trimmingCharacters(in: .whitespacesAndNewlines)
        input = current.isEmpty ? trimmed : current + "\n\n" + trimmed
    }

    private func dismissKeyboard() {
        collapseKeyboardDock(reason: "dismissKeyboard")
        composerFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    // Plain-text export of the whole conversation (Copy Full Chat).
    private func fullChatText() -> String {
        guard let conv else { return "" }
        var out: [String] = []
        if let t = conv.title { out.append("# " + vcCleanTitle(t)); out.append("") }
        for m in conv.messages {
            out.append(m.role == "user" ? "## User" : "## Assistant")
            if let atts = m.attachments, !atts.isEmpty {
                out.append("(промпт: " + atts.map(\.name).joined(separator: ", ") + ")")
            }
            if let tools = m.toolCalls, !tools.isEmpty {
                for tc in tools { out.append("[tool] " + tc.displayName + " " + tc.preview) }
            }
            if let thinking = m.thinking, !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append("[thinking]")
                out.append(thinking)
            }
            if !m.content.isEmpty { out.append(m.content) }
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    private func send(promptId: String?, variationId: String?) {
        guard !store.offline else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentPromptAttachments = promptAttachments
        let sendPromptId = promptId ?? sentPromptAttachments.first?.promptId
        let sendVariationId = variationId ?? sentPromptAttachments.first?.variationId
        let attachments = gtAttachments
        guard !text.isEmpty || sendPromptId != nil || !attachments.isEmpty else { return }
        // Scroll-jump-on-send fix (research June 2026, ChatGPT-5.5 33 src + Opus
        // 4.8). The bug: the optimistic append fires pin()→scrollTo(.bottom) in the
        // SAME runloop as dismissKeyboard()'s full-screen safe-area collapse, and
        // `.defaultScrollAnchor(.bottom)` re-anchors on that size change — over
        // variable-height rows this is FB20979569, an iOS-26-only regression
        // (fine on iOS 18). Net: content lurches up ~a keyboard-height, new row
        // lands off-screen-top. Fix = DON'T dismiss the keyboard in the same
        // transaction as the append. Arm follow-bottom + append first so the pin
        // lands against stable (keyboard-up) geometry; defer dismissKeyboard to
        // the next runloop. NOT switching to safeAreaInset — the overlay composer
        // is the documented keyboard model (fact-voice-chat-tab.md::Composer keyboard).
        followBottom = true
        let optimistic = VCMessage(
            id: "local-" + UUID().uuidString,
            role: "user",
            content: text,
            attachments: sentPromptAttachments + attachments,
            createdAt: Date().timeIntervalSince1970 * 1000
        )
        optimisticMessages = [optimistic]
        localSending = true
        input = ""
        promptAttachments = []
        gtAttachments = []
        Task { @MainActor in
            await Task.yield()      // let the append + bottom-pin commit first
            dismissKeyboard()       // THEN collapse the keyboard — no coincident scrollTo
        }
        Task {
            do {
                let id = try await store.send(chatId: chatId, text: text, promptId: sendPromptId,
                                              variationId: sendVariationId, model: model, thinkingLevel: think,
                                              bypass: bypass, attachments: attachments)
                localSending = false
                optimisticMessages = []
                chatId = id
                onChatIdChange(id)
            } catch {
                localSending = false
                optimisticMessages = []
                if input.isEmpty { input = text }
                if promptAttachments.isEmpty { promptAttachments = sentPromptAttachments }
                if gtAttachments.isEmpty { gtAttachments = attachments }
                if let id = chatId {
                    store.turnError[id] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    private func addPromptAttachment(promptId: String, variationId: String?, label: String) {
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanVariation = variationId?.trimmingCharacters(in: .whitespacesAndNewlines)
        promptAttachments = [
            VCAttachment(
                kind: "prompt",
                name: cleanLabel.isEmpty ? "Промпт" : cleanLabel,
                promptId: promptId,
                variationId: cleanVariation?.isEmpty == true ? nil : cleanVariation
            )
        ]
    }

    private func addGtAttachment(_ att: VCAttachment) {
        guard let path = att.filePath else { return }
        if gtAttachments.contains(where: { $0.filePath == path }) { return }
        gtAttachments.append(att)
    }

    private func removeComposerAttachment(_ att: VCAttachment) {
        if att.kind == "prompt" {
            promptAttachments.removeAll { $0.id == att.id }
        } else if att.kind == "gtfile" {
            gtAttachments.removeAll { $0.id == att.id }
        }
    }

    private func openGtPreview(_ att: VCAttachment) {
        guard att.kind == "gtfile", att.filePath != nil else { return }
        gtPreviewTarget = GTFilePreviewTarget(attachment: att)
    }
}

// MARK: - One message

struct ComposerAttachmentChip: View {
    let attachment: VCAttachment
    let onPreview: () -> Void
    let onRemove: () -> Void

    private var isPrompt: Bool { attachment.kind == "prompt" }
    private var isGTFile: Bool { attachment.kind == "gtfile" }
    private var tint: Color { isPrompt ? VCAccent : Color(hex: "22d3ee") }
    private var foreground: Color { isPrompt ? Color(hex: "ede9fe") : Color(hex: "cffafe") }

    var body: some View {
        HStack(spacing: 5) {
            if isGTFile {
                Button(action: onPreview) {
                    label
                }
                .buttonStyle(.plain)
            } else {
                label
            }

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.18)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.45)))
    }

    private var label: some View {
        HStack(spacing: 5) {
            if isPrompt {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
            } else {
                VCGTGlyph(size: 18)
            }
            Text(attachment.displayName)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
    }
}

struct GTFilePreviewTarget: Identifiable {
    let attachment: VCAttachment
    var id: String { attachment.filePath ?? attachment.id }
}

private struct MessageView: View {
    let msg: VCMessage
    let chatFont: Double
    let onPreviewAttachment: (VCAttachment) -> Void
    @State private var showFullUserMessage = false
    private let userPreviewLimit = 12_000
    private let assistantPreviewLimit = 16_000

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Attachment chips above a user message — desktop parity: per-kind
            // color + label (context chips show the SOURCE APP: "Yandex",
            // gtfile — the filename, paste — "Вставка", prompt — its title).
            // Wrapping flow layout not needed at our chip counts; trailing
            // HStack matches the desktop's right-aligned chip row.
            if msg.role == "user", let atts = msg.attachments, !atts.isEmpty {
                HStack(spacing: 4) {
                    Spacer(minLength: 20)
                    ForEach(atts) { a in
                        VCChipView(att: a, onPreview: onPreviewAttachment)
                    }
                }
            }

            // Assistant artifacts (thinking, tools), then the final text. This
            // order mirrors desktop claude-blocks: reasoning first, actions next.
            if msg.role == "assistant" {
                if let thinking = msg.thinking?.trimmingCharacters(in: .whitespacesAndNewlines), !thinking.isEmpty {
                    ThinkingCardView(text: thinking, chatFont: chatFont)
                }
                if let tools = msg.toolCalls, !tools.isEmpty {
                    ForEach(tools) { tc in
                        ToolCardView(tool: tc, chatFont: chatFont, defaultOpen: tc.isError)
                    }
                }
            }

            if msg.role == "user" {
                if !msg.content.trimmingCharacters(in: .whitespaces).isEmpty {
                    HStack {
                        Spacer(minLength: 40)
                        // Real .contextMenu (iMessage-style), NOT textSelection's
                        // legacy balloon: long-press → the bubble LIFTS (slight
                        // scale-up) → haptic → menu. All three come free from the
                        // system interaction; textSelection's menu had none.
                        // contextMenuPreview shape = the bubble's rounded rect so
                        // the lifted preview doesn't flash square corners (same
                        // scar as the history cards' cardCornerRadius).
                        VStack(alignment: .trailing, spacing: 6) {
                            Text(vcClippedText(msg.content, maxCharacters: userPreviewLimit))
                                .font(.system(size: chatFont))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 14).fill(VCAccent.opacity(0.28)))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(VCAccent.opacity(0.4)))
                                .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .contextMenu {
                                    Button { UIPasteboard.general.string = msg.content } label: {
                                        Label("Copy", systemImage: "doc.on.doc")
                                    }
                                }
                            if vcTextExceeds(msg.content, maxCharacters: userPreviewLimit) {
                                Button { showFullUserMessage = true } label: {
                                    Label("Full", systemImage: "doc.text.magnifyingglass")
                                        .font(.system(size: max(11, chatFont - 3), weight: .semibold))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(VCAccent)
                            }
                        }
                    }
                }
            } else {
                if !msg.content.isEmpty {
                    VCMarkdownView(messageId: msg.id, markdown: msg.content, fontSize: chatFont, maxCharacters: assistantPreviewLimit)
                        .contextMenu {
                            Button { UIPasteboard.general.string = msg.content } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                        }
                }
                if msg.stopped == true {
                    Label("остановлено", systemImage: "stop.circle")
                        .font(.system(size: chatFont - 4))
                        .foregroundStyle(.secondary.opacity(0.75))
                }
                if let ms = msg.durationMs, ms > 0 {
                    Text(String(format: "%.0fs", ms / 1000))
                        .font(.system(size: chatFont - 4)).foregroundStyle(.secondary.opacity(0.6))
                }
            }
        }
        .sheet(isPresented: $showFullUserMessage) {
            VCLongTextSheet(title: "Message", text: msg.content, chatFont: chatFont)
        }
    }
}

// MARK: - Attachment chip (desktop color scheme: prompt.tsx::ChipView)

private struct VCChipView: View {
    let att: VCAttachment
    let onPreview: ((VCAttachment) -> Void)?

    // Desktop palette: prompt → accent purple; gtfile → cyan; context → orange;
    // image → green; audio → blue; everything else (paste, pdf) → violet.
    private var tint: Color {
        switch att.kind {
        case "prompt": return VCAccent
        case "gtfile": return Color(hex: "22d3ee")
        case "context": return Color(hex: "fb923c")
        case "image": return Color(hex: "34d399")
        case "audio": return Color(hex: "60a5fa")
        default: return Color(hex: "c084fc")
        }
    }
    private var icon: String? {
        switch att.kind {
        case "prompt": return "sparkles"
        case "gtfile": return nil
        case "context": return "text.quote"
        case "image": return "photo"
        case "paste": return "doc.on.clipboard"
        default: return nil
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            if att.kind == "gtfile" {
                VCGTGlyph(size: 16)
            } else if let icon {
                Image(systemName: icon).font(.system(size: 9))
            }
            Text(att.displayName).font(.system(size: 11)).lineLimit(1)
        }
        .foregroundStyle(tint.opacity(0.95))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .overlay(Capsule().stroke(tint.opacity(0.5)))
        .contentShape(Capsule())
        .onTapGesture {
            guard att.kind == "gtfile" else { return }
            onPreview?(att)
        }
    }
}

struct GTFilePreviewSheet: View {
    let attachment: VCAttachment
    @Environment(\.dismiss) private var dismiss
    @AppStorage(VoiceChatConfig.Keys.chatFont,
                store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var chatFont: Double = 15
    @State private var file: VCGTFile? = nil
    @State private var emojiShortcuts: [VCGTEmojiShortcut] = []
    @State private var loading = true
    @State private var error: String? = nil

    private var text: String { file?.content ?? "" }
    private var lineCount: Int {
        guard !text.isEmpty else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    VStack(spacing: 12) {
                        ProgressView().tint(.white)
                        Text("Загрузка файла…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 32))
                            .foregroundStyle(Color(hex: "f87171"))
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 22)
                        Button("Повторить") { Task { await load() } }
                            .buttonStyle(.borderedProminent)
                            .tint(Color(hex: "8AB4F8"))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                VCGTGlyph(size: 22)
                                Text("\(lineCount) строк · \(text.count) симв.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            if text.isEmpty {
                                Text("Файл пустой.")
                                    .font(.system(size: chatFont))
                                    .foregroundStyle(GTMarkdownPalette.muted)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                GTMarkdownFilePreview(markdown: text, fontSize: chatFont, emojiShortcuts: emojiShortcuts)
                            }
                        }
                        .padding(14)
                    }
                }
            }
            .background(VCPageBackground.ignoresSafeArea())
            .navigationTitle(attachment.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
        .task(id: attachment.filePath) { await load() }
    }

    private func load() async {
        guard let path = attachment.filePath else {
            error = "У вложения нет пути к файлу."
            loading = false
            return
        }
        loading = true
        error = nil
        do {
            file = try await VoiceChatAPI.fetchGTFile(path: path)
            emojiShortcuts = (try? await VoiceChatAPI.fetchGTSettings()) ?? []
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        loading = false
    }
}

// MARK: - GT file markdown preview

private enum GTMarkdownPalette {
    static let background = Color(hex: "1e1e2e")
    static let foreground = Color(hex: "f0efed")
    static let muted = Color(hex: "6c7086")
    static let bold = Color(hex: "ffa348")
    static let italic = Color(hex: "69dbdb")
    static let code = Color(hex: "50fa7b")
    static let strike = Color(hex: "868e96")
    static let link = Color(hex: "89b4fa")
    static let list = Color(hex: "f9e2af")
    static let border = Color(hex: "45475a")
    static let icon = Color(hex: "22d3ee")
    static let directive = Color(hex: "fab387")
    static let ai = Color(hex: "fb7185")

    static func heading(_ level: Int) -> Color {
        switch level {
        case 1: return Color(hex: "c678dd")
        case 2: return Color(hex: "b197fc")
        case 3: return Color(hex: "a78bfa")
        case 4: return Color(hex: "9775fa")
        case 5: return Color(hex: "8b5cf6")
        default: return Color(hex: "7c3aed")
        }
    }

    static func headingSize(_ level: Int, base: Double) -> Double {
        switch level {
        case 1: return base + 3
        case 2: return base + 2
        case 3: return base + 1
        default: return base
        }
    }
}

private enum GTMarkdownBlock {
    case heading(indent: Int, level: Int, text: String)
    case collapsible(indent: Int, marker: String, level: Int?, text: String)
    case paragraph(indent: Int, text: String)
    case unordered(indent: Int, text: String)
    case ordered(indent: Int, marker: String, text: String)
    case quote(indent: Int, text: String)
    case image(indent: Int, alt: String, path: String)
    case directive(indent: Int, kind: String, value: String)
    case ai(indent: Int, summary: String, lines: Int, characters: Int)
    case emojiLine(indent: Int, name: String, text: String)
    case code(indent: Int, text: String)
    case rule(indent: Int)
}

private enum GTInlineStyle {
    case plain, bold, italic, code, strike, link, customEmoji
}

private struct GTInlineSegment {
    let text: String
    let style: GTInlineStyle
}

private enum GTMarkdownParser {
    static func blocks(_ markdown: String) -> [GTMarkdownBlock] {
        var blocks: [GTMarkdownBlock] = []
        var paragraph: [String] = []
        var paragraphIndent = 0
        var code: [String] = []
        var inCode = false
        var codeIndent = 0

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(indent: paragraphIndent, text: joined)) }
            paragraph = []
        }

        func appendParagraph(_ text: String, indent: Int) {
            if paragraph.isEmpty {
                paragraphIndent = indent
            } else if paragraphIndent != indent {
                flushParagraph()
                paragraphIndent = indent
            }
            paragraph.append(text)
        }

        let lines = markdown.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let raw = lines[index]
            defer { index += 1 }
            let line = lineInfo(raw)
            let trimmed = line.content.trimmingCharacters(in: .whitespaces)
            if isFence(trimmed) {
                if inCode {
                    blocks.append(.code(indent: codeIndent, text: code.joined(separator: "\n")))
                    code = []
                    inCode = false
                } else {
                    flushParagraph()
                    codeIndent = line.indent
                    inCode = true
                }
                continue
            }
            if inCode {
                code.append(raw)
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule(indent: line.indent))
                continue
            }

            if let ai = parseAIBlock(lines, start: index) {
                flushParagraph()
                blocks.append(.ai(indent: ai.indent, summary: ai.summary, lines: ai.lines, characters: ai.characters))
                index = ai.nextIndex - 1
                continue
            }

            if let icon = parseLeadingCustomEmoji(line.content) {
                flushParagraph()
                blocks.append(.emojiLine(indent: line.indent, name: icon.name, text: icon.text))
            } else if let directive = parseDirective(trimmed) {
                flushParagraph()
                blocks.append(.directive(indent: line.indent, kind: directive.kind, value: directive.value))
            } else if let collapsible = parseCollapsible(line.content) {
                flushParagraph()
                if let heading = parseHeading(collapsible.text.trimmingCharacters(in: .whitespaces)) {
                    blocks.append(.collapsible(indent: line.indent, marker: collapsible.marker, level: heading.level, text: heading.text))
                } else {
                    blocks.append(.collapsible(indent: line.indent, marker: collapsible.marker, level: nil, text: collapsible.text))
                }
            } else if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(.heading(indent: line.indent, level: heading.level, text: heading.text))
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                blocks.append(.quote(indent: line.indent, text: String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else if let image = parseImage(trimmed) {
                flushParagraph()
                blocks.append(.image(indent: line.indent, alt: image.alt, path: image.path))
            } else if let list = parseList(line.content, baseIndent: line.indent) {
                flushParagraph()
                switch list.kind {
                case .unordered:
                    blocks.append(.unordered(indent: list.indent, text: list.text))
                case .ordered(let marker):
                    blocks.append(.ordered(indent: list.indent, marker: marker, text: list.text))
                }
            } else {
                appendParagraph(line.content, indent: line.indent)
            }
        }
        if inCode { blocks.append(.code(indent: codeIndent, text: code.joined(separator: "\n"))) }
        flushParagraph()
        return blocks
    }

    static func inline(_ line: String) -> [GTInlineSegment] {
        var out: [GTInlineSegment] = []
        var plain = ""
        var i = line.startIndex

        func flushPlain() {
            if !plain.isEmpty {
                out.append(.init(text: plain, style: .plain))
                plain = ""
            }
        }

        func consume(_ marker: String, style: GTInlineStyle) -> Bool {
            guard line[i...].hasPrefix(marker) else { return false }
            let start = line.index(i, offsetBy: marker.count)
            guard start <= line.endIndex,
                  let close = line[start...].range(of: marker) else { return false }
            flushPlain()
            out.append(.init(text: String(line[start..<close.lowerBound]), style: style))
            i = close.upperBound
            return true
        }

        while i < line.endIndex {
            if consume("**", style: .bold) { continue }
            if consume("~~", style: .strike) { continue }
            if consume("`", style: .code) { continue }

            if line[i] == "*" {
                let next = line.index(after: i)
                if next < line.endIndex, line[next] != "*",
                   let close = line[next...].firstIndex(of: "*") {
                    flushPlain()
                    out.append(.init(text: String(line[next..<close]), style: .italic))
                    i = line.index(after: close)
                    continue
                }
            }

            if line[i] == "[",
               let closeLabel = line[i...].firstIndex(of: "]") {
                let openParen = line.index(after: closeLabel)
                if openParen < line.endIndex,
                   line[openParen] == "(" {
                    let urlStart = line.index(after: openParen)
                    if let closeParen = line[urlStart...].firstIndex(of: ")") {
                        flushPlain()
                        let labelStart = line.index(after: i)
                        out.append(.init(text: String(line[labelStart..<closeLabel]), style: .link))
                        i = line.index(after: closeParen)
                        continue
                    }
                }
            }

            if line[i] == ":",
               let emoji = consumeCustomEmoji(line, from: i) {
                flushPlain()
                out.append(.init(text: emoji.text, style: .customEmoji))
                i = emoji.end
                continue
            }

            plain.append(line[i])
            i = line.index(after: i)
        }
        flushPlain()
        return out
    }

    private enum ListKind {
        case unordered
        case ordered(String)
    }

    private static func lineInfo(_ line: String) -> (indent: Int, content: String) {
        let leading = line.prefix(while: { $0 == " " || $0 == "\t" })
        let cols = leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        return (min(8, cols / 4), String(line.dropFirst(leading.count)))
    }

    private static func isFence(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    private static func isRule(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        return trimmed.allSatisfy { $0 == "-" } ||
               trimmed.allSatisfy { $0 == "/" } ||
               trimmed.allSatisfy { $0 == "\\" }
    }

    private static func parseCollapsible(_ content: String) -> (marker: String, text: String)? {
        guard content.hasPrefix(">>") || content.hasPrefix("^^") else { return nil }
        let marker = String(content.prefix(2))
        var text = String(content.dropFirst(2))
        if text.hasPrefix(" ") { text = String(text.dropFirst()) }
        return (marker, text)
    }

    private static func parseDirective(_ trimmed: String) -> (kind: String, value: String)? {
        guard trimmed.hasPrefix("<!-- @") else { return nil }
        var body = String(trimmed.dropFirst("<!-- @".count))
        if body.hasSuffix("-->") {
            body = String(body.dropLast(3))
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }

        if let colon = body.firstIndex(of: ":") {
            let kind = String(body[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(body[body.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            return (kind.isEmpty ? "directive" : kind, value)
        }

        let parts = body.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
        let kind = parts.first.map(String.init) ?? "directive"
        let value = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        return (kind, value)
    }

    private static func parseAIBlock(
        _ lines: [String],
        start: Int
    ) -> (indent: Int, summary: String, lines: Int, characters: Int, nextIndex: Int)? {
        guard start < lines.count else { return nil }
        let first = lineInfo(lines[start])
        guard let payloadStart = aiPayloadStart(in: first.content) else { return nil }

        var collected: [String] = []
        let firstPayload = String(first.content[payloadStart...])
        if let close = firstPayload.range(of: "-->") {
            let value = String(firstPayload[..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (
                first.indent,
                aiSummary(value),
                max(1, value.isEmpty ? 1 : value.split(separator: "\n", omittingEmptySubsequences: false).count),
                value.count,
                start + 1
            )
        }
        if !firstPayload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            collected.append(firstPayload)
        }

        var cursor = start + 1
        while cursor < lines.count {
            let content = lineInfo(lines[cursor]).content
            if let close = content.range(of: "-->") {
                let beforeClose = String(content[..<close.lowerBound])
                if !beforeClose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    collected.append(beforeClose)
                }
                let value = collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                return (first.indent, aiSummary(value), max(1, collected.count), value.count, cursor + 1)
            }
            collected.append(content)
            cursor += 1
        }

        let value = collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (first.indent, aiSummary(value), max(1, collected.count), value.count, lines.count)
    }

    private static func aiPayloadStart(in content: String) -> String.Index? {
        guard content.hasPrefix("<!--") else { return nil }
        var cursor = content.index(content.startIndex, offsetBy: 4)
        while cursor < content.endIndex, content[cursor] == " " || content[cursor] == "\t" {
            cursor = content.index(after: cursor)
        }
        guard content[cursor...].hasPrefix("@ai:") else { return nil }
        return content.index(cursor, offsetBy: 4)
    }

    private static func aiSummary(_ text: String) -> String {
        let firstMeaningfulLine = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        guard !firstMeaningfulLine.isEmpty else { return "AI block" }
        if firstMeaningfulLine.count <= 120 { return firstMeaningfulLine }
        let end = firstMeaningfulLine.index(firstMeaningfulLine.startIndex, offsetBy: 120)
        return String(firstMeaningfulLine[..<end]) + "…"
    }

    private static func parseImage(_ trimmed: String) -> (alt: String, path: String)? {
        guard trimmed.hasPrefix("!["),
              let closeLabel = trimmed.firstIndex(of: "]") else { return nil }
        let openParen = trimmed.index(after: closeLabel)
        guard openParen < trimmed.endIndex, trimmed[openParen] == "(" else { return nil }
        let pathStart = trimmed.index(after: openParen)
        guard let closeParen = trimmed[pathStart...].firstIndex(of: ")") else { return nil }
        let altStart = trimmed.index(trimmed.startIndex, offsetBy: 2)
        let alt = String(trimmed[altStart..<closeLabel])
        let path = String(trimmed[pathStart..<closeParen])
        if path.isEmpty { return nil }
        return (alt.isEmpty ? "image" : alt, path)
    }

    private static func parseList(_ content: String, baseIndent: Int) -> (kind: ListKind, indent: Int, text: String)? {
        if content.hasPrefix("- ") || content.hasPrefix("* ") || content.hasPrefix("+ ") {
            return (.unordered, baseIndent, String(content.dropFirst(2)))
        }

        var digits = ""
        var idx = content.startIndex
        while idx < content.endIndex, content[idx].isNumber {
            digits.append(content[idx])
            idx = content.index(after: idx)
        }
        guard !digits.isEmpty, idx < content.endIndex, content[idx] == "." else { return nil }
        let afterDot = content.index(after: idx)
        guard afterDot < content.endIndex, content[afterDot] == " " else { return nil }
        let bodyStart = content.index(after: afterDot)
        return (.ordered("\(digits)."), baseIndent, String(content[bodyStart...]))
    }

    private static func parseHeading(_ trimmed: String) -> (level: Int, text: String)? {
        var level = 0
        var idx = trimmed.startIndex
        while idx < trimmed.endIndex, level < 6, trimmed[idx] == "#" {
            level += 1
            idx = trimmed.index(after: idx)
        }
        guard level > 0, idx < trimmed.endIndex, trimmed[idx] == " " else { return nil }
        let text = String(trimmed[trimmed.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (level, text)
    }

    private static func parseLeadingCustomEmoji(_ content: String) -> (name: String, text: String)? {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(":"),
              let emoji = consumeCustomEmoji(trimmed, from: trimmed.startIndex) else { return nil }
        let name = String(emoji.text.dropFirst().dropLast())
        let rest = String(trimmed[emoji.end...]).trimmingCharacters(in: .whitespaces)
        return (name, rest)
    }

    private static func consumeCustomEmoji(_ line: String, from start: String.Index) -> (text: String, end: String.Index)? {
        let nameStart = line.index(after: start)
        guard nameStart < line.endIndex,
              let close = line[nameStart...].firstIndex(of: ":"),
              close > nameStart else { return nil }
        let name = String(line[nameStart..<close])
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return nil }
        return (":\(name):", line.index(after: close))
    }
}

private struct GTMarkdownInlineText: View {
    let text: String
    let fontSize: Double
    var weight: Font.Weight = .regular
    var color: Color = GTMarkdownPalette.foreground
    var allowInlineColors = true
    var emojiMap: [String: VCGTEmojiShortcut] = [:]

    var body: some View {
        composed
            .textSelection(.enabled)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composed: Text {
        GTMarkdownParser.inline(text).reduce(Text("")) { partial, segment in
            partial + styled(segment)
        }
    }

    private func styled(_ segment: GTInlineSegment) -> Text {
        let segmentColor: Color
        switch segment.style {
        case .plain: segmentColor = color
        case .bold: segmentColor = allowInlineColors ? GTMarkdownPalette.bold : color
        case .italic: segmentColor = allowInlineColors ? GTMarkdownPalette.italic : color
        case .code: segmentColor = allowInlineColors ? GTMarkdownPalette.code : color
        case .strike: segmentColor = allowInlineColors ? GTMarkdownPalette.strike : color
        case .link: segmentColor = allowInlineColors ? GTMarkdownPalette.link : color
        case .customEmoji: segmentColor = allowInlineColors ? GTMarkdownPalette.icon : color
        }

        var t = Text(displayText(for: segment)).foregroundColor(segmentColor)
        switch segment.style {
        case .plain:
            t = t.font(.system(size: fontSize, weight: weight))
        case .bold:
            t = t.font(.system(size: fontSize, weight: .bold))
        case .italic:
            t = t.font(.system(size: fontSize, weight: weight)).italic()
        case .code:
            t = t.font(.system(size: max(10, fontSize - 1), design: .monospaced))
        case .strike:
            t = t.font(.system(size: fontSize, weight: weight)).strikethrough(true, color: segmentColor)
        case .link:
            t = t.font(.system(size: fontSize, weight: weight)).underline(true, color: segmentColor)
        case .customEmoji:
            t = t.font(.system(size: fontSize, weight: .semibold))
        }
        return t
    }

    private func displayText(for segment: GTInlineSegment) -> String {
        guard segment.style == .customEmoji else { return segment.text }
        let name = String(segment.text.dropFirst().dropLast()).lowercased()
        if let emoji = emojiMap[name]?.emoji?.trimmingCharacters(in: .whitespacesAndNewlines), !emoji.isEmpty {
            return emoji
        }
        return "▣"
    }
}

private struct GTMarkdownFilePreview: View {
    let markdown: String
    let fontSize: Double
    let emojiShortcuts: [VCGTEmojiShortcut]

    private var emojiMap: [String: VCGTEmojiShortcut] {
        Dictionary(uniqueKeysWithValues: emojiShortcuts.map { ($0.name.lowercased(), $0) })
    }

    private var blocks: [GTMarkdownBlock] {
        GTMarkdownParser.blocks(markdown)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: GTMarkdownBlock) -> some View {
        switch block {
        case .heading(let indent, let level, let text):
            indented(indent) {
                GTMarkdownInlineText(
                    text: text,
                    fontSize: GTMarkdownPalette.headingSize(level, base: fontSize),
                    weight: .bold,
                    color: GTMarkdownPalette.heading(level),
                    allowInlineColors: false,
                    emojiMap: emojiMap
                )
                .padding(.top, level <= 2 ? 8 : 4)
            }

        case .collapsible(let indent, let marker, let level, let text):
            indented(indent) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: marker == ">>" ? "chevron.down" : "chevron.right")
                        .font(.system(size: max(10, fontSize - 4), weight: .bold))
                        .foregroundColor(GTMarkdownPalette.muted)
                        .frame(width: 13)
                    GTMarkdownInlineText(
                        text: text,
                        fontSize: level.map { GTMarkdownPalette.headingSize($0, base: fontSize) } ?? fontSize,
                        weight: .semibold,
                        color: level.map { GTMarkdownPalette.heading($0) } ?? GTMarkdownPalette.foreground,
                        allowInlineColors: level == nil,
                        emojiMap: emojiMap
                    )
                }
                .padding(.vertical, 2)
            }

        case .paragraph(let indent, let text):
            indented(indent) {
                GTMarkdownInlineText(text: text, fontSize: fontSize, emojiMap: emojiMap)
            }

        case .unordered(let indent, let text):
            listRow(indent: indent, marker: "•", text: text)

        case .ordered(let indent, let marker, let text):
            listRow(indent: indent, marker: marker, text: text)

        case .quote(let indent, let text):
            indented(indent) {
                HStack(alignment: .top, spacing: 10) {
                    Rectangle()
                        .fill(GTMarkdownPalette.italic.opacity(0.65))
                        .frame(width: 3)
                        .clipShape(Capsule())
                    GTMarkdownInlineText(text: text, fontSize: fontSize, color: GTMarkdownPalette.foreground.opacity(0.82), emojiMap: emojiMap)
                }
                .padding(.vertical, 3)
            }

        case .image(let indent, let alt, let path):
            indented(indent) {
                HStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.system(size: max(12, fontSize - 1), weight: .semibold))
                        .foregroundColor(GTMarkdownPalette.icon)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(alt)
                            .font(.system(size: fontSize, weight: .semibold))
                            .foregroundColor(GTMarkdownPalette.foreground)
                            .lineLimit(1)
                        Text(path)
                            .font(.system(size: max(10, fontSize - 3), design: .monospaced))
                            .foregroundColor(GTMarkdownPalette.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(GTMarkdownPalette.icon.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(GTMarkdownPalette.icon.opacity(0.3)))
            }

        case .directive(let indent, let kind, let value):
            indented(indent) {
                GTMarkdownDirectiveChip(kind: kind, value: value, fontSize: fontSize)
            }

        case .ai(let indent, let summary, let lines, let characters):
            indented(indent) {
                GTMarkdownAIBlock(summary: summary, lines: lines, characters: characters, fontSize: fontSize)
            }

        case .emojiLine(let indent, let name, let text):
            indented(indent) {
                HStack(alignment: .center, spacing: 8) {
                    GTCustomEmojiGlyph(name: name, shortcut: emojiMap[name.lowercased()], fontSize: fontSize)
                    if text.isEmpty {
                        Text(name)
                            .font(.system(size: fontSize, weight: .semibold))
                            .foregroundColor(GTMarkdownPalette.foreground)
                            .textSelection(.enabled)
                    } else {
                        GTMarkdownInlineText(text: text, fontSize: fontSize, emojiMap: emojiMap)
                    }
                }
                .padding(.vertical, 1)
            }

        case .code(let indent, let code):
            indented(indent) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code.isEmpty ? " " : code)
                        .font(.system(size: max(11, fontSize - 2), design: .monospaced))
                        .foregroundColor(GTMarkdownPalette.code)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.38)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(GTMarkdownPalette.border.opacity(0.7)))
            }

        case .rule(let indent):
            indented(indent) {
                Rectangle()
                    .fill(GTMarkdownPalette.border.opacity(0.8))
                    .frame(height: 1)
                    .padding(.vertical, 8)
            }
        }
    }

    private func listRow(indent: Int, marker: String, text: String) -> some View {
        indented(indent) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundColor(GTMarkdownPalette.list)
                    .frame(width: marker == "•" ? 16 : 30, alignment: .trailing)
                GTMarkdownInlineText(text: text, fontSize: fontSize, emojiMap: emojiMap)
            }
        }
    }

    private func indented<Content: View>(_ indent: Int, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.leading, CGFloat(indent) * 18)
            .overlay(alignment: .leading) {
                if indent > 0 {
                    HStack(spacing: 0) {
                        ForEach(0..<indent, id: \.self) { _ in
                            ZStack {
                                Rectangle()
                                    .fill(GTMarkdownPalette.border.opacity(0.68))
                                    .frame(width: 1)
                                    .frame(maxHeight: .infinity)
                            }
                            .frame(width: 18)
                            .frame(maxHeight: .infinity)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
    }
}

private struct GTCustomEmojiGlyph: View {
    let name: String
    var shortcut: VCGTEmojiShortcut? = nil
    let fontSize: Double

    private var size: CGFloat { CGFloat(max(22, fontSize + 8)) }
    private var image: UIImage? {
        guard let raw = shortcut?.image?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let base64 = raw.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).last.map(String.init) ?? raw
        guard let data = Data(base64Encoded: base64) else { return nil }
        return UIImage(data: data)
    }
    private var emoji: String? {
        guard let raw = shortcut?.emoji?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw
    }
    private var symbol: String? {
        let lower = name.lowercased()
        if lower.contains("terminal") { return "terminal" }
        if lower.contains("folder") || lower.contains("directory") { return "folder" }
        if lower.contains("file") || lower.contains("doc") { return "doc.text" }
        if lower.contains("ai") || lower.contains("claude") || lower.contains("gpt") { return "sparkles" }
        if lower.contains("image") || lower.contains("photo") { return "photo" }
        return nil
    }
    private var letters: String {
        let value = name
            .split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
            .compactMap { $0.first }
            .prefix(2)
            .map { String($0).uppercased() }
            .joined()
        return value.isEmpty ? String(name.prefix(2)).uppercased() : value
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(GTMarkdownPalette.icon.opacity(0.14))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(GTMarkdownPalette.icon.opacity(0.36)))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(3)
            } else if let emoji {
                Text(emoji)
                    .font(.system(size: max(14, fontSize), weight: .semibold))
                    .minimumScaleFactor(0.65)
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: max(11, fontSize - 2), weight: .semibold))
                    .foregroundColor(GTMarkdownPalette.icon)
            } else {
                Text(letters)
                    .font(.system(size: max(9, fontSize - 5), weight: .heavy, design: .rounded))
                    .foregroundColor(GTMarkdownPalette.icon)
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(name)
    }
}

private struct GTMarkdownAIBlock: View {
    let summary: String
    let lines: Int
    let characters: Int
    let fontSize: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("AI")
                    .font(.system(size: max(11, fontSize - 2), weight: .heavy))
                    .foregroundColor(GTMarkdownPalette.ai)
                Text("\(lines) строк · \(characters) симв.")
                    .font(.system(size: max(10, fontSize - 4), weight: .medium))
                    .foregroundColor(GTMarkdownPalette.foreground.opacity(0.64))
                Spacer(minLength: 0)
            }
            if !summary.isEmpty {
                Text(summary)
                    .font(.system(size: max(11, fontSize - 2), design: .monospaced))
                    .foregroundColor(GTMarkdownPalette.foreground.opacity(0.82))
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(GTMarkdownPalette.ai.opacity(0.13)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(GTMarkdownPalette.ai.opacity(0.34)))
    }
}

private struct GTMarkdownDirectiveChip: View {
    let kind: String
    let value: String
    let fontSize: Double

    private var normalizedKind: String { kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    private var tint: Color {
        switch normalizedKind {
        case "include": return GTMarkdownPalette.link
        case "link": return Color(hex: "6ee7b7")
        case "embedding": return Color(hex: "f472b6")
        case "ai": return GTMarkdownPalette.ai
        default: return GTMarkdownPalette.muted
        }
    }
    private var icon: String {
        switch normalizedKind {
        case "include": return "doc.text"
        case "link": return "link"
        case "embedding": return "brain.head.profile"
        case "ai": return "sparkles"
        default: return "chevron.left.forwardslash.chevron.right"
        }
    }
    private var title: String {
        switch normalizedKind {
        case "include": return "Include"
        case "link": return "Link"
        case "embedding": return "Embedding"
        case "ai": return "AI"
        default: return kind.isEmpty ? "Directive" : kind
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: max(11, fontSize - 2), weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 16)
            Text(title)
                .font(.system(size: max(11, fontSize - 2), weight: .bold))
                .foregroundColor(tint)
            if !value.isEmpty {
                Text(value)
                    .font(.system(size: max(10, fontSize - 3), design: .monospaced))
                    .foregroundColor(GTMarkdownPalette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.28)))
    }
}

// MARK: - Tool card (collapsible)

struct ThinkingCardView: View {
    let text: String
    let chatFont: Double
    @State private var open = false
    @State private var showFull = false
    private let previewLimit = 4_000
    private var clipped: Bool { vcTextExceeds(text, maxCharacters: previewLimit) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { open.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(VCAccent)
                    Text("Thinking")
                        .font(.system(size: chatFont - 2, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    Text("\(text.utf16.count) симв.")
                        .font(.system(size: chatFont - 3).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 0 : -90))
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                Text(vcClippedText(text, maxCharacters: previewLimit))
                    .font(.system(size: chatFont - 3).monospaced())
                    .foregroundStyle(Color(hex: "c4b5fd"))
                    .textSelection(.enabled)
                    .lineLimit(80)
                    .padding(.horizontal, 10).padding(.bottom, 8)
                if clipped {
                    Button { showFull = true } label: {
                        Label("Full", systemImage: "doc.text.magnifyingglass")
                            .font(.system(size: chatFont - 3, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(VCAccent)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 9)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(VCAccent.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(VCAccent.opacity(0.32)))
        .sheet(isPresented: $showFull) {
            VCLongTextSheet(title: "Thinking", text: text, chatFont: chatFont)
        }
    }
}

struct ToolCardView: View {
    let tool: VCToolCall
    let chatFont: Double
    let defaultOpen: Bool
    @State private var open: Bool? = nil   // nil → defaultOpen
    @State private var showFull = false
    private let previewLimit = 20_000

    private var isOpen: Bool { open ?? defaultOpen }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                open = !isOpen
            } label: {
                HStack(spacing: 7) {
                    if tool.isRunning {
                        ProgressView().controlSize(.mini).tint(.orange)
                    } else {
                        Circle().fill(tool.isError ? Color(hex: "ef4444") : Color(hex: "22c55e"))
                            .frame(width: 7, height: 7)
                    }
                    if tool.name.hasPrefix("mcp__") || tool.name.contains("__") {
                        Text("MCP")
                            .font(.system(size: max(8, chatFont - 6), weight: .heavy, design: .rounded))
                            .foregroundStyle(Color(hex: "86efac"))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color(hex: "14532d").opacity(0.38)))
                            .overlay(Capsule().stroke(Color(hex: "22c55e").opacity(0.45)))
                    }
                    Text(tool.displayName)
                        .font(.system(size: chatFont - 2, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    Text(tool.preview)
                        .font(.system(size: chatFont - 3).monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 0 : -90))
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                let text = tool.detailText(maxCharacters: previewLimit)
                if !text.isEmpty {
                    ScrollView([.vertical, .horizontal], showsIndicators: true) {
                        Text(text)
                            .font(.system(size: chatFont - 3).monospaced())
                            .foregroundStyle(tool.isError ? Color(hex: "fca5a5") : Color(hex: "b6b6ba"))
                            .textSelection(.enabled)
                            .lineLimit(nil)
                            .fixedSize(horizontal: true, vertical: true)
                            .padding(10)
                    }
                    .frame(maxHeight: 320, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.16)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08)))
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    if text.utf16.count >= previewLimit {
                        Button { showFull = true } label: {
                            Label("Full", systemImage: "doc.text.magnifyingglass")
                                .font(.system(size: chatFont - 3, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(VCAccent)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 9)
                    }
                } else if tool.isRunning {
                    Text("выполняется…")
                        .font(.system(size: chatFont - 3)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.bottom, 8)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 0.16)))
        .sheet(isPresented: $showFull) {
            VCToolDetailSheet(tool: tool, chatFont: chatFont)
        }
    }
}

struct VCLongTextSheet: View {
    let title: String
    let text: String
    let chatFont: Double
    @Environment(\.dismiss) private var dismiss
    @State private var chunks: [String]?

    var body: some View {
        NavigationStack {
            Group {
                if let chunks {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
                                Text(chunk)
                                    .font(.system(size: chatFont - 2).monospaced())
                                    .foregroundStyle(Color(hex: "d4d4d8"))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(14)
                    }
                    .background(Color(hex: "101014").ignoresSafeArea())
                } else {
                    VStack(spacing: 12) {
                        ProgressView().tint(.white)
                        Text("Loading")
                            .font(.system(size: chatFont - 2, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(hex: "101014").ignoresSafeArea())
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task(id: text.utf16.count) {
            chunks = nil
            let source = text
            chunks = await Task.detached(priority: .userInitiated) {
                vcChunkText(source)
            }.value
        }
    }
}

private struct VCToolDetailSheet: View {
    let tool: VCToolCall
    let chatFont: Double
    @Environment(\.dismiss) private var dismiss
    @State private var text: String?

    var body: some View {
        Group {
            if let text {
                VCLongTextSheet(title: tool.displayName, text: text, chatFont: chatFont)
            } else {
                NavigationStack {
                    VStack(spacing: 12) {
                        ProgressView().tint(.white)
                        Text("Loading")
                            .font(.system(size: chatFont - 2, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(hex: "101014").ignoresSafeArea())
                    .navigationTitle(tool.displayName)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { dismiss() }
                        }
                    }
                }
            }
        }
        .task(id: tool.id) {
            let value = tool
            text = await Task.detached(priority: .userInitiated) {
                value.detailText(maxCharacters: 500_000)
            }.value
        }
    }
}

// MARK: - Background bash tray

private func vcElapsedLabel(_ startedAt: Double, now: Date) -> String {
    let start = Date(timeIntervalSince1970: startedAt / 1000)
    let s = max(0, Int(now.timeIntervalSince(start)))
    if s < 60 { return "\(s)s" }
    let m = s / 60
    let rest = s % 60
    return rest == 0 ? "\(m)m" : "\(m)m \(rest)s"
}

private struct BackgroundTaskTrayView: View {
    let tasks: [VCBackgroundTask]
    let chatFont: Double
    @State private var openId: String?
    @State private var now = Date()

    private var openTask: VCBackgroundTask? {
        guard let openId else { return nil }
        return tasks.first { $0.id == openId }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tasks) { task in
                        let selected = task.id == openId
                        Button {
                            openId = selected ? nil : task.id
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color(hex: "f59e0b"))
                                    .frame(width: 7, height: 7)
                                    .shadow(color: Color(hex: "f59e0b").opacity(0.45), radius: 3)
                                Image(systemName: "terminal")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(task.label)
                                    .font(.system(size: chatFont - 3, weight: .semibold).monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: 180, alignment: .leading)
                                Text(vcElapsedLabel(task.startedAt, now: now))
                                    .font(.system(size: chatFont - 4).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .foregroundStyle(Color(hex: "d4d4d8"))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color(hex: "f59e0b").opacity(0.13) : Color.white.opacity(0.055)))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color(hex: "f59e0b").opacity(0.45) : Color.white.opacity(0.10)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }

            if let openTask {
                BackgroundTaskDetailView(task: openTask, chatFont: chatFont)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.075)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12)))
        .task(id: tasks.map(\.id).joined(separator: "|")) {
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: tasks.map(\.id)) { _, ids in
            if let openId, !ids.contains(openId) { self.openId = nil }
        }
    }
}

private struct BackgroundTaskDetailView: View {
    let task: VCBackgroundTask
    let chatFont: Double
    @State private var content = ""
    @State private var offset = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(task.command)
                    .font(.system(size: chatFont - 4).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Button {
                    VoiceChatStore.shared.killBackgroundTask(task.id)
                } label: {
                    Text("Стоп")
                        .font(.system(size: chatFont - 4, weight: .semibold))
                        .foregroundStyle(Color(hex: "fca5a5"))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: "7f1d1d").opacity(0.22)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: "ef4444").opacity(0.35)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            ScrollView {
                Text(content.isEmpty ? "ждём вывод…" : String(content.suffix(20000)))
                    .font(.system(size: chatFont - 4).monospaced())
                    .foregroundStyle(content.isEmpty ? .secondary : Color(hex: "cbd5e1"))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 170)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.22)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08)))
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .task(id: task.id) {
            content = ""
            offset = 0
            while !Task.isCancelled {
                await pull()
                try? await Task.sleep(for: .milliseconds(650))
            }
        }
    }

    private func pull() async {
        do {
            let r: VCBackgroundOutput = try await VoiceChatAPI.getJSON("/api/agent/bg/" + vcPathComponent(task.id) + "/output?offset=\(offset)")
            if r.missing == true { return }
            if let size = r.size { offset = size }
            if let c = r.content, !c.isEmpty { content += c }
        } catch {
            VCLog.log("Store", "bg output FAILED id=\(task.id): \(error.localizedDescription)")
        }
    }
}

// MARK: - Tool-approval card (By-pass OFF)

private struct ConfirmCardView: View {
    let req: VCConfirmRequest
    let chatFont: Double
    let onAnswer: (Bool) -> Void

    private var title: String {
        switch req.action {
        case "bash": return "Выполнить команду?"
        case "create": return "Создать файл?"
        case "overwrite": return "Перезаписать файл?"
        default: return "Изменить файл?"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: req.action == "bash" ? "terminal" : "pencil")
                    .font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: chatFont - 1, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(Color(hex: "fbbf24"))

            if let p = req.path {
                Text((p as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: chatFont - 3).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            if let cmd = req.command {
                Text(cmd)
                    .font(.system(size: chatFont - 3).monospaced())
                    .foregroundStyle(Color(hex: "d4d4d8"))
                    .lineLimit(6)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.4)))
            }
            // Mini-diff: red old / green new (trimmed — the full diff lives on
            // the desktop; the phone needs enough to decide).
            if let old = req.oldString, !old.isEmpty {
                Text(old.prefix(400))
                    .font(.system(size: chatFont - 4).monospaced())
                    .foregroundStyle(Color(hex: "fca5a5"))
                    .lineLimit(6)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: "7f1d1d").opacity(0.25)))
            }
            if let new = req.newString, !new.isEmpty {
                Text(new.prefix(400))
                    .font(.system(size: chatFont - 4).monospaced())
                    .foregroundStyle(Color(hex: "86efac"))
                    .lineLimit(6)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: "14532d").opacity(0.25)))
            }

            HStack(spacing: 10) {
                Button { onAnswer(true) } label: {
                    Text("Разрешить")
                        .font(.system(size: chatFont - 2, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color(hex: "16a34a")))
                        .foregroundStyle(.white)
                }
                Button { onAnswer(false) } label: {
                    Text("Отклонить")
                        .font(.system(size: chatFont - 2, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color(white: 0.18)))
                        .foregroundStyle(Color(hex: "fca5a5"))
                }
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: "fbbf24").opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: "fbbf24").opacity(0.45)))
    }
}

// MARK: - Bypass pill (navbar — compact 2-row: toggle over caption)

private struct BypassPill: View {
    @Binding var on: Bool
    var body: some View {
        Button { on.toggle() } label: {
            VStack(spacing: 2) {
                Capsule().fill(on ? Color(hex: "22c55e") : Color(white: 0.28))
                    .frame(width: 30, height: 17)
                    .overlay(alignment: on ? .trailing : .leading) {
                        Circle().fill(.white).frame(width: 13, height: 13).padding(2)
                    }
                Text("By-pass")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(on ? Color(hex: "22c55e") : .secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Markdown (cached per message id — never re-parsed on scroll)

private enum MDBlock: Sendable {
    case text(AttributedString)
    case code(String)
}

private enum VCMarkdownCache {
    // Keyed by messageId + font size (font change re-renders). Bounded.
    static var cache: [String: [MDBlock]] = [:]
    private struct ColorChipStyle {
        let background: Color
        let foreground: Color
    }

    private static let colorTokenRegex = try! NSRegularExpression(
        pattern: #"(?<![\w#])#(?:[0-9a-f]{6}|[0-9a-f]{3})\b|\brgba?\(\s*(25[0-5]|2[0-4]\d|1?\d?\d)\s*,\s*(25[0-5]|2[0-4]\d|1?\d?\d)\s*,\s*(25[0-5]|2[0-4]\d|1?\d?\d)(?:\s*,\s*(0(?:\.\d+)?|1(?:\.0+)?|\.\d+))?\s*\)"#,
        options: [.caseInsensitive]
    )
    private static let rgbFunctionRegex = try! NSRegularExpression(
        pattern: #"^rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)(?:\s*,\s*(0(?:\.\d+)?|1(?:\.0+)?|\.\d+))?\s*\)$"#,
        options: [.caseInsensitive]
    )

    static func cacheKey(messageId: String, fontSize: Double) -> String {
        messageId + ":" + String(Int(fontSize))
    }

    static func cached(key: String) -> [MDBlock]? { cache[key] }

    static func store(_ blocks: [MDBlock], key: String) {
        if cache.count > 400 { cache.removeAll() }
        cache[key] = blocks
    }

    static func blocks(messageId: String, markdown: String, fontSize: Double) -> [MDBlock] {
        let key = cacheKey(messageId: messageId, fontSize: fontSize)
        if let hit = cache[key] { return hit }
        if cache.count > 400 { cache.removeAll() }
        let built = build(markdown, fontSize: fontSize)
        cache[key] = built
        return built
    }

    // Pure, main-actor-independent build for off-main rendering. Same logic as
    // build(); split out so a Task.detached can call it without touching the cache
    // (the caller stores the result back on the main actor).
    nonisolated static func buildDetached(_ md: String, fontSize: Double) -> [MDBlock] {
        build(md, fontSize: fontSize)
    }

    nonisolated private static func build(_ md: String, fontSize: Double) -> [MDBlock] {
        var blocks: [MDBlock] = []
        var textRun: [String] = []

        func flushText() {
            guard !textRun.isEmpty else { return }
            let joined = textRun.joined(separator: "\n")
            blocks.append(.text(renderText(joined, fontSize: fontSize)))
            textRun = []
        }

        var inCode = false
        var codeRun: [String] = []
        for raw in md.components(separatedBy: "\n") {
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    blocks.append(.code(codeRun.joined(separator: "\n")))
                    codeRun = []; inCode = false
                } else {
                    flushText(); inCode = true
                }
                continue
            }
            if inCode { codeRun.append(raw) } else { textRun.append(raw) }
        }
        if inCode { blocks.append(.code(codeRun.joined(separator: "\n"))) }
        flushText()
        return blocks
    }

    // Line-oriented renderer: headers/bullets handled manually, inline markdown
    // (bold/italic/code/links) via Foundation's parser per line.
    nonisolated private static func renderText(_ text: String, fontSize: Double) -> AttributedString {
        var out = AttributedString()
        var first = true
        for raw in text.components(separatedBy: "\n") {
            var line = raw
            var font = Font.system(size: fontSize)
            if line.hasPrefix("### ") { line = String(line.dropFirst(4)); font = .system(size: fontSize + 1, weight: .semibold) }
            else if line.hasPrefix("## ") { line = String(line.dropFirst(3)); font = .system(size: fontSize + 2, weight: .bold) }
            else if line.hasPrefix("# ") { line = String(line.dropFirst(2)); font = .system(size: fontSize + 3, weight: .bold) }
            else if line.hasPrefix("- ") || line.hasPrefix("* ") { line = "•  " + line.dropFirst(2) }
            var seg: AttributedString
            if let parsed = try? AttributedString(
                markdown: line,
                options: .init(allowsExtendedAttributes: false,
                               interpretedSyntax: .inlineOnlyPreservingWhitespace,
                               failurePolicy: .returnPartiallyParsedIfPossible)) {
                seg = parsed
            } else {
                seg = AttributedString(line)
            }
            // Base font for runs that didn't get one from inline markdown.
            for run in seg.runs where run.font == nil {
                seg[run.range].font = font
            }
            for run in seg.runs where run.foregroundColor == nil {
                seg[run.range].foregroundColor = Color(hex: "e6e6e6")
            }
            applyColorChips(&seg)
            if !first { out += AttributedString("\n") }
            out += seg
            first = false
        }
        return out
    }

    // Hex/rgb color literals only appear in short snippets ("background: #ff0"). For
    // very long segments (a minified blob, a giant JSON/log line dumped by a tool)
    // the chip pass is pure cost — and it was the 12-SECOND main-thread hang on a
    // 546 KB assistant entry: the old code called visible.distance(...) +
    // chars.index(...offsetBy:) per match, each O(n) over AttributedString's
    // CharacterView → O(n²). Skip it past this length; nobody color-codes a 20 KB line.
    private static let colorChipMaxSegmentChars = 20_000

    nonisolated private static func applyColorChips(_ seg: inout AttributedString) {
        let visible = String(seg.characters)
        guard !visible.isEmpty, visible.utf16.count <= colorChipMaxSegmentChars else { return }

        let fullRange = NSRange(visible.startIndex..<visible.endIndex, in: visible)
        let matches = colorTokenRegex.matches(in: visible, range: fullRange)
        guard !matches.isEmpty else { return }

        // Map each match's String range to the AttributedString index space ONCE via
        // AttributedString's own UTF-8 view (O(1) per endpoint), instead of re-walking
        // the character view per match (the old O(n²)). Apply back-to-front so earlier
        // ranges stay valid after styling.
        for match in matches.reversed() {
            guard let stringRange = Range(match.range, in: visible) else { continue }
            let token = String(visible[stringRange])
            guard let style = chipStyle(for: token) else { continue }
            guard
                let lo = AttributedString.Index(stringRange.lowerBound, within: seg),
                let hi = AttributedString.Index(stringRange.upperBound, within: seg)
            else { continue }
            seg[lo..<hi].backgroundColor = style.background
            seg[lo..<hi].foregroundColor = style.foreground
        }
    }

    nonisolated private static func chipStyle(for raw: String) -> ColorChipStyle? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.hasPrefix("#") {
            let hex = String(token.dropFirst())
            let hex6: String
            if hex.count == 3 {
                hex6 = hex.map { "\($0)\($0)" }.joined()
            } else if hex.count == 6 {
                hex6 = hex
            } else {
                return nil
            }
            guard let value = Int(hex6, radix: 16) else { return nil }
            let r = (value >> 16) & 255
            let g = (value >> 8) & 255
            let b = value & 255
            return chipStyle(red: r, green: g, blue: b, alpha: 1)
        }

        let ns = token as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = rgbFunctionRegex.firstMatch(in: token, range: range) else { return nil }
        let r = Int(ns.substring(with: match.range(at: 1))) ?? 0
        let g = Int(ns.substring(with: match.range(at: 2))) ?? 0
        let b = Int(ns.substring(with: match.range(at: 3))) ?? 0
        let alpha: Double
        if match.range(at: 4).location == NSNotFound {
            alpha = 1
        } else {
            alpha = Double(ns.substring(with: match.range(at: 4))) ?? 1
        }
        return chipStyle(red: r, green: g, blue: b, alpha: alpha)
    }

    nonisolated private static func chipStyle(red: Int, green: Int, blue: Int, alpha: Double) -> ColorChipStyle {
        let opacity = min(1, max(0, alpha))
        let background = Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255, opacity: opacity)

        var contrastRed = Double(red)
        var contrastGreen = Double(green)
        var contrastBlue = Double(blue)
        if opacity < 1 {
            let base = (r: 22.0, g: 22.0, b: 25.0)
            contrastRed = contrastRed * opacity + base.r * (1 - opacity)
            contrastGreen = contrastGreen * opacity + base.g * (1 - opacity)
            contrastBlue = contrastBlue * opacity + base.b * (1 - opacity)
        }
        let yiq = (contrastRed * 299 + contrastGreen * 587 + contrastBlue * 114) / 1000
        return ColorChipStyle(background: background, foreground: yiq >= 140 ? .black : .white)
    }
}

struct VCMarkdownView: View {
    let messageId: String
    let markdown: String
    let fontSize: Double
    var maxCharacters: Int? = nil

    // Rendered blocks. Cache hit → set synchronously in init-time read (the common
    // scroll case stays instant). Cache miss → built in Task.detached. For huge
    // terminal artifacts, callers pass maxCharacters so SwiftUI never lays out
    // the whole 500KB+ AttributedString in the current chat row.
    @State private var blocks: [MDBlock]?

    // Threshold above which we DON'T even attempt the synchronous path — always go
    // off-main. Small messages render in-place (no placeholder flash).
    private static let asyncThreshold = 2_000
    @State private var showFull = false

    private var renderedMarkdown: String {
        if let maxCharacters {
            return vcClippedText(markdown, maxCharacters: maxCharacters)
        }
        return markdown
    }

    private var markdownClipped: Bool {
        guard let maxCharacters else { return false }
        return vcTextExceeds(markdown, maxCharacters: maxCharacters)
    }

    private var cacheIdentity: String {
        let md = renderedMarkdown
        return VCMarkdownCache.cacheKey(messageId: messageId, fontSize: fontSize)
            + ":limit=\(maxCharacters ?? -1):len=\(md.utf16.count):hash=\(md.hashValue)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let blocks {
                    rendered(blocks)
                } else {
                    // Placeholder while the off-main build runs: raw text, capped so the
                    // placeholder itself is cheap. Real markdown swaps in when ready.
                    Text(vcClippedText(renderedMarkdown, maxCharacters: 8_000))
                        .font(.system(size: fontSize))
                        .foregroundStyle(Color(hex: "e6e6e6"))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineSpacing(3)
                        .padding(.horizontal, 2)
                }
            }
            if markdownClipped {
                Button { showFull = true } label: {
                    Label("Full", systemImage: "doc.text.magnifyingglass")
                        .font(.system(size: fontSize - 2, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(VCAccent)
            }
        }
        .task(id: cacheIdentity) {
            await loadBlocks()
        }
        .sheet(isPresented: $showFull) {
            VCLongTextSheet(title: "Message", text: markdown, chatFont: fontSize)
        }
    }

    private func loadBlocks() async {
        let key = cacheIdentity
        if let hit = VCMarkdownCache.cached(key: key) {
            blocks = hit
            return
        }
        blocks = nil
        let source = renderedMarkdown
        // Small messages: build synchronously (no flash). Big ones: off-main.
        if source.utf16.count <= Self.asyncThreshold {
            let built = VCMarkdownCache.buildDetached(source, fontSize: fontSize)
            VCMarkdownCache.store(built, key: key)
            blocks = built
            return
        }
        let md = source
        let fs = fontSize
        let built = await Task.detached(priority: .userInitiated) {
            VCMarkdownCache.buildDetached(md, fontSize: fs)
        }.value
        guard !Task.isCancelled else { return }
        VCMarkdownCache.store(built, key: key)
        blocks = built
    }

    @ViewBuilder
    private func rendered(_ blocks: [MDBlock]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let attr):
                    Text(attr)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineSpacing(3)
                case .code(let code):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code)
                            .font(.system(size: fontSize - 2).monospaced())
                            .foregroundStyle(Color(hex: "d4d4d8"))
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.45)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(white: 0.16)))
                    .contextMenu {
                        Button { UIPasteboard.general.string = code } label: {
                            Label("Copy code", systemImage: "doc.on.doc")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 2)
    }
}

// MARK: - Settings (fonts FIRST, then source)

// Thin wrapper kept for standalone use / previews. Content lives in
// VoiceChatSettingsBody so AppSettingsSheet can host it under a shared segmented stack.
struct VoiceChatSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VoiceChatSettingsBody()
                .navigationTitle("AI Chat")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}

struct VoiceChatSettingsBody: View {
    @State private var showLogs = false

    @AppStorage(VoiceChatConfig.Keys.model,
                store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var model = "flash"
    @AppStorage(VoiceChatConfig.Keys.think,
                store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var think = "NONE"
    @AppStorage(VoiceChatConfig.Keys.activePreset,
                store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var activePreset = 1
    @AppStorage(VoiceChatConfig.Keys.defaultPreset,
                store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var defaultPreset = 1
    @AppStorage(VoiceChatConfig.Keys.preset1Model,
                store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var preset1Model = VoiceChatConfig.defaultPresetModel(1)
    @AppStorage(VoiceChatConfig.Keys.preset1Think,
                store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var preset1Think = VoiceChatConfig.defaultPresetThink(1)
    @AppStorage(VoiceChatConfig.Keys.preset2Model,
                store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var preset2Model = VoiceChatConfig.defaultPresetModel(2)
    @AppStorage(VoiceChatConfig.Keys.preset2Think,
                store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var preset2Think = VoiceChatConfig.defaultPresetThink(2)
    @AppStorage(VoiceChatConfig.Keys.uiFont,
                store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var uiFont: Double = 14
    @AppStorage(VoiceChatConfig.Keys.chatFont,
                store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var chatFont: Double = 15

    var body: some View {
            Form {
                // ── Шрифт — two compact steppers on one row. The Prod/Dev source
                // picker + dev host were removed: the native client always talks
                // to the prod URL through the tunnel (a LAN dev-mode never came
                // up in practice and only confused the sheet).
                Section("Шрифт") {
                    HStack(spacing: 12) {
                        FontStepper(label: "UI", value: $uiFont)
                        FontStepper(label: "Чат", value: $chatFont)
                        Spacer()
                    }
                    .listRowBackground(Color.white.opacity(0.05))
                }

                Section {
                    VCPresetSettingsRow(
                        title: "Light",
                        slot: 1,
                        model: $preset1Model,
                        think: $preset1Think,
                        defaultPreset: $defaultPreset,
                        activePreset: $activePreset,
                        currentModel: $model,
                        currentThink: $think
                    )
                    VCPresetSettingsRow(
                        title: "Pro",
                        slot: 2,
                        model: $preset2Model,
                        think: $preset2Think,
                        defaultPreset: $defaultPreset,
                        activePreset: $activePreset,
                        currentModel: $model,
                        currentThink: $think
                    )
                } header: {
                    Text("Модели")
                } footer: {
                    Text("Галочка выбирает пресет, который первым открывается в Chat picker. Switch быстро меняет Light ↔ Pro без отдельных select-ов.")
                }

                Section {
                    HStack {
                        Text("Сервер")
                        Spacer()
                        Text(VoiceChatConfig.displayHost())
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                            .lineLimit(1).truncationMode(.middle)
                    }
                } footer: {
                    Text("Mac должен быть включён с запущенным Voice Record.")
                }

                Section {
                    HStack(spacing: 12) {
                        Button {
                            showLogs = true
                        } label: {
                            Label("Show debug log", systemImage: "doc.text.magnifyingglass")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            UIPasteboard.general.string = VCLog.readRecent(maxLines: 500)
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 36, height: 32)
                        }
                        .buttonStyle(.bordered)
                        .tint(.blue)

                        Button(role: .destructive) {
                            VCLog.clearLocal()
                            UINotificationFeedbackGenerator().notificationOccurred(.warning)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 36, height: 32)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("Keyboard/composer diagnostics live here. Reproduce the bug, then copy this log.")
                }
            }
            .sheet(isPresented: $showLogs) {
                VoiceChatLogViewerSheet()
            }
            .onAppear { VoiceChatConfig.ensureMobileModelPresetDefaults() }
    }
}

private struct VoiceChatLogViewerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text.isEmpty ? "(log is empty)" : text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(hex: "1C1C1E"))
            .navigationTitle("AI Chat log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            UIPasteboard.general.string = text
                        } label: {
                            Label("Copy all", systemImage: "doc.on.doc")
                        }
                        ShareLink(item: shareFile(), preview: SharePreview("ios-chat-log.txt")) {
                            Label("Share log", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            VCLog.clearLocal()
                            text = ""
                        } label: {
                            Label("Clear log", systemImage: "trash")
                        }
                        Button {
                            text = VCLog.readRecent(maxLines: 500)
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .onAppear {
            text = VCLog.readRecent(maxLines: 500)
        }
    }

    private func shareFile() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ios-chat-log.txt")
        try? text.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }
}

private struct VCPresetSettingsRow: View {
    let title: String
    let slot: Int
    @Binding var model: String
    @Binding var think: String
    @Binding var defaultPreset: Int
    @Binding var activePreset: Int
    @Binding var currentModel: String
    @Binding var currentThink: String

    private var isDefault: Bool { VoiceChatConfig.normalizedPreset(defaultPreset) == slot }
    private var isActive: Bool { VoiceChatConfig.normalizedPreset(activePreset) == slot }
    private var modelLabel: String { vcCompactModelLabel(model) }
    private var thinkLabel: String { vcCompactThinkLabel(think) }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.body.weight(.semibold))
                .frame(width: 48, alignment: .leading)

            Menu {
                ForEach(VC_MODELS) { option in
                    Button {
                        model = option.key
                        syncCurrentIfActive()
                    } label: {
                        if model == option.key {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
            } label: {
                settingsChip(modelLabel)
            }

            Menu {
                ForEach(VC_THINKING) { option in
                    Button {
                        think = option.key
                        syncCurrentIfActive()
                    } label: {
                        if think == option.key {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
            } label: {
                settingsChip(thinkLabel, active: think != "NONE")
            }

            Spacer(minLength: 0)

            Button {
                defaultPreset = slot
                activePreset = slot
                currentModel = model
                currentThink = think
                VoiceChatConfig.applyMobileModelPreset(slot)
            } label: {
                Image(systemName: isDefault ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isDefault ? VCAccent : Color.white.opacity(0.38))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isDefault ? "\(title) is default" : "Make \(title) default")
        }
        .listRowBackground(isActive ? VCAccent.opacity(0.16) : Color.white.opacity(0.05))
    }

    private func syncCurrentIfActive() {
        guard isActive else { return }
        currentModel = model
        currentThink = think
        VoiceChatConfig.applyMobileModelPreset(slot)
    }

    private func settingsChip(_ text: String, active: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .opacity(0.65)
        }
        .foregroundStyle(active ? VCAccent : Color.white.opacity(0.88))
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(active ? VCAccent : Color.white.opacity(0.12)))
    }
}

// MARK: - Chat title editor

private struct VoiceChatTitleEditorSheet: View {
    let initialTitle: String
    let placeholder: String
    let onSave: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @FocusState private var focused: Bool

    init(initialTitle: String, placeholder: String, onSave: @escaping (String?) -> Void) {
        self.initialTitle = initialTitle
        self.placeholder = placeholder
        self.onSave = onSave
        _title = State(initialValue: initialTitle)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(placeholder, text: $title, axis: .vertical)
                        .focused($focused)
                        .lineLimit(1...3)
                } footer: {
                    Text("Leave empty to use the automatic chat title.")
                }
                if !title.isEmpty {
                    Button("Reset to auto", role: .destructive) { title = "" }
                }
            }
            .navigationTitle("Rename chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(trimmed.isEmpty ? nil : trimmed)
                        dismiss()
                    }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.height(220), .medium])
    }
}

// Minimal font control: [−] 14px [+]. Tap the number to type it. Small —
// intrinsic width only, NOT a full-width row.
private struct FontStepper: View {
    let label: String
    @Binding var value: Double
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 0) {
                Button { value = max(10, value - 1) } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)

                if editing {
                    TextField("", text: $draft)
                        .keyboardType(.numberPad)
                        .focused($focused)
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .multilineTextAlignment(.center)
                        .frame(width: 44)
                        .onSubmit { commit() }
                        .onChange(of: focused) { _, f in if !f { commit() } }
                } else {
                    Text("\(Int(value))px")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .frame(width: 44)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            draft = String(Int(value)); editing = true
                            DispatchQueue.main.async { focused = true }
                        }
                }

                Button { value = min(24, value + 1) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.white)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
        }
    }

    private func commit() {
        editing = false
        if let v = Double(draft) { value = min(24, max(10, v)) }
    }
}

// Measures the docked composer's height so the transcript's bottom sentinel can
// be sized to it exactly (no fixed-142 dead space above the input).
private struct ComposerDockHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private extension Notification {
    var vcKeyboardEndFrame: CGRect? {
        if let rect = userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
            return rect
        }
        if let value = userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue {
            return value.cgRectValue
        }
        return nil
    }

    func vcKeyboardAnimation(opening: Bool, zeroDurationFallback: Double? = nil) -> Animation {
        let rawDuration = (userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let duration = rawDuration <= 0.01 ? (zeroDurationFallback ?? 0.01) : rawDuration
        let rawCurve = userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int ?? -1
        if rawCurve == 7 {
            if opening {
                let adjusted = min(0.28, max(0.18, duration * 0.70))
                return .timingCurve(0.17, 0.84, 0.44, 1.0, duration: adjusted)
            }
            return .easeOut(duration: duration)
        }
        guard let curveValue = userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int,
              let curve = UIView.AnimationCurve(rawValue: curveValue) else {
            // Keyboard notifications can report private curve values such as 7.
            // SwiftUI has no faithful representation for those UIKit bit patterns.
            return .easeOut(duration: duration)
        }
        let timing = UICubicTimingParameters(animationCurve: curve)
        return .timingCurve(
            Double(timing.controlPoint1.x),
            Double(timing.controlPoint1.y),
            Double(timing.controlPoint2.x),
            Double(timing.controlPoint2.y),
            duration: duration
        )
    }

    var vcKeyboardCurveDebug: String {
        let duration = (userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? -1
        let curve = userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int ?? -1
        return "\(curve)/\(String(format: "%.3f", duration))"
    }

    func vcKeyboardAnimationDebug(opening: Bool, zeroDurationFallback: Double? = nil) -> String {
        let rawDuration = (userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let duration = rawDuration <= 0.01 ? (zeroDurationFallback ?? 0.01) : rawDuration
        let curve = userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int ?? -1
        if curve == 7, opening {
            return "private7-open/front/\(String(format: "%.3f", min(0.28, max(0.18, duration * 0.70))))"
        }
        if curve == 7 {
            return "private7-close/easeOut/\(String(format: "%.3f", duration))"
        }
        return "public\(curve)/\(String(format: "%.3f", duration))"
    }
}

private extension CGRect {
    var vcDebug: String {
        "(\(Int(origin.x)),\(Int(origin.y)),\(Int(width)),\(Int(height)))"
    }
}

private extension View {
    @ViewBuilder
    func vcLiquidGlassCapsuleSurface() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.tint(.black.opacity(0.22)).interactive(), in: Capsule(style: .continuous))
        } else {
            self
                .background(.regularMaterial, in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
                }
        }
    }

    @ViewBuilder
    func vcLiquidGlassCircleSurface() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.tint(.black.opacity(0.22)).interactive(), in: Circle())
        } else {
            self
                .background(.regularMaterial, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
                }
        }
    }

    @ViewBuilder
    func vcLiquidGlassRoundedSurface(cornerRadius: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(
                .regular.tint(.black.opacity(0.24)).interactive(),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            self
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
                }
        }
    }
}
