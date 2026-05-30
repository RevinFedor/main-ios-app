import WidgetKit
import SwiftUI

@main
struct HabitWidget_Bundle: WidgetBundle {
    var body: some Widget {
        HabitWidget_()
        HabitWidget_Control()
        VoiceRecordControl()
        VoiceRecordingLiveActivity()
    }
}
