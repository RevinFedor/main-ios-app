import Foundation
import OSLog

// Cross-process logger. Writes to:
//   1. Apple os_log (visible via Console.app, Predicate
//      subsystem == "com.habittracker.swift.voicerecord").
//   2. App-Group file <container>/voice-record-debug.log so the user can
//      view recent lines directly inside Voice Settings ("Show logs").
//
// Lives in HabitWidget./ so BOTH app target and widget extension target
// can write. The widget extension's logs end up in the same file — that's
// how we'll diagnose "perform() never runs" issues with Control Center
// toggles.

enum VRLog {
    private static let logger = Logger(subsystem: "com.habittracker.swift.voicerecord",
                                       category: "vr")
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func d(_ tag: String, _ msg: String) {
        let line = "[\(dateFmt.string(from: Date()))] [\(tag)] \(msg)"
        logger.debug("\(line, privacy: .public)")
        append(line)
    }

    static func e(_ tag: String, _ msg: String) {
        let line = "[\(dateFmt.string(from: Date()))] [\(tag)] ERR \(msg)"
        logger.error("\(line, privacy: .public)")
        append(line)
    }

    static func readRecent(maxLines: Int = 400) -> String {
        guard let url = logFileURL,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return "" }
        let lines = text.split(separator: "\n")
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    // Approximate count of lines currently in the on-disk log. Counts raw
    // newline bytes — cheaper than splitting and good enough for a header
    // counter that just signals "log is growing / log was cleared".
    static func lineCount() -> Int {
        guard let url = logFileURL,
              let data = try? Data(contentsOf: url) else { return 0 }
        return data.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
    }

    static func clear() {
        guard let url = logFileURL else { return }
        try? Data().write(to: url)
    }

    // MARK: - Private

    private static var logFileURL: URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.fedor277.habittracker"
        ) else { return nil }
        return container.appendingPathComponent("voice-record-debug.log")
    }

    private static let ioQueue = DispatchQueue(label: "voice-record.vrlog", qos: .utility)
    private static let maxBytes = 200_000   // ~200 KB rolling window

    private static func append(_ line: String) {
        guard let url = logFileURL else { return }
        ioQueue.async {
            var blob = (try? Data(contentsOf: url)) ?? Data()
            blob.append((line + "\n").data(using: .utf8) ?? Data())
            if blob.count > maxBytes {
                blob = blob.suffix(maxBytes)
            }
            try? blob.write(to: url, options: .atomic)
        }
    }
}
