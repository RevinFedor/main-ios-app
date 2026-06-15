import SwiftUI
import UIKit

private let CTAccent = Color(hex: "DA7756")
private let CTPageBackground = Color(white: 0.055)
private let CTHeaderBackground = Color(white: 0.055)
private let CTGreen = Color(hex: "22c55e")
private let CTCodexGreen = Color(hex: "22c55e")
private let CTViolet = Color(hex: "a78bfa")

// MARK: - Terminal back-swipe (UIKit recognizer)
//
// The Terminal back-swipe (rightward → up one nav level: chat→tabs→projects) must
// coexist with TWO other horizontal gestures on the same surface: the root pager
// (RootTabView's paging UIScrollView — leftward pages chat→Voice) and vertical
// list scrolling. A SwiftUI `DragGesture` cannot arbitrate with `UIScrollView` on
// iOS 18/26 (FB14688465; `fix-ios-stability.md::custom DragGesture kills scroll`):
// fast flicks were grabbed by the pager's pan and rubber-banded into empty space
// (the black area), slow drags reached the DragGesture — the "иногда листается,
// иногда нет" symptom. So this is a UIKit `UIPanGestureRecognizer`, mirroring
// `HistoryDrawerPanRecognizer`: it claims RIGHTWARD only and `canPrevent`s the
// scroll-view pan (back wins rightward, deterministically), and DECLINES leftward
// + vertical so the pager pages to Voice and lists scroll. Directional split =
// no race, no black overscroll.
private final class TerminalBackPanRecognizer: UIPanGestureRecognizer {
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Once we've begun (claimed a rightward back-swipe), prevent the root
        // pager's scroll pan so it can't also move.
        if preventedGestureRecognizer.isScrollViewPanGesture { return true }
        return super.canPrevent(preventedGestureRecognizer)
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        // We are never prevented by a scroll-view pan — our `shouldBegin` already
        // gated on direction, so if we begin we mean it.
        if preventingGestureRecognizer.isScrollViewPanGesture { return false }
        return super.canBePrevented(by: preventingGestureRecognizer)
    }
}

@available(iOS 18.0, *)
private struct TerminalBackPanGesture: UIGestureRecognizerRepresentable {
    let isEnabled: Bool          // swipeBackEnabled && canStepBack && no forward anim
    let width: CGFloat
    let onBegan: () -> Void
    let onChanged: (CGFloat) -> Void          // rightward translation, clamped ≥ 0
    let onEnded: (_ translationX: CGFloat, _ predictedX: CGFloat, _ velocityX: CGFloat) -> Void
    let onCancelled: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> TerminalBackPanRecognizer {
        let r = TerminalBackPanRecognizer()
        r.maximumNumberOfTouches = 1
        r.cancelsTouchesInView = true
        r.delaysTouchesBegan = false
        r.delaysTouchesEnded = false
        r.delegate = context.coordinator
        context.coordinator.configuration = self
        return r
    }

    func updateUIGestureRecognizer(_ recognizer: TerminalBackPanRecognizer, context: Context) {
        context.coordinator.configuration = self
    }

    func handleUIGestureRecognizerAction(_ recognizer: TerminalBackPanRecognizer, context: Context) {
        context.coordinator.handle(recognizer)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var configuration: TerminalBackPanGesture?

        func handle(_ recognizer: TerminalBackPanRecognizer) {
            guard let configuration, let view = recognizer.view else { return }
            let tx = recognizer.translation(in: view).x
            switch recognizer.state {
            case .began:
                VCLog.log("term-swipe", "uikit BEGAN tx=\(Int(tx))")
                configuration.onBegan()
            case .changed:
                configuration.onChanged(max(0, tx))
            case .ended:
                let v = recognizer.velocity(in: view).x
                // predicted end = current + velocity-projected (UIKit doesn't give
                // predictedEndTranslation on pan, approximate with v * 0.25s).
                let predicted = tx + v * 0.25
                VCLog.log("term-swipe", "uikit ENDED tx=\(Int(tx)) v=\(Int(v)) predicted=\(Int(predicted))")
                configuration.onEnded(tx, predicted, v)
            case .cancelled, .failed:
                VCLog.log("term-swipe", "uikit \(recognizer.state == .cancelled ? "CANCELLED" : "FAILED")")
                configuration.onCancelled()
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let configuration,
                  configuration.isEnabled,
                  let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = gestureRecognizer.view else {
                VCLog.log("term-swipe", "uikit shouldBegin=NO enabled=\(configuration?.isEnabled ?? false)")
                return false
            }
            let t = pan.translation(in: view)
            let v = pan.velocity(in: view)
            // RIGHTWARD + dominantly horizontal only. Leftward (page→Voice) and
            // vertical (list scroll) are declined so their owners win.
            let translationThreshold: CGFloat = 8
            let velocityThreshold: CGFloat = 140
            let translationRight = t.x >= translationThreshold && t.x >= abs(t.y) * 1.2
            // Slow-start rightward swipes often report almost zero translation on
            // shouldBegin, but a clear rightward velocity. The old 220pt/s gate let
            // those fall through to the root pager (black overscroll). Lower the
            // velocity gate, but require a stronger horizontal dominance so vertical
            // scrolls with a little rightward drift still lose.
            let velocityRight = v.x >= velocityThreshold && v.x >= abs(v.y) * 1.4
            let begin = translationRight || velocityRight
            VCLog.log("term-swipe", "uikit shouldBegin=\(begin ? "YES" : "no") t=(\(Int(t.x)),\(Int(t.y))) v=(\(Int(v.x)),\(Int(v.y)))")
            // DIAGNOSTIC (no behavior change): flag the "1-in-10 black overscroll"
            // case — a back-swipe is possible (isEnabled) and the gesture LEANS
            // rightward (the user meant to go back), but it failed BOTH thresholds,
            // so the recognizer declines and the rightward pan falls through to the
            // root pager → leading overscroll = black area. This isolates WHY it was
            // rejected: slow start (low velocity, small translation) vs not-yet-
            // horizontal. Grep [term-swipe-miss] to tune the thresholds next session.
            if !begin {
                let leansRight = t.x > 0 && v.x > 0          // intent was rightward
                let mostlyHorizontal = abs(t.x) >= abs(t.y)  // not a vertical scroll
                if leansRight && mostlyHorizontal {
                    let reason: String
                    if t.x < translationThreshold && v.x < velocityThreshold { reason = "below-both (slow start)" }
                    else if t.x < translationThreshold { reason = "translation<8" }
                    else { reason = "velocity<140/horizontal" }
                    VCLog.log("term-swipe-miss", "BACK MISS \(reason) → falls through to pager (black overscroll) t=(\(Int(t.x)),\(Int(t.y))) v=(\(Int(v.x)),\(Int(v.y)))")
                }
            }
            return begin
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            // Don't start a back-swipe from inside editable text. Do allow it from
            // row Buttons: Terminal back is a container gesture, and cancelsTouches
            // must beat the row tap when the user swipes right over a project/tab.
            var current = touch.view
            while let view = current {
                if view is UITextField || view is UITextView { return false }
                current = view.superview
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // Exclusive: once we own the rightward back-swipe, nobody else moves.
            false
        }
    }
}

private extension UIGestureRecognizer {
    var isScrollViewPanGesture: Bool {
        guard let scrollView = view as? UIScrollView else { return false }
        return scrollView.panGestureRecognizer === self
    }
}

private struct TerminalHeaderTitle: View {
    let title: String
    let subtitle: String
    let uiFont: Double
    var maxWidth: CGFloat = 210

    var body: some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.system(size: uiFont, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)

            Text(subtitle)
                .font(.system(size: max(9, uiFont - 4)))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: maxWidth)
    }
}

// Custom top header for the three Terminal levels — replaces the system `.toolbar`.
// WHY: the levels live inside a CUSTOM horizontal slide (not NavigationStack
// pushes), but each declared its own `.toolbar` + `.toolbarBackground` on the ONE
// shared navigation bar. Swapping levels made SwiftUI tear down and rebuild the
// nav bar's Liquid Glass chrome — the measured ~79ms first-commit (phase log
// commit=79ms), independent of row count, AND the visible "hamburger button
// doubles for a frame" (two nav bars overlap during the rebuild). A plain HStack
// header is just three views; swapping it is free, no nav-bar reconfiguration.
// Fixed gear on the left (unified settings), a center slot, a trailing slot.
private struct TerminalHeaderBar<Center: View, Trailing: View>: View {
    let onSettings: () -> Void
    @ViewBuilder let center: () -> Center
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            // Gear gets the same circular Liquid Glass as the system toolbar
            // buttons elsewhere in the app — the custom header had flattened it to
            // a bare glyph. Glass IS the button label, so the whole circle taps.
            Button(action: onSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .ctGlassCircle()
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
            center()
            Spacer(minLength: 0)

            // The trailing control (refresh / install) applies .ctGlassCircle()
            // to its OWN label at each call site, so its disabled/spinner state and
            // full-circle hit target stay correct; the header just lays it out.
            trailing()
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(CTHeaderBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
        }
    }
}

private struct TerminalFrozenChatHeader: View {
    let tab: CTTabInfo
    let uiFont: Double
    private let store = TerminalControlStore.shared

    private var tabId: String { tab.tabId ?? "" }
    private var status: String { store.statusByTab[tabId] ?? tab.sessionStatus ?? "inactive" }
    private var statusColor: Color {
        switch status {
        case "busy": return Color(hex: "d97706")
        case "active": return CTGreen
        case "starting": return CTAccent
        default: return Color(white: 0.38)
        }
    }

    var body: some View {
        VStack(spacing: 1) {
            Text(tab.name)
                .font(.system(size: uiFont, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
            HStack(spacing: 4) {
                Circle().fill(statusColor).frame(width: 6, height: 6)
                Text(status)
                    .font(.system(size: max(9, uiFont - 4)).monospacedDigit())
                    .foregroundStyle(.secondary)
                if tab.isClaudePTY || tab.isCodexPTY || tab.isSDK {
                    if let pct = store.contextPctByTab[tabId] {
                        Text("· \(pct)%")
                            .font(.system(size: max(11, uiFont - 2), weight: .semibold).monospacedDigit())
                            .foregroundStyle(contextPctColor(pct))
                    } else {
                        Text("· –")
                            .font(.system(size: max(11, uiFont - 2), weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: 220)
    }
}

private extension View {
    // Circular Liquid Glass surface for header icon buttons — mirrors the app's
    // vcLiquidGlassCircleSurface() (private to VoiceChatUI). Sizes the content to a
    // fixed circle so the glass and the tap target coincide.
    @ViewBuilder
    func ctGlassCircle(diameter: CGFloat = 38) -> some View {
        if #available(iOS 26.0, *) {
            self.frame(width: diameter, height: diameter)
                .glassEffect(.regular.tint(.black.opacity(0.22)).interactive(), in: Circle())
                .contentShape(Circle())
        } else {
            self.frame(width: diameter, height: diameter)
                .background(.regularMaterial, in: Circle())
                .overlay { Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5) }
                .contentShape(Circle())
        }
    }

    @ViewBuilder
    func ctGlassCapsule(width: CGFloat, height: CGFloat = 38) -> some View {
        if #available(iOS 26.0, *) {
            self.frame(width: width, height: height)
                .glassEffect(.regular.tint(.black.opacity(0.22)).interactive(), in: Capsule())
                .contentShape(Capsule())
        } else {
            self.frame(width: width, height: height)
                .background(.regularMaterial, in: Capsule())
                .overlay { Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5) }
                .contentShape(Capsule())
        }
    }
}

private struct TerminalActivityBadge: View {
    let count: Int
    let streaming: Bool
    // The ring is a tiny UIKit/CALayer view, not SwiftUI repeatForever state.
    // Project rows can keep a live-looking loader without re-entering SwiftUI
    // body every frame or restarting animation on row re-renders.
    var animated: Bool = true

    var body: some View {
        ZStack {
            TerminalActivityRingView(streaming: streaming, animated: animated)
            Text("\(min(count, 99))")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.92))
        }
        .frame(width: 22, height: 22)
        .accessibilityLabel(streaming ? "Active terminal tabs, streaming" : "Active terminal tabs")
        .accessibilityValue("\(count)")
    }
}

private struct TerminalActivityRingView: UIViewRepresentable {
    let streaming: Bool
    let animated: Bool

    func makeUIView(context: Context) -> TerminalActivityRingUIView {
        TerminalActivityRingUIView()
    }

    func updateUIView(_ uiView: TerminalActivityRingUIView, context: Context) {
        uiView.configure(streaming: streaming, animated: animated)
    }
}

private final class TerminalActivityRingUIView: UIView {
    private let fillLayer = CAShapeLayer()
    private let outlineLayer = CAShapeLayer()
    private let arcLayer = CAShapeLayer()
    private var isStreaming = false
    private var isAnimated = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.addSublayer(fillLayer)
        layer.addSublayer(outlineLayer)
        layer.addSublayer(arcLayer)

        fillLayer.fillColor = UIColor.white.withAlphaComponent(0.075).cgColor
        outlineLayer.fillColor = UIColor.clear.cgColor
        outlineLayer.strokeColor = UIColor.white.withAlphaComponent(0.16).cgColor
        outlineLayer.lineWidth = 1
        arcLayer.fillColor = UIColor.clear.cgColor
        arcLayer.strokeColor = UIColor(red: 0x22 / 255, green: 0xc5 / 255, blue: 0x5e / 255, alpha: 1).cgColor
        arcLayer.lineWidth = 1.5
        arcLayer.lineCap = .round
        arcLayer.strokeStart = 0.08
        arcLayer.strokeEnd = 0.78
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(streaming: Bool, animated: Bool) {
        let changed = streaming != isStreaming || animated != isAnimated
        isStreaming = streaming
        isAnimated = animated
        arcLayer.isHidden = !streaming
        guard changed else { return }

        if streaming && animated {
            if arcLayer.animation(forKey: "terminalActivitySpin") == nil {
                let animation = CABasicAnimation(keyPath: "transform.rotation.z")
                animation.fromValue = 0
                animation.toValue = Double.pi * 2
                animation.duration = 1.35
                animation.repeatCount = .infinity
                animation.timingFunction = CAMediaTimingFunction(name: .linear)
                arcLayer.add(animation, forKey: "terminalActivitySpin")
            }
        } else {
            arcLayer.removeAnimation(forKey: "terminalActivitySpin")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            arcLayer.transform = CATransform3DIdentity
            CATransaction.commit()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = UIBezierPath(ovalIn: rect).cgPath
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.frame = bounds
        outlineLayer.frame = bounds
        arcLayer.frame = bounds
        fillLayer.path = UIBezierPath(ovalIn: bounds).cgPath
        outlineLayer.path = path
        arcLayer.path = path
        CATransaction.commit()
    }
}

private enum TerminalForwardDestination: Identifiable {
    case project(CTProject)
    case tab(CTTabInfo, CTProject)

    var id: String {
        switch self {
        case .project(let project):
            return "project:" + project.id
        case .tab(let tab, let project):
            return "tab:" + project.id + ":" + tab.id
        }
    }
}

private enum TerminalNavLevel: Int {
    case projects = 0
    case tabs = 1
    case chat = 2

