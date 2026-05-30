import SwiftUI

// Reusable debug-log viewer, mirrors the one in VoiceSettingsSheet but shared
// so the Habits tab can show the SAME on-disk VRLog buffer. Habit-side events
// are written via VRLog.d("HABIT", ...) so drag/reorder/toggle diagnostics
// land in the same file as the Voice subsystem.
struct DiagnosticsLogView: View {
    @Environment(\.dismiss) var dismiss
    @State private var text: String = ""

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
            .navigationTitle("Debug log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            UIPasteboard.general.string = text
                        } label: { Label("Copy all", systemImage: "doc.on.doc") }

                        ShareLink(item: shareFile(), preview: SharePreview("habit-log.txt")) {
                            Label("Share log", systemImage: "square.and.arrow.up")
                        }
                        Button(role: .destructive) {
                            VRLog.clear()
                            text = ""
                        } label: { Label("Clear log", systemImage: "trash") }
                        Button {
                            text = VRLog.readRecent(maxLines: 400)
                        } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .onAppear {
            text = VRLog.readRecent(maxLines: 400)
        }
    }

    // Materialise the buffer to a tmp .txt so ShareLink offers file targets
    // (AirDrop/Files/Mail), not just text-share destinations.
    private func shareFile() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("habit-log.txt")
        try? text.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }
}
