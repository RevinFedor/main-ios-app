import Foundation

enum AppGroupContainer {
    static var defaults: UserDefaults {
        UserDefaults(suiteName: VoiceRecordConfig.appGroup) ?? .standard
    }

    static var containerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: VoiceRecordConfig.appGroup
        )
    }

    static var audioDirURL: URL? {
        guard let base = containerURL else { return nil }
        let dir = base.appendingPathComponent(VoiceRecordConfig.audioDirName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static var historyURL: URL? {
        containerURL?.appendingPathComponent(VoiceRecordConfig.historyFileName)
    }
}