    var previous: TerminalNavLevel? {
        switch self {
        case .projects: return nil
        case .tabs: return .projects
        case .chat: return .tabs
        }
    }
}

struct TerminalControlRootView: View {
    let onShowHistory: () -> Void
    var onComposerFocusChange: (Bool) -> Void = { _ in }
    var swipeBackEnabled = true
    @EnvironmentObject private var router: TabRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(VoiceChatConfig.Keys.uiFont, store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var uiFont: Double = 14
    private let store = TerminalControlStore.shared   // @Observable singleton (Phase C)
    @State private var backDragOffset: CGFloat = 0
    @State private var forwardDestination: TerminalForwardDestination?
    @State private var forwardOffset: CGFloat = 0
    // Generation token for forward-push animations. A back-swipe that interrupts an
    // in-flight push bumps this, so the original push's `completion` (which commits
    // the navigation) sees a stale generation and no-ops — the push is abandoned
    // instead of committing under the user who just swiped back.
    @State private var forwardGeneration = 0
    // True from the instant a rightward back-swipe interrupts a forward push until
    // the reverse animation settles. While set, the back-drag's changed/ended are
    // ignored — the reverse is a single committed animation, not finger-tracked.
    @State private var interruptingForward = false
    @State private var horizontalScrollLocked = false
    @State private var terminalSelectionSuppressed = false
    @State private var terminalSelectionSuppressionGeneration = 0
    @State private var terminalHeavySurfaceSuspended = false
    @State private var showBuildInstallConfirm = false
    @State private var installAlert: TerminalInstallAlert?
    @State private var rootRenameTab: CTTabInfo?
    @State private var chatLogLineCount: Int = 0
    private let chatLogCountTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @AppStorage(VoiceChatConfig.Keys.developerMode, store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var developerMode: Bool = true
    // True from the instant a back-swipe begins (before the offset moves), so the
    // heavy back-preview list mounts and renders one frame EARLY instead of
    // instantiating on the same frame the drag first offsets it — that same-frame
    // cost was the stutter when sliding back to the projects list.
    @State private var backInteractionActive = false
    // Immutable destination snapshot captured at back-swipe start; the preview
    // renders from this, observing no live store state during the slide.
    @State private var backPreviewSnapshot: TerminalBackPreviewSnapshot = .none
    // Frozen SOURCE layer for any horizontal transition. Without this, the
    // outgoing projects/tabs view stayed live while sliding, so store/AppStorage
    // invalidations could repaint the layer that is currently moving.
    @State private var transitionSourceSnapshot: TerminalBackPreviewSnapshot = .none
    // Immutable source snapshot for chat→tabs back. During the slide-out we render
    // a cheap placeholder instead of the live transcript, so late history/cell work
    // cannot repaint the outgoing layer while it is animating away.
    @State private var backOutgoingSnapshot: TerminalOutgoingSnapshot = .none
    // Same idea for the FORWARD push into a project's tabs: capture the tabs once
    // at push-start so the incoming layer renders static during the slide.
    @State private var forwardTabsSnapshot: TerminalBackPreviewSnapshot = .none
    // Covers the live committed screen for a short beat after a transition. The
    // navigation state is already committed (so gestures behave correctly), while
    // the expensive live SwiftUI tree mounts behind this inert snapshot.
    @State private var terminalSnapshotOverlay: TerminalBackPreviewSnapshot = .none
    @State private var terminalBitmapTransition: TerminalBitmapTransitionState?
    @State private var terminalBitmapOverlayView: TerminalBitmapTransitionHostView?
    @State private var terminalSnapshotHostView: UIView?
    @State private var cachedProjectsBitmap: UIImage?
    @State private var cachedTabsBitmapByProject: [String: UIImage] = [:]
    // The visible store selection is still the source of truth for network/SSE.
    // These are only retained view inputs so projects/tabs layers stay mounted
    // when the committed selection moves back up the stack.
    @State private var persistentProject: CTProject?
    @State private var persistentTab: CTTabInfo?
    @Environment(\.bottomBarInset) private var bottomBarInset
    private var terminalInteractionsSuspended: Bool {
        terminalSelectionSuppressed || forwardDestination != nil || backDragOffset > 0
    }
    private var terminalRenderSuspended: Bool {
        terminalInteractionsSuspended || terminalHeavySurfaceSuspended
    }
    private let snapshotOverlayHoldMs: UInt64 = 220
    // Keep row spinners/context menus/refresh/FAB parked past FrameMonitor's
    // settle window. 22:56 traces showed tab rows re-enabling at ~420ms into
    // settle (`term-render row bodies=18`) and causing 80ms frames while the
    // user was already backing out. Row buttons remain live; only heavy chrome
    // and animated indicators are deferred.
    private let heavySurfaceResumeDelayMs: UInt64 = 1_500
    private let projectForwardPreRenderMs: UInt64 = 32
    private let bitmapOverlayPreflightMs: UInt64 = 24
    private let bitmapPushDuration: TimeInterval = 0.14
    private let bitmapBackDuration: TimeInterval = 0.13
    // Targeted bitmap was re-tested at 00:29 and reproduced the old visual races
    // (missing/incorrect preview, same page flashing over itself). Keep it off
    // unless the whole projects/tabs boundary moves to a true UIKit container.
    private let terminalBitmapProjectTransitionsEnabled = false
    private let terminalBitmapChatTransitionsEnabled = false
    // Stop-loss: the project directory boundary is currently too unstable as an
    // animated SwiftUI/bitmap hybrid. Make forward project opens instant so the
    // outgoing projects ScrollView cannot visibly re-anchor mid-slide.
    private let terminalAnimatedProjectPushEnabled = false
    // Phase E: move the projects/tabs/chat navigation surface into a UIKit-owned
    // container. The SwiftUI stack below remains as a fallback while the new
    // container takes ownership of horizontal navigation and vertical scroll state.
    private let terminalUIKitContainerEnabled = true
    private var terminalSnapshotOverlayActive: Bool {
        switch terminalSnapshotOverlay {
        case .none: return false
        case .projects, .tabs: return true
        }
    }
    private var terminalBitmapMotionActive: Bool {
        guard let terminalBitmapTransition else { return false }
        return terminalBitmapTransition.mode != .hold
    }
    private var terminalMotionActive: Bool {
        terminalBitmapMotionActive || forwardDestination != nil || backInteractionActive || backDragOffset > 0
    }
    private var terminalCommittedLevel: TerminalNavLevel {
        if store.selectedTab != nil { return .chat }
        if store.selectedProject != nil { return .tabs }
        return .projects
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                terminalRootHeader
                    .transaction { $0.animation = nil }
                    .zIndex(10)

                GeometryReader { contentGeo in
                    let contentSize = contentGeo.size
                    if terminalUIKitContainerEnabled {
                        TerminalUIKitNavigationHost(
                            onShowHistory: onShowHistory,
                            onComposerFocusChange: onComposerFocusChange,
                            bottomBarInset: bottomBarInset
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(CTPageBackground.ignoresSafeArea())
                        .clipped()
                    } else {
                        ZStack(alignment: .leading) {
                            terminalPersistentLayer(.projects, size: contentSize)
                                .frame(width: contentSize.width)
                                .overlay(alignment: .leading) {
                                    if terminalLayerNeedsEdgeShade(.projects, width: contentSize.width) {
                                        terminalEdgeShade.frame(width: 18).offset(x: -18)
                                    }
                                }
                                .offset(x: terminalLayerOffset(.projects, width: contentSize.width))
                                .zIndex(terminalLayerZIndex(.projects))
                                .allowsHitTesting(terminalLayerAllowsHitTesting(.projects))

                            terminalPersistentLayer(.tabs, size: contentSize)
                                .frame(width: contentSize.width)
                                .overlay(alignment: .leading) {
                                    if terminalLayerNeedsEdgeShade(.tabs, width: contentSize.width) {
                                        terminalEdgeShade.frame(width: 18).offset(x: -18)
                                    }
                                }
                                .offset(x: terminalLayerOffset(.tabs, width: contentSize.width))
                                .zIndex(terminalLayerZIndex(.tabs))
                                .allowsHitTesting(terminalLayerAllowsHitTesting(.tabs))

                            terminalPersistentLayer(.chat, size: contentSize)
                                .frame(width: contentSize.width)
                                .overlay(alignment: .leading) {
                                    if terminalLayerNeedsEdgeShade(.chat, width: contentSize.width) {
                                        terminalEdgeShade.frame(width: 18).offset(x: -18)
                                    }
                                }
                                .offset(x: terminalLayerOffset(.chat, width: contentSize.width))
                                .zIndex(terminalLayerZIndex(.chat))
                                .allowsHitTesting(terminalLayerAllowsHitTesting(.chat))

                            TerminalBitmapTransitionOverlay(state: terminalBitmapTransition) { view in
                                if terminalBitmapOverlayView !== view {
                                    terminalBitmapOverlayView = view
                                }
                            }
                                .frame(width: contentSize.width, height: contentSize.height)
                                .allowsHitTesting(false)
                                .zIndex(30)
                        }
                        .background(TerminalSnapshotHostReader { terminalSnapshotHostView = $0 })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .scrollDisabled(horizontalScrollLocked)
                        .gesture(
                            TerminalBackPanGesture(
                                isEnabled: swipeBackEnabled && !interruptingForward && (forwardDestination != nil || store.canStepBack),
                                width: contentSize.width,
                                onBegan: { beginTerminalBackDrag(size: contentSize) },
                                onChanged: { tx in updateTerminalBackDrag(tx, width: contentSize.width) },
                                onEnded: { tx, predicted, _ in endTerminalBackDrag(tx, predicted: predicted, size: contentSize) },
                                onCancelled: { cancelTerminalBackDrag() }
                            )
                        )
                    }
                }
            }
            .background(CTPageBackground.ignoresSafeArea())
            .onAppear {
                store.resetNavigationToProjectsOnFirstOpen()
                store.start()
                chatLogLineCount = VCLog.lineCount()
                syncPersistentTerminalSelection()
            }
            .onReceive(chatLogCountTimer) { _ in
                guard developerMode else { return }
                let count = VCLog.lineCount()
                if count != chatLogLineCount { chatLogLineCount = count }
            }
            .onChange(of: store.selectedProject?.id) { _, _ in
                syncPersistentTerminalSelection()
            }
            .onChange(of: store.selectedTab?.tabId) { _, _ in
                syncPersistentTerminalSelection()
            }
            .onDisappear {
                if let tabId = store.selectedTab?.tabId, !tabId.isEmpty {
                    VoiceChatStore.shared.clearActiveComposerKey(VoiceChatStore.terminalComposerKey(tabId: tabId))
                }
            }
        }
        .confirmationDialog("Запустить npm run build:install?", isPresented: $showBuildInstallConfirm, titleVisibility: .visible) {
            Button("Запустить install", role: .destructive) {
                VCLog.log("TerminalInstallUI", "confirm accepted")
                Task { await runBuildInstall() }
            }
            Button("Отмена", role: .cancel) {
                VCLog.log("TerminalInstallUI", "confirm cancelled")
            }
        } message: {
            Text("Custom Terminal станет недоступен на время переустановки. Запуск пойдёт через Voice Record, поэтому процесс не оборвётся при закрытии Terminal.")
        }
        .alert(item: $installAlert) { item in
            Alert(
                title: Text(item.title),
                message: Text(item.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .sheet(item: $rootRenameTab) { tab in
            CTRenameSheet(title: "Rename tab", label: "Tab name", initialName: tab.name) { newName in
                store.renameTab(tab, to: newName)
            }
        }
        // Keep the system NavigationStack bar out of every transient Terminal
        // surface, including forward/back snapshots. Hiding it only inside the
        // three committed level views left short windows where a snapshot without
        // that modifier could let SwiftUI relayout the top chrome, seen as the
        // custom header disappearing / height twitching during transitions.
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }

    private func syncPersistentTerminalSelection() {
        if let project = store.selectedProject {
            persistentProject = project
        }
        if let tab = store.selectedTab {
            persistentTab = tab
        }
    }

    @ViewBuilder
    private func terminalPersistentLayer(_ level: TerminalNavLevel, size: CGSize) -> some View {
        switch level {
        case .projects:
            // Projects must stay as the live ScrollView while sliding both ways.
            // A value preview cannot preserve the user's vertical offset, so it
            // looks like an instant jump to the top on push/back.
            TerminalProjectsView(onShowHistory: onShowHistory, interactionsSuspended: terminalInteractionsSuspended, renderSuspended: terminalRenderSuspended, showsHeader: false) { project in
                pushProject(project, size: size)
            }
        case .tabs:
            ZStack {
                if let project = terminalLayerProject {
                    // Keep the real tabs screen mounted even while a static proxy is
                    // moving above it. This pays ScrollView/Button/scrollPosition
                    // construction in the pre-render mount phase instead of the
                    // visible settle tail after `store.selectProject`.
                    TerminalProjectTabsView(project: project, onShowHistory: onShowHistory, interactionsSuspended: terminalInteractionsSuspended, renderSuspended: terminalRenderSuspended, showsHeader: false) { tab in
                        pushTab(tab, project: project, size: size)
                    }
                    .opacity(terminalTabsLiveVisible ? 1 : 0)
                    .allowsHitTesting(terminalTabsLiveHitTesting)
                } else {
                    CTPageBackground.ignoresSafeArea()
                }

                if backInteractionActive,
                   terminalCommittedLevel == .chat,
                   case .tabs(let tabs, let marker, let name) = backPreviewSnapshot {
                    TerminalTabsBackPreview(tabs: tabs, marker: marker, projectName: name, style: .lightweight, showsHeader: false)
                } else if backInteractionActive,
                          terminalCommittedLevel == .tabs,
                          case .tabs(let tabs, let marker, let name) = transitionSourceSnapshot {
                    TerminalTabsBackPreview(tabs: tabs, marker: marker, projectName: name, style: .lightweight, showsHeader: false)
                } else if case .project = forwardDestination,
                          case .tabs(let tabs, let marker, let name) = forwardTabsSnapshot {
                    TerminalTabsBackPreview(tabs: tabs, marker: marker, projectName: name, style: .lightweight, showsHeader: false)
                }
            }
        case .chat:
            if let tab = terminalLayerTab {
                if terminalLayerShouldShowLiveChat(tab) {
                    TerminalChatDetailView(tab: tab, onShowHistory: onShowHistory, onComposerFocusChange: onComposerFocusChange, showsHeader: false)
                } else {
                    TerminalChatForwardPlaceholder(tab: tab, showsHeader: false)
                }
            } else {
                CTPageBackground.ignoresSafeArea()
            }
        }
    }

    private var terminalLayerProject: CTProject? {
        if case .project(let project) = forwardDestination {
            return project
        }
        if case .tab(_, let project) = forwardDestination {
            return project
        }
        return store.selectedProject ?? persistentProject
    }

    private var terminalLayerTab: CTTabInfo? {
        if case .tab(let tab, _) = forwardDestination {
            return tab
        }
        if let tab = store.selectedTab {
            return tab
        }
        if backInteractionActive, case .chat(let tab) = backOutgoingSnapshot {
            return tab
        }
        return nil
    }

    private func terminalLayerShouldShowLiveChat(_ tab: CTTabInfo) -> Bool {
        store.selectedTab?.tabId == tab.tabId && forwardDestination == nil
    }

    private var terminalTabsProxyActive: Bool {
        if case .project = forwardDestination { return true }
        if backInteractionActive {
            return terminalCommittedLevel == .tabs || terminalCommittedLevel == .chat
        }
        return false
    }

    private var terminalTabsLiveVisible: Bool {
        terminalCommittedLevel == .tabs && !terminalTabsProxyActive
    }

    private var terminalTabsLiveHitTesting: Bool {
        terminalCommittedLevel == .tabs && !terminalMotionActive
    }

    private func terminalTargetLevel(for destination: TerminalForwardDestination) -> TerminalNavLevel {
        switch destination {
        case .project:
            return .tabs
        case .tab:
            return .chat
        }
    }

    private func terminalLayerOffset(_ level: TerminalNavLevel, width: CGFloat) -> CGFloat {
        guard terminalBitmapTransition == nil else { return 0 }
        guard width > 0 else { return 0 }

        if let forwardDestination {
            let source = terminalCommittedLevel
            let target = terminalTargetLevel(for: forwardDestination)
            if level == source {
                return terminalForwardContentOffset(width: width)
            }
            if level == target {
                return forwardOffset
            }
            return restingOffset(for: level, committed: source, width: width)
        }

        if backInteractionActive {
            let source = terminalCommittedLevel
            let target = source.previous ?? .projects
            if level == source {
                return backDragOffset
            }
            if level == target {
                return terminalBackPreviewOffset(width: width)
            }
            return restingOffset(for: level, committed: source, width: width)
        }

        return restingOffset(for: level, committed: terminalCommittedLevel, width: width)
    }

    private func restingOffset(for level: TerminalNavLevel, committed: TerminalNavLevel, width: CGFloat) -> CGFloat {
        if level == committed { return 0 }
        if level.rawValue < committed.rawValue {
            return -min(72, width * 0.22)
        }
        return width
    }

    private func terminalLayerZIndex(_ level: TerminalNavLevel) -> Double {
        Double(level.rawValue)
    }

    private func terminalLayerAllowsHitTesting(_ level: TerminalNavLevel) -> Bool {
        !terminalMotionActive && terminalCommittedLevel == level
    }

    private func terminalLayerNeedsEdgeShade(_ level: TerminalNavLevel, width: CGFloat) -> Bool {
        guard level != .projects, width > 0 else { return false }
        let x = terminalLayerOffset(level, width: width)
        return x > -1 && x < width
    }

    @ViewBuilder
    private func terminalContent(size: CGSize) -> some View {
        if (backInteractionActive || forwardDestination != nil) && !transitionSourceSnapshot.isEmpty {
            terminalSourceSnapshotView
        } else if let tab = store.selectedTab {
            if backInteractionActive, case .chat(let outgoingTab) = backOutgoingSnapshot {
                TerminalChatForwardPlaceholder(tab: outgoingTab, showsHeader: false)
            } else {
                TerminalChatDetailView(tab: tab, onShowHistory: onShowHistory, onComposerFocusChange: onComposerFocusChange, showsHeader: false)
            }
        } else if let project = store.selectedProject {
            TerminalProjectTabsView(project: project, onShowHistory: onShowHistory, interactionsSuspended: terminalInteractionsSuspended, renderSuspended: terminalRenderSuspended, showsHeader: false) { tab in
                pushTab(tab, project: project, size: size)
            }
        } else {
            TerminalProjectsView(onShowHistory: onShowHistory, interactionsSuspended: terminalInteractionsSuspended, renderSuspended: terminalRenderSuspended, showsHeader: false) { project in
                pushProject(project, size: size)
            }
        }
    }

    @ViewBuilder
    private var terminalSourceSnapshotView: some View {
        switch transitionSourceSnapshot {
        case .projects(let rows):
            TerminalProjectsBackPreview(rows: rows, showsHeader: false)
        case .tabs(let tabs, let marker, let name):
            TerminalTabsBackPreview(tabs: tabs, marker: marker, projectName: name, style: .lightweight, showsHeader: false)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private var terminalRootHeader: some View {
        if let tab = store.selectedTab {
            TerminalHeaderBar(onSettings: { router.openSettings() }) {
                terminalRootChatHeader(tab)
            } trailing: {
                HStack(spacing: 6) {
                    terminalDebugLogButtons
                    Button { Task { await store.loadHistory(tabId: tab.tabId ?? "") } } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .semibold))
                            .ctGlassCircle()
                    }
                    .buttonStyle(.plain)
                }
            }
        } else if let project = store.selectedProject {
            TerminalHeaderBar(onSettings: { router.openSettings() }) {
                TerminalHeaderTitle(title: project.name, subtitle: "Terminal projects", uiFont: uiFont, maxWidth: 190)
            } trailing: {
                HStack(spacing: 6) {
                    terminalDebugLogButtons
                    Button { Task { await store.loadTabs(projectId: project.id) } } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .semibold))
                            .ctGlassCircle()
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            TerminalHeaderBar(onSettings: { router.openSettings() }) {
                TerminalHeaderTitle(title: "Terminal", subtitle: TerminalControlConfig.displayHost(), uiFont: uiFont)
            } trailing: {
                HStack(spacing: 6) {
                    terminalDebugLogButtons
                    Button {
                        VCLog.log("TerminalInstallUI", "button tap running=\(store.terminalInstallRunning) offline=\(store.offline) projects=\(store.projects.count)")
                        Task { await prepareBuildInstall() }
                    } label: {
                        Group {
                            if store.terminalInstallRunning {
                                ProgressView().controlSize(.small).tint(.white)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                        }
                        .ctGlassCircle()
                    }
                    .buttonStyle(.plain)
                    .disabled(store.terminalInstallRunning)
                    .accessibilityLabel("Run npm install build")
                }
            }
        }
    }

    @ViewBuilder
    private var terminalDebugLogButtons: some View {
        if developerMode {
            Button {
                UIPasteboard.general.string = VCLog.readRecent(maxLines: 1_000)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                chatLogLineCount = VCLog.lineCount()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 14, weight: .semibold))
                    Text("(\(chatLogLineCount))")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .foregroundStyle(.white.opacity(0.92))
                .ctGlassCapsule(width: 64, height: 38)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy Terminal and AI Chat log, \(chatLogLineCount) lines")

            Button {
                VCLog.clearLocal()
                chatLogLineCount = 0
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.red)
                    .ctGlassCircle()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear Terminal and AI Chat log")
        }
    }

    @ViewBuilder
    private func terminalRootChatHeader(_ tab: CTTabInfo) -> some View {
        TerminalFrozenChatHeader(tab: tab, uiFont: uiFont)
            .contentShape(Rectangle())
            .contextMenu {
                Button { rootRenameTab = tab } label: { Label("Rename", systemImage: "pencil") }
                Button { UIPasteboard.general.string = tab.name } label: { Label("Copy name", systemImage: "doc.on.doc") }
                if !tab.isCodexPTY {
                    let tabId = tab.tabId ?? ""
                    let thinkingOn = (store.paramsByTab[tabId]?.thinking ?? "adaptive") != "disabled"
                    Button {
                        Task { await store.setParams(tabId: tabId, partial: ["thinking": thinkingOn ? "disabled" : "adaptive"]) }
                    } label: {
                        Label(thinkingOn ? "Think: ON" : "Think: OFF", systemImage: thinkingOn ? "brain.head.profile.fill" : "brain")
                    }
                    .disabled(store.isTabTurnBusy(tabId))
                }
            }
    }

    @ViewBuilder
    private func terminalForwardView(_ destination: TerminalForwardDestination, width: CGFloat) -> some View {
        switch destination {
        case .project(let project):
            // Render a STATIC snapshot of the destination tabs during the push
            // slide (reads no @Observable state), not the live TerminalProjectTabsView
            // — which read store.tabsByProject + activitySummary per row and got its
            // body re-run every frame by mid-slide store mutations (the forward-push
            // hitch: 63 dropped frames, term-render bodies=30, no main hang). The
            // live view mounts in terminalContent once the push commits.
            if case .tabs(let tabs, let marker, let name) = forwardTabsSnapshot, !tabs.isEmpty {
                TerminalTabsBackPreview(tabs: tabs, marker: marker, projectName: name, style: .lightweight, showsHeader: false)
            } else {
                TerminalProjectTabsView(project: project, onShowHistory: onShowHistory, interactionsSuspended: true, renderSuspended: true, showsHeader: false) { tab in
                    pushTab(tab, project: project, size: CGSize(width: width, height: 0))
                }
            }
        case .tab(let tab, _):
            // Like the tabs case: render a STATIC, cheap placeholder during the
            // slide, NOT the live TerminalChatDetailView. The live detail mounts a
            // ScrollView + LazyVStack + composer AND kicks off the history load
            // (one chat was 546 KB JSON) — all on the main thread, competing with
            // the slide animation (commit=103ms). The placeholder matches the chat
            // header geometry so nothing jumps; the live detail mounts in
            // terminalContent once the push commits.
            TerminalChatForwardPlaceholder(tab: tab, showsHeader: false)
        }
    }

    @ViewBuilder
    private var terminalSnapshotOverlayView: some View {
        switch terminalSnapshotOverlay {
        case .tabs(let tabs, let marker, let name):
            TerminalTabsBackPreview(tabs: tabs, marker: marker, projectName: name, style: .lightweight, showsHeader: false)
        case .projects(let rows):
            TerminalProjectsBackPreview(rows: rows, showsHeader: false)
        case .none:
            EmptyView()
        }
    }

    // Static edge gradient that fakes the sliding layer's drop shadow at near-zero
    // GPU cost (no per-frame shadow rasterization). Dark at the layer edge → clear.
    private var terminalEdgeShade: some View {
        LinearGradient(
            colors: [Color.black.opacity(0.28), Color.black.opacity(0)],
            startPoint: .trailing, endPoint: .leading
        )
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var terminalBackPreview: some View {
        // Render from the snapshot captured at slide-start (backPreviewSnapshot),
        // NOT live store reads — so a status-poll/SSE mutation mid-slide can't
        // re-run this subtree's body. Falls back to a live capture if the snapshot
        // is somehow empty (defensive).
        switch backPreviewSnapshot {
        case .tabs(let tabs, let marker, let name):
            TerminalTabsBackPreview(tabs: tabs, marker: marker, projectName: name, style: .lightweight, showsHeader: false)
        case .projects(let rows):
            TerminalProjectsBackPreview(rows: rows, showsHeader: false)
        case .none:
            Color.clear
        }
    }

    // Immutable snapshot of the destination shown during the back-slide. Captured
    // once in beginTerminalBackDrag so the preview observes no @Observable state.
    private func captureBackPreviewSnapshot() -> TerminalBackPreviewSnapshot {
        if store.selectedTab != nil, let project = store.selectedProject {
            let tabs = store.tabsByProject[project.id] ?? []
            let marker = store.statusMarkerByProject[project.id] ?? .fallback
            return .tabs(tabs, marker, project.name)
        } else {
            let rows = store.projects.map {
                CTProjectRowSnapshot(project: $0, activity: store.activitySummary(projectId: $0.id))
            }
            return .projects(rows)
        }
    }

    private func captureBackOutgoingSnapshot() -> TerminalOutgoingSnapshot {
        if let tab = store.selectedTab { return .chat(tab) }
        return .none
    }

    private func captureTransitionSourceSnapshot() -> TerminalBackPreviewSnapshot {
        if store.selectedTab != nil {
            return .none
        }
        if let project = store.selectedProject {
            let tabs = store.tabsByProject[project.id] ?? []
            let marker = store.statusMarkerByProject[project.id] ?? .fallback
            return .tabs(tabs, marker, project.name)
        }
        let rows = store.projects.map {
            CTProjectRowSnapshot(project: $0, activity: store.activitySummary(projectId: $0.id))
        }
        return .projects(rows)
    }

    // UIKit back-swipe handlers (driven by TerminalBackPanGesture). The recognizer
    // already gated direction/enable in shouldBegin, so these just track the drag.
    private func beginTerminalBackDrag(size: CGSize) {
        let width = size.width
        // INTERRUPT case: a forward push is mid-flight. The committed level under it
        // is still the SOURCE level (selection commits only at the push's completion),
        // so reversing here just abandons the push — no back-step needed. Bump the
        // generation so the push's completion no-ops, then animate the forward layer
        // back out and tear it down. This is a committed reverse, not finger-tracked
        // (interpolating a half-played .easeOut from the finger fights the in-flight
        // animation); the user gets immediate visual response + lands on the source.
        if forwardDestination != nil {
            VCLog.log("term-swipe", "begin drag — INTERRUPT forward push, reversing")
            forwardGeneration += 1
            interruptingForward = true
            beginTerminalHorizontalInteraction(label: "interrupt-forward from=\(terminalLevelLabel)", initialPhase: "interrupt")
            withAnimation(.easeOut(duration: 0.16), completionCriteria: .logicallyComplete) {
                forwardOffset = width
            } completion: {
                commitWithoutTerminalAnimation {
                    forwardDestination = nil
                    forwardOffset = 0
                    forwardTabsSnapshot = .none
                    transitionSourceSnapshot = .none
                    interruptingForward = false
                    endTerminalHorizontalInteraction()
                }
            }
            return
        }
        VCLog.log("term-swipe", "begin drag level=\(terminalLevelLabel)")
        if beginBitmapBackDrag(size: size) {
            return
        }
        backPreviewSnapshot = captureBackPreviewSnapshot()
        transitionSourceSnapshot = captureTransitionSourceSnapshot()
        backOutgoingSnapshot = captureBackOutgoingSnapshot()
        backInteractionActive = true   // mount the preview before the offset moves
        beginTerminalHorizontalInteraction(label: "back from=\(terminalLevelLabel)", initialPhase: "gesture")
    }

    private func updateTerminalBackDrag(_ translationX: CGFloat, width: CGFloat) {
        // An interrupt-reverse owns the animation; ignore finger tracking during it.
        guard !interruptingForward, forwardDestination == nil else { return }
        if terminalBitmapTransition != nil {
            terminalBitmapOverlayView?.setInteractiveOffset(
                min(translationX, max(0, width - 18)),
                mode: .back
            )
            return
        }
        backDragOffset = min(translationX, max(0, width - 18))
    }

    private func endTerminalBackDrag(_ translationX: CGFloat, predicted: CGFloat, size: CGSize) {
        let width = size.width
        // The interrupt-reverse (begun in beginTerminalBackDrag) owns its own
        // animation + teardown; the gesture's end must not commit a second step.
        if interruptingForward || forwardDestination != nil {
            VCLog.log("term-swipe", "end ignored (interrupt-reverse owns the animation)")
            return
        }
        let commit = translationX > 64 || predicted > 110
        if terminalBitmapTransition != nil {
            endBitmapBackDrag(commit: commit, translationX: translationX, predicted: predicted, size: size)
            return
        }
        guard commit else {
            VCLog.log("term-swipe", "end CANCEL tx=\(Int(translationX)) predicted=\(Int(predicted)) (below threshold)")
            withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.9), completionCriteria: .logicallyComplete) {
                backDragOffset = 0
            } completion: {
                backInteractionActive = false
                backOutgoingSnapshot = .none
                transitionSourceSnapshot = .none
                endTerminalHorizontalInteraction()
            }
            return
        }
        let fromLevel = terminalLevelLabel
        VCLog.log("term-swipe", "end COMMIT tx=\(Int(translationX)) predicted=\(Int(predicted)) → stepBack from \(fromLevel)")
        MainThreadWatchdog.mark("term-back-commit from=\(fromLevel)")
        FrameMonitor.shared.setPhase("animate")
        withAnimation(.easeOut(duration: 0.16), completionCriteria: .logicallyComplete) {
            backDragOffset = width
            } completion: {
                FrameMonitor.shared.setPhase("swap")
                commitWithoutTerminalAnimation {
                    store.stepBackOneLevel()
                    backDragOffset = 0
                    backInteractionActive = false
                backOutgoingSnapshot = .none
                transitionSourceSnapshot = .none
                endTerminalHorizontalInteraction()
            }
        }
    }

    private func cancelTerminalBackDrag() {
        // Interrupt-reverse owns its teardown — a cancel mustn't double-fire it.
        if interruptingForward || forwardDestination != nil {
            VCLog.log("term-swipe", "cancel ignored (interrupt-reverse owns the animation)")
            return
        }
        VCLog.log("term-swipe", "cancel drag")
        if terminalBitmapTransition != nil {
            animateTerminalBitmap(to: 0, mode: .back, duration: 0.16, curve: .easeOut) {
                commitWithoutTerminalAnimation {
                    terminalBitmapTransition = nil
                    backInteractionActive = false
                    endTerminalHorizontalInteraction()
                }
            }
            return
        }
        withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.9)) {
            backDragOffset = 0
        }
        backInteractionActive = false
        backOutgoingSnapshot = .none
        transitionSourceSnapshot = .none
        endTerminalHorizontalInteraction()
    }

    // Human-readable current Terminal nav level for swipe logs.
    private var terminalLevelLabel: String {
        if store.selectedTab != nil { return "chat" }
        if store.selectedProject != nil { return "tabs" }
        return "projects"
    }

    private func terminalBackPreviewOffset(width: CGFloat) -> CGFloat {
        let initial = min(72, width * 0.22)
        guard width > 0 else { return -initial }
        let progress = min(1, max(0, backDragOffset / width))
        return -initial * (1 - progress)
    }

    private func terminalForwardContentOffset(width: CGFloat) -> CGFloat {
        guard forwardDestination != nil, width > 0 else { return 0 }
        let progress = 1 - min(1, max(0, forwardOffset / width))
        return -min(48, width * 0.12) * progress
    }

    private func pushProject(_ project: CTProject, size: CGSize) {
        let width = size.width
        guard !terminalInteractionsSuspended else { return }
        guard terminalAnimatedProjectPushEnabled,
              forwardDestination == nil,
              width > 0,
              !reduceMotion
        else {
            VCLog.log("term-swipe", "pushProject \(project.name) — instant project boundary")
            persistentProject = project
            store.selectProject(project)
            return
        }
        VCLog.log("term-swipe", "pushProject \(project.name) — mount@width then slide")
        if beginBitmapPushProject(project, size: size) {
            return
        }
        persistentProject = project
        backDragOffset = 0
        // Keep the already-scrolled Projects ScrollView live while it slides out.
        // Replacing it with TerminalProjectsBackPreview loses the current offset,
        // which looked like an instant jump to the top on project tap.
        transitionSourceSnapshot = .none
        let tabs = store.tabsByProject[project.id] ?? []
        let marker = store.statusMarkerByProject[project.id] ?? .fallback
        forwardTabsSnapshot = .tabs(tabs, marker, project.name)
        beginTerminalHorizontalInteraction(label: "pushProject name=\(project.name) id=\(String(project.id.suffix(8)))", initialPhase: "mount")
        // Mount the incoming page OFF-SCREEN (forwardOffset = width) with NO
        // animation first; let SwiftUI render that frame, THEN slide it in next
        // runloop. Previously mount + animate shared one transaction, so the heavy
        // tabs list instantiated on the slide's first frame → the "дёрганое"
        // open. The pre-render frame absorbs the instantiation cost off-screen.
        forwardDestination = .project(project)
        forwardOffset = width
        forwardGeneration += 1
        let generation = forwardGeneration
        Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(projectForwardPreRenderMs))
            guard generation == forwardGeneration else { return }
            FrameMonitor.shared.setPhase("animate")   // commit phase = up to here
            withAnimation(.easeOut(duration: 0.18), completionCriteria: .logicallyComplete) {
                forwardOffset = 0
            } completion: {
                // A back-swipe may have interrupted and reversed this push; if so the
                // generation bumped and we must NOT commit the navigation.
                guard generation == forwardGeneration else { return }
                // Commit the nav state immediately so a fast right-swipe is a real
                // tabs→projects back gesture, not an "interrupt forward from projects".
                // The live tabs tree stays in lightweight render mode during the
                // quiet tail, but remains visible and scrollable.
                FrameMonitor.shared.setPhase("swap")
                commitWithoutTerminalAnimation {
                    store.selectProject(project)
                    forwardDestination = nil
                    forwardOffset = 0
                    forwardTabsSnapshot = .none
                    transitionSourceSnapshot = .none
                    endTerminalHorizontalInteraction()
                }
            }
        }
    }

    private func pushTab(_ tab: CTTabInfo, project: CTProject, size: CGSize) {
        let width = size.width
        guard tab.isInteractiveAI else { return }
        guard !terminalInteractionsSuspended else { return }
        // PHASE B: navigation only SETS the selection. The actual load
        // (activateSelectedTab) is owned by TerminalChatDetailView's
        // `.task(id: tabId)`, so it auto-cancels if the user swipes back before
        // it finishes — instead of a fire-and-forget Task that outlived the view
        // and mutated torn-down state (the back-before-load crash).
        guard forwardDestination == nil, width > 0, !reduceMotion else {
            persistentProject = project
            persistentTab = tab
            store.selectTabForDisplay(tab, project: project)
            return
        }
        VCLog.log("term-swipe", "pushTab \(tab.name) — mount@width then slide")
        if beginBitmapPushTab(tab, project: project, size: size) {
            return
        }
        persistentProject = project
        persistentTab = tab
        backDragOffset = 0
        transitionSourceSnapshot = .none
        beginTerminalHorizontalInteraction(label: "pushTab name=\(tab.name) id=\(String((tab.tabId ?? tab.id).suffix(8)))", initialPhase: "mount")
        forwardDestination = .tab(tab, project)
        forwardOffset = width
        forwardGeneration += 1
        let generation = forwardGeneration
        Task { @MainActor in
            await Task.yield()
            FrameMonitor.shared.setPhase("animate")
            withAnimation(.easeOut(duration: 0.18), completionCriteria: .logicallyComplete) {
                forwardOffset = 0
            } completion: {
                guard generation == forwardGeneration else { return }   // interrupted → don't commit
                FrameMonitor.shared.setPhase("swap")   // live chat detail mounts HERE
                commitWithoutTerminalAnimation {
                    store.selectTabForDisplay(tab, project: project)
                    forwardDestination = nil
                    forwardOffset = 0
                    transitionSourceSnapshot = .none
                    endTerminalHorizontalInteraction()
                }
            }
        }
    }

