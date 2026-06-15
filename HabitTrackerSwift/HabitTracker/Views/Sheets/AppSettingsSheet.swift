import SwiftUI

// Unified settings, presented full-screen over the whole app (fullScreenCover at
// the root — not a per-tab sheet). One NavigationStack hosts a segmented control
// (AI Chat · Voice · Habits) plus a horizontal paging ScrollView so the three
// section bodies can be swiped left/right exactly like the root tab pager.
//
// Why a custom paging ScrollView and not a TabView(.page): mirrors the root
// shell's choice (`fact-voice-chat-tab.md::Свайп root-вкладок`) — paging +
// `scrollPosition(id:)` + `containerRelativeFrame`, the only combo that animates
// like a book between sibling pages. No conflict with the root pager / history
// drawer here: this lives INSIDE a fullScreenCover, which sits above the root
// shell, so there's no competing horizontal pan recognizer on this surface.
//
// Section memory: the visible segment is `router.settingsSection`, which the
// router re-seeds to the current tab on every root-tab change and otherwise
// leaves alone — so the swipe/segment choice persists across open/close while the
// user stays on one tab, but re-defaults to the entered-from tab after a tab
// switch. (Logic in TabRouter.selected.didSet.)
struct AppSettingsSheet: View {
    @EnvironmentObject var router: TabRouter
    @Environment(\.dismiss) private var dismiss

    // Drives the paging ScrollView; kept in sync with router.settingsSection both
    // ways (segment tap / programmatic → scroll; swipe-settle → segment + router).
    @State private var scrollIndex: Int?

    private let sections = TabRouter.Tab.allCases   // chat · voice · habits

    private func title(_ t: TabRouter.Tab) -> String {
        switch t {
        case .chat:   return "AI Chat"
        case .voice:  return "Voice"
        case .habits: return "Habits"
        }
    }

    private var selection: Binding<TabRouter.Tab> {
        Binding(
            get: { router.settingsSection },
            set: { router.settingsSection = $0 }
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Settings section", selection: selection) {
                    ForEach(sections, id: \.self) { t in
                        Text(title(t)).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 10)

                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(Array(sections.enumerated()), id: \.offset) { idx, t in
                            sectionBody(t)
                                .containerRelativeFrame(.horizontal)
                                .id(idx)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $scrollIndex, anchor: .center)
                .scrollIndicators(.hidden)
                .ignoresSafeArea(.container, edges: .horizontal)
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // Land the pager on the seeded section without animation.
            scrollIndex = sections.firstIndex(of: router.settingsSection) ?? 0
        }
        // Segment tap / programmatic change → animate the pager to it.
        .onChange(of: router.settingsSection) { _, t in
            let target = sections.firstIndex(of: t) ?? 0
            if scrollIndex != target {
                withAnimation(.easeInOut(duration: 0.22)) { scrollIndex = target }
            }
        }
        // Swipe-settle → reflect back into the segment + router.
        .onChange(of: scrollIndex) { _, idx in
            guard let idx, let t = sections[safe: idx], router.settingsSection != t else { return }
            router.settingsSection = t
        }
    }

    @ViewBuilder
    private func sectionBody(_ t: TabRouter.Tab) -> some View {
        switch t {
        case .chat:   VoiceChatSettingsBody()
        case .voice:  VoiceSettingsBody()
        case .habits: HabitsSettingsBody()
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
