import SwiftUI

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

struct RootTabView: View {
    @EnvironmentObject var recorder: RecordingCoordinator
    @EnvironmentObject var router: TabRouter

    var body: some View {
        TabView(selection: $router.selected) {
            // AI Chat — first tab (before Voice). A full tab (not a fullscreen
            // cover) so the footer menu stays visible and back-navigation works.
            VoiceChatTabView()
                .tabItem { Label("AI Chat", systemImage: "bubble.left.and.bubble.right") }
                .tag(TabRouter.Tab.chat)

            VoiceRecordTabView()
                .tabItem {
                    // Only DICTATION drives the tab's REC state — a long capture
                    // is self-contained inside its panel icon and must not light
                    // up the footer tab (separation of concerns). recorder.isRecording
                    // is now the dictation slot only, so it gates this directly.
                    Label("Voice",
                          systemImage: recorder.isRecording ? "mic.fill" : "mic")
                }
                .badge(recorder.isRecording ? "REC" : nil)
                .tag(TabRouter.Tab.voice)

            ContentView()
                .tabItem { Label("Habits", systemImage: "checklist") }
                .tag(TabRouter.Tab.habits)
        }
        .tint(.white)
        .background(Color(white: 0.055).ignoresSafeArea())
        .toolbarBackground(Color(white: 0.055), for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        // Chat-creation progress/error presented at the ROOT so it survives the
        // Voice→AI Chat tab switch the "Chat" button triggers (an alert bound to
        // the Voice tab would vanish with it).
        .overlay(alignment: .top) {
            if router.chatCreating {
                HStack(spacing: 8) { ProgressView().tint(.white); Text("Создаю чат…").foregroundStyle(.secondary).font(.caption) }
                    .padding(10).background(.ultraThinMaterial).clipShape(Capsule()).padding(.top, 8)
            }
        }
        .alert("Не удалось создать чат", isPresented: Binding(get: { router.chatCreateError != nil }, set: { if !$0 { router.chatCreateError = nil } })) {
            Button("OK", role: .cancel) { router.chatCreateError = nil }
        } message: { Text(router.chatCreateError ?? "") }
    }
}