    private func beginBitmapPushProject(_ project: CTProject, size: CGSize) -> Bool {
        guard terminalBitmapProjectTransitionsEnabled else { return false }
        guard size.width > 1, size.height > 1 else { return false }
        let tabs = store.tabsByProject[project.id] ?? []
        let marker = store.statusMarkerByProject[project.id] ?? .fallback
        let destinationSurface = TerminalBitmapSurface.tabs(tabs, marker, project.name)
        guard let source = captureCurrentTerminalBitmap(size: size),
              let destination = cachedTabsBitmapByProject[project.id]
                ?? renderTerminalBitmap(surface: destinationSurface, size: size)
        else {
            VCLog.log("term-swipe", "bitmap pushProject unavailable → SwiftUI fallback")
            return false
        }

        cachedProjectsBitmap = source
        backDragOffset = 0
        forwardGeneration += 1
        let generation = forwardGeneration
        beginTerminalHorizontalInteraction(label: "bitmap pushProject name=\(project.name) id=\(String(project.id.suffix(8)))", initialPhase: "snapshot")
        let transition = TerminalBitmapTransitionState(
            mode: .forward,
            source: source,
            destination: destination,
            offset: size.width,
            size: size
        )
        terminalBitmapTransition = transition
        terminalBitmapOverlayView?.configure(transition)
        Task { @MainActor in
            await waitForBitmapOverlay()
            guard generation == forwardGeneration else { return }
            await preflightTerminalBitmapOverlay()
            guard generation == forwardGeneration else { return }
            FrameMonitor.shared.setPhase("animate")
            animateTerminalBitmap(to: 0, mode: .forward, duration: bitmapPushDuration, curve: .linear) {
                guard generation == forwardGeneration else { return }
                FrameMonitor.shared.setPhase("live-mount")
                commitWithoutTerminalAnimation {
                    store.selectProject(project)
                    endTerminalHorizontalInteraction()
                }
                holdBitmapDestination(destination, generation: generation)
            }
        }
        return true
    }

    private func beginBitmapPushTab(_ tab: CTTabInfo, project: CTProject, size: CGSize) -> Bool {
        guard terminalBitmapChatTransitionsEnabled else { return false }
        guard size.width > 1, size.height > 1 else { return false }
        let sourceSnapshot = captureTransitionSourceSnapshot()
        let destinationSurface = TerminalBitmapSurface.chatPlaceholder(tab)
        guard let source = captureCurrentTerminalBitmap(size: size)
                ?? renderTerminalBitmap(surface: sourceSnapshot.bitmapSurface, size: size),
              let destination = renderTerminalBitmap(surface: destinationSurface, size: size)
        else {
            VCLog.log("term-swipe", "bitmap pushTab unavailable → SwiftUI fallback")
            return false
        }

        cachedTabsBitmapByProject[project.id] = source
        backDragOffset = 0
        forwardGeneration += 1
        let generation = forwardGeneration
        beginTerminalHorizontalInteraction(label: "bitmap pushTab name=\(tab.name) id=\(String((tab.tabId ?? tab.id).suffix(8)))", initialPhase: "snapshot")
        let transition = TerminalBitmapTransitionState(
            mode: .forward,
            source: source,
            destination: destination,
            offset: size.width,
            size: size
        )
        terminalBitmapTransition = transition
        terminalBitmapOverlayView?.configure(transition)
        Task { @MainActor in
            await waitForBitmapOverlay()
            guard generation == forwardGeneration else { return }
            await preflightTerminalBitmapOverlay()
            guard generation == forwardGeneration else { return }
            FrameMonitor.shared.setPhase("animate")
            animateTerminalBitmap(to: 0, mode: .forward, duration: bitmapPushDuration, curve: .linear) {
                guard generation == forwardGeneration else { return }
                FrameMonitor.shared.setPhase("swap")
                commitWithoutTerminalAnimation {
                    store.selectTabForDisplay(tab, project: project)
                    endTerminalHorizontalInteraction()
                }
                holdBitmapDestination(destination, generation: generation)
            }
        }
        return true
    }

    private func beginBitmapBackDrag(size: CGSize) -> Bool {
        guard size.width > 1, size.height > 1 else { return false }
        let isChatBack = store.selectedTab != nil
        let isProjectBack = store.selectedProject != nil && store.selectedTab == nil
        guard (isProjectBack && terminalBitmapProjectTransitionsEnabled)
                || (isChatBack && terminalBitmapChatTransitionsEnabled)
        else { return false }

        let sourceFallback: TerminalBitmapSurface? = isChatBack ? store.selectedTab.map { .chatPlaceholder($0) } : nil
        guard let source = captureCurrentTerminalBitmap(size: size)
                ?? sourceFallback.flatMap({ renderTerminalBitmap(surface: $0, size: size) })
        else {
            VCLog.log("term-swipe", "bitmap back unavailable source → SwiftUI fallback")
            return false
        }

        let destination: UIImage
        if isProjectBack {
            guard let cachedProjectsBitmap else {
                VCLog.log("term-swipe", "bitmap back tabs unavailable (no projects bitmap) → SwiftUI fallback")
                return false
            }
            destination = cachedProjectsBitmap
            if let projectId = store.selectedProject?.id {
                // Source is the current tabs list with its real scroll offset.
                cachedTabsBitmapByProject[projectId] = source
            }
        } else {
            let destinationSurface = captureBackPreviewSnapshot().bitmapSurface
            guard let projectId = store.selectedProject?.id,
                  let cached = cachedTabsBitmapByProject[projectId]
                    ?? renderTerminalBitmap(surface: destinationSurface, size: size)
            else {
                VCLog.log("term-swipe", "bitmap back chat unavailable destination → SwiftUI fallback")
                return false
            }
            destination = cached
            cachedTabsBitmapByProject[projectId] = destination
        }

        transitionSourceSnapshot = .none
        backPreviewSnapshot = .none
        backOutgoingSnapshot = .none
        backInteractionActive = true
        backDragOffset = 0
        terminalBitmapTransition = TerminalBitmapTransitionState(
            mode: .back,
            source: source,
            destination: destination,
            offset: 0,
            size: size
        )
        terminalBitmapOverlayView?.configure(terminalBitmapTransition)
        beginTerminalHorizontalInteraction(label: "bitmap back from=\(terminalLevelLabel)", initialPhase: "gesture")
        return true
    }

    private func endBitmapBackDrag(commit: Bool, translationX: CGFloat, predicted: CGFloat, size: CGSize) {
        guard terminalBitmapTransition != nil else { return }
        let width = size.width
        if !commit {
            VCLog.log("term-swipe", "bitmap end CANCEL tx=\(Int(translationX)) predicted=\(Int(predicted)) (below threshold)")
            animateTerminalBitmap(to: 0, mode: .back, duration: 0.16, curve: .easeOut) {
                commitWithoutTerminalAnimation {
                    terminalBitmapTransition = nil
                    backInteractionActive = false
                    endTerminalHorizontalInteraction()
                }
            }
            return
        }

        let fromLevel = terminalLevelLabel
        let destination = terminalBitmapTransition?.destination
        VCLog.log("term-swipe", "bitmap end COMMIT tx=\(Int(translationX)) predicted=\(Int(predicted)) → stepBack from \(fromLevel)")
        MainThreadWatchdog.mark("term-back-commit from=\(fromLevel)")
        FrameMonitor.shared.setPhase("animate")
        forwardGeneration += 1
        let generation = forwardGeneration
        animateTerminalBitmap(to: width, mode: .back, duration: bitmapBackDuration, curve: .linear) {
            guard generation == forwardGeneration else { return }
            FrameMonitor.shared.setPhase(fromLevel == "tabs" ? "live-mount" : "swap")
            commitWithoutTerminalAnimation {
                store.stepBackOneLevel()
                backDragOffset = 0
                backInteractionActive = false
                endTerminalHorizontalInteraction()
            }
            if let destination {
                holdBitmapDestination(destination, generation: generation)
            } else {
                terminalBitmapTransition = nil
            }
        }
    }

    private func waitForBitmapOverlay() async {
        for _ in 0..<12 {
            if let overlay = terminalBitmapOverlayView, overlay.bounds.width > 1, overlay.bounds.height > 1 {
                return
            }
            try? await Task.sleep(for: .milliseconds(8))
        }
    }

    private func preflightTerminalBitmapOverlay() async {
        guard let overlay = terminalBitmapOverlayView,
              let state = terminalBitmapTransition
        else { return }
        FrameMonitor.shared.setPhase("bitmap-preflight")
        overlay.configure(state)
        overlay.setNeedsLayout()
        overlay.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(bitmapOverlayPreflightMs))
    }

    private func animateTerminalBitmap(
        to targetOffset: CGFloat,
        mode: TerminalBitmapTransitionState.Mode,
        duration: TimeInterval,
        curve: TerminalBitmapAnimationCurve,
        completion: @escaping @MainActor () -> Void
    ) {
        guard let overlay = terminalBitmapOverlayView,
              let state = terminalBitmapTransition,
              overlay.bounds.width > 1,
              overlay.bounds.height > 1
        else {
            VCLog.log("term-swipe", "bitmap overlay not ready — direct commit fallback")
            commitWithoutTerminalAnimation {
                terminalBitmapTransition?.offset = targetOffset
            }
            Task { @MainActor in
                await Task.yield()
                completion()
            }
            return
        }

        overlay.configure(state)
        overlay.animate(to: targetOffset, mode: mode, duration: duration, curve: curve) { _ in
            Task { @MainActor in
                commitWithoutTerminalAnimation {
                    terminalBitmapTransition?.offset = targetOffset
                }
                completion()
            }
        }
    }

    private func holdBitmapDestination(_ image: UIImage, generation: Int) {
        guard var current = terminalBitmapTransition else { return }
        current.source = image
        current.destination = image
        current.offset = 0
        current.mode = .hold
        terminalBitmapTransition = current
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(snapshotOverlayHoldMs))
            guard generation == forwardGeneration else { return }
            commitWithoutTerminalAnimation {
                terminalBitmapTransition = nil
            }
        }
    }

    private func captureCurrentTerminalBitmap(size: CGSize) -> UIImage? {
        guard size.width > 1, size.height > 1,
              let host = terminalSnapshotHostView,
              let window = host.window
        else { return nil }
        let rect = host.convert(host.bounds, to: window).integral
        guard rect.width > 1, rect.height > 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
            context.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        return image.preparingForDisplay() ?? image
    }

    private func renderTerminalBitmap(surface: TerminalBitmapSurface?, size: CGSize) -> UIImage? {
        guard let surface, size.width > 1, size.height > 1 else { return nil }
        let renderer = ImageRenderer(
            content: terminalBitmapSurfaceView(surface)
                .frame(width: size.width, height: size.height)
                .environment(\.bottomBarInset, bottomBarInset)
        )
        renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
        renderer.scale = UIScreen.main.scale
        guard let image = renderer.uiImage else { return nil }
        return image.preparingForDisplay() ?? image
    }

    @ViewBuilder
    private func terminalBitmapSurfaceView(_ surface: TerminalBitmapSurface) -> some View {
        switch surface {
        case .projects(let rows):
            TerminalProjectsBackPreview(rows: rows, showsHeader: false)
        case .tabs(let tabs, let marker, let name):
            TerminalTabsBackPreview(tabs: tabs, marker: marker, projectName: name, style: .lightweight, showsHeader: false)
        case .chatPlaceholder(let tab):
            TerminalChatForwardPlaceholder(tab: tab, showsHeader: false)
        }
    }

    private func commitWithoutTerminalAnimation<T>(_ updates: () -> T) -> T {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        return withTransaction(transaction, updates)
    }

    private func beginTerminalHorizontalInteraction(label: String, initialPhase: String = "commit") {
        horizontalScrollLocked = true
        terminalSelectionSuppressed = true
        terminalHeavySurfaceSuspended = true
        terminalSnapshotOverlay = .none
        terminalSelectionSuppressionGeneration += 1
        // Park background tabs-prefetch while we navigate, so its writes can't land
        // mid-slide and hitch the projects back-preview (watchdog proved this is a
        // HITCH, not a hang — see TerminalControlStore.interactionActive).
        store.setInteractionActive(true)
        // Watch presented frames during the slide — the only instrument that sees
        // GPU/compositing jank the main-thread watchdog can't.
        FrameMonitor.shared.arm(reason: "term-nav", label: label, phase: initialPhase)
    }

    private func endTerminalHorizontalInteraction() {
        horizontalScrollLocked = false
        store.setInteractionActive(false)
        let generation = terminalSelectionSuppressionGeneration
        FrameMonitor.shared.setPhase("settle")
        DispatchQueue.main.async {
            guard terminalSelectionSuppressionGeneration == generation else { return }
            terminalSelectionSuppressed = false
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(heavySurfaceResumeDelayMs))
            guard terminalSelectionSuppressionGeneration == generation else { return }
            terminalSnapshotOverlay = .none
            terminalHeavySurfaceSuspended = false
        }
    }

    private func prepareBuildInstall() async {
        guard !store.terminalInstallRunning else {
            VCLog.log("TerminalInstallUI", "prepare ignored already-running")
            return
        }
        VCLog.log("TerminalInstallUI", "prepare start")
        do {
            let blockers = try await store.terminalBuildInstallBlockers()
            if !blockers.isEmpty {
                VCLog.log("TerminalInstallUI", "prepare blocked count=\(blockers.count)")
                installAlert = TerminalInstallAlert(
                    title: "Terminal занят",
                    message: buildBlockerMessage(blockers)
                )
                return
            }
            VCLog.log("TerminalInstallUI", "prepare ok showConfirm")
            showBuildInstallConfirm = true
        } catch {
            VCLog.log("TerminalInstallUI", "prepare failed: \(friendlyError(error))")
            installAlert = TerminalInstallAlert(
                title: "Не удалось проверить Terminal",
                message: friendlyError(error)
            )
        }
    }

    private func runBuildInstall() async {
        VCLog.log("TerminalInstallUI", "run start")
        do {
            let job = try await store.runTerminalBuildInstall()
            let command = job?.command ?? "npm run build:install"
            VCLog.log("TerminalInstallUI", "run success command=\(command)")
            installAlert = TerminalInstallAlert(title: "Install завершён", message: command + " завершился.")
            await store.refreshProjects()
        } catch {
            VCLog.log("TerminalInstallUI", "run failed: \(friendlyError(error))")
            installAlert = TerminalInstallAlert(title: "Install не завершился", message: friendlyError(error))
        }
    }

    private func buildBlockerMessage(_ blockers: [CTActiveLoader]) -> String {
        var lines = blockers.prefix(6).map { loader in
            var line = loader.title
            if let status = loader.status, !status.isEmpty { line += " · " + status }
            if let cwd = loader.cwd, !cwd.isEmpty { line += "\n" + cwd }
            if let command = loader.command, !command.isEmpty { line += "\n" + command }
            return line
        }
        if blockers.count > lines.count {
            lines.append("ещё \(blockers.count - lines.count)")
        }
        return "Остановите вкладки, где сейчас идёт streaming или loader, перед install:\n\n" + lines.joined(separator: "\n\n")
    }

    private func friendlyError(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        return error.localizedDescription
    }
}

// Back-preview = a STATIC snapshot of the destination, shown only while the slide
// animates. CRITICAL (validated June 2026, +research agent reading this code): its
// body must read ZERO @Observable store state. Previously it read store.projects +
// store.activitySummary() (which reads projects/tabsByProject/statusByTab/
// runningTabs) — so the status-poll Timer mutating statusByTab mid-slide re-ran the
// whole preview body every frame → LazyVStack rebuild → the sustained per-frame
// cost the FrameMonitor measured (38 dropped frames, no main-thread hang; not GPU,
// so .drawingGroup didn't help). Now the parent captures an immutable value array
// ONCE at slide-start and passes it in; the preview observes nothing. Plain VStack
// (not Lazy): ~12 cheap rows don't need laziness, and lazy viewport estimation is
// exactly what an ancestor .offset animation perturbs on iOS 26.
// Static placeholder shown while a chat-detail push slides in — mirrors the chat
// header geometry (so nothing jumps when the live view commits) and an empty
// transcript area. Reads only the immutable `tab`, no @Observable store state, and
// mounts no ScrollView/composer and no history load. The live TerminalChatDetailView
// mounts in terminalContent once the push commits.
private struct TerminalChatForwardPlaceholder: View {
    let tab: CTTabInfo
    var showsHeader = true
    @AppStorage(VoiceChatConfig.Keys.uiFont, store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var uiFont: Double = 14

    private var status: String { tab.sessionStatus ?? "inactive" }
    private var statusColor: Color {
        switch status {
        case "busy": return Color(hex: "d97706")
        case "active": return CTGreen
        case "starting": return CTAccent
        default: return Color(white: 0.38)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                TerminalHeaderBar(onSettings: {}) {
                    VStack(spacing: 1) {
                        Text(tab.name)
                            .font(.system(size: uiFont, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Circle().fill(statusColor).frame(width: 6, height: 6)
                            Text(status)
                                .font(.system(size: max(9, uiFont - 4)).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: 220)
                } trailing: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .semibold)).ctGlassCircle()
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CTPageBackground)
        .allowsHitTesting(false)
    }
}

private struct TerminalProjectsBackPreview: View {
    let rows: [CTProjectRowSnapshot]
    var showsHeader = true
    @AppStorage(VoiceChatConfig.Keys.uiFont, store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var uiFont: Double = 14

    var body: some View {
        // MUST mirror TerminalProjectsView's layout: a 44pt header above the list.
        // Without it the sliding snapshot has no header, so the header visually
        // disappears mid-slide and the rows jump down ~44pt when the live level
        // commits its header back. The gear/trailing here are decorative — the
        // whole preview is allowsHitTesting(false).
        VStack(spacing: 0) {
            if showsHeader {
                TerminalHeaderBar(onSettings: {}) {
                    TerminalHeaderTitle(title: "Terminal", subtitle: TerminalControlConfig.displayHost(), uiFont: uiFont)
                } trailing: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 15, weight: .semibold)).ctGlassCircle()
                }
            }
            TerminalProjectsPreviewList(rows: rows, uiFont: uiFont, bottomPadding: 120)
        }
        .background(CTPageBackground)
        .allowsHitTesting(false)
    }
}

private struct TerminalProjectsPreviewList: View {
    let rows: [CTProjectRowSnapshot]
    let uiFont: Double
    let bottomPadding: CGFloat

    var body: some View {
        VStack(spacing: 9) {
            ForEach(rows) { row in
                TerminalProjectRow(project: row.project, uiFont: uiFont, activity: row.activity, animatedBadge: false)
                    .equatable()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, bottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
    }
}

private enum TerminalTabsPreviewStyle {
    case full
    case lightweight
    case skeleton
}

private struct TerminalTabsBackPreview: View {
    let tabs: [CTTabInfo]
    let marker: CTStatusMarker
    // Project name, frozen into the snapshot so the header matches the live
    // TerminalProjectTabsView level without reading @Observable state mid-slide.
    var projectName: String = ""
    var style: TerminalTabsPreviewStyle = .full
    var showsHeader = true
    @AppStorage(VoiceChatConfig.Keys.uiFont, store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var uiFont: Double = 14

    var body: some View {
        // Mirror TerminalProjectTabsView: 44pt header above the list (see the
        // projects preview note — a headerless snapshot makes the header flicker
        // and the rows jump during the slide).
        VStack(spacing: 0) {
            if showsHeader {
                TerminalHeaderBar(onSettings: {}) {
                    TerminalHeaderTitle(title: projectName, subtitle: "Terminal projects", uiFont: uiFont, maxWidth: 190)
                } trailing: {
                    if style == .lightweight {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 38, height: 38)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .semibold)).ctGlassCircle()
                    }
                }
            }
            if style == .skeleton {
                TerminalTabsSkeletonList(count: tabs.count, uiFont: uiFont, bottomPadding: 120)
            } else if style == .lightweight {
                TerminalTabsPreviewList(tabs: tabs, marker: marker, uiFont: uiFont, bottomPadding: 120)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(tabs) { tab in
                            TerminalTabRow(tab: tab, selected: false, uiFont: uiFont, marker: marker, animated: false)
                                .equatable()
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .padding(.bottom, 120)
                }
            }
        }
        .background(CTPageBackground)
        .allowsHitTesting(false)
    }
}

private struct TerminalTabsSkeletonList: View {
    let count: Int
    let uiFont: Double
    let bottomPadding: CGFloat

    private var rowCount: Int {
        min(max(count, 3), 18)
    }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(0..<rowCount, id: \.self) { index in
                TerminalTabSkeletonRow(uiFont: uiFont, variant: index % 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, bottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct TerminalTabSkeletonRow: View, Equatable {
    let uiFont: Double
    let variant: Int

    nonisolated static func == (lhs: TerminalTabSkeletonRow, rhs: TerminalTabSkeletonRow) -> Bool {
        lhs.uiFont == rhs.uiFont && lhs.variant == rhs.variant
    }

    private var titleWidth: CGFloat {
        [154, 118, 178, 136][variant % 4]
    }

    private var pathWidth: CGFloat {
        [230, 198, 256, 174][variant % 4]
    }

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.11))
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(Color.white.opacity(0.16))
                        .frame(width: 8, height: 8)
                    Capsule()
                        .fill(Color.white.opacity(0.17))
                        .frame(width: titleWidth, height: max(10, uiFont - 3))
                }
                Capsule()
                    .fill(Color.white.opacity(0.10))
                    .frame(width: pathWidth, height: max(8, uiFont - 5))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Circle()
                .fill(Color.white.opacity(0.14))
                .frame(width: 8, height: 8)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.white.opacity(0.055)))
    }
}

private struct TerminalTabsPreviewList: View {
    let tabs: [CTTabInfo]
    let marker: CTStatusMarker
    let uiFont: Double
    let bottomPadding: CGFloat

