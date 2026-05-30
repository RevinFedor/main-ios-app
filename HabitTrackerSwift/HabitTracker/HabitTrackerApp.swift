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
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        router.consumeVoiceTabFlagIfSet()
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
            VoiceRecordTabView()
                .tabItem {
                    Label("Voice", systemImage: recorder.isRecording ? "mic.fill" : "mic")
                }
                .badge(recorder.isRecording ? "REC" : nil)
                .tag(TabRouter.Tab.voice)

            ContentView()
                .tabItem { Label("Habits", systemImage: "checklist") }
                .tag(TabRouter.Tab.habits)
        }
        .tint(.white)
    }
}
