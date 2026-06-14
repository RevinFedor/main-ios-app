# Research Prompt: Native iOS / SwiftUI Side History Drawer Gestures

Date: June 11, 2026

I need a deep, up-to-date research answer for an iOS 26 SwiftUI app. Please use current Apple documentation, WWDC sessions, Human Interface Guidelines, relevant UIKit/SwiftUI API references, and reputable implementation examples. Do not give generic advice. I need a production-grade diagnosis and implementation plan.

## App Context

This is a native iOS app written in SwiftUI. It has an AI Chat tab. The chat and its history are inside the same tab. The design goal is similar to a modern AI chat app:

- Main chat is visible by default.
- Swiping right from the chat should open a left-side history drawer.
- When the drawer is open, the history drawer is visible on the left, and about 10% of the chat remains visible on the right.
- Swiping left should close the drawer.
- The gesture should feel native and forgiving. It should not require a perfectly horizontal line.
- Vertical scrolling inside chat and history must still work naturally.
- Row taps, long-press context menus, and search should keep working.
- We removed horizontal swipe-to-delete on history cards, so the drawer can own horizontal swipes.
- Current implementation feels bad: sometimes the drawer does not move, sometimes vertical ScrollView seems to steal the gesture, sometimes it only works if the swipe is extremely straight.

Target/device details:

- SwiftUI app, iOS deployment target 18.0.
- Current device is iPhone 15 Pro on iOS 26.5.
- Built with Xcode/iOS SDK 26.4.
- The AI Chat UI uses `NavigationStack`, `ScrollView`, `LazyVStack`, custom SwiftUI drawer, and a UIKit `UIPanGestureRecognizer` bridge.

## What I Need From You

Please research and answer:

1. What is the most native Apple-approved architecture for this pattern in 2026?
   - Should this be a custom drawer at all?
   - Should it use `NavigationSplitView`, a system sidebar, a sheet, a navigation transition, or a custom overlay?
   - How do Apple apps and current iOS 26 design guidance expect side/history panels to behave on iPhone?

2. If a custom drawer is acceptable, what is the correct gesture architecture?
   - SwiftUI `DragGesture` vs UIKit `UIPanGestureRecognizer`.
   - `UIScreenEdgePanGestureRecognizer` vs full-screen pan.
   - `gesture`, `highPriorityGesture`, `simultaneousGesture`, `exclusively`, gesture masks, and how they interact with SwiftUI `ScrollView`.
   - Whether the gesture should be attached to the root, an overlay, the drawer, the chat content, or a transparent hit-test layer.
   - Whether different gestures should be used when closed vs open:
     - closed: edge pan or rightward pan from chat
     - open: full drawer/chat-overlay pan left to close

3. How to correctly arbitrate horizontal drawer drag against vertical `ScrollView` pan.
   - Best angle/velocity thresholds for forgiving horizontal intent.
   - Direction lock / hysteresis pattern: do not decide too late, do not require perfect horizontal movement.
   - How to avoid the vertical scroll recognizer winning too often.
   - Whether to disable scrolling while the horizontal drawer gesture is active.
   - How to use `gestureRecognizerShouldBegin`, `shouldRecognizeSimultaneouslyWith`, `canPrevent`, `canBePrevented`, `require(toFail:)`, or `scrollView.panGestureRecognizer` relationships.
   - Whether `cancelsTouchesInView = false` is helping or hurting.

4. What exact implementation should replace the current code?
   - Provide SwiftUI code and, if needed, UIKit bridge code.
   - Include a robust state machine: closed, dragging open, open, dragging closed, settling.
   - Include velocity projection and thresholds that feel native.
   - Include rubber-banding / clamping behavior if appropriate.
   - Include animation recommendations: spring parameters, interruptible behavior, preserving drag continuity.
   - Include accessibility considerations.

5. What should be tested manually on device?
   - Swipe right from chat body.
   - Swipe right from near left edge.
   - Swipe left from open drawer.
   - Swipe left from the 10% visible chat sliver.
   - Vertical scroll in chat when drawer closed.
   - Vertical scroll in history when drawer open.
   - Diagonal swipes.
   - Long-press on rows.
   - Search field active / keyboard open.
   - Bottom tab bar present.

Please include:

- A concise diagnosis of why the current implementation feels unstable.
- The recommended architecture.
- A drop-in or near drop-in code example.
- Tradeoffs and failure modes.
- Links/citations to the Apple docs, WWDC sessions, HIG, or reputable sources used.

## Current Code

The current implementation is below. Please analyze it directly and point out what is wrong or fragile.