    var body: some View {
        VStack(spacing: 8) {
            ForEach(tabs) { tab in
                TerminalTabPreviewRow(tab: tab, uiFont: uiFont, marker: marker)
                    .equatable()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, bottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct TerminalTabPreviewRow: View, Equatable {
    let tab: CTTabInfo
    let uiFont: Double
    let marker: CTStatusMarker

    nonisolated static func == (lhs: TerminalTabPreviewRow, rhs: TerminalTabPreviewRow) -> Bool {
        lhs.tab == rhs.tab && lhs.uiFont == rhs.uiFont && lhs.marker == rhs.marker
    }

    private var runtime: String { tab.sessionStatus ?? "inactive" }
    private var tint: Color {
        if tab.awaiting == true { return CTViolet }
        switch runtime {
        case "busy": return Color(hex: "d97706")
        case "active": return CTGreen
        case "starting": return CTAccent
        default: return Color(white: 0.38)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            AgentIconView(toolType: tab.effectiveToolType, size: 26)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    StatusMarkerSlot(colorHex: tab.statusColor, marker: marker)
                    Text(tab.name)
                        .font(.system(size: uiFont, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                Text(tab.cwd)
                    .font(.system(size: uiFont - 3).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Circle().fill(tint).frame(width: 8, height: 8)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(tabRowBackground(tab.color, selected: false, busy: runtime == "busy", isCodex: tab.isCodexPTY, isClaude: tab.isClaudePTY)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.white.opacity(0.07)))
    }
}

// Value snapshot for one project row, captured at slide-start so the preview's body
// reads no @Observable state.
private struct CTProjectRowSnapshot: Identifiable {
    let project: CTProject
    let activity: CTActivitySummary
    var id: String { project.id }
}

// Immutable destination snapshot for the back-slide preview (projects list or one
// project's tabs), captured once at slide-start.
private enum TerminalBackPreviewSnapshot {
    case none
    case projects([CTProjectRowSnapshot])
    case tabs([CTTabInfo], CTStatusMarker, String)   // tabs, status marker, project name (for the header)

    var isEmpty: Bool {
        switch self {
        case .none: return true
        case .projects(let r): return r.isEmpty
        case .tabs(let t, _, _): return t.isEmpty
        }
    }

    var bitmapSurface: TerminalBitmapSurface? {
        switch self {
        case .none:
            return nil
        case .projects(let rows):
            return .projects(rows)
        case .tabs(let tabs, let marker, let name):
            return .tabs(tabs, marker, name)
        }
    }
}

private enum TerminalOutgoingSnapshot {
    case none
    case chat(CTTabInfo)
}

private enum TerminalBitmapSurface {
    case projects([CTProjectRowSnapshot])
    case tabs([CTTabInfo], CTStatusMarker, String)
    case chatPlaceholder(CTTabInfo)
}

private struct TerminalBitmapTransitionState {
    enum Mode: Equatable {
        case forward
        case back
        case hold
    }

    var mode: Mode
    var source: UIImage
    var destination: UIImage
    var offset: CGFloat
    let size: CGSize
}

private enum TerminalBitmapAnimationCurve {
    case linear
    case easeOut

    var options: UIView.AnimationOptions {
        switch self {
        case .linear: return .curveLinear
        case .easeOut: return .curveEaseOut
        }
    }
}

private final class TerminalBitmapTransitionHostView: UIView {
    private let destinationView = UIImageView()
    private let sourceView = UIImageView()
    private let edgeLayer = CAGradientLayer()
    private var currentMode: TerminalBitmapTransitionState.Mode = .hold
    private var currentOffset: CGFloat = 0
    private var currentSize: CGSize = .zero
    private var isInteractiveTracking = false
    private(set) var isBitmapAnimating = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        isHidden = true
        backgroundColor = UIColor(white: 0.055, alpha: 1)

        [destinationView, sourceView].forEach { imageView in
            imageView.contentMode = .scaleToFill
            imageView.clipsToBounds = true
            imageView.isUserInteractionEnabled = false
            addSubview(imageView)
        }

        edgeLayer.colors = [
            UIColor.black.withAlphaComponent(0.28).cgColor,
            UIColor.black.withAlphaComponent(0).cgColor
        ]
        edgeLayer.startPoint = CGPoint(x: 1, y: 0.5)
        edgeLayer.endPoint = CGPoint(x: 0, y: 0.5)
        layer.addSublayer(edgeLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ state: TerminalBitmapTransitionState?) {
        guard let state else {
            isHidden = true
            isBitmapAnimating = false
            layer.removeAllAnimations()
            sourceView.layer.removeAllAnimations()
            destinationView.layer.removeAllAnimations()
            sourceView.image = nil
            destinationView.image = nil
            edgeLayer.isHidden = true
            currentOffset = 0
            currentMode = .hold
            isInteractiveTracking = false
            return
        }

        isHidden = false
        currentSize = state.size
        let replacesImages = sourceView.image !== state.source || destinationView.image !== state.destination
        if destinationView.image !== state.destination {
            destinationView.image = state.destination
        }
        if sourceView.image !== state.source {
            sourceView.image = state.source
        }
        setNeedsLayout()
        layoutIfNeeded()
        if replacesImages || currentMode != state.mode {
            isInteractiveTracking = false
        }
        if !isBitmapAnimating {
            if isInteractiveTracking, !replacesImages, currentMode == state.mode {
                apply(offset: currentOffset, mode: state.mode)
            } else {
                apply(offset: state.offset, mode: state.mode)
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        destinationView.frame = bounds
        sourceView.frame = bounds
        apply(offset: currentOffset, mode: currentMode)
    }

    func animate(
        to targetOffset: CGFloat,
        mode: TerminalBitmapTransitionState.Mode,
        duration: TimeInterval,
        curve: TerminalBitmapAnimationCurve,
        completion: @escaping (Bool) -> Void
    ) {
        isBitmapAnimating = true
        isInteractiveTracking = false
        layoutIfNeeded()
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [curve.options, .beginFromCurrentState, .allowUserInteraction],
            animations: {
                self.apply(offset: targetOffset, mode: mode)
            },
            completion: { finished in
                self.isBitmapAnimating = false
                self.apply(offset: targetOffset, mode: mode)
                completion(finished)
            }
        )
    }

    func setInteractiveOffset(_ offset: CGFloat, mode: TerminalBitmapTransitionState.Mode) {
        guard !isHidden else { return }
        isInteractiveTracking = true
        layer.removeAllAnimations()
        sourceView.layer.removeAllAnimations()
        destinationView.layer.removeAllAnimations()
        apply(offset: offset, mode: mode)
    }

    private func apply(offset: CGFloat, mode: TerminalBitmapTransitionState.Mode) {
        currentOffset = offset
        currentMode = mode
        let width = max(1, bounds.width > 1 ? bounds.width : currentSize.width)
        let progress: CGFloat
        switch mode {
        case .forward:
            progress = 1 - min(1, max(0, offset / width))
        case .back:
            progress = min(1, max(0, offset / width))
        case .hold:
            progress = 1
        }

        let sourceOffset: CGFloat
        let destinationOffset: CGFloat
        switch mode {
        case .forward:
            // Push: destination slides OVER the source, while source parallax-shifts
            // slightly behind it. If source stays on top, the user sees only the old
            // projects page twitch and then jump to tabs at commit.
            bringSubviewToFront(destinationView)
            sourceOffset = -min(48, width * 0.12) * progress
            destinationOffset = offset
        case .back:
            // Back: current source page follows the finger to the right, revealing
            // the destination underneath.
            bringSubviewToFront(sourceView)
            sourceOffset = offset
            destinationOffset = -min(72, width * 0.22) * (1 - progress)
        case .hold:
            bringSubviewToFront(sourceView)
            sourceOffset = 0
            destinationOffset = 0
        }

        destinationView.transform = CGAffineTransform(translationX: destinationOffset, y: 0)
        sourceView.transform = CGAffineTransform(translationX: sourceOffset, y: 0)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edgeLayer.isHidden = mode == .hold
        let shadowX: CGFloat
        switch mode {
        case .forward:
            shadowX = destinationOffset - 18
        case .back:
            shadowX = sourceOffset - 18
        case .hold:
            shadowX = -18
        }
        edgeLayer.frame = CGRect(x: shadowX, y: 0, width: 18, height: bounds.height)
        CATransaction.commit()
    }
}

private struct TerminalBitmapTransitionOverlay: UIViewRepresentable {
    let state: TerminalBitmapTransitionState?
    let onResolve: (TerminalBitmapTransitionHostView) -> Void

    func makeUIView(context: Context) -> TerminalBitmapTransitionHostView {
        TerminalBitmapTransitionHostView()
    }

    func updateUIView(_ uiView: TerminalBitmapTransitionHostView, context: Context) {
        uiView.configure(state)
        DispatchQueue.main.async {
            onResolve(uiView)
        }
    }
}

private struct TerminalSnapshotHostReader: UIViewRepresentable {
    let onResolve: (UIView) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            onResolve(uiView)
        }
    }
}

private struct TerminalUIKitNavigationHost: UIViewControllerRepresentable {
    let onShowHistory: () -> Void
    let onComposerFocusChange: (Bool) -> Void
    let bottomBarInset: CGFloat
    @EnvironmentObject private var router: TabRouter

    func makeUIViewController(context: Context) -> TerminalUIKitNavigationController {
        let controller = TerminalUIKitNavigationController()
        controller.update(router: router, onShowHistory: onShowHistory, onComposerFocusChange: onComposerFocusChange, bottomBarInset: bottomBarInset)
        return controller
    }

    func updateUIViewController(_ uiViewController: TerminalUIKitNavigationController, context: Context) {
        uiViewController.update(router: router, onShowHistory: onShowHistory, onComposerFocusChange: onComposerFocusChange, bottomBarInset: bottomBarInset)
    }
}

@MainActor
private final class TerminalUIKitNavigationController: UIViewController, UIGestureRecognizerDelegate {
    private let store = TerminalControlStore.shared
    private let projectsController = TerminalUIKitProjectsController()
    private let tabsController = TerminalUIKitTabsController()
    private let projectsShell = UIView()
    private let tabsShell = UIView()
    private let chatShell = UIView()
    private var chatController: UIHostingController<AnyView>?
    private weak var router: TabRouter?
    private var onShowHistory: () -> Void = {}
    private var onComposerFocusChange: (Bool) -> Void = { _ in }
    private var bottomBarInset: CGFloat = 0
    private var currentLevel: TerminalNavLevel = .projects
    private var transitionLevel: TerminalNavLevel?
    private var panRecognizer: UIPanGestureRecognizer?
    private var syncTimer: Timer?
    private var lastSelectedProjectId: String?
    private var lastSelectedTabId: String?
    private var lastBackGeometryLogBucket = -1

    private var isTransitioning: Bool {
        transitionLevel != nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ctUIKitColor(gray: 0.055)
        installShell(projectsShell)
        installShell(tabsShell)
        installShell(chatShell)
        installChild(projectsController, in: projectsShell)
        installChild(tabsController, in: tabsShell)
        chatShell.isHidden = true

        projectsController.onOpenProject = { [weak self] project in
            self?.pushProject(project)
        }
        projectsController.onRenameProject = { [weak self] project in
            self?.presentRenameProject(project)
        }
        projectsController.onCopyProject = { project in
            UIPasteboard.general.string = project.path
        }
        tabsController.onOpenTab = { [weak self] tab in
            self?.pushTab(tab)
        }
        tabsController.onRefresh = { [weak self] project in
            self?.refreshTabs(project)
        }
        tabsController.onNewTerminal = { [weak self] project in
            self?.presentNewTerminal(project)
        }
        tabsController.onRenameTab = { [weak self] tab, project in
            self?.presentRenameTab(tab, project: project)
        }
        tabsController.onCopyTab = { tab in
            UIPasteboard.general.string = tab.name
        }

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleBackPan(_:)))
        pan.delegate = self
        pan.cancelsTouchesInView = true
        view.addGestureRecognizer(pan)
        panRecognizer = pan

        syncFromStore(force: true)
        arrangeSettled(animated: false)
        syncTimer = Timer.scheduledTimer(withTimeInterval: 0.20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncFromStore(force: false) }
        }
    }

    deinit {
        syncTimer?.invalidate()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !isTransitioning else { return }
        for shell in [projectsShell, tabsShell, chatShell] {
            shell.frame = view.bounds
            shell.subviews.first?.frame = shell.bounds
        }
        arrangeSettled(animated: false)
    }

    func update(
        router: TabRouter,
        onShowHistory: @escaping () -> Void,
        onComposerFocusChange: @escaping (Bool) -> Void,
        bottomBarInset: CGFloat
    ) {
        self.router = router
        self.onShowHistory = onShowHistory
        self.onComposerFocusChange = onComposerFocusChange
        self.bottomBarInset = bottomBarInset
        projectsController.bottomBarInset = bottomBarInset
        tabsController.bottomBarInset = bottomBarInset
        rebuildChatIfNeeded(force: false)
        syncFromStore(force: false)
    }

    private func installShell(_ shell: UIView) {
        shell.backgroundColor = .clear
        shell.clipsToBounds = true
        shell.frame = view.bounds
        view.addSubview(shell)
    }

    private func installChild(_ child: UIViewController, in shell: UIView) {
        addChild(child)
        shell.addSubview(child.view)
        child.view.frame = shell.bounds
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        child.didMove(toParent: self)
    }

    private func syncFromStore(force: Bool) {
        projectsController.apply(
            projects: store.projects,
            activities: Dictionary(uniqueKeysWithValues: store.projects.map { ($0.id, store.activitySummary(projectId: $0.id)) }),
            savedAnchorId: store.projectsScrollAnchorId,
            force: force
        )

        if let project = store.selectedProject {
            let tabs = store.tabsByProject[project.id] ?? []
            tabsController.apply(
                project: project,
                tabs: tabs,
                marker: store.statusMarkerByProject[project.id] ?? .fallback,
                statusByTab: store.statusByTab,
                runningTabs: store.runningTabs,
                loading: store.loadingTabs.contains(project.id),
                savedAnchorId: store.tabsScrollAnchorByProject[project.id],
                force: force || project.id != lastSelectedProjectId
            )
        } else {
            tabsController.applyEmpty(force: force || lastSelectedProjectId != nil)
        }

        let selectedProjectId = store.selectedProject?.id
        let selectedTabId = store.selectedTab?.tabId
        if selectedProjectId != lastSelectedProjectId || selectedTabId != lastSelectedTabId {
            lastSelectedProjectId = selectedProjectId
            lastSelectedTabId = selectedTabId
            rebuildChatIfNeeded(force: true)
        }

        guard !isTransitioning else { return }
        let desired = desiredLevelFromStore()
        if desired != currentLevel {
            currentLevel = desired
            arrangeSettled(animated: false)
        }
    }

    private func desiredLevelFromStore() -> TerminalNavLevel {
        if store.selectedTab != nil { return .chat }
        if store.selectedProject != nil { return .tabs }
        return .projects
    }

    private func arrangeSettled(animated: Bool) {
        let updates = {
            for shell in [self.projectsShell, self.tabsShell, self.chatShell] {
                shell.frame = self.view.bounds
                shell.subviews.first?.frame = shell.bounds
                shell.transform = .identity
                shell.layer.zPosition = 0
            }
            self.projectsShell.isHidden = false
            self.tabsShell.isHidden = self.store.selectedProject == nil && self.currentLevel == .projects
            self.chatShell.isHidden = self.store.selectedTab == nil && self.currentLevel != .chat
            self.view.bringSubviewToFront(self.projectsShell)
            if self.currentLevel.rawValue >= TerminalNavLevel.tabs.rawValue {
                self.view.bringSubviewToFront(self.tabsShell)
            }
            if self.currentLevel == .chat {
                self.view.bringSubviewToFront(self.chatShell)
            }
        }
        if animated {
            UIView.animate(withDuration: 0.16, delay: 0, options: [.beginFromCurrentState, .curveEaseOut], animations: updates)
        } else {
            UIView.performWithoutAnimation(updates)
        }
    }

    private func pushProject(_ project: CTProject) {
        guard !isTransitioning, currentLevel == .projects else { return }
        let width = max(1, view.bounds.width)
        VCLog.log("term-swipe", "pushProject \(project.name) — UIKit container")
        MainThreadWatchdog.mark("term-project-push \(String(project.id.suffix(8)))")
        beginUIKitNavigation(label: "uikit pushProject name=\(project.name) id=\(String(project.id.suffix(8)))", phase: "animate")
        transitionLevel = .tabs
        tabsController.prepareForProject(project)
        store.selectProject(project)
        syncFromStore(force: true)
        tabsShell.isHidden = false
        projectsShell.isHidden = false
        projectsShell.frame = view.bounds
        tabsShell.frame = view.bounds
        projectsShell.transform = .identity
        tabsShell.transform = CGAffineTransform(translationX: width, y: 0)
        view.bringSubviewToFront(projectsShell)
        view.bringSubviewToFront(tabsShell)
        UIView.animate(
            withDuration: 0.18,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]
        ) {
            self.tabsShell.transform = .identity
        } completion: { _ in
            self.currentLevel = .tabs
            self.transitionLevel = nil
            self.arrangeSettled(animated: false)
            self.endUIKitNavigation()
        }
    }

    private func pushTab(_ tab: CTTabInfo) {
        guard !isTransitioning, currentLevel == .tabs, tab.isInteractiveAI else { return }
        guard let project = store.selectedProject else { return }
        let width = max(1, view.bounds.width)
        VCLog.log("term-swipe", "pushTab \(tab.name) — UIKit container")
        MainThreadWatchdog.mark("term-tab-push \(String((tab.tabId ?? tab.id).suffix(8)))")
        beginUIKitNavigation(label: "uikit pushTab name=\(tab.name) id=\(String((tab.tabId ?? tab.id).suffix(8)))", phase: "animate")
        transitionLevel = .chat
        store.selectTabForDisplay(tab, project: project)
        rebuildChatIfNeeded(force: true)
        guard chatController != nil else {
            transitionLevel = nil
            endUIKitNavigation()
            return
        }
        chatShell.isHidden = false
        tabsShell.frame = view.bounds
        chatShell.frame = view.bounds
        tabsShell.transform = .identity
        chatShell.transform = CGAffineTransform(translationX: width, y: 0)
        view.bringSubviewToFront(tabsShell)
        view.bringSubviewToFront(chatShell)
        UIView.animate(
            withDuration: 0.18,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]
        ) {
            self.chatShell.transform = .identity
        } completion: { _ in
            self.currentLevel = .chat
            self.transitionLevel = nil
            self.arrangeSettled(animated: false)
            self.endUIKitNavigation()
        }
    }

    private func rebuildChatIfNeeded(force: Bool) {
        guard let tab = store.selectedTab else {
            if let chatController {
                chatController.willMove(toParent: nil)
                chatController.view.removeFromSuperview()
                chatController.removeFromParent()
                self.chatController = nil
            }
            chatShell.isHidden = true
            return
        }
        let tabId = tab.tabId ?? tab.id
        if !force, chatController != nil, lastSelectedTabId == tabId { return }
        let root: AnyView
        if let router {
            root = AnyView(
                TerminalChatDetailView(
                    tab: tab,
                    onShowHistory: onShowHistory,
                    onComposerFocusChange: onComposerFocusChange,
                    showsHeader: false
                )
                .environmentObject(router)
                .environment(\.bottomBarInset, bottomBarInset)
            )
        } else {
            root = AnyView(
                TerminalChatDetailView(
                    tab: tab,
                    onShowHistory: onShowHistory,
                    onComposerFocusChange: onComposerFocusChange,
                    showsHeader: false
                )
                .environment(\.bottomBarInset, bottomBarInset)
            )
        }

        if let chatController {
            chatController.rootView = root
        } else {
            let controller = UIHostingController(rootView: root)
            controller.view.backgroundColor = ctUIKitColor(gray: 0.055)
            installChild(controller, in: chatShell)
            chatController = controller
        }
    }

    private func refreshTabs(_ project: CTProject) {
        Task {
            await store.loadTabs(projectId: project.id, showLoader: false, updateSelectedProject: true)
            tabsController.endRefreshing()
        }
    }

    private func presentNewTerminal(_ project: CTProject) {
        let sheet = UIAlertController(title: "New terminal", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Codex", style: .default) { [weak self] _ in
            self?.store.createAgentTab(in: project, toolType: "codex")
        })
        sheet.addAction(UIAlertAction(title: "Claude", style: .default) { [weak self] _ in
            self?.store.createAgentTab(in: project, toolType: "claude")
        })
        sheet.addAction(UIAlertAction(title: "Claude SDK tab", style: .default) { [weak self] _ in
            self?.store.createSDKTab(in: project)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = tabsController.newButton
            popover.sourceRect = tabsController.newButton.bounds
        }
        present(sheet, animated: true)
    }

    private func presentRenameProject(_ project: CTProject) {
        presentRename(title: "Rename project", initialName: project.name) { [weak self] name in
            self?.store.renameProject(project, to: name)
        }
    }

    private func presentRenameTab(_ tab: CTTabInfo, project: CTProject) {
        presentRename(title: "Rename tab", initialName: tab.name) { [weak self] name in
            self?.store.renameTab(tab, to: name, projectId: project.id)
        }
    }

    private func presentRename(title: String, initialName: String, onSave: @escaping (String) -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = initialName
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { _ in
            let value = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty { onSave(value) }
        })
        present(alert, animated: true)
    }

    private func beginUIKitNavigation(label: String, phase: String) {
        store.setInteractionActive(true, source: "term-uikit")
        FrameMonitor.shared.arm(reason: "term-nav", label: label, phase: phase)
    }

    private func endUIKitNavigation() {
        store.setInteractionActive(false, source: "term-uikit")
        FrameMonitor.shared.setPhase("settle")
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === panRecognizer else { return true }
        guard !isTransitioning, currentLevel != .projects else {
            VCLog.log("term-swipe", "uikit shouldBegin=NO enabled=false")
            return false
        }
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
        let velocity = pan.velocity(in: view)
        let location = pan.location(in: view)
        let horizontal = velocity.x > abs(velocity.y) * 1.15 && velocity.x > 80
        // This is Terminal's own page-back gesture, not the system edge pop. The
        // user expects a book-like page drag from the content area too. Direction
        // filtering protects vertical scroll; an edge-only gate made mid-screen
        // rightward swipes fall through as "cannot go back".
        let should = horizontal
        VCLog.log("term-swipe", "uikit shouldBegin=\(should ? "YES" : "NO") t=(\(Int(location.x)),0) v=(\(Int(velocity.x)),\(Int(velocity.y)))")
        return should
    }

    @objc private func handleBackPan(_ recognizer: UIPanGestureRecognizer) {
        let width = max(1, view.bounds.width)
        let translationX = max(0, min(width, recognizer.translation(in: view).x))
        switch recognizer.state {
        case .began:
            let from = currentLevel
            let to: TerminalNavLevel = from == .chat ? .tabs : .projects
            transitionLevel = to
            VCLog.log("term-swipe", "begin drag level=\(levelLabel(from))")
            beginUIKitNavigation(label: "uikit back from=\(levelLabel(from))", phase: "gesture")
            prepareBackTransition(from: from, to: to)
            updateBackTransition(translationX: max(translationX, initialBackPreviewOffset(width: width)), width: width)
        case .changed:
            let velocityX = max(0, recognizer.velocity(in: view).x)
            updateBackTransition(translationX: visualBackTranslation(raw: translationX, velocityX: velocityX, width: width), width: width)
        case .ended:
            let velocityX = recognizer.velocity(in: view).x
            let predicted = translationX + max(0, velocityX) * 0.18
            let commit = translationX > width * 0.28 || predicted > width * 0.42 || velocityX > 900
            finishBackTransition(commit: commit, translationX: translationX, predicted: predicted, width: width)
        case .cancelled, .failed:
            finishBackTransition(commit: false, translationX: translationX, predicted: translationX, width: width)
        default:
            break
        }
    }

    private func initialBackPreviewOffset(width: CGFloat) -> CGFloat {
        min(36, width * 0.10)
    }

    private func visualBackTranslation(raw: CGFloat, velocityX: CGFloat, width: CGFloat) -> CGFloat {
        let velocityLead = min(width * 0.22, velocityX * 0.06)
        return min(width, max(raw, raw + velocityLead, initialBackPreviewOffset(width: width)))
    }

    private func prepareBackTransition(from: TerminalNavLevel, to: TerminalNavLevel) {
        let source = viewForLevel(from)
        let destination = viewForLevel(to)
        source.frame = view.bounds
        destination.frame = view.bounds
        source.isHidden = false
        destination.isHidden = false
        source.transform = .identity
        destination.transform = .identity
        source.layer.removeAllAnimations()
        destination.layer.removeAllAnimations()
        source.layer.zPosition = 1
        destination.layer.zPosition = 0
        view.bringSubviewToFront(destination)
        view.bringSubviewToFront(source)
        lastBackGeometryLogBucket = -1
        logBackGeometry("prepare", translationX: 0, width: max(1, view.bounds.width))
    }

    private func updateBackTransition(translationX: CGFloat, width: CGFloat) {
        currentBackSourceView()?.transform = CGAffineTransform(translationX: translationX, y: 0)
        currentBackDestinationView()?.transform = .identity
        let progress = min(1, max(0, translationX / width))
        let bucket = Int((progress * 4).rounded(.down))
        if bucket != lastBackGeometryLogBucket {
            lastBackGeometryLogBucket = bucket
            logBackGeometry("drag", translationX: translationX, width: width)
        }
    }

    private func currentBackSourceView() -> UIView? {
        switch currentLevel {
        case .projects: return nil
        case .tabs: return tabsShell
        case .chat: return chatController == nil ? nil : chatShell
        }
    }

    private func currentBackDestinationView() -> UIView? {
        switch transitionLevel {
        case .projects: return projectsShell
        case .tabs: return tabsShell
        case .chat: return chatController == nil ? nil : chatShell
        case nil: return nil
        }
    }

    private func finishBackTransition(commit: Bool, translationX: CGFloat, predicted: CGFloat, width: CGFloat) {
        guard let source = currentBackSourceView() else {
            transitionLevel = nil
            endUIKitNavigation()
            return
        }
        let destination = currentBackDestinationView()
        let from = currentLevel
        let to: TerminalNavLevel = from == .chat ? .tabs : .projects
        if commit {
            VCLog.log("term-swipe", "uikit end COMMIT tx=\(Int(translationX)) predicted=\(Int(predicted)) → stepBack from \(levelLabel(from))")
            MainThreadWatchdog.mark("term-back-commit from=\(levelLabel(from))")
            FrameMonitor.shared.setPhase("animate")
        } else {
            VCLog.log("term-swipe", "uikit end CANCEL tx=\(Int(translationX)) predicted=\(Int(predicted))")
        }
        logBackGeometry(commit ? "commit-start" : "cancel-start", translationX: translationX, width: width)
        UIView.animate(
            withDuration: commit ? 0.16 : 0.14,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]
        ) {
            source.transform = CGAffineTransform(translationX: commit ? width : 0, y: 0)
            destination?.transform = .identity
        } completion: { _ in
            if commit {
                self.store.stepBackOneLevel()
                self.currentLevel = to
                // Hide the outgoing page BEFORE clearing its transform. If we reset
                // transform first, the tabs/chat page can briefly snap back over the
                // destination on the completion frame, which reads as a double page
                // flash before the preserved scroll position appears.
                source.isHidden = true
                UIView.performWithoutAnimation {
                    source.transform = .identity
                    source.frame = self.view.bounds
                    source.layer.zPosition = 0
                }
            } else {
                source.transform = .identity
                source.frame = self.view.bounds
                source.layer.zPosition = 0
            }
            destination?.transform = .identity
            destination?.frame = self.view.bounds
            destination?.layer.zPosition = 0
            self.transitionLevel = nil
            self.syncFromStore(force: true)
            self.arrangeSettled(animated: false)
            self.logBackGeometry(commit ? "commit-done" : "cancel-done", translationX: commit ? width : 0, width: width)
            self.endUIKitNavigation()
        }
    }

    private func logBackGeometry(_ event: String, translationX: CGFloat, width: CGFloat) {
        func state(_ label: String, _ view: UIView?) -> String {
            guard let view else { return "\(label)=nil" }
            return "\(label)[hidden=\(view.isHidden) frameX=\(Int(view.frame.minX)) tx=\(Int(view.transform.tx)) centerX=\(Int(view.center.x)) w=\(Int(view.bounds.width))]"
        }
        let transition = transitionLevel.map(levelLabel) ?? "nil"
        VCLog.log(
            "term-swipe-geo",
            "event=\(event) current=\(levelLabel(currentLevel)) transition=\(transition) tx=\(Int(translationX)) width=\(Int(width)) " +
            state("projects", projectsShell) + " " +
            state("tabs", tabsShell) + " " +
            state("chat", chatController == nil ? nil : chatShell)
        )
    }

    private func viewForLevel(_ level: TerminalNavLevel) -> UIView {
        switch level {
        case .projects: return projectsShell
        case .tabs: return tabsShell
        case .chat:
            rebuildChatIfNeeded(force: false)
            return chatController == nil ? tabsShell : chatShell
        }
    }

    private func levelLabel(_ level: TerminalNavLevel) -> String {
        switch level {
        case .projects: return "projects"
        case .tabs: return "tabs"
        case .chat: return "chat"
        }
    }
}

@MainActor
private final class TerminalUIKitProjectsController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    let tableView = UITableView(frame: .zero, style: .plain)
    var onOpenProject: (CTProject) -> Void = { _ in }
    var onRenameProject: (CTProject) -> Void = { _ in }
    var onCopyProject: (CTProject) -> Void = { _ in }
    var bottomBarInset: CGFloat = 0 {
        didSet { updateInsets() }
    }
    private var projects: [CTProject] = []
    private var activities: [String: CTActivitySummary] = [:]
    private var snapshotKey = ""
    private var restoredSavedAnchor = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ctUIKitColor(gray: 0.055)
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.showsVerticalScrollIndicator = true
        tableView.alwaysBounceVertical = true
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.estimatedRowHeight = 0
        tableView.register(TerminalUIKitProjectCell.self, forCellReuseIdentifier: TerminalUIKitProjectCell.reuseID)
        tableView.dataSource = self
        tableView.delegate = self
        view.addSubview(tableView)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        updateInsets()
    }

    func apply(projects: [CTProject], activities: [String: CTActivitySummary], savedAnchorId: String?, force: Bool) {
        let key = projects.map { project in
            let activity = activities[project.id] ?? CTActivitySummary(count: 0, streaming: false)
            return [
                project.id,
                project.name,
                String(project.tabCount ?? -1),
                String(project.liveSdkCount ?? -1),
                String(project.hasAwaiting == true),
                "\(activity.count):\(activity.streaming)"
            ].joined(separator: "|")
        }.joined(separator: "\n")
        guard force || key != snapshotKey else { return }
        let offset = tableView.contentOffset
        self.projects = projects
        self.activities = activities
        snapshotKey = key
        tableView.reloadData()
        tableView.layoutIfNeeded()
        if !restoredSavedAnchor, let savedAnchorId, let row = projects.firstIndex(where: { $0.id == savedAnchorId }) {
            restoredSavedAnchor = true
            tableView.scrollToRow(at: IndexPath(row: row, section: 0), at: .top, animated: false)
            VCLog.log("TerminalScroll", "projects restore id=\(String(savedAnchorId.suffix(8)))")
        } else if force || offset.y > -tableView.adjustedContentInset.top {
            tableView.setContentOffset(offset, animated: false)
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        projects.count
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        86
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: TerminalUIKitProjectCell.reuseID, for: indexPath) as! TerminalUIKitProjectCell
        let project = projects[indexPath.row]
        cell.configure(project: project, activity: activities[project.id] ?? CTActivitySummary(count: 0, streaming: false))
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard projects.indices.contains(indexPath.row) else { return }
        let project = projects[indexPath.row]
        commitAnchor(reason: "click")
        VCLog.log("TerminalScroll", "projects open click id=\(String(project.id.suffix(8)))")
        onOpenProject(project)
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard projects.indices.contains(indexPath.row) else { return nil }
        let project = projects[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: "Rename", image: UIImage(systemName: "pencil")) { _ in self?.onRenameProject(project) },
                UIAction(title: "Copy path", image: UIImage(systemName: "doc.on.doc")) { _ in self?.onCopyProject(project) }
            ])
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { commitAnchor(reason: "idle") }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        commitAnchor(reason: "idle")
    }

    private func commitAnchor(reason: String) {
        guard let first = tableView.indexPathsForVisibleRows?.sorted().first,
              projects.indices.contains(first.row)
        else { return }
        let id = projects[first.row].id
        if TerminalControlStore.shared.projectsScrollAnchorId != id {
            TerminalControlStore.shared.projectsScrollAnchorId = id
            VCLog.log("TerminalScroll", "projects anchor \(reason) id=\(String(id.suffix(8)))")
        }
    }

    private func updateInsets() {
        tableView.contentInset = UIEdgeInsets(top: 10, left: 0, bottom: bottomBarInset + 18, right: 0)
        tableView.scrollIndicatorInsets = tableView.contentInset
    }
}

