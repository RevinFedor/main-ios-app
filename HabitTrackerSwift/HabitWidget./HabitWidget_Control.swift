import AppIntents
import SwiftUI
import WidgetKit

struct HabitWidget_Control: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: "com.fedor277.habittracker.control"
        ) {
            ControlWidgetButton(action: OpenHabitTrackerIntent()) {
                Label("Добавить", systemImage: "plus.circle.fill")
            }
        }
        .displayName("Habit Tracker")
        .description("Открыть трекер привычек")
    }
}

struct OpenHabitTrackerIntent: AppIntent, OpenIntent {
    static var title: LocalizedStringResource = "Open Habit Tracker"
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Target")
    var target: HabitTrackerTarget

    init() { self.target = .habits }
    init(target: HabitTrackerTarget) { self.target = target }

    func perform() async throws -> some IntentResult & OpensIntent {
        return .result(opensIntent: OpenURLIntent(target.url))
    }
}

enum HabitTrackerTarget: String, AppEnum {
    case habits
    case voice

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Habit Tracker Tab"
    static var caseDisplayRepresentations: [HabitTrackerTarget: DisplayRepresentation] = [
        .habits: "Habits",
        .voice: "Voice"
    ]

    var url: URL {
        switch self {
        case .habits: return URL(string: "habittracker://habits")!
        case .voice:  return URL(string: "habittracker://voice")!
        }
    }
}
