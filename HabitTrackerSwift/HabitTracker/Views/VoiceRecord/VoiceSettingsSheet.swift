import AVFoundation
import SwiftUI

struct VoiceSettingsSheet: View {
    @Environment(\.dismiss) var dismiss
    @State private var availableInputs: [AVAudioSessionPortDescription] = []
    @State private var currentPortType: AVAudioSession.Port? = nil
    @State private var showLogs = false

    // @AppStorage with the SAME store as VoiceRecordTabView so any change
    // here propagates to the Voice navbar live, without needing a tab
    // bounce. Using @State + manual UserDefaults.set bypasses @AppStorage's
    // internal observer in the other view — that's why the navbar didn't
    // refresh when Dev mode was toggled.
    @AppStorage(VoiceRecordConfig.SharedKeys.autoCopyAfterStop,
                store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var autoCopy: Bool = true
    @AppStorage(VoiceRecordConfig.SharedKeys.devMode,
                store: UserDefaults(suiteName: VoiceRecordConfig.appGroup))
    private var devMode: Bool = false

    @State private var laTrailingPad: Double = {
        let d = UserDefaults(suiteName: VoiceRecordConfig.appGroup)
        return d?.object(forKey: VoiceRecordConfig.SharedKeys.liveActivityTrailingPadding) as? Double ?? 8
    }()

    // Default playback speed for the History audio player. Seeded from the App
    // Group (fallback 1.0); every new playback starts here. Persisted on change
    // so the next item played picks it up without a restart.
    @State private var playbackDefaultRate: Double = {
        let d = UserDefaults(suiteName: VoiceRecordConfig.appGroup)
        return d?.object(forKey: VoiceRecordConfig.SharedKeys.playbackDefaultRate) as? Double
            ?? VoiceRecordConfig.playbackDefaultRateFallback
    }()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ProvisioningExpiryView()
                }

                Section {
                    Toggle("Auto-copy transcript", isOn: $autoCopy)
                        .tint(.blue)
                    Toggle("Developer mode", isOn: $devMode)
                        .tint(.purple)
                } footer: {
                    // Was: "Always use iPhone microphone" toggle. Moved out of
                    // Settings into MicSourcePicker on the main Voice screen
                    // (long-press / tap menu) so the user can switch input on
                    // the fly without diving into Settings.
                    Text("Выбор микрофона перенесён на главный экран — кнопка справа от микрофона.")
                        .font(.footnote)
                }

                Section {
                    HStack {
                        Text("Preview trailing padding")
                        Spacer()
                        Text("\(Int(laTrailingPad)) pt").foregroundStyle(.secondary)
                    }
                    Slider(value: $laTrailingPad, in: 0...48, step: 1) {
                        Text("Padding")
                    } minimumValueLabel: {
                        Text("0").font(.caption2).foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Text("48").font(.caption2).foregroundStyle(.secondary)
                    }
                    .tint(.red)
                    .onChange(of: laTrailingPad) { _, newValue in
                        let d = UserDefaults(suiteName: VoiceRecordConfig.appGroup)
                        d?.set(newValue, forKey: VoiceRecordConfig.SharedKeys.liveActivityTrailingPadding)
                        d?.synchronize()
                    }
                } header: {
                    Text("Live Activity")
                } footer: {
                    Text("Extra padding on the right side of the preview text in the Lock Screen and Dynamic Island so the last visible line doesn't run into the corner.")
                }

                Section {
                    Picker("Default speed", selection: $playbackDefaultRate) {
                        ForEach(VoiceRecordConfig.playbackRates, id: \.self) { r in
                            Text(VoiceRecordConfig.playbackRateLabel(r)).tag(r)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: playbackDefaultRate) { _, newValue in
                        let d = UserDefaults(suiteName: VoiceRecordConfig.appGroup)
                        d?.set(newValue, forKey: VoiceRecordConfig.SharedKeys.playbackDefaultRate)
                        d?.synchronize()
                    }
                } header: {
                    Text("Playback")
                } footer: {
                    Text("Скорость, с которой стартует каждое новое воспроизведение в Истории. Кнопка скорости в плеере дальше переключает 1 → 1.5 → 2 → 2.5 для текущей записи.")
                }

                Section("Available inputs") {
                    if availableInputs.isEmpty {
                        Text("Recording must be started once for iOS to publish input options.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(availableInputs, id: \.uid) { input in
                            HStack {
                                Image(systemName: icon(for: input))
                                    .frame(width: 24)
                                Text(input.portName)
                                Spacer()
                                if currentPortType == input.portType {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                    }
                }

                Section("Soniox API key") {
                    if Secrets.sonioxAPIKey.isEmpty {
                        Label("Missing — paste into VoiceRecord/Secrets.swift",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.footnote)
                    } else {
                        Label("Configured (•••\(Secrets.sonioxAPIKey.suffix(4)))",
                              systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .font(.footnote)
                    }
                }

                Section {
                    HStack(spacing: 12) {
                        Button {
                            showLogs = true
                        } label: {
                            Label("Show debug log", systemImage: "doc.text.magnifyingglass")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            UIPasteboard.general.string = VRLog.readRecent(maxLines: 400)
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 36, height: 32)
                        }
                        .buttonStyle(.bordered)
                        .tint(.blue)

                        Button(role: .destructive) {
                            VRLog.clear()
                            UINotificationFeedbackGenerator().notificationOccurred(.warning)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 36, height: 32)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("Tap the log icon to open the full viewer. Use the icons on the right to copy the recent log or clear it without opening.")
                }
            }
            .navigationTitle("Voice Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { refresh() }
            .sheet(isPresented: $showLogs) {
                LogViewerSheet()
            }
        }
    }

    private func refresh() {
        availableInputs = AudioSessionManager.shared.availableInputs
        currentPortType = AudioSessionManager.shared.currentInputPortType
    }

    private func icon(for input: AVAudioSessionPortDescription) -> String {
        switch input.portType {
        case .builtInMic:     return "iphone"
        case .headsetMic:     return "earpods"
        case .bluetoothHFP:   return "airpods"
        case .usbAudio:       return "cable.connector"
        case .lineIn:         return "cable.coaxial"
        default:              return "mic"
        }
    }
}

private struct LogViewerSheet: View {
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
                        // System share sheet for the current log buffer. The
                        // file is materialised in a tmp directory so the share
                        // sheet shows the full set of destinations (Mail,
                        // Messages, Files, AirDrop) — passing a plain String
                        // here would only allow text-style targets and the
                        // user couldn't AirDrop it to the Mac as a .txt.
                        ShareLink(item: shareFile(), preview: SharePreview("voice-log.txt")) {
                            Label("Share log", systemImage: "square.and.arrow.up")
                        }
                        Button {
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

    // Materialise the current log buffer to a tmp .txt file so ShareLink can
    // hand it to AirDrop / Files / Mail as a real attachment instead of a
    // plain-text string. Overwritten on each share so the file always reflects
    // the latest buffer state without needing Refresh first.
    private func shareFile() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-log.txt")
        try? text.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }
}