@MainActor
private final class TerminalUIKitTabsController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    let tableView = UITableView(frame: .zero, style: .plain)
    let newButton = UIButton(type: .system)
    var onOpenTab: (CTTabInfo) -> Void = { _ in }
    var onRefresh: (CTProject) -> Void = { _ in }
    var onNewTerminal: (CTProject) -> Void = { _ in }
    var onRenameTab: (CTTabInfo, CTProject) -> Void = { _, _ in }
    var onCopyTab: (CTTabInfo) -> Void = { _ in }
    var bottomBarInset: CGFloat = 0 {
        didSet { updateInsetsAndButton() }
    }
    private var project: CTProject?
    private var tabs: [CTTabInfo] = []
    private var marker: CTStatusMarker = .fallback
    private var statusByTab: [String: String] = [:]
    private var runningTabs: Set<String> = []
    private var loading = false
    private var snapshotKey = ""
    private var restoredAnchorByProject: Set<String> = []
    private var offsetByProject: [String: CGPoint] = [:]
    private let emptyLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ctUIKitColor(gray: 0.055)
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.showsVerticalScrollIndicator = true
        tableView.alwaysBounceVertical = true
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.estimatedRowHeight = 0
        tableView.register(TerminalUIKitTabCell.self, forCellReuseIdentifier: TerminalUIKitTabCell.reuseID)
        tableView.dataSource = self
        tableView.delegate = self
        let refresh = UIRefreshControl()
        refresh.tintColor = .white
        refresh.addTarget(self, action: #selector(refreshPulled), for: .valueChanged)
        tableView.refreshControl = refresh

        emptyLabel.text = "No terminal tabs"
        emptyLabel.textColor = UIColor.secondaryLabel
        emptyLabel.font = .systemFont(ofSize: 14, weight: .medium)
        emptyLabel.textAlignment = .center
        emptyLabel.isHidden = true

        var config = UIButton.Configuration.filled()
        config.title = "New Terminal"
        config.image = UIImage(systemName: "plus")
        config.imagePadding = 7
        config.baseForegroundColor = .black
        config.baseBackgroundColor = .white
        config.cornerStyle = .capsule
        newButton.configuration = config
        newButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        newButton.addTarget(self, action: #selector(newTerminalTapped), for: .touchUpInside)

        view.addSubview(tableView)
        view.addSubview(emptyLabel)
        view.addSubview(newButton)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        newButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -24),
            newButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            newButton.heightAnchor.constraint(equalToConstant: 46)
        ])
        updateInsetsAndButton()
    }

    func prepareForProject(_ project: CTProject) {
        if let oldId = self.project?.id {
            offsetByProject[oldId] = tableView.contentOffset
        }
        self.project = project
        newButton.isHidden = false
    }

    func apply(
        project: CTProject,
        tabs: [CTTabInfo],
        marker: CTStatusMarker,
        statusByTab: [String: String],
        runningTabs: Set<String>,
        loading: Bool,
        savedAnchorId: String?,
        force: Bool
    ) {
        if let oldId = self.project?.id, oldId != project.id {
            offsetByProject[oldId] = tableView.contentOffset
        }
        self.project = project
        self.marker = marker
        self.statusByTab = statusByTab
        self.runningTabs = runningTabs
        self.loading = loading
        let key = tabs.map { tab in
            let id = tab.tabId ?? tab.id
            return [
                id,
                tab.name,
                tab.cwd,
                tab.effectiveToolType ?? "-",
                runtimeStatus(for: tab),
                String(tab.awaiting == true),
                tab.statusColor ?? "-"
            ].joined(separator: "|")
        }.joined(separator: "\n") + "|loading=\(loading)|project=\(project.id)"
        guard force || key != snapshotKey else { return }
        let previousOffset = tableView.contentOffset
        self.tabs = tabs
        snapshotKey = key
        emptyLabel.isHidden = !tabs.isEmpty || loading
        tableView.reloadData()
        tableView.layoutIfNeeded()
        if let stored = offsetByProject[project.id] {
            tableView.setContentOffset(stored, animated: false)
        } else if !restoredAnchorByProject.contains(project.id),
                  let savedAnchorId,
                  let row = tabs.firstIndex(where: { ($0.tabId ?? $0.id) == savedAnchorId }) {
            restoredAnchorByProject.insert(project.id)
            tableView.scrollToRow(at: IndexPath(row: row, section: 0), at: .top, animated: false)
            VCLog.log("TerminalScroll", "tabs restore project=\(String(project.id.suffix(8))) tab=\(String(savedAnchorId.suffix(8)))")
        } else if force || previousOffset.y > -tableView.adjustedContentInset.top {
            tableView.setContentOffset(previousOffset, animated: false)
        }
        newButton.isHidden = false
    }

    func applyEmpty(force: Bool) {
        guard force || project != nil || !tabs.isEmpty else { return }
        if let oldId = project?.id {
            offsetByProject[oldId] = tableView.contentOffset
        }
        project = nil
        tabs = []
        snapshotKey = ""
        emptyLabel.isHidden = true
        newButton.isHidden = true
        tableView.reloadData()
    }

    func endRefreshing() {
        tableView.refreshControl?.endRefreshing()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        tabs.count
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        70
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: TerminalUIKitTabCell.reuseID, for: indexPath) as! TerminalUIKitTabCell
        let tab = tabs[indexPath.row]
        cell.configure(tab: tab, marker: marker, runtime: runtimeStatus(for: tab), running: isRunning(tab))
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard tabs.indices.contains(indexPath.row) else { return }
        let tab = tabs[indexPath.row]
        guard tab.isInteractiveAI else { return }
        if let project {
            commitAnchor(reason: "click")
            offsetByProject[project.id] = tableView.contentOffset
            VCLog.log("TerminalScroll", "tabs open click project=\(String(project.id.suffix(8))) tab=\(String((tab.tabId ?? tab.id).suffix(8)))")
        }
        onOpenTab(tab)
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard tabs.indices.contains(indexPath.row), let project else { return nil }
        let tab = tabs[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: "Rename", image: UIImage(systemName: "pencil")) { _ in self?.onRenameTab(tab, project) },
                UIAction(title: "Copy name", image: UIImage(systemName: "doc.on.doc")) { _ in self?.onCopyTab(tab) }
            ])
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { commitAnchor(reason: "idle") }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        commitAnchor(reason: "idle")
    }

    private func commitAnchor(reason: String) {
        guard let project,
              let first = tableView.indexPathsForVisibleRows?.sorted().first,
              tabs.indices.contains(first.row)
        else { return }
        let id = tabs[first.row].tabId ?? tabs[first.row].id
        offsetByProject[project.id] = tableView.contentOffset
        if TerminalControlStore.shared.tabsScrollAnchorByProject[project.id] != id {
            TerminalControlStore.shared.tabsScrollAnchorByProject[project.id] = id
            VCLog.log("TerminalScroll", "tabs anchor \(reason) project=\(String(project.id.suffix(8))) tab=\(String(id.suffix(8)))")
        }
    }

    private func runtimeStatus(for tab: CTTabInfo) -> String {
        guard let id = tab.tabId else { return tab.sessionStatus ?? "inactive" }
        return statusByTab[id] ?? tab.sessionStatus ?? "inactive"
    }

    private func isRunning(_ tab: CTTabInfo) -> Bool {
        guard let id = tab.tabId else { return false }
        return runningTabs.contains(id)
    }

    private func updateInsetsAndButton() {
        tableView.contentInset = UIEdgeInsets(top: 10, left: 0, bottom: bottomBarInset + 74, right: 0)
        tableView.scrollIndicatorInsets = tableView.contentInset
        for constraint in view.constraints where constraint.firstItem === newButton && constraint.firstAttribute == .bottom {
            constraint.isActive = false
        }
        newButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -(bottomBarInset + 12)).isActive = true
    }

    @objc private func refreshPulled() {
        guard let project else {
            endRefreshing()
            return
        }
        onRefresh(project)
    }

    @objc private func newTerminalTapped() {
        guard let project else { return }
        onNewTerminal(project)
    }
}

private final class TerminalUIKitProjectCell: UITableViewCell {
    static let reuseID = "TerminalUIKitProjectCell"
    private let cardView = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let pathLabel = UILabel()
    private let metaLabel = UILabel()
    private let activityLabel = UILabel()
    private let awaitingDot = UIView()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(project: CTProject, activity: CTActivitySummary) {
        titleLabel.text = project.name
        pathLabel.text = project.path
        var meta = ["\(project.tabCount ?? 0) tabs"]
        if (project.liveSdkCount ?? 0) > 0 { meta.append("live \(project.liveSdkCount ?? 0)") }
        if project.isOpen == true { meta.append("open") }
        metaLabel.text = meta.joined(separator: "  ")
        awaitingDot.isHidden = project.hasAwaiting != true
        if activity.count > 0 {
            activityLabel.isHidden = false
            activityLabel.text = "\(activity.count)"
            activityLabel.backgroundColor = activity.streaming ? ctUIKitColor(hex: "22c55e", alpha: 0.24) : UIColor.white.withAlphaComponent(0.14)
            activityLabel.textColor = activity.streaming ? ctUIKitColor(hex: "86efac") : .white
        } else {
            activityLabel.isHidden = true
        }
        if let image = ctImageFromDataURL(project.icon) {
            iconView.image = image
            iconView.contentMode = .scaleAspectFill
            iconView.tintColor = nil
        } else {
            iconView.image = UIImage(systemName: "folder")
            iconView.contentMode = .center
            iconView.tintColor = UIColor.white.withAlphaComponent(0.84)
        }
    }

    private func build() {
        backgroundColor = .clear
        selectedBackgroundView = UIView()
        selectedBackgroundView?.backgroundColor = UIColor.white.withAlphaComponent(0.05)
        contentView.backgroundColor = .clear
        cardView.backgroundColor = UIColor.white.withAlphaComponent(0.065)
        cardView.layer.cornerRadius = 12
        cardView.layer.cornerCurve = .continuous
        cardView.layer.borderWidth = 1 / UIScreen.main.scale
        cardView.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor

        iconView.backgroundColor = UIColor.white.withAlphaComponent(0.10)
        iconView.layer.cornerRadius = 9
        iconView.layer.cornerCurve = .continuous
        iconView.clipsToBounds = true

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        pathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pathLabel.textColor = UIColor.secondaryLabel
        pathLabel.lineBreakMode = .byTruncatingMiddle
        metaLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        metaLabel.textColor = UIColor.secondaryLabel.withAlphaComponent(0.75)
        activityLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        activityLabel.textAlignment = .center
        activityLabel.layer.cornerRadius = 8
        activityLabel.layer.cornerCurve = .continuous
        activityLabel.clipsToBounds = true
        awaitingDot.backgroundColor = ctUIKitColor(hex: "a78bfa")
        awaitingDot.layer.cornerRadius = 3.5
        chevron.tintColor = UIColor.secondaryLabel

        [cardView, iconView, titleLabel, pathLabel, metaLabel, activityLabel, awaitingDot, chevron].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        contentView.addSubview(cardView)
        cardView.addSubview(iconView)
        cardView.addSubview(titleLabel)
        cardView.addSubview(pathLabel)
        cardView.addSubview(metaLabel)
        cardView.addSubview(activityLabel)
        cardView.addSubview(awaitingDot)
        cardView.addSubview(chevron)

        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            iconView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 38),
            iconView.heightAnchor.constraint(equalToConstant: 38),
            chevron.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),
            chevron.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 16),
            activityLabel.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -10),
            activityLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            activityLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 22),
            activityLabel.heightAnchor.constraint(equalToConstant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 11),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: activityLabel.leadingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 11),
            awaitingDot.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
            awaitingDot.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            awaitingDot.widthAnchor.constraint(equalToConstant: 7),
            awaitingDot.heightAnchor.constraint(equalToConstant: 7),
            pathLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            pathLabel.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -12),
            pathLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            metaLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            metaLabel.trailingAnchor.constraint(equalTo: pathLabel.trailingAnchor),
            metaLabel.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 5)
        ])
    }
}

private final class TerminalUIKitTabCell: UITableViewCell {
    static let reuseID = "TerminalUIKitTabCell"
    private let cardView = UIView()
    private let iconView = UIImageView()
    private let markerView = UIView()
    private let titleLabel = UILabel()
    private let cwdLabel = UILabel()
    private let statusDot = UIView()
    private let spinner = UIActivityIndicatorView(style: .medium)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(tab: CTTabInfo, marker: CTStatusMarker, runtime: String, running: Bool) {
        titleLabel.text = tab.name
        cwdLabel.text = tab.cwd
        iconView.image = agentUIImage(toolType: tab.effectiveToolType)
        iconView.tintColor = agentUIColor(toolType: tab.effectiveToolType).withAlphaComponent(tab.effectiveToolType == nil ? 0.7 : 1)
        markerView.backgroundColor = ctUIKitColor(hex: tab.statusColor ?? "6b7280")
        let markerSize = max(4, min(12, marker.sizePx ?? 8))
        markerView.layer.cornerRadius = marker.shape == "square" ? 2 : CGFloat(markerSize) / 2
        let busy = runtime == "busy" || runtime == "running" || running
        statusDot.backgroundColor = statusUIColor(runtime: runtime, awaiting: tab.awaiting == true)
        statusDot.isHidden = busy
        if busy {
            spinner.color = statusUIColor(runtime: runtime, awaiting: tab.awaiting == true)
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        let enabled = tab.isInteractiveAI
        contentView.alpha = enabled ? 1 : 0.55
        cardView.backgroundColor = tabUIKitBackground(tab: tab, runtime: runtime)
    }

    private func build() {
        backgroundColor = .clear
        selectedBackgroundView = UIView()
        selectedBackgroundView?.backgroundColor = UIColor.white.withAlphaComponent(0.05)
        contentView.backgroundColor = .clear
        cardView.layer.cornerRadius = 11
        cardView.layer.cornerCurve = .continuous
        cardView.layer.borderWidth = 1 / UIScreen.main.scale
        cardView.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
        iconView.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        iconView.layer.cornerRadius = 13
        iconView.layer.cornerCurve = .continuous
        iconView.contentMode = .center
        markerView.layer.cornerCurve = .continuous
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        cwdLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        cwdLabel.textColor = UIColor.secondaryLabel
        cwdLabel.lineBreakMode = .byTruncatingMiddle
        statusDot.layer.cornerRadius = 4
        spinner.transform = CGAffineTransform(scaleX: 0.72, y: 0.72)

        [cardView, iconView, markerView, titleLabel, cwdLabel, statusDot, spinner].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        contentView.addSubview(cardView)
        cardView.addSubview(iconView)
        cardView.addSubview(markerView)
        cardView.addSubview(titleLabel)
        cardView.addSubview(cwdLabel)
        cardView.addSubview(statusDot)
        cardView.addSubview(spinner)

        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            iconView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 11),
            iconView.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26),
            markerView.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 11),
            markerView.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            markerView.widthAnchor.constraint(equalToConstant: 8),
            markerView.heightAnchor.constraint(equalToConstant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: markerView.trailingAnchor, constant: 7),
            titleLabel.trailingAnchor.constraint(equalTo: statusDot.leadingAnchor, constant: -10),
            titleLabel.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 12),
            cwdLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            cwdLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            cwdLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            statusDot.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),
            statusDot.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),
            spinner.centerXAnchor.constraint(equalTo: statusDot.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: statusDot.centerYAnchor)
        ])
    }
}

private func ctUIKitColor(gray: CGFloat, alpha: CGFloat = 1) -> UIColor {
    UIColor(white: gray, alpha: alpha)
}

private func ctUIKitColor(hex: String, alpha: CGFloat = 1) -> UIColor {
    var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("#") { value.removeFirst() }
    guard value.count == 6, let int = Int(value, radix: 16) else {
        return UIColor.white.withAlphaComponent(alpha)
    }
    return UIColor(
        red: CGFloat((int >> 16) & 0xff) / 255,
        green: CGFloat((int >> 8) & 0xff) / 255,
        blue: CGFloat(int & 0xff) / 255,
        alpha: alpha
    )
}

private func agentUIColor(toolType: String?) -> UIColor {
    switch toolType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "codex": return ctUIKitColor(hex: "22c55e")
    case "claude": return ctUIKitColor(hex: "DA7756")
    default: return UIColor.white.withAlphaComponent(0.58)
    }
}

private func agentUIImage(toolType: String?) -> UIImage? {
    let normalized = toolType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized == "claude", let image = ctClaudeIconImage { return image }
    if normalized == "codex", let image = ctCodexIconImage { return image }
    return UIImage(systemName: "terminal")
}

private func statusUIColor(runtime: String, awaiting: Bool) -> UIColor {
    if awaiting { return ctUIKitColor(hex: "a78bfa") }
    switch runtime {
    case "busy", "running": return ctUIKitColor(hex: "d97706")
    case "active": return ctUIKitColor(hex: "22c55e")
    case "starting": return ctUIKitColor(hex: "DA7756")
    default: return ctUIKitColor(gray: 0.38)
    }
}

private func tabUIKitBackground(tab: CTTabInfo, runtime: String) -> UIColor {
    if runtime == "busy" || runtime == "running" {
        if tab.isCodexPTY { return ctUIKitColor(hex: "12351f", alpha: 0.55) }
        return ctUIKitColor(hex: "3f2a13", alpha: 0.45)
    }
    switch tab.effectiveToolType {
    case "codex": return ctUIKitColor(hex: "22c55e", alpha: 0.12)
    case "claude": return ctUIKitColor(hex: "DA7756", alpha: 0.13)
    default: return UIColor.white.withAlphaComponent(0.065)
    }
}

private struct TerminalInstallAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct TerminalProjectsView: View {
    let onShowHistory: () -> Void
    let interactionsSuspended: Bool
    let renderSuspended: Bool
    var showsHeader = true
    let onOpenProject: (CTProject) -> Void
    private let store = TerminalControlStore.shared   // @Observable singleton (Phase C)
    @EnvironmentObject private var router: TabRouter
    @Environment(\.bottomBarInset) private var bottomBarInset
    @State private var showBuildInstallConfirm = false
    @State private var installAlert: TerminalInstallAlert?
    @State private var renameTarget: CTProject?
    @State private var visibleProjectIds: [String] = []
    @State private var userScrollActive = false
    @AppStorage(VoiceChatConfig.Keys.uiFont, store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var uiFont: Double = 14

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                TerminalHeaderBar(onSettings: { router.openSettings() }) {
                    TerminalHeaderTitle(title: "Terminal", subtitle: TerminalControlConfig.displayHost(), uiFont: uiFont)
                } trailing: {
                    Button {
                        VCLog.log("TerminalInstallUI", "button tap running=\(store.terminalInstallRunning) offline=\(store.offline) projects=\(store.projects.count)")
                        Task { await prepareBuildInstall() }
                    } label: {
                        Group {
                            if store.terminalInstallRunning {
                                ProgressView().controlSize(.small).tint(.white)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                        }
                        .ctGlassCircle()
                    }
                    .buttonStyle(.plain)
                    .disabled(store.terminalInstallRunning)
                    .accessibilityLabel("Run npm install build")
                }
            }
        ZStack {
            CTPageBackground.ignoresSafeArea()
            if store.offline && store.projects.isEmpty {
                TerminalOfflineView(message: store.lastError, retry: { Task { await store.refreshProjects() } })
            } else if store.loadingProjects && store.projects.isEmpty {
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("Загрузка проектов…").font(.system(size: uiFont - 1)).foregroundStyle(.secondary)
                }
            } else if store.offline {
                TerminalOfflineView(message: store.lastError, retry: { Task { await store.refreshProjects() } })
            } else {
                terminalProjectsList(animatedBadge: !renderSuspended, fullControls: true)
            }
        }
        }
        .navigationBarHidden(true)
        .confirmationDialog("Запустить npm run build:install?", isPresented: $showBuildInstallConfirm, titleVisibility: .visible) {
            Button("Запустить install", role: .destructive) {
                VCLog.log("TerminalInstallUI", "confirm accepted")
                Task { await runBuildInstall() }
            }
            Button("Отмена", role: .cancel) {
                VCLog.log("TerminalInstallUI", "confirm cancelled")
            }
        } message: {
            Text("Custom Terminal станет недоступен на время переустановки. Запуск пойдёт через Voice Record, поэтому процесс не оборвётся при закрытии Terminal.")
        }
        .alert(item: $installAlert) { item in
            Alert(
                title: Text(item.title),
                message: Text(item.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .sheet(item: $renameTarget) { project in
            CTRenameSheet(title: "Rename project", label: "Project name", initialName: project.name) { newName in
                store.renameProject(project, to: newName)
            }
        }
    }

    private func prepareBuildInstall() async {
        guard !store.terminalInstallRunning else {
            VCLog.log("TerminalInstallUI", "prepare ignored already-running")
            return
        }
        VCLog.log("TerminalInstallUI", "prepare start")
        do {
            let blockers = try await store.terminalBuildInstallBlockers()
            if !blockers.isEmpty {
                VCLog.log("TerminalInstallUI", "prepare blocked count=\(blockers.count)")
                installAlert = TerminalInstallAlert(
                    title: "Terminal занят",
                    message: buildBlockerMessage(blockers)
                )
                return
            }
            VCLog.log("TerminalInstallUI", "prepare ok showConfirm")
            showBuildInstallConfirm = true
        } catch {
            VCLog.log("TerminalInstallUI", "prepare failed: \(friendlyError(error))")
            installAlert = TerminalInstallAlert(
                title: "Не удалось проверить Terminal",
                message: friendlyError(error)
            )
        }
    }

    private func runBuildInstall() async {
        VCLog.log("TerminalInstallUI", "run start")
        do {
            let job = try await store.runTerminalBuildInstall()
            let command = job?.command ?? "npm run build:install"
            VCLog.log("TerminalInstallUI", "run success command=\(command)")
            installAlert = TerminalInstallAlert(title: "Install завершён", message: command + " завершился.")
            await store.refreshProjects()
        } catch {
            VCLog.log("TerminalInstallUI", "run failed: \(friendlyError(error))")
            installAlert = TerminalInstallAlert(title: "Install не завершился", message: friendlyError(error))
        }
    }

    private func buildBlockerMessage(_ blockers: [CTActiveLoader]) -> String {
        var lines = blockers.prefix(6).map { loader in
            var line = loader.title
            if let status = loader.status, !status.isEmpty { line += " · " + status }
            if let cwd = loader.cwd, !cwd.isEmpty { line += "\n" + cwd }
            if let command = loader.command, !command.isEmpty { line += "\n" + command }
            return line
        }
        if blockers.count > lines.count {
            lines.append("ещё \(blockers.count - lines.count)")
        }
        return "Остановите вкладки, где сейчас идёт streaming или loader, перед install:\n\n" + lines.joined(separator: "\n\n")
    }

    private func friendlyError(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        return error.localizedDescription
    }

    private func terminalProjectsList(animatedBadge: Bool, fullControls: Bool) -> some View {
        ScrollView {
            // Plain VStack: 9 cheap rows, no laziness needed; avoids the lazy
            // viewport recompute under the slide .offset (iOS 26). Do not bind
            // live `.scrollPosition` here: setting it on tap/API refresh turns
            // into a programmatic scroll command and resets the list.
            VStack(spacing: 9) {
                ForEach(store.projects) { project in
                    Button {
                        guard !interactionsSuspended else { return }
                        onOpenProject(project)
                    } label: {
                        TerminalProjectRow(
                            project: project,
                            uiFont: uiFont,
                            activity: store.activitySummary(projectId: project.id),
                            animatedBadge: animatedBadge
                        )
                        .equatable()
                    }
                    .buttonStyle(.plain)
                    .allowsHitTesting(!interactionsSuspended)
                    .modifier(TerminalProjectContextMenuModifier(project: project, enabled: fullControls) { selected in
                        renameTarget = selected
                    })
                    .id(project.id)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, bottomBarInset + 70)   // clear glass bar
        }
        .onScrollTargetVisibilityChange(idType: String.self) { visibleIds in
            visibleProjectIds = visibleIds
        }
        .onScrollPhaseChange { _, newPhase in
            let active = newPhase == .tracking || newPhase == .interacting || newPhase == .decelerating
            if active {
                userScrollActive = true
            } else if userScrollActive {
                userScrollActive = false
                commitProjectsScrollAnchor(reason: "idle")
            }
        }
        .modifier(TerminalProjectsRefreshModifier(enabled: fullControls, store: store))
    }

    private func commitProjectsScrollAnchor(reason: String) {
        guard !interactionsSuspended, let anchor = visibleProjectIds.first else { return }
        if store.projectsScrollAnchorId != anchor {
            VCLog.log("TerminalScroll", "projects anchor \(reason) id=\(String(anchor.suffix(8)))")
            store.projectsScrollAnchorId = anchor
        }
    }
}

private struct TerminalProjectContextMenuModifier: ViewModifier {
    let project: CTProject
    let enabled: Bool
    let onRename: (CTProject) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.contextMenu {
                Button { onRename(project) } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button { UIPasteboard.general.string = project.name } label: {
                    Label("Copy name", systemImage: "doc.on.doc")
                }
                Button { UIPasteboard.general.string = project.path } label: {
                    Label("Copy path", systemImage: "folder")
                }
            }
        } else {
            content
        }
    }
}