```swift
private struct DrawerPanGestureBridge: UIViewRepresentable {
    let drawerWidth: CGFloat
    let isOpen: Bool
    let onChanged: (CGFloat) -> Void
    let onEnded: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.drawerWidth = drawerWidth
        context.coordinator.isOpen = isOpen
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded

        DispatchQueue.main.async {
            if let host = uiView.superview {
                context.coordinator.attach(to: host)
            }
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var drawerWidth: CGFloat = 0
        var isOpen = false
        var onChanged: ((CGFloat) -> Void)?
        var onEnded: ((Bool) -> Void)?

        private weak var attachedView: UIView?
        private var pan: UIPanGestureRecognizer?
        private var gestureStartedOpen = false

        func attach(to view: UIView) {
            guard attachedView !== view else { return }
            detach()

            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            recognizer.delegate = self
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            view.addGestureRecognizer(recognizer)
            attachedView = view
            pan = recognizer
        }

        func detach() {
            if let pan, let attachedView {
                attachedView.removeGestureRecognizer(pan)
            }
            self.pan = nil
            self.attachedView = nil
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard drawerWidth > 0, let view = recognizer.view else { return }
            switch recognizer.state {
            case .began:
                gestureStartedOpen = isOpen
            case .changed:
                let translation = recognizer.translation(in: view).x
                let base = gestureStartedOpen ? drawerWidth : 0
                let clamped = min(drawerWidth, max(0, base + translation))
                onChanged?(clamped - base)
            case .ended, .cancelled, .failed:
                let translation = recognizer.translation(in: view).x
                let velocity = recognizer.velocity(in: view).x
                let base = gestureStartedOpen ? drawerWidth : 0
                let current = min(drawerWidth, max(0, base + translation))
                let projected = current + velocity * 0.16
                let shouldOpen: Bool
                if abs(velocity) > 320 {
                    shouldOpen = velocity > 0
                } else {
                    shouldOpen = projected > drawerWidth * 0.46
                }
                onEnded?(shouldOpen)
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = gestureRecognizer.view else { return true }
            let velocity = pan.velocity(in: view)
            guard abs(velocity.x) > 70, abs(velocity.x) > abs(velocity.y) * 1.15 else { return false }
            if isOpen { return true }
            return velocity.x > 0
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
```

Root layout:

```swift
struct VoiceChatTabView: View {
    @State private var historyOpen = false
    @State private var historyDragX: CGFloat = 0
    @State private var showingAllChats = false

    var body: some View {
        GeometryReader { geo in
            let drawerWidth = max(280, geo.size.width * 0.9)
            let x = drawerOffset(drawerWidth: drawerWidth)
            let progress = drawerWidth == 0 ? 0 : x / drawerWidth

            ZStack(alignment: .leading) {
                VCPageBackground.ignoresSafeArea()

                NavigationStack {
                    Group {
                        if showingAllChats {
                            AllChatsView(...)
                        } else {
                            ChatDetailView(...)
                                .id(chatIdentity)
                        }
                    }
                }
                .offset(x: x)
                .background(VCPageBackground.ignoresSafeArea())
                .overlay {
                    if progress > 0 {
                        Color.black.opacity(0.2 * progress)
                            .ignoresSafeArea()
                            .onTapGesture { closeHistory() }
                    }
                }

                historyDrawer(width: drawerWidth)
                    .frame(width: drawerWidth)
                    .offset(x: -drawerWidth + x)
            }
            .clipped()
            .contentShape(Rectangle())
            .background(
                DrawerPanGestureBridge(
                    drawerWidth: drawerWidth,
                    isOpen: historyOpen,
                    onChanged: { dragX in historyDragX = dragX },
                    onEnded: { shouldOpen in
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            historyOpen = shouldOpen
                            historyDragX = 0
                        }
                    }
                )
            )
        }
    }

    private func drawerOffset(drawerWidth: CGFloat) -> CGFloat {
        let base = historyOpen ? drawerWidth : 0
        return min(drawerWidth, max(0, base + historyDragX))
    }

    private func openHistory() {
        Task { await store.refreshChats() }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            historyOpen = true
            historyDragX = 0
        }
    }

    private func closeHistory() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            historyOpen = false
            historyDragX = 0
        }
    }
}
```

Drawer content:

```swift
private func historyDrawer(width: CGFloat) -> some View {
    VStack(spacing: 0) {
        HStack(spacing: 10) {
            Text("AI Chat")
            Spacer()
            drawerSettingsButton { showSettings = true }
        }

        ScrollView {
            LazyVStack(spacing: 8) {
                sidebarActionRow(title: "Chats", ...)
                Text("Recent")

                ForEach(Array(store.chats.prefix(14))) { chat in
                    VCChatListRow(...)
                }

                sidebarActionRow(title: "All chats", ...)
            }
            .padding(.bottom, 20)
        }
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
    }
    .background(VCPageBackground.ignoresSafeArea())
    .overlay(alignment: .bottomTrailing) {
        floatingNewChatButton(action: startNewChat)
            .padding(.trailing, 14)
            .padding(.bottom, 16)
    }
}
```

The chat content itself also contains a vertical `ScrollView` with messages and a composer in `safeAreaInset(edge: .bottom)`. The full history page contains another vertical `ScrollView` and `.searchable`.

## Suspected Problems

These are guesses, not conclusions. Please verify or reject them:

- The pan recognizer is attached indirectly to `uiView.superview` from a background representable, which may be fragile in SwiftUI hierarchy updates.
- The representable view itself has `isUserInteractionEnabled = false`, so the actual recognizer is installed on a host view we do not fully control.
- The recognizer begins only when `abs(x) > 70` and `abs(x) > abs(y) * 1.15`. This may be too strict and velocity-based at begin time may be unreliable for slow drags.
- Returning `true` from `shouldRecognizeSimultaneouslyWith` may allow vertical ScrollView and horizontal drawer to both update, producing inconsistent results.
- Current code has no explicit gesture state after horizontal intent is locked.
- Current code has no relationship with nested `UIScrollView.panGestureRecognizer`.
- It treats open and closed states almost the same, but the desired hit testing is different.
- The overlay used for dimming and tap-to-close may affect hit testing during open/partial states.
- `historyDragX` stores a delta from base rather than an absolute progress state, which may be fine but could be fragile if state changes during a gesture.

## Desired Output Format

Please structure your answer like this:

1. Executive recommendation
2. Native Apple pattern analysis
3. Diagnosis of the current code
4. Recommended implementation
5. Full Swift code example
6. Tuning values and why
7. Gesture conflict table
8. Manual QA checklist
9. Sources

Please be concrete. I need enough detail to implement the fix in a real app.