private struct TerminalProjectsRefreshModifier: ViewModifier {
    let enabled: Bool
    let store: TerminalControlStore

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.refreshable { await store.refreshProjects() }
        } else {
            content
        }
    }
}

private struct TerminalProjectRow: View, Equatable {
    let project: CTProject
    let uiFont: Double
    let activity: CTActivitySummary
    var animatedBadge: Bool = true   // false in the back-preview (no live spinner)

    // Phase D extended: skip re-render unless this row's own inputs changed. The
    // projects list is the heaviest surface (9 rows w/ icons + activity badges)
    // and it renders as the back-preview DURING the project→projects slide; without
    // this, every row re-evaluated each frame of the slide (the remaining jank the
    // user saw on that specific transition).
    nonisolated static func == (lhs: TerminalProjectRow, rhs: TerminalProjectRow) -> Bool {
        lhs.project == rhs.project && lhs.uiFont == rhs.uiFont
            && lhs.activity == rhs.activity && lhs.animatedBadge == rhs.animatedBadge
    }

    var body: some View {
        HStack(spacing: 11) {
            CTProjectIconView(icon: project.icon)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(project.name)
                        .font(.system(size: uiFont + 1, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if project.hasAwaiting == true {
                        Circle().fill(CTViolet).frame(width: 7, height: 7)
                    }
                    Spacer(minLength: 6)
                    if activity.count > 0 {
                        TerminalActivityBadge(count: activity.count, streaming: activity.streaming, animated: animatedBadge)
                    }
                }
                Text(project.path)
                    .font(.system(size: uiFont - 3).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    Text("\(project.tabCount ?? 0) tabs")
                    if (project.liveSdkCount ?? 0) > 0 { Text("live \(project.liveSdkCount ?? 0)") }
                    if project.isOpen == true { Text("open") }
                }
                .font(.system(size: uiFont - 4).monospacedDigit())
                .foregroundStyle(.secondary.opacity(0.75))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.065)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.08)))
    }
}

private struct CTProjectIconView: View {
    let icon: String?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.10))
            if let image = ctImageFromDataURL(icon) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else {
                Image(systemName: "folder")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.84))
            }
        }
        .frame(width: 38, height: 38)
    }
}

// Decoded-icon cache. Project icons arrive as base64 data-URLs (the /api/projects
// payload is ~38KB of embedded PNGs for 9 projects). ctImageFromDataURL used to
// base64-decode + UIImage(data:) on EVERY body eval — so the 9-row projects list,
// rendered as the back-preview DURING the project→projects slide, re-decoded all
// 9 PNGs each frame. UIImage decode is render-phase work (often deferred to draw),
// which is why it lagged visibly but didn't always trip the main-thread watchdog.
// Cache by the data-URL string so each icon decodes once for the app's lifetime.
private let ctIconCache: NSCache<NSString, UIImage> = {
    let c = NSCache<NSString, UIImage>()
    c.countLimit = 64
    return c
}()

private func ctImageFromDataURL(_ value: String?) -> UIImage? {
    guard let value, !value.isEmpty else { return nil }
    let key = value as NSString
    if let cached = ctIconCache.object(forKey: key) { return cached }
    let base64: String
    if let comma = value.firstIndex(of: ",") {
        base64 = String(value[value.index(after: comma)...])
    } else {
        base64 = value
    }
    guard let data = Data(base64Encoded: base64), let image = UIImage(data: data) else { return nil }
    // Force-decode now (off the render path) so the first draw doesn't pay the
    // decompress cost; then cache the ready-to-draw image.
    let decoded = image.preparingForDisplay() ?? image
    ctIconCache.setObject(decoded, forKey: key)
    return decoded
}

private struct TerminalProjectTabsView: View {
    let project: CTProject
    let onShowHistory: () -> Void
    let interactionsSuspended: Bool
    let renderSuspended: Bool
    var showsHeader = true
    let onOpenTab: (CTTabInfo) -> Void
    private let store = TerminalControlStore.shared   // @Observable singleton (Phase C)
    @EnvironmentObject private var router: TabRouter
    @Environment(\.bottomBarInset) private var bottomBarInset
    @State private var showNewTerminal = false
    @State private var renameTarget: CTTabInfo?
    @State private var visibleTabIds: [String] = []
    @State private var restoredTabsProjectId: String?
    @State private var userScrollActive = false
    @AppStorage(VoiceChatConfig.Keys.uiFont, store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var uiFont: Double = 14

    private var tabs: [CTTabInfo] { store.tabsByProject[project.id] ?? [] }
    private var marker: CTStatusMarker { store.statusMarkerByProject[project.id] ?? .fallback }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                TerminalHeaderBar(onSettings: { router.openSettings() }) {
                    TerminalHeaderTitle(title: project.name, subtitle: "Terminal projects", uiFont: uiFont, maxWidth: 190)
                } trailing: {
                    Button { Task { await store.loadTabs(projectId: project.id) } } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .semibold)).ctGlassCircle()
                    }
                    .buttonStyle(.plain)
                }
            }
        ZStack {
            CTPageBackground.ignoresSafeArea()
            if store.loadingTabs.contains(project.id) && tabs.isEmpty {
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("Загрузка вкладок…").font(.system(size: uiFont - 1)).foregroundStyle(.secondary)
                }
            } else {
                terminalTabsList(animatedRows: !renderSuspended, fullControls: true)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !interactionsSuspended {
                TerminalFloatingNewButton(title: "New Terminal") {
                    showNewTerminal = true
                }
                .padding(.trailing, 16)
                // Lift above the root glass bar (user: "на странице проекта в правом
                // нижнем углу New Terminal тоже повыше поднять"). +4 keeps a touch
                // more gap than the list rows since this is a tap target.
                .padding(.bottom, bottomBarInset + 4)
            }
        }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showNewTerminal) {
            TerminalNewTerminalSheet(project: project)
                .presentationDetents([.medium])
        }
        .sheet(item: $renameTarget) { tab in
            CTRenameSheet(title: "Rename tab", label: "Tab name", initialName: tab.name) { newName in
                store.renameTab(tab, to: newName, projectId: project.id)
            }
        }
    }

    private func terminalTabsList(animatedRows: Bool, fullControls: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Plain VStack (not Lazy): ≤~12 cheap rows. A live
                // `.scrollPosition` binding is intentionally avoided: status
                // refreshes and taps must not issue hidden scroll commands while
                // the user is flick-scrolling or navigating.
                VStack(spacing: 8) {
                    ForEach(tabs) { tab in
                        Button {
                            guard tab.isInteractiveAI else { return }
                            guard !interactionsSuspended else { return }
                            onOpenTab(tab)
                        } label: {
                            TerminalTabRow(tab: tab, selected: false, uiFont: uiFont, marker: marker, animated: animatedRows)
                                .equatable()
                        }
                        .buttonStyle(.plain)
                        .allowsHitTesting(!interactionsSuspended)
                        .disabled(!tab.isInteractiveAI)
                        .opacity(tab.isInteractiveAI ? 1 : 0.55)
                        .modifier(TerminalTabContextMenuModifier(tab: tab, enabled: fullControls) { selected in
                            renameTarget = selected
                        })
                        .id(tab.tabId ?? tab.id)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, bottomBarInset + 70)   // clear glass bar + New Terminal FAB
            }
            .onAppear {
                restoreTabsScrollIfNeeded(proxy, projectId: project.id)
            }
            .onChange(of: project.id) { _, newProjectId in
                restoredTabsProjectId = nil
                visibleTabIds = []
                userScrollActive = false
                restoreTabsScrollIfNeeded(proxy, projectId: newProjectId)
            }
            .onScrollTargetVisibilityChange(idType: String.self) { visibleIds in
                visibleTabIds = visibleIds
            }
            .onScrollPhaseChange { _, newPhase in
                let active = newPhase == .tracking || newPhase == .interacting || newPhase == .decelerating
                if active {
                    userScrollActive = true
                } else if userScrollActive {
                    userScrollActive = false
                    commitTabsScrollAnchor(reason: "idle")
                }
            }
            .modifier(TerminalTabsRefreshModifier(enabled: fullControls, projectId: project.id, store: store))
        }
    }

    private func commitTabsScrollAnchor(reason: String) {
        guard !interactionsSuspended, let anchor = visibleTabIds.first else { return }
        if store.tabsScrollAnchorByProject[project.id] != anchor {
            VCLog.log("TerminalScroll", "tabs anchor \(reason) project=\(String(project.id.suffix(8))) tab=\(String(anchor.suffix(8)))")
            store.tabsScrollAnchorByProject[project.id] = anchor
        }
    }

    private func restoreTabsScrollIfNeeded(_ proxy: ScrollViewProxy, projectId: String) {
        guard store.selectedProject?.id == projectId,
              store.selectedTab == nil,
              !interactionsSuspended,
              restoredTabsProjectId != projectId
        else { return }
        let rowIds = tabs.map { $0.tabId ?? $0.id }
        guard !rowIds.isEmpty else { return }
        guard let savedAnchor = store.tabsScrollAnchorByProject[projectId],
              rowIds.contains(savedAnchor)
        else { return }
        let target = savedAnchor
        restoredTabsProjectId = projectId
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(target, anchor: .top)
            VCLog.log("TerminalScroll", "tabs restore project=\(String(projectId.suffix(8))) tab=\(String(target.suffix(8)))")
        }
    }
}

private struct TerminalTabContextMenuModifier: ViewModifier {
    let tab: CTTabInfo
    let enabled: Bool
    let onRename: (CTTabInfo) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.contextMenu {
                Button { onRename(tab) } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button { UIPasteboard.general.string = tab.name } label: {
                    Label("Copy name", systemImage: "doc.on.doc")
                }
            }
        } else {
            content
        }
    }
}

private struct TerminalTabsRefreshModifier: ViewModifier {
    let enabled: Bool
    let projectId: String
    let store: TerminalControlStore

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.refreshable { await store.loadTabs(projectId: projectId) }
        } else {
            content
        }
    }
}

private struct TerminalFloatingNewButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .bold))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Capsule(style: .continuous).fill(.white))
            .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
        }
        .buttonStyle(.plain)
    }
}

private struct TerminalNewTerminalSheet: View {
    let project: CTProject
    private let store = TerminalControlStore.shared   // @Observable singleton (Phase C)
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color(white: 0.28)).frame(width: 36, height: 4).padding(.top, 8).padding(.bottom, 18)
            HStack {
                Text("New terminal")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Menu {
                    Button("Claude SDK tab") {
                        dismiss()
                        store.createSDKTab(in: project)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)

            VStack(spacing: 10) {
                newAgentButton(title: "Codex", subtitle: "PTY terminal · rollout history", toolType: "codex", accent: CTCodexGreen)
                newAgentButton(title: "Claude", subtitle: "PTY terminal · JSONL history", toolType: "claude", accent: CTAccent)
            }
            .padding(.horizontal, 16)
            Spacer(minLength: 0)
        }
        .background(Color(white: 0.04).ignoresSafeArea())
    }

    private func newAgentButton(title: String, subtitle: String, toolType: String, accent: Color) -> some View {
        Button {
            dismiss()
            store.createAgentTab(in: project, toolType: toolType)
        } label: {
            HStack(spacing: 12) {
                AgentIconView(toolType: toolType, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(accent)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.white.opacity(0.075)))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(accent.opacity(0.28)))
        }
        .buttonStyle(.plain)
    }
}

private struct TerminalTabRow: View, Equatable {
    let tab: CTTabInfo
    let selected: Bool
    let uiFont: Double
    let marker: CTStatusMarker
    // false in the back-preview: a busy tab shows an indeterminate ProgressView
    // (a repeatForever-class live animation). 12-tab lists with a busy row rendered
    // as the back-preview spun that spinner behind the slide → the residual lag the
    // watchdog couldn't see (render/animation, not a main-thread block). Static dot
    // in preview; live spinner only in the foreground list.
    var animated: Bool = true

    nonisolated static func == (lhs: TerminalTabRow, rhs: TerminalTabRow) -> Bool {
        lhs.tab == rhs.tab && lhs.selected == rhs.selected
            && lhs.uiFont == rhs.uiFont && lhs.marker == rhs.marker && lhs.animated == rhs.animated
    }

    private var runtime: String { tab.sessionStatus ?? "inactive" }
    private var tint: Color {
        if tab.awaiting == true { return CTViolet }
        switch runtime {
        case "busy": return Color(hex: "d97706")
        case "active": return CTGreen
        case "starting": return CTAccent
        default: return Color(white: 0.38)
        }
    }

    var body: some View {
        // Render-churn probe (grep [term-render], label tab:). Fires per body eval
        // in the foreground list so a re-render storm is visible; preview rows
        // (animated:false) are excluded to avoid noise.
        if animated { TerminalRenderProbe.tick("tab:" + (tab.tabId ?? tab.id)) }
        return rowBody
    }

    @ViewBuilder
    private var rowBody: some View {
        HStack(spacing: 11) {
            AgentIconView(toolType: agentToolType, size: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    StatusMarkerSlot(colorHex: tab.statusColor, marker: marker)
                    Text(tab.name)
                        .font(.system(size: uiFont, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                Text(tab.cwd)
                    .font(.system(size: uiFont - 3).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if runtime == "busy" && animated {
                ProgressView().controlSize(.small).tint(tint)
            } else {
                // Static dot for non-busy, AND for busy in the back-preview (no live
                // spinner competing with the slide).
                Circle().fill(tint).frame(width: 8, height: 8)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(tabRowBackground(tab.color, selected: selected, busy: runtime == "busy", isCodex: tab.isCodexPTY, isClaude: tab.isClaudePTY)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(selected ? CTAccent.opacity(0.55) : Color.white.opacity(0.08)))
    }

    private var agentToolType: String? {
        tab.effectiveToolType
    }
}

private struct StatusMarkerSlot: View {
    let colorHex: String?
    let marker: CTStatusMarker

    private var size: CGFloat {
        CGFloat(max(4, min(12, marker.sizePx ?? 8)))
    }

    var body: some View {
        ZStack {
            if let colorHex {
                Group {
                    if marker.shape == "square" {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color(hex: colorHex))
                    } else {
                        Circle().fill(Color(hex: colorHex))
                    }
                }
                .frame(width: size, height: size)
            }
        }
        .frame(width: 13, height: 13)
    }
}

// Pre-decoded agent icons, resolved once. Per-row `Image("ClaudeIcon")` lookups
// (×~15 rows) on first render of the live tabs list were part of the post-open
// cost; a module-level cached UIImage skips the asset-catalog hit per row.
private let ctClaudeIconImage = UIImage(named: "ClaudeIcon")?.preparingForDisplay() ?? UIImage(named: "ClaudeIcon")
private let ctCodexIconImage = UIImage(named: "CodexIcon")?.preparingForDisplay() ?? UIImage(named: "CodexIcon")

private struct AgentIconView: View {
    let toolType: String?
    var size: CGFloat = 24
    private var normalizedToolType: String? {
        toolType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var body: some View {
        ZStack {
            Circle().fill(agentAccent(toolType).opacity(0.13))
            if normalizedToolType == "claude", let img = ctClaudeIconImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.18)
            } else if normalizedToolType == "codex", let img = ctCodexIconImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.12)
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.68))
            }
        }
        .frame(width: size, height: size)
    }
}

private func agentAccent(_ toolType: String?) -> Color {
    switch toolType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "codex": return CTCodexGreen
    case "claude": return CTAccent
    default: return Color.white.opacity(0.55)
    }
}

private func tabRowBackground(_ color: String?, selected: Bool, busy: Bool, isCodex: Bool, isClaude: Bool) -> Color {
    if busy {
        if isCodex { return Color(hex: "12351f").opacity(0.55) }
        return Color(hex: "3f2a13").opacity(0.45)
    }
    if selected { return CTAccent.opacity(0.18) }
    switch color {
    case "claude": return CTAccent.opacity(0.16)
    case "codex": return CTCodexGreen.opacity(0.15)
    case "purple": return Color(hex: "7c3aed").opacity(0.18)
    case "blue": return Color(hex: "2563eb").opacity(0.16)
    case "green": return Color(hex: "16a34a").opacity(0.14)
    case "red": return Color(hex: "dc2626").opacity(0.14)
    case "yellow": return Color(hex: "ca8a04").opacity(0.14)
    default:
        if isCodex { return CTCodexGreen.opacity(0.12) }
        if isClaude { return CTAccent.opacity(0.13) }
        return Color.white.opacity(0.065)
    }
}

private struct TerminalScrollMetrics: Equatable {
    static let zero = TerminalScrollMetrics(offsetY: 0, contentHeight: 0, containerHeight: 0)

    let offsetY: CGFloat
    let contentHeight: CGFloat
    let containerHeight: CGFloat

    var scrollableHeight: CGFloat {
        max(0, contentHeight - containerHeight)
    }

    var distFromBottom: CGFloat {
        contentHeight - containerHeight - offsetY
    }

    var bottomRatio: Double {
        guard scrollableHeight > 1 else { return 1 }
        return Double(offsetY / scrollableHeight)
    }

    var logSummary: String {
        "off=\(Int(offsetY)) content=\(Int(contentHeight)) container=\(Int(containerHeight)) dist=\(Int(distFromBottom)) ratio=\(String(format: "%.2f", bottomRatio))"
    }
}

private struct TerminalChatDetailView: View {
    let tab: CTTabInfo
    let onShowHistory: () -> Void
    var onComposerFocusChange: (Bool) -> Void = { _ in }
    var showsHeader = true

    private let store = TerminalControlStore.shared   // @Observable singleton (Phase C)
    @ObservedObject private var voiceStore = VoiceChatStore.shared
    @EnvironmentObject private var router: TabRouter
    @Environment(\.bottomBarInset) private var bottomBarInset
    @State private var input = ""
    @State private var showTerminalPrompts = false
    @State private var showVoicePrompts = false
    @State private var showGTPicker = false
    @State private var gtAttachments: [VCAttachment] = []
    @State private var gtPreviewTarget: GTFilePreviewTarget? = nil
    @State private var draftNotice: String?
    @State private var showQueue = false
    @State private var showTimeline = false
    @State private var showRename = false
    @State private var localSending = false
    @State private var followBottom = true
    @State private var userTouching = false
    @State private var userScrollIntent = false
    @State private var distFromBottom: CGFloat = 0
    @State private var scrollMetrics: TerminalScrollMetrics = .zero
    @State private var lastScrollLogAt = Date.distantPast
    @State private var lastDriftPinAt = Date.distantPast
    // Auto-send arming (see ComposerSendButton). Armed → purple spinner on the
    // send button; the next dictation insert auto-submits instead of just
    // landing in the field.
    @State private var autoSendArmed = false
    @FocusState private var composerFocused: Bool
    // Keyboard lift for the docked composer. The terminal chat previously had NO
    // keyboard handling at all — it relied on the system's automatic avoidance,
    // which the root pager's containerRelativeFrame + ignoresSafeArea defeat, so
    // the keyboard rose but the composer stayed pinned behind it (user: "инпут не
    // поднимается"). We mirror the Gemini ChatDetailView overlay model: measure
    // keyboard overlap against the window and lift the composer by an offset
    // (NOT safeAreaInset — the documented overlay-composer model).
    @State private var keyboardOverlap: CGFloat = 0
    @State private var keyboardLiftAnim: Animation = .easeOut(duration: 0.22)

    @AppStorage(VoiceChatConfig.Keys.chatFont, store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var chatFont: Double = 15
    @AppStorage(VoiceChatConfig.Keys.uiFont, store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var uiFont: Double = 14

    private var tabId: String { tab.tabId ?? "" }
    private var voiceComposerKey: String { VoiceChatStore.terminalComposerKey(tabId: tabId) }
    private var entries: [CTEntry] { store.entriesByTab[tabId] ?? [] }
    private var status: String { store.statusByTab[tabId] ?? tab.sessionStatus ?? "inactive" }
    private var awaitingInterrupt: Bool { store.interruptAwaitingTabs.contains(tabId) }
    private var busy: Bool { localSending || awaitingInterrupt || store.runningTabs.contains(tabId) || status == "busy" }
    private var canResume: Bool { (tab.isClaudePTY || tab.isCodexPTY) && (tab.activeSessionId?.isEmpty == false) && status == "inactive" }
    private var canUseComposer: Bool { !tabId.isEmpty && !canResume && status != "starting" }

    // Center of the custom header (replaces the old principal toolbar item): tab
    // name + status line + context%, long-press for rename / think toggle.
    @ViewBuilder private var chatHeaderCenter: some View {
        VStack(spacing: 1) {
            Text(tab.name)
                .font(.system(size: uiFont, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
            HStack(spacing: 4) {
                Circle().fill(statusColor).frame(width: 6, height: 6)
                Text(status)
                    .font(.system(size: max(9, uiFont - 4)).monospacedDigit())
                    .foregroundStyle(.secondary)
                if tab.isClaudePTY || tab.isCodexPTY || tab.isSDK {
                    if let pct = store.contextPctByTab[tabId] {
                        Text("· \(pct)%")
                            .font(.system(size: max(11, uiFont - 2), weight: .semibold).monospacedDigit())
                            .foregroundStyle(contextPctColor(pct))
                    } else {
                        Text("· –")
                            .font(.system(size: max(11, uiFont - 2), weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: 220)
        .contentShape(Rectangle())
        .contextMenu {
            Button { showRename = true } label: { Label("Rename", systemImage: "pencil") }
            Button { UIPasteboard.general.string = tab.name } label: { Label("Copy name", systemImage: "doc.on.doc") }
            if !tab.isCodexPTY {
                let thinkingOn = (store.paramsByTab[tabId]?.thinking ?? "adaptive") != "disabled"
                Button {
                    Task { await store.setParams(tabId: tabId, partial: ["thinking": thinkingOn ? "disabled" : "adaptive"]) }
                } label: {
                    Label(thinkingOn ? "Think: ON" : "Think: OFF", systemImage: thinkingOn ? "brain.head.profile.fill" : "brain")
                }
                .disabled(store.isTabTurnBusy(tabId))
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                TerminalHeaderBar(onSettings: { router.openSettings() }) {
                    chatHeaderCenter
                } trailing: {
                    Button { Task { await store.loadHistory(tabId: tabId) } } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .semibold)).ctGlassCircle()
                    }
                    .buttonStyle(.plain)
                }
            }
        ZStack {
            CTPageBackground.ignoresSafeArea()
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if store.historyLoading.contains(tabId) && entries.isEmpty {
                                VStack(spacing: 10) {
                                    ProgressView().tint(.white)
                                    Text("Loading history…").font(.system(size: chatFont - 2)).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.top, 120)
                            } else if entries.isEmpty {
                                TerminalEmptyState(tab: tab, chatFont: chatFont)
                            } else {
                                ForEach(entries) { entry in
                                    TerminalEntryView(entry: entry, chatFont: chatFont)
                                        .equatable()   // Phase D: skip unchanged rows during streaming
                                }
                            }
                            Color.clear.frame(height: 142 + bottomBarInset).id("BOTTOM")
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 48)
                    }
                    .defaultScrollAnchor(.bottom)
                    .scrollDismissesKeyboard(.interactively)
                    .onScrollPhaseChange { oldPhase, newPhase in
                        let userDriven = newPhase == .tracking || newPhase == .interacting || newPhase == .decelerating
                        userTouching = (newPhase == .tracking || newPhase == .interacting)
                        userScrollIntent = userDriven
                        if userDriven && distFromBottom > 120 { followBottom = false }
                        logScroll(
                            "phase \(String(describing: oldPhase))->\(String(describing: newPhase))",
                            force: true
                        )
                    }
                    .onScrollGeometryChange(for: TerminalScrollMetrics.self) { geo in
                        TerminalScrollMetrics(
                            offsetY: geo.contentOffset.y,
                            contentHeight: geo.contentSize.height,
                            containerHeight: geo.containerSize.height
                        )
                    } action: { oldMetrics, newMetrics in
                        updateScrollMetrics(old: oldMetrics, new: newMetrics, proxy: proxy)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    TerminalFloatingControls(
                        status: status,
                        canQueue: tab.isClaudePTY || tab.isCodexPTY,
                        timelineCount: tab.timelineCount,
                        onQueue: { showQueue = true },
                        onTimeline: { showTimeline = true },
                        onStopProcess: { store.stopProcess(tabId: tabId) }
                    )
                    .padding(.top, 8)
                    .padding(.trailing, 10)
                }
                .overlay(alignment: .bottom) {
                    terminalComposer(proxy: proxy)
                        // Lift above the keyboard. When the keyboard is up,
                        // keyboardOverlap = its height minus the home-indicator
                        // inset already baked into the composer's bottom padding.
                        .offset(y: -keyboardOverlap)
                        .animation(keyboardLiftAnim, value: keyboardOverlap)
                }
                .onChange(of: entries.count) { _, _ in pin(proxy, reason: "entries") }
                .onChange(of: busy) { _, _ in pin(proxy, reason: "busy") }
                // Streaming follow-bottom: the reducer grows the assistant/thinking
                // answer by mutating the tail entry's `text` IN PLACE, so
                // entries.count stays stable while a single answer streams. Pin on
                // the tail entry's char count too, otherwise auto-scroll only fires
                // when a NEW entry is appended and freezes mid-answer. pin() is gated
                // by the followBottom intent, so a user who scrolled up is not yanked.
                .onChange(of: entries.last?.text.count ?? 0) { _, _ in pin(proxy, reason: "tail") }
                .onChange(of: keyboardOverlap) { oldValue, newValue in
                    logScroll("keyboard old=\(Int(oldValue)) new=\(Int(newValue))", force: true)
                }
            }
        }
        }
        .navigationBarHidden(true)
        .onAppear {
            if !tabId.isEmpty {
                voiceStore.setActiveComposerKey(voiceComposerKey)
                consumePendingDictationInsert()
            }
        }
        // PHASE B: view-owned activation. `.task(id: tabId)` runs when this detail
        // appears for a tabId and is AUTOMATICALLY cancelled by SwiftUI when the
        // view disappears or the id changes — so swiping back mid-load cancels the
        // load instead of leaving an orphan Task to mutate torn-down state. Heavy
        // history parse is off-main (Phase A); the store's identity guards are the
        // belt to this suspenders. Only the committed copy (store.selectedTab ==
        // this tab) activates — the transient forward-push copy skips, avoiding a
        // double load. The supplementary refreshes ride the same cancellable task.
        .task(id: tabId) {
            guard !tabId.isEmpty else { return }
            guard store.selectedTab?.tabId == tabId else {
                VCLog.log("TerminalSSE", "task(id:) skip activate — transient copy tab=\(tabId.suffix(6))")
                return
            }
            await store.awaitTerminalActivationWindow(tabId: tabId)
            guard !Task.isCancelled else {
                VCLog.log("TerminalSSE", "task(id:) cancelled before activate tab=\(tabId.suffix(6))")
                return
            }
            guard store.selectedTab?.tabId == tabId else {
                VCLog.log("TerminalSSE", "task(id:) skip activate after quiet wait — tab changed tab=\(tabId.suffix(6))")
                return
            }
            VCLog.log("TerminalSSE", "task(id:) activate begin tab=\(tabId.suffix(6))")
            await store.activateSelectedTab(tabId: tabId)
            if Task.isCancelled {
                VCLog.log("TerminalSSE", "task(id:) cancelled after activate tab=\(tabId.suffix(6))")
                return
            }
            await store.refreshQueue(tabId: tabId)
            await store.refreshPendingQuestion(tabId: tabId)
            VCLog.log("TerminalSSE", "task(id:) activate done tab=\(tabId.suffix(6))")
        }
        .onDisappear {
            // Only release dictation ownership when we are TRULY leaving this tab.
            // During the animated drill-in, TerminalControlRootView mounts this
            // view twice (transient forward-push copy + committed content copy)
            // with the same tabId/composer key. The transient copy's teardown
            // must NOT clear the key the surviving copy still owns, otherwise
            // activeComposerKey becomes nil and a later Voice-dictation stop has
            // no target → text is silently dropped. selectedTab is set before the
            // forward copy unmounts, so this guard preserves the key on handoff.
            if !tabId.isEmpty && store.selectedTab?.tabId != tabId {
                voiceStore.clearActiveComposerKey(voiceComposerKey)
                autoSendArmed = false   // arming is ephemeral to this composer
            }
        }
        .onChange(of: tabId) { oldValue, newValue in
            if !oldValue.isEmpty { voiceStore.clearActiveComposerKey(VoiceChatStore.terminalComposerKey(tabId: oldValue)) }
            autoSendArmed = false       // switching tabs drops any pending arm
            if !newValue.isEmpty {
                voiceStore.setActiveComposerKey(VoiceChatStore.terminalComposerKey(tabId: newValue))
                consumePendingDictationInsert()
                Task { await store.refreshPendingQuestion(tabId: newValue) }
            }
        }
        .onChange(of: composerFocused) { _, focused in onComposerFocusChange(focused) }
        // Keyboard lift: drive the composer offset off the real keyboard frame.
        // willChangeFrame covers show/predictive/interactive; willHide covers
        // dismissal. Overlap = how much the keyboard intrudes into the window
        // minus the home-indicator safe area (the composer already floats above
        // that via its bottom padding), so we don't double-count it.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            applyTerminalKeyboard(note, hiding: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { note in
            applyTerminalKeyboard(note, hiding: true)
        }
        .sheet(isPresented: $showTerminalPrompts) {
            TerminalPromptPicker { text in
                appendPrompt(text)
                showTerminalPrompts = false
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showVoicePrompts) {
            TerminalVoicePromptPicker { text in
                appendPrompt(text)
                showVoicePrompts = false
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showQueue) {
            TerminalQueueSheet(tabId: tabId)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showTimeline) {
            TerminalTimelineSheet(tabId: tabId)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showRename) {
            CTRenameSheet(title: "Rename tab", label: "Tab name", initialName: tab.name) { newName in
                store.renameTab(tab, to: newName)
            }
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
        .onChange(of: store.restoredInputByTab[tabId]) { _, restored in
            guard let restored else { return }
            appendPrompt(restored)
            draftNotice = nil
            composerFocused = true
            store.consumeRestoredInput(tabId: tabId)
        }
        .onChange(of: store.draftNoticeByTab[tabId]) { _, notice in
            draftNotice = notice
            if notice != nil { store.consumeDraftNotice(tabId: tabId) }
        }
        .onChange(of: voiceStore.pendingComposerInsert) { _, _ in
            consumePendingDictationInsert()
        }
    }

    private var statusColor: Color {
        switch status {
        case "busy": return Color(hex: "d97706")
        case "active": return CTGreen
        case "starting": return CTAccent
        default: return Color(white: 0.38)
        }
    }

    private func updateScrollMetrics(old: TerminalScrollMetrics, new: TerminalScrollMetrics, proxy: ScrollViewProxy) {
        let wasFollowing = followBottom
        scrollMetrics = new
        distFromBottom = new.distFromBottom
        if new.scrollableHeight > 1, new.distFromBottom < -90 {
            let now = Date()
            if now.timeIntervalSince(lastDriftPinAt) * 1000 > 220 {
                lastDriftPinAt = now
                followBottom = true
                logScroll("overscroll-clamp re-pin", force: true)
                pin(proxy, reason: "overscroll-clamp")
            }
        }
        if userTouching || userScrollIntent {
            if new.distFromBottom > 120 { followBottom = false }
            else if new.distFromBottom <= 60 { followBottom = true }
        }
        logScrollGeometryIfNeeded(old: old, new: new, followChanged: wasFollowing != followBottom)

        // During streaming the user reports a blank area and the content only comes
        // back after a manual scroll. If SwiftUI drifts away from bottom while the
        // follow intent is still armed and the user is not touching the list, re-pin
        // once per short window and log it. This is intentionally gated to streaming
        // / busy periods so ordinary reading position is not fought.
        let driftedWhileFollowing = !userTouching
            && !userScrollIntent
            && followBottom
            && busy
            && new.scrollableHeight > 1
            && (new.distFromBottom > 140 || new.distFromBottom < -90)
        if driftedWhileFollowing {
            let now = Date()
            if now.timeIntervalSince(lastDriftPinAt) * 1000 > 350 {
                lastDriftPinAt = now
                logScroll("geometry-drift re-pin", force: true)
                pin(proxy, reason: "geometry-drift")
            }
        }
    }

    private func logScrollGeometryIfNeeded(old: TerminalScrollMetrics, new: TerminalScrollMetrics, followChanged: Bool) {
        let distDelta = abs(new.distFromBottom - old.distFromBottom)
        let offsetDelta = abs(new.offsetY - old.offsetY)
        let contentDelta = abs(new.contentHeight - old.contentHeight)
        let suspicious = new.distFromBottom < -80
            || (!userTouching && !userScrollIntent && followBottom && new.distFromBottom > 120)
        let shouldLog = followChanged
            || suspicious
            || distDelta > 90
            || offsetDelta > 90
            || contentDelta > 80
        guard shouldLog else { return }
        let now = Date()
        guard suspicious || followChanged || now.timeIntervalSince(lastScrollLogAt) * 1000 > 450 else { return }
        lastScrollLogAt = now
        VCLog.log(
            "TerminalScroll",
            "geom tab=\(tabId.suffix(6)) entries=\(entries.count) tail=\(entries.last?.text.count ?? 0) busy=\(busy) follow=\(followBottom) touch=\(userTouching) userScroll=\(userScrollIntent) focus=\(composerFocused) kb=\(Int(keyboardOverlap)) dOff=\(Int(new.offsetY - old.offsetY)) dContent=\(Int(new.contentHeight - old.contentHeight)) old[\(old.logSummary)] new[\(new.logSummary)]"
        )
    }

    private func logScroll(_ message: String, force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastScrollLogAt) * 1000 > 650 else { return }
        lastScrollLogAt = now
        VCLog.log(
            "TerminalScroll",
            "\(message) tab=\(tabId.suffix(6)) entries=\(entries.count) tail=\(entries.last?.text.count ?? 0) busy=\(busy) follow=\(followBottom) touch=\(userTouching) userScroll=\(userScrollIntent) focus=\(composerFocused) kb=\(Int(keyboardOverlap)) \(scrollMetrics.logSummary)"
        )
    }

    private func pin(_ proxy: ScrollViewProxy, reason: String) {
        guard followBottom else {
            logScroll("pin skip reason=\(reason)", force: reason != "tail")
            return
        }
        logScroll("pin reason=\(reason)")
        // Pin now + once more after a yield: a row appended in this update isn't
        // measured yet, so the first scrollTo can resolve against stale geometry.
        // The deferred re-pin lands against the materialized row. Both instant
        // (animated scrolls undershoot). followBottom re-checked after the yield.
        proxy.scrollTo("BOTTOM", anchor: .bottom)
        Task { @MainActor in
            await Task.yield()
            guard followBottom else {
                logScroll("pin skip-after-yield reason=\(reason)", force: reason != "tail")
                return
            }
            proxy.scrollTo("BOTTOM", anchor: .bottom)
            logScroll("pin after-yield reason=\(reason)")
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        followBottom = true
        logScroll("manual-bottom", force: true)
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo("BOTTOM", anchor: .bottom)
        }
    }

    @ViewBuilder
    private func terminalComposer(proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 6) {
            ZStack {
                if distFromBottom > 180 {
                    terminalKeyboardActionButton(systemName: "arrow.down.to.line") {
                        scrollToBottom(proxy)
                    }
                    .accessibilityLabel("Scroll to bottom")
                }

                if composerFocused {
                    terminalKeyboardActionButton(systemName: "keyboard.chevron.compact.down") {
                        dismissTerminalKeyboard()
                    }
                    .accessibilityLabel("Hide keyboard")
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(height: 36)
            .padding(.horizontal, 10)
            .opacity((distFromBottom > 180 || composerFocused) ? 1 : 0)
            .allowsHitTesting(distFromBottom > 180 || composerFocused)

            if canResume {
                TerminalResumeBanner(resuming: status == "starting", accent: agentAccent(tab.isCodexPTY ? "codex" : "claude")) {
                    store.resume(tabId: tabId)
                }
            } else if status == "starting" {
                TerminalStartingStrip(accent: agentAccent(tab.isCodexPTY ? "codex" : "claude"))
            } else {
                if let question = store.pendingQuestionByTab[tabId] {
                    TerminalQuestionCard(
                        question: question,
                        answering: store.questionAnsweringTabs.contains(tabId),
                        onAnswer: { answers in store.answerQuestion(tabId: tabId, question: question, answers: answers) },
                        onStop: { store.answerQuestion(tabId: tabId, question: question, stop: true) }
                    )
                    .padding(.horizontal, 10)
                }
                if busy {
                    HStack(spacing: 6) {
                        Text(awaitingInterrupt ? "canceling" : "thinking")
                        ProgressView().controlSize(.mini).tint(Color(hex: "d97706"))
                    }
                    .font(.system(size: chatFont - 3, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                }
                if let draftNotice {
                    Text(draftNotice)
                        .font(.system(size: chatFont - 4, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                }
                VStack(alignment: .leading, spacing: 8) {
                    if !gtAttachments.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(gtAttachments) { att in
                                    ComposerAttachmentChip(
                                        attachment: att,
                                        onPreview: { openGtPreview(att) },
                                        onRemove: { removeGtAttachment(att) }
                                    )
                                }
                            }
                        }
                        .frame(maxHeight: 30)
                    }

                    TextField(tab.isCodexPTY ? "Команда для Codex…" : "Команда для Claude…", text: $input, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .font(.system(size: max(15, chatFont)))
                        .foregroundStyle(.white)
                        .focused($composerFocused)
                        .disabled(!canUseComposer || busy)
                        .frame(minHeight: 32, alignment: .topLeading)

                    HStack(spacing: 6) {
                        TerminalModelMenuChip(tabId: tabId, isCodex: tab.isCodexPTY)
                        TerminalEffortMenuChip(tabId: tabId, isCodex: tab.isCodexPTY)
                        // Think moved to the tab-title long-press menu (the brain
                        // chip ate too much composer width); see the title
                        // .contextMenu below.
                        Button { showVoicePrompts = true } label: {
                            terminalIconButton(active: false) {
                                Image(systemName: "text.quote")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                        }
                        Button { showTerminalPrompts = true } label: {
                            terminalIconButton(active: false) {
                                Image("TerminalIcon")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 18, height: 18)
                            }
                        }
                        Button { showGTPicker = true } label: {
                            terminalIconButton(active: !gtAttachments.isEmpty) {
                                VCGTGlyph(size: 20)
                            }
                        }
                        Spacer(minLength: 0)
                        if busy {
                            Button { store.interrupt(tabId: tabId) } label: {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 38, height: 38)
                                    .background(Circle().fill(Color(hex: "ef4444")))
                            }
                        } else {
                            ComposerSendButton(
                                hasDraft: hasDraft,
                                armed: autoSendArmed,
                                accent: CTViolet,
                                onSend: { if canUseComposer { send() } },
                                onArm: { if canUseComposer { autoSendArmed = true } },
                                onCancelArm: { autoSendArmed = false }
                            )
                            .opacity(canUseComposer ? 1 : 0.5)
                        }
                    }
                }
                .padding(.horizontal, 13)
                .padding(.top, gtAttachments.isEmpty ? 14 : 12)
                .padding(.bottom, 10)
                .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color(white: 0.105)))
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Color.white.opacity(0.18)))
                .padding(.horizontal, 10)
            }
        }
        // Lift the WHOLE dock — composer, Resume banner, Starting strip, question
        // card — above the root glass bar by the same amount. Previously only the
        // composer branch carried this inset, so the Resume banner sat lower and
        // the bar clipped it (user's Image #5: "resume session тоже вылазит").
        // When the keyboard is up the root bar hides and the lift already clears
        // it, so the inset drops to a small constant gap.
        .padding(.bottom, 8 + (composerFocused ? 0 : bottomBarInset))
        .background(LinearGradient(colors: [CTPageBackground.opacity(0), CTPageBackground], startPoint: .top, endPoint: .bottom).allowsHitTesting(false))
    }

    private var hasDraft: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !gtAttachments.isEmpty
    }

    private func terminalIconButton<Content: View>(active: Bool, @ViewBuilder content: () -> Content) -> some View {
        content()
            .foregroundStyle(active ? CTAccent : Color(hex: "c9c9cf"))
            .frame(width: 34, height: 34)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(white: 0.12)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(active ? CTAccent : Color(white: 0.17)))
    }

    private func terminalKeyboardActionButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .frame(width: 36, height: 32)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.18)))
        }
        .buttonStyle(.plain)
    }

    // Compute keyboard overlap against the key window and lift the composer by
    // it. Mirrors the Gemini chat's overlay-keyboard model but kept minimal and
    // self-contained for the terminal chat. Subtract the bottom safe-area inset
    // because the composer already floats above the home indicator via padding.
    private func applyTerminalKeyboard(_ note: Notification, hiding: Bool) {
        if let isLocal = note.userInfo?[UIResponder.keyboardIsLocalUserInfoKey] as? Bool, !isLocal { return }
        var overlap: CGFloat = 0
        if !hiding,
           let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
           let win = UIApplication.vcKeyWindow {
            let inWindow = win.convert(end, from: win.screen.coordinateSpace)
            let inter = win.bounds.intersection(inWindow)
            let raw = inter.isNull ? 0 : inter.height
            let safeBottom = win.safeAreaInsets.bottom
            overlap = max(0, raw - safeBottom)
        }
        // Match the keyboard's own duration/curve (private curve 7 on iOS 26 has
        // no faithful SwiftUI mapping → front-loaded open / easeOut close).
        let rawDur = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let dur = rawDur <= 0.01 ? 0.22 : rawDur
        let curve = note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int ?? -1
        let opening = overlap > 0
        if curve == 7 {
            keyboardLiftAnim = opening
                ? .timingCurve(0.17, 0.84, 0.44, 1.0, duration: min(0.28, max(0.18, dur * 0.70)))
                : .easeOut(duration: dur)
        } else if let c = UIView.AnimationCurve(rawValue: curve) {
            let t = UICubicTimingParameters(animationCurve: c)
            keyboardLiftAnim = .timingCurve(Double(t.controlPoint1.x), Double(t.controlPoint1.y),
                                            Double(t.controlPoint2.x), Double(t.controlPoint2.y), duration: dur)
        } else {
            keyboardLiftAnim = .easeOut(duration: dur)
        }
        if keyboardOverlap != overlap {
            withAnimation(keyboardLiftAnim) { keyboardOverlap = overlap }
            VCLog.log("term-kbd", "overlap=\(Int(overlap)) hiding=\(hiding) curve=\(curve) dur=\(String(format: "%.2f", dur))")
        }
    }

    private func dismissTerminalKeyboard() {
        composerFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func appendPrompt(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let current = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if current == clean || current.contains(clean) { return }
        input = current.isEmpty ? clean : current + "\n\n" + clean
    }

    private func consumePendingDictationInsert() {
        guard let insert = voiceStore.pendingComposerInsert,
              insert.targetKey == voiceComposerKey else { return }
        appendPrompt(insert.text)
        // seq-guarded consume → idempotent against view rebuilds.
        voiceStore.consumeDictationInsert(insert)
        // Armed → auto-submit. Disarm FIRST so a second insert mid-send can't
        // re-fire. Only when the composer is actually usable (not resuming/busy).
        if autoSendArmed && canUseComposer && !busy {
            autoSendArmed = false
            send()
        } else {
            composerFocused = true
        }
    }

    private func send() {
        let typedText = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentAttachments = gtAttachments
        let text = terminalPromptText(typedText: typedText, attachments: sentAttachments)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        input = ""
        gtAttachments = []
        localSending = true
        followBottom = true
        // Scroll-jump-on-send fix (mirror of the Gemini composer): dismissing the
        // keyboard in the SAME runloop as the append collides with the pin and
        // `.defaultScrollAnchor(.bottom)` re-anchor over variable-height rows
        // (FB20979569, iOS-26-only). Defer the keyboard dismiss one runloop so the
        // bottom-pin lands against stable geometry first.
        Task { @MainActor in
            await Task.yield()
            composerFocused = false
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        Task {
            do {
                try await store.send(tabId: tabId, text: text)
                localSending = false
            } catch {
                localSending = false
                if input.isEmpty { input = typedText }
                if gtAttachments.isEmpty { gtAttachments = sentAttachments }
            }
        }
    }

    private func terminalPromptText(typedText: String, attachments: [VCAttachment]) -> String {
        let gtLines = attachments.compactMap { att -> String? in
            guard let path = att.filePath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
            let title = att.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return "- " + (title.isEmpty ? path : title + ": " + path)
        }
        guard !gtLines.isEmpty else { return typedText }

        var parts: [String] = []
        if !typedText.isEmpty { parts.append(typedText) }
        parts.append("Read these GT Editor files before responding:\n" + gtLines.joined(separator: "\n"))
        return parts.joined(separator: "\n\n")
    }

    private func addGtAttachment(_ att: VCAttachment) {
        guard let path = att.filePath, !path.isEmpty else { return }
        if gtAttachments.contains(where: { $0.filePath == path }) { return }
        gtAttachments.append(att)
    }

    private func removeGtAttachment(_ att: VCAttachment) {
        gtAttachments.removeAll { $0.id == att.id }
    }

    private func openGtPreview(_ att: VCAttachment) {
        guard att.kind == "gtfile", att.filePath != nil else { return }
        gtPreviewTarget = GTFilePreviewTarget(attachment: att)
    }
}

private struct TerminalQuestionCard: View {
    let question: CTPendingQuestion
    let answering: Bool
    let onAnswer: ([String: Any]) -> Void
    let onStop: () -> Void

    @State private var selected: [String: Set<String>] = [:]

    private var canAnswer: Bool {
        question.questions.allSatisfy { q in
            guard let options = q.options, !options.isEmpty else { return false }
            return !(selected[q.question] ?? []).isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(hex: "fbbf24"))
                Text("Claude question")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                if answering {
                    ProgressView().controlSize(.mini).tint(.white)
                }
            }

            ForEach(question.questions) { item in
                VStack(alignment: .leading, spacing: 7) {
                    Text(item.question)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)

                    if let options = item.options, !options.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 6)], alignment: .leading, spacing: 6) {
                            ForEach(options) { option in
                                questionOptionButton(item: item, option: option)
                            }
                        }
                    } else {
                        Text("No structured options. Respond manually from the composer.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 8) {
                Button(action: onStop) {
                    Text("Respond manually")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(hex: "fca5a5"))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color(hex: "7f1d1d").opacity(0.24)))
                }
                .buttonStyle(.plain)
                .disabled(answering)

                Spacer()

                Button { onAnswer(answerPayload()) } label: {
                    Text("Answer")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(canAnswer ? CTViolet : Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .disabled(!canAnswer || answering)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(hex: "2a210c").opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color(hex: "f59e0b").opacity(0.32)))
    }

    private func questionOptionButton(item: CTQuestionItem, option: CTQuestionOption) -> some View {
        let isOn = selected[item.question, default: []].contains(option.label)
        return Button {
            toggle(item: item, label: option.label)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12, weight: .semibold))
                Text(option.label)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isOn ? .white : Color(hex: "d4d4d8"))
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isOn ? CTViolet.opacity(0.28) : Color.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(isOn ? CTViolet.opacity(0.65) : Color.white.opacity(0.10)))
        }
        .buttonStyle(.plain)
        .disabled(answering)
    }

    private func toggle(item: CTQuestionItem, label: String) {
        if item.multiSelect == true {
            var current = selected[item.question, default: []]
            if current.contains(label) { current.remove(label) } else { current.insert(label) }
            selected[item.question] = current
        } else {
            selected[item.question] = [label]
        }
    }

    private func answerPayload() -> [String: Any] {
        var out: [String: Any] = [:]
        for item in question.questions {
            let labels = Array(selected[item.question] ?? [])
            if item.multiSelect == true {
                out[item.question] = labels
            } else if let first = labels.first {
                out[item.question] = first
            }
        }
        return out
    }
}

private struct TerminalModelMenuChip: View {
    let tabId: String
    let isCodex: Bool
    private let store = TerminalControlStore.shared   // @Observable singleton (Phase C)
    @State private var applying: String?

    private var params: CTParams {
        store.paramsByTab[tabId] ?? CTParams(tabId: tabId, model: isCodex ? "gpt-5.5" : "default", effort: "high", thinking: "adaptive")
    }
    // Live catalog from `GET /api/agent-models` (codex via `codex debug models`,
    // claude via desktop literal); falls back to static rows offline / old build.
    // `default` is prepended for both agents — our "let the CLI decide" row, not
    // part of the server catalog. The tab's current value is always kept present
    // so a server-hidden model the tab already runs doesn't vanish from the menu.
    private var options: [(String, String)] {
        let catalog = isCodex ? store.modelCatalog?.codex : store.modelCatalog?.claude
        if let catalog, !catalog.isEmpty {
            var values: [(String, String)] = [("default", isCodex ? "default" : "opus")]
            // Claude: drop the explicit `opus` row — `/model default` already IS
            // opus but with the full 1M context window, whereas `/model opus`
            // caps context. One Opus entry only (user request).
            for m in catalog where m.id != "default" && !(!isCodex && m.id == "opus") {
                values.append((m.id, m.label))
            }
            let cur = params.model
            if !cur.isEmpty, !values.contains(where: { $0.0 == cur }) { values.append((cur, cur)) }
            return values
        }
        if isCodex {
            let current = params.model.isEmpty ? "gpt-5.5" : params.model
            var values = [("default", "default"), ("gpt-5.5", "gpt-5.5")]
            if current != "default" && current != "gpt-5.5" { values.append((current, current)) }
            return values
        }
        // Claude fallback: `default` (= opus, 1M ctx) only — no separate `opus`.
        return [("default", "opus"), ("sonnet", "sonnet"), ("haiku", "haiku")]
    }

    // Lock while a turn is running: a live `/model` switch mid-answer is unsafe
    // (fact-codex.md::Модели и effort). No toast — disabled is the affordance.
    private var locked: Bool { applying != nil || store.isTabTurnBusy(tabId) }

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { value, label in
                Button {
                    apply(value)
                } label: {
                    if params.model == value { Label(label, systemImage: "checkmark") } else { Text(label) }
                }
            }
        } label: {
            TerminalParamMenuLabel(text: terminalModelLabel(params.model, isCodex: isCodex), active: false, busy: applying != nil, dimmed: locked)
        }
        .disabled(locked)
    }

    private func apply(_ value: String) {
        applying = value
        Task {
            await store.setParams(tabId: tabId, partial: ["model": value])
            applying = nil
        }
    }
}

private struct TerminalEffortMenuChip: View {
    let tabId: String
    let isCodex: Bool
    private let store = TerminalControlStore.shared   // @Observable singleton (Phase C)
    @State private var applying: String?

    private var params: CTParams {
        store.paramsByTab[tabId] ?? CTParams(tabId: tabId, model: isCodex ? "gpt-5.5" : "default", effort: "high", thinking: "adaptive")
    }
    // Codex models advertise their own reasoning levels (`efforts` per model in
    // the catalog) — use the selected model's list when present; otherwise the
    // static per-agent fallback. Claude rows omit `efforts`, so Claude always
    // uses the literal. Current value kept present so it never disappears.
    private var options: [String] {
        let fallback = isCodex ? ["minimal", "low", "medium", "high", "xhigh"] : ["low", "medium", "high", "xhigh", "max"]
        guard isCodex, let codex = store.modelCatalog?.codex else { return fallback }
        let efforts = codex.first(where: { $0.id == params.model })?.efforts ?? []
        guard !efforts.isEmpty else { return fallback }
        var values = efforts
        if !params.effort.isEmpty, !values.contains(params.effort) { values.append(params.effort) }
        return values
    }

    // Same turn-busy lock as the model chip: effort feeds the same `/model`
    // picker on Codex, unsafe to apply mid-turn.
    private var locked: Bool { applying != nil || store.isTabTurnBusy(tabId) }

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { value in
                Button {
                    apply(value)
                } label: {
                    if params.effort == value { Label(value, systemImage: "checkmark") } else { Text(value) }
                }
            }
        } label: {
            TerminalParamMenuLabel(text: params.effort, active: true, busy: applying != nil, dimmed: locked)
        }
        .disabled(locked)
    }

    private func apply(_ value: String) {
        applying = value
        Task {
            await store.setParams(tabId: tabId, partial: ["effort": value])
            applying = nil
        }
    }
}

// (Think toggle moved to the tab-title long-press context menu — see
// TerminalChatDetailView's title .contextMenu. The composer brain chip was
// removed because it ate too much width.)

private struct TerminalParamMenuLabel: View {
    let text: String
    let active: Bool
    let busy: Bool
    // Explicit disabled affordance: a locked chip dims instead of just going
    // unresponsive (user: "должно писаться явное затемнение"). Leading icon and
    // chevron removed — the menu is obvious on tap, and both ate composer width.
    var dimmed: Bool = false

    var body: some View {
        // The label text always occupies the layout (just hidden while busy), so
        // the chip width is fixed by the model/effort name and never reflows. The
        // spinner is a CENTERED OVERLAY — it adds no width, so switching model
        // can't make the chip grow→shrink→jerk (user: "ширина должна быть
        // фиксирована … недёргалось"). Mirrors desktop busy-overlay scar
        // (fact-claude-control-bar.md::Busy-overlay вместо disabled).
        Text(text)
            .font(.system(size: 12.5, weight: .semibold))
            .lineLimit(1)
            .opacity(busy ? 0 : 1)
            .foregroundStyle(active ? CTViolet : Color(hex: "c9c9cf"))
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(white: 0.12)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(active ? CTViolet : Color(white: 0.17)))
            .overlay {
                if busy {
                    ProgressView().controlSize(.mini).tint(active ? CTViolet : Color(hex: "c9c9cf"))
                }
            }
            .opacity(dimmed ? 0.4 : 1)
    }
}

// Context-fill color, green→red as the window fills (mirrors desktop meter).
// <50% green, <75% yellow, <90% orange, else red.
private func contextPctColor(_ pct: Int) -> Color {
    switch pct {
    case ..<50: return Color(hex: "4ade80")
    case ..<75: return Color(hex: "fcd34d")
    case ..<90: return Color(hex: "fb923c")
    default:    return Color(hex: "f87171")
    }
}

private func terminalModelLabel(_ model: String, isCodex: Bool) -> String {
    if isCodex {
        if model == "default" || model.isEmpty { return "codex" }
        return model.replacingOccurrences(of: "gpt-", with: "g")
    }
    switch model {
    case "default", "opus", "": return "opus"
    case "sonnet": return "sonnet"
    case "haiku": return "haiku"
    default: return model
    }
}

private struct TerminalFloatingControls: View {
    let status: String
    let canQueue: Bool
    let timelineCount: Int?
    let onQueue: () -> Void
    let onTimeline: () -> Void
    let onStopProcess: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onQueue) {
                Image(systemName: "list.bullet.rectangle")
                    .frame(width: 30, height: 30)
            }
            .disabled(!canQueue)
            .opacity(canQueue ? 1 : 0.45)
            if status == "active" || status == "busy" {
                Button(action: onStopProcess) {
                    Image(systemName: "stop.fill")
                        .foregroundStyle(Color(hex: "fca5a5"))
                        .frame(width: 30, height: 30)
                }
            }
            Button(action: onTimeline) {
                HStack(spacing: 5) {
                    Image(systemName: "timeline.selection")
                    if let count = timelineCount, count > 0 {
                        Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 30, minHeight: 30)
            }
        }
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundStyle(.white.opacity(0.86))
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(Capsule(style: .continuous).fill(Color(white: 0.075).opacity(0.94)))
        .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.11)))
        .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
    }
}

// Equatable (Phase D): the transcript ForEach applies `.equatable()` so SwiftUI
// compares (entry, chatFont) and re-renders ONLY the row whose value changed.
// During streaming the reducer republishes the whole array but mutates a single
// tail entry; without this, every row's body re-evaluated each token. The view
// is a pure function of these two inputs, so value-equality is a sound skip test.
private struct TerminalEntryView: View, Equatable {
    let entry: CTEntry
    let chatFont: Double

    nonisolated static func == (lhs: TerminalEntryView, rhs: TerminalEntryView) -> Bool {
        lhs.entry == rhs.entry && lhs.chatFont == rhs.chatFont
    }

    var body: some View {
        // Render-churn probe (Phase D). Counts how many entry-row bodies actually
        // evaluate; spikes here mean .equatable() isn't short-circuiting (e.g. a
        // value that changes every frame leaked into CTEntry). Batched so the log
        // itself never floods. Grep [term-render].
        TerminalRenderProbe.tick(entry.id)
        return bodyContent
    }

    @ViewBuilder
    private var bodyContent: some View {
        switch entry.kind {
        case .user:
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(vcClippedText(entry.text, maxCharacters: 12_000))
                        .font(.system(size: chatFont))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 14).fill(CTAccent.opacity(0.26)))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(CTAccent.opacity(0.42)))
                    if entry.wasQueued {
                        Text("queued")
                            .font(.system(size: chatFont - 5, weight: .semibold))
                            .foregroundStyle(CTViolet)
                    }
                }
            }
        case .assistant:
            if !entry.text.isEmpty {
                VCMarkdownView(messageId: entry.id, markdown: entry.text, fontSize: chatFont, maxCharacters: 16_000)
            }
        case .thinking:
            ThinkingCardView(text: entry.text, chatFont: chatFont)
        case .tool:
            ToolCardView(tool: entry.asToolCall, chatFont: chatFont, defaultOpen: entry.toolResult == nil || entry.toolIsError)
        case .slash:
            HStack {
                Spacer(minLength: 32)
                Text(entry.text)
                    .font(.system(size: chatFont - 2, weight: .semibold, design: .monospaced))
                    .foregroundStyle(CTViolet)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(CTViolet.opacity(0.12)))
                    .overlay(Capsule().stroke(CTViolet.opacity(0.42)))
            }
        case .compactSummary:
            TerminalCompactSummaryView(entry: entry, chatFont: chatFont)
        case .error:
            Text(entry.text)
                .font(.system(size: chatFont - 2))
                .foregroundStyle(Color(hex: "fca5a5"))
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: "7f1d1d").opacity(0.22)))
        }
    }
}

// Batched render-churn probe for the terminal transcript (Phase D). Each row body
// eval calls tick(); we accumulate and flush a compact summary at most ~3x/sec so
// the log never floods. A healthy stream shows tiny counts (1-2 rows/flush — the
// streaming tail + maybe a tool card); a regression shows counts ≈ visible-row
// count every flush (whole ForEach re-rendering). Grep [term-render].
@MainActor
private enum TerminalRenderProbe {
    private static var count = 0
    private static var distinct = Set<String>()
    private static var samples: [String] = []
    private static var burstStart: Date?
    private static var lastTickAt: Date?
    private static let flushInterval: TimeInterval = 0.33
    private static let idleResetInterval: TimeInterval = 1.0

    static func tick(_ id: String) {
        let now = Date()
        if let lastTickAt, now.timeIntervalSince(lastTickAt) > idleResetInterval {
            reset()
        }
        if burstStart == nil { burstStart = now }
        lastTickAt = now
        count += 1
        if distinct.insert(id).inserted, samples.count < 4 {
            samples.append(id)
        }
        guard let burstStart else { return }
        if now.timeIntervalSince(burstStart) >= flushInterval {
            if count > 0 {
                VCLog.log(
                    "term-render",
                    "row bodies=\(count) distinct=\(distinct.count) burstMs=\(Int(now.timeIntervalSince(burstStart) * 1000)) sample=[\(samples.joined(separator: ","))] nav=\(TerminalPerfContext.shared.snapshot())"
                )
            }
            reset()
        }
    }

    private static func reset() {
        count = 0
        distinct.removeAll(keepingCapacity: true)
        samples.removeAll(keepingCapacity: true)
        burstStart = nil
        lastTickAt = nil
    }
}

private struct TerminalCompactSummaryView: View {
    let entry: CTEntry
    let chatFont: Double
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { open.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 12, weight: .semibold))
                    Text("COMPACT SUMMARY")
                        .font(.system(size: chatFont - 2, weight: .heavy))
                    if let metrics = entry.metrics, let pre = metrics.preTokens, let post = metrics.postTokens {
                        Text("\(pre) → \(post)")
                            .font(.system(size: chatFont - 4).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(open ? 0 : -90))
                }
                .foregroundStyle(CTAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            if open {
                Text(vcClippedText(entry.text, maxCharacters: 4_000))
                    .font(.system(size: chatFont - 3))
                    .foregroundStyle(Color(hex: "f4c7b3"))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(CTAccent.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(CTAccent.opacity(0.32)))
    }
}

private struct TerminalEmptyState: View {
    let tab: CTTabInfo
    let chatFont: Double

    var body: some View {
        VStack(spacing: 7) {
            AgentIconView(toolType: tab.isCodexPTY ? "codex" : (tab.isClaudePTY || tab.isSDK ? "claude" : nil), size: 42)
            Text(tab.name)
                .font(.system(size: chatFont + 1, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(tab.isCodexPTY ? "История появится после rollout-событий Codex." : (tab.isClaudePTY ? "История появится после JSONL-событий Claude." : "Отправь сообщение в SDK-чат."))
                .font(.system(size: chatFont - 2))
                .foregroundStyle(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }
}

private struct TerminalResumeBanner: View {
    let resuming: Bool
    let accent: Color
    let onResume: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Button(action: onResume) {
                HStack(spacing: 8) {
                    if resuming { ProgressView().controlSize(.small).tint(accent) }
                    Image(systemName: "play.fill")
                    Text(resuming ? "RESUMING…" : "Resume session")
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(resuming ? accent : Color(white: 0.08))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 14).fill(resuming ? accent.opacity(0.12) : Color.white))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(accent.opacity(0.34)))
            }
            .buttonStyle(.plain)
            Text(resuming ? "launching CLI · waiting for input prompt" : "session stopped · history preserved")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .background(CTPageBackground)
    }
}

private struct TerminalStartingStrip: View {
    let accent: Color

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(accent)
            Text("Starting session…")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(accent.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(accent.opacity(0.24)))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
}

private struct TerminalParamsChip: View {
    let params: CTParams?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "cpu").font(.system(size: 11))
            Text(modelLabel)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
            Text("·").foregroundStyle(.secondary)
            Text(effortLabel)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(params?.thinking == "disabled" ? .secondary : CTViolet)
        }
        .foregroundStyle(Color(hex: "c9c9cf"))
        .padding(.horizontal, 9)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(white: 0.12)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color(white: 0.17)))
    }

    private var modelLabel: String {
        switch params?.model {
        case "default": return "opus"
        case "opus": return "opus"
        case "sonnet": return "sonnet"
        case "haiku": return "haiku"
        case .some(let v): return v
        case nil: return "model"
        }
    }

    private var effortLabel: String {
        if params?.thinking == "disabled" { return "off" }
        return params?.effort ?? "?"
    }
}

private struct TerminalParamsSheet: View {
    let tabId: String
    private let store = TerminalControlStore.shared   // @Observable singleton (Phase C)
    @Environment(\.dismiss) private var dismiss
    @State private var busyKey: String?

    private var params: CTParams {
        store.paramsByTab[tabId] ?? CTParams(tabId: tabId, model: "default", effort: "high", thinking: "adaptive")
    }
    private var isCodex: Bool {
        store.selectedTab?.tabId == tabId && store.selectedTab?.isCodexPTY == true
    }
    private var modelOptions: [(String, String)] {
        if isCodex {
            let current = params.model.isEmpty ? "gpt-5.5" : params.model
            var values = [("default", "default"), ("gpt-5.5", "gpt-5.5")]
            if current != "default" && current != "gpt-5.5" { values.append((current, current)) }
            return values
        }
        return [("default", "default · opus-4.8 [1M]"), ("opus", "opus-4.8 [1M]"), ("sonnet", "sonnet-4.6"), ("haiku", "haiku-4.5")]
    }
    private var effortOptions: [String] {
        isCodex ? ["minimal", "low", "medium", "high", "xhigh"] : ["low", "medium", "high", "xhigh", "max"]
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color(white: 0.28)).frame(width: 36, height: 4).padding(.top, 8).padding(.bottom, 14)
            paramsRow("Model") {
                ForEach(modelOptions, id: \.0) { value, label in
                    paramPill(label: label, active: params.model == value, key: "model:" + value) {
                        await apply(key: "model:" + value, body: ["model": value])
                    }
                }
            }
            paramsRow("Effort") {
                ForEach(effortOptions, id: \.self) { value in
                    paramPill(label: value, active: params.effort == value, key: "effort:" + value) {
                        await apply(key: "effort:" + value, body: ["effort": value])
                    }
                }
            }
            if !isCodex {
                paramsRow("Thinking") {
                    let next = params.thinking == "adaptive" ? "disabled" : "adaptive"
                    paramPill(label: params.thinking == "adaptive" ? "Think ON" : "Think OFF", active: params.thinking == "adaptive", key: "think") {
                        await apply(key: "think", body: ["thinking": next])
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .background(Color(white: 0.04).ignoresSafeArea())
        .task { await store.refreshParams(tabId: tabId) }
    }

    private func paramsRow<Content: View>(_ title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            FlowLikeRow { content() }
        }
        .padding(.bottom, 16)
    }

    private func paramPill(label: String, active: Bool, key: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 6) {
                if busyKey == key { ProgressView().controlSize(.mini).tint(active ? .black : CTViolet) }
                Text(label).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(active ? Color(white: 0.08) : Color(hex: "d4d4d8"))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(active ? CTViolet : Color.white.opacity(0.08)))
            .overlay(Capsule().stroke(active ? CTViolet.opacity(0.1) : Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .disabled(busyKey != nil)
    }

    private func apply(key: String, body: [String: Any]) async {
        guard busyKey == nil else { return }
        busyKey = key
        await store.setParams(tabId: tabId, partial: body)
        busyKey = nil
        dismiss()
    }
}

private struct FlowLikeRow<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) { content() }
                .padding(.vertical, 1)
        }
    }
}

private struct TerminalQueueSheet: View {
    let tabId: String
    private let store = TerminalControlStore.shared   // @Observable singleton (Phase C)
    @State private var newPrompt = ""

    private var queue: CTQueueCore? { store.queueByTab[tabId] }

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color(white: 0.28)).frame(width: 36, height: 4).padding(.top, 8).padding(.bottom, 12)
            HStack {
                Text("Run after")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                if let count = queue?.items.count {
                    Text("[\(count)]").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if let queue {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            queueToggle("Run", on: queue.autoRun, color: CTViolet) {
                                await store.mutateQueue(tabId: tabId, op: "setAutoRun", args: ["value": !queue.autoRun])
                            }
                            queueToggle("Stop", on: queue.stopAfter, color: CTAccent) {
                                await store.mutateQueue(tabId: tabId, op: "setStopAfter", args: ["value": !queue.stopAfter])
                            }
                            queueToggle("Close", on: queue.closeAfter, color: Color(hex: "ef4444")) {
                                await store.mutateQueue(tabId: tabId, op: "setCloseAfter", args: ["value": !queue.closeAfter])
                            }
                        }
                        if queue.items.isEmpty {
                            Text("queue is empty")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 28)
                        } else {
                            ForEach(queue.items) { item in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title?.isEmpty == false ? item.title! : "Prompt")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(.white)
                                    Text(item.text)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
                VStack(spacing: 8) {
                    TextField("Add prompt…", text: $newPrompt, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
                    HStack {
                        Button("Clear") { Task { await store.mutateQueue(tabId: tabId, op: "clear") } }
                            .tint(.secondary)
                        Spacer()
                        Button("Add") {
                            let text = newPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { return }
                            newPrompt = ""
                            Task { await store.mutateQueue(tabId: tabId, op: "add", args: ["text": text]) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(CTViolet)
                    }
                }
                .padding(16)
            } else {
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("Загрузка очереди…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(white: 0.04).ignoresSafeArea())
        .task { await store.refreshQueue(tabId: tabId) }
    }

    private func queueToggle(_ label: String, on: Bool, color: Color, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            HStack(spacing: 6) {
                Circle().fill(on ? color : Color(white: 0.35)).frame(width: 7, height: 7)
                Text(label).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(on ? color : .secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(on ? color.opacity(0.12) : Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }
}

private struct TerminalTimelineSheet: View {
    let tabId: String
    private let store = TerminalControlStore.shared   // @Observable singleton (Phase C)

    private var entries: [CTTimelineEntry]? { store.timelineByTab[tabId] }
    private var loading: Bool { store.timelineLoading.contains(tabId) }
    private var error: String? { store.timelineErrorByTab[tabId] }

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color(white: 0.28)).frame(width: 36, height: 4).padding(.top, 8).padding(.bottom, 12)
            HStack {
                Text("Timeline")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Button { Task { await store.refreshTimeline(tabId: tabId) } } label: {
                    Group {
                        if loading {
                            ProgressView().controlSize(.mini).tint(.white)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14, weight: .semibold))
                        }
                    }
                    .foregroundStyle(.white.opacity(0.82))
                    .frame(width: 34, height: 32)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .disabled(loading)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            if let entries, !entries.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if let error {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(Color(hex: "fca5a5"))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: "7f1d1d").opacity(0.22)))
                        }
                        ForEach(entries) { e in
                            TerminalTimelineEntryRow(entry: e)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 18)
                }
            } else if loading {
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("Loading timeline…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                VStack(spacing: 10) {
                    Text("Timeline unavailable")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.86))
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Button { Task { await store.refreshTimeline(tabId: tabId) } } label: {
                        Text("Retry")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color.white.opacity(0.10)))
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if entries?.isEmpty == true {
                    VStack(spacing: 8) {
                        Text("Timeline empty")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 8) {
                        Text("Timeline not loaded")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color(white: 0.04).ignoresSafeArea())
        .task { await store.refreshTimeline(tabId: tabId) }
    }
}

private struct TerminalTimelineEntryRow: View {
    let entry: CTTimelineEntry
    @State private var expanded = false

    private var isCompact: Bool { entry.kind == "compact" }
    private var fullText: String {
        (entry.full ?? entry.preview).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var canExpand: Bool {
        let preview = entry.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        return fullText.count > preview.count + 8
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if isCompact {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color(hex: entry.color ?? "f59e0b"))
                        .frame(width: 13, height: 4)
                } else {
                    Circle().fill(Color(hex: entry.color ?? "888888")).frame(width: 7, height: 7)
                }
                Text(label)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isCompact ? Color(hex: "fbbf24") : .secondary)
                if let preTokens = entry.preTokens, preTokens > 0 {
                    Text("\(max(1, Int(ceil(Double(preTokens) / 1000.0))))k")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text(expanded ? fullText : entry.preview)
                .font(.callout)
                .foregroundStyle(.white)
                .lineLimit(expanded ? nil : (isCompact ? 3 : 4))
                .textSelection(.enabled)

            if canExpand {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() }
                } label: {
                    Text(expanded ? "Show less" : "Show full")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(hex: "c4b5fd"))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 11).fill(isCompact ? Color(hex: "3a2a0a").opacity(0.34) : Color.white.opacity(0.065)))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(isCompact ? Color(hex: "f59e0b").opacity(0.22) : Color.white.opacity(0.08)))
    }

    private var label: String {
        switch entry.kind {
        case "compact": return "COMPACT"
        case "continued": return "CONTINUED"
        case "docs_edit": return "DOCS"
        case "docs_search": return "DOCS SEARCH"
        default: return entry.kind.uppercased()
        }
    }
}

private struct TerminalPromptPicker: View {
    let onPick: (String) -> Void
    @State private var response: CTPromptsResponse?
    @State private var expandedGroup: Int?
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        promptPickerShell(title: "Terminal prompts", loading: loading, error: error, retry: { Task { await load() } }) {
            List {
                let groups = (response?.groups ?? []).sorted { ($0.position ?? 0) < ($1.position ?? 0) }
                let prompts = (response?.prompts ?? []).sorted { ($0.position ?? 0) < ($1.position ?? 0) }
                let ungrouped = prompts.filter { $0.group_id == nil }
                ForEach(groups) { group in
                    Button { expandedGroup = expandedGroup == group.id ? nil : group.id } label: {
                        HStack {
                            Text(group.name).foregroundStyle(.white)
                            Spacer()
                            Image(systemName: expandedGroup == group.id ? "chevron.down" : "chevron.right").foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(Color(white: 0.12))
                    if expandedGroup == group.id {
                        ForEach(prompts.filter { $0.group_id == group.id }) { prompt in
                            promptRow(prompt)
                                .padding(.leading, 12)
                        }
                    }
                }
                ForEach(ungrouped) { prompt in promptRow(prompt) }
            }
            .scrollContentBackground(.hidden)
            .background(Color(white: 0.04))
        }
        .task { await load() }
    }

    private func promptRow(_ prompt: CTPrompt) -> some View {
        Button { onPick(prompt.content) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(prompt.title.isEmpty ? "Prompt" : prompt.title)
                    .foregroundStyle(.white)
                    .font(.body.weight(.medium))
                if !prompt.content.isEmpty {
                    Text(prompt.content)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .lineLimit(2)
                }
            }
        }
        .listRowBackground(Color(white: 0.10))
    }

    private func load() async {
        loading = true; error = nil
        do {
            response = try await TerminalAPI.prompts()
            loading = false
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            loading = false
        }
    }
}

private struct TerminalVoicePromptLibrary: Decodable {
    var groups: [TerminalVoicePromptGroup]?
    var prompts: [TerminalVoicePrompt]?
}

private struct TerminalVoicePromptGroup: Identifiable, Decodable {
    let id: String
    let name: String
    var position: Int?
}

private struct TerminalVoiceInstruction: Decodable {
    var content: String?
}

private struct TerminalVoiceVariation: Identifiable, Decodable {
    let id: String
    let title: String
    var description: String?
    var instructions: [TerminalVoiceInstruction]?
}

private struct TerminalVoicePrompt: Identifiable, Decodable {
    let id: String
    let title: String
    var description: String?
    var groupId: String?
    var position: Int?
    var instructions: [TerminalVoiceInstruction]?
    var variations: [TerminalVoiceVariation]?

    func resolvedText(variation: TerminalVoiceVariation? = nil) -> String {
        var parts = (instructions ?? []).compactMap { $0.content?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if let variation {
            parts.append(contentsOf: (variation.instructions ?? []).compactMap { $0.content?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        }
        return parts.joined(separator: "\n\n")
    }
}

private struct TerminalVoicePromptPicker: View {
    let onPick: (String) -> Void
    @State private var library: TerminalVoicePromptLibrary?
    @State private var expandedPrompt: String?
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        promptPickerShell(title: "Voice prompts", loading: loading, error: error, retry: { Task { await load() } }) {
            List {
                ForEach((library?.prompts ?? []).sorted { ($0.position ?? 0) < ($1.position ?? 0) }) { prompt in
                    let vars = prompt.variations ?? []
                    Button {
                        if vars.isEmpty {
                            onPick(prompt.resolvedText())
                        } else {
                            expandedPrompt = expandedPrompt == prompt.id ? nil : prompt.id
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(prompt.title.isEmpty ? "Prompt" : prompt.title).foregroundStyle(.white).font(.body.weight(.medium))
                                if let d = prompt.description, !d.isEmpty {
                                    Text(d).foregroundStyle(.secondary).font(.caption)
                                }
                            }
                            Spacer()
                            if !vars.isEmpty {
                                Image(systemName: expandedPrompt == prompt.id ? "chevron.down" : "chevron.right").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listRowBackground(Color(white: 0.12))
                    if expandedPrompt == prompt.id {
                        Button { onPick(prompt.resolvedText()) } label: {
                            Text("Базовый").foregroundStyle(.secondary)
                        }
                        .listRowBackground(Color(white: 0.09))
                        .padding(.leading, 12)
                        ForEach(vars) { variation in
                            Button { onPick(prompt.resolvedText(variation: variation)) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(variation.title.isEmpty ? "Вариант" : variation.title).foregroundStyle(.white)
                                    if let d = variation.description, !d.isEmpty {
                                        Text(d).foregroundStyle(.secondary).font(.caption)
                                    }
                                }
                            }
                            .listRowBackground(Color(white: 0.09))
                            .padding(.leading, 12)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(white: 0.04))
        }
        .task { await load() }
    }

    private func load() async {
        loading = true; error = nil
        do {
            library = try await VoiceChatAPI.getJSON("/api/prompts")
            loading = false
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            loading = false
        }
    }
}

private func promptPickerShell<Content: View>(title: String, loading: Bool, error: String?, retry: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
    VStack(spacing: 0) {
        Capsule().fill(Color(white: 0.28)).frame(width: 36, height: 4).padding(.top, 8).padding(.bottom, 10)
        HStack {
            Text(title).font(.headline).foregroundStyle(.white)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        if loading {
            VStack(spacing: 12) {
                ProgressView().tint(.white)
                Text("Загрузка промптов…").foregroundStyle(.secondary).font(.caption)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            VStack(spacing: 12) {
                Text("Не удалось загрузить промпты").foregroundStyle(.white)
                Text(error).foregroundStyle(.secondary).font(.caption).multilineTextAlignment(.center)
                Button("Повторить", action: retry).tint(Color(hex: "8AB4F8"))
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content()
        }
    }
    .background(Color(white: 0.04).ignoresSafeArea())
}

private struct TerminalOfflineView: View {
    let message: String?
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.5))
            Text("custom-terminal недоступен")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text(message ?? "Mac не отвечает или Remote endpoint недоступен.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Button(action: retry) {
                Label("Повторить", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(hex: "8AB4F8"))
            .padding(.horizontal, 48)
        }
    }
}

// Shared rename bottom-sheet for terminal tabs and projects. Mirrors the
// Gemini-chat rename sheet (`VoiceChatTitleEditorSheet`) the user named as the
// reference: NavigationStack + Form, Cancel left / Save right, partial-height
// detents, autofocused field. `title`/`label` let one sheet serve both surfaces.
struct CTRenameSheet: View {
    let title: String          // nav title, e.g. "Rename tab" / "Rename project"
    let label: String          // field placeholder
    let initialName: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @FocusState private var focused: Bool

    init(title: String, label: String, initialName: String, onSave: @escaping (String) -> Void) {
        self.title = title
        self.label = label
        self.initialName = initialName
        self.onSave = onSave
        _name = State(initialValue: initialName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(label, text: $name, axis: .vertical)
                        .focused($focused)
                        .lineLimit(1...3)
                        .submitLabel(.done)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { onSave(trimmed) }
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.height(220), .medium])
        .presentationDragIndicator(.visible)
    }
}
