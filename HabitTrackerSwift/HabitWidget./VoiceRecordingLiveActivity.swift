import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

// Live Activity UI for Voice Record.
// Self-ticking timer via Text(timerInterval:) — zero Activity.update() needed
// for second-by-second display. Activity.update() is reserved for state
// transitions AND throttled preview-text updates (~1 every 2s).
//
// Interactive Stop / Cancel buttons: ActivityKit supports Button(intent:)
// since iOS 17. Both buttons conform to AudioRecordingIntent so iOS runs
// perform() in the app's process and our coordinator can finalize cleanly.
//
// Phase mapping:
//   .starting  → orange progress ring + "Starting…" — instant feedback after
//                tap, before mic / WS finish setting up
//   .recording → pulsing red dot + live timer (Text(timerInterval:))
//   .stopping  → orange progress ring + "Stopping…" — finalize in flight
//   .ended     → green checkmark — Activity in dismissal grace window

struct VoiceRecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingAttributes.self) { context in
            // ─── Lock Screen / Notification Center ───
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    PhaseIcon(phase: context.state.phase,
                              isStreaming: context.state.isStreaming)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayTitle(phase: context.state.phase,
                                          original: context.attributes.title))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .foregroundStyle(.white)
                        phaseLine(state: context.state)
                            .font(.title3.monospacedDigit())
                            .foregroundStyle(.white)
                        micSourceLine(state: context.state)
                    }
                    Spacer()
                    actionCluster(phase: context.state.phase)
                }

                if !context.state.previewText.isEmpty {
                    Text(context.state.previewText)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(3)
                        .truncationMode(.head)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                        .padding(.trailing, trailingPadding())
                        .transition(.opacity)
                }
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.6))
            .activitySystemActionForegroundColor(.red)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PhaseIcon(phase: context.state.phase,
                              isStreaming: context.state.isStreaming)
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    actionCluster(phase: context.state.phase)
                }
                DynamicIslandExpandedRegion(.center) {
                    phaseLine(state: context.state)
                        .monospacedDigit()
                        .font(.title3)
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        micSourceLine(state: context.state)
                        if context.state.previewText.isEmpty {
                            Text(bottomCaption(phase: context.state.phase,
                                               isStreaming: context.state.isStreaming))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(context.state.previewText)
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(2)
                                .truncationMode(.head)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.trailing, trailingPadding())
                        }
                    }
                }
            } compactLeading: {
                // PhaseIcon uses a repeating animation via .onAppear which
                // can fault SpringBoard when SwiftUI re-creates compact views
                // out-of-process — Apple silently drops the entire Dynamic
                // Island slot on view-faulting (NC still renders because that
                // is a separate render path). Compact slot is ~24pt wide, an
                // animated pulse is invisible anyway — use a plain icon.
                compactLeadingIcon(phase: context.state.phase,
                                   isStreaming: context.state.isStreaming)
            } compactTrailing: {
                compactTrailingView(state: context.state)
                    .frame(maxWidth: 56)
            } minimal: {
                minimalView(state: context.state)
            }
            .keylineTint(.red)
        }
    }

    // Title shown in Notification Center / Lock Screen. In idle mode we
    // pretend the Activity belongs to "Habit Tracker" with neutral text —
    // the actual app is a recorder, but when we're pinned and not yet
    // recording we don't want bystanders to think audio capture is active.
    // The mic-themed copy only appears once the user explicitly starts.
    private func displayTitle(phase: RecordingAttributes.Phase, original: String) -> String {
        switch phase {
        case .idle: return "Habit Tracker"
        default:    return original
        }
    }

    @ViewBuilder
    private func phaseLine(state: RecordingAttributes.ContentState) -> some View {
        switch state.phase {
        case .idle:
            Text("Приложение активно")
                .foregroundStyle(.secondary)
        case .starting:
            Text("Starting…")
                .foregroundStyle(.orange)
        case .recording:
            Text(timerInterval: state.startedAt ... .distantFuture,
                 countsDown: false)
        case .stopping:
            Text("Stopping…")
                .foregroundStyle(.orange)
        case .ended:
            if let endedAt = state.endedAt {
                Text("Готово · скопировано · \(elapsedString(from: state.startedAt, to: endedAt))")
                    .foregroundStyle(.green)
            } else {
                Text("Готово · скопировано")
                    .foregroundStyle(.green)
            }
        }
    }

    @ViewBuilder
    private func actionCluster(phase: RecordingAttributes.Phase) -> some View {
        if #available(iOS 17.0, *) {
            switch phase {
            case .idle:
                // Neutral dark button with a non-audio glyph so bystanders
                // peeking at the user's screen don't assume an active mic.
                // sparkles = generic "AI / smart action", visually consistent
                // with iOS 26 Apple Intelligence affordances.
                Button(intent: ToggleVoiceRecordingIntent(value: true)) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.18))
                            .frame(width: 42, height: 42)
                        Image(systemName: "sparkles")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .buttonStyle(.plain)
            case .starting, .recording:
                HStack(spacing: 8) {
                    // ✕ Cancel — hard drop, no save, dismiss LA
                    Button(intent: CancelVoiceRecordingIntent()) {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.18))
                                .frame(width: 36, height: 36)
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                    }
                    .buttonStyle(.plain)
                    // ■ Stop — normal finalize
                    Button(intent: StopVoiceRecordingIntent()) {
                        ZStack {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 42, height: 42)
                            Image(systemName: "stop.fill")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)
                }
            case .stopping:
                // Only Cancel remains — Stop is in-flight, prevent re-tap.
                Button(intent: CancelVoiceRecordingIntent()) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.18))
                            .frame(width: 42, height: 42)
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                .buttonStyle(.plain)
            case .ended:
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
            }
        } else {
            Image(systemName: "mic.fill")
                .font(.title3)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func compactTrailingView(state: RecordingAttributes.ContentState) -> some View {
        switch state.phase {
        case .idle:
            // Empty in compact — Activity is just a hook for background
            // updates. Compact slot stays slim.
            Text(" ")
        case .starting:
            // Static dot instead of ProgressView — see compactLeadingIcon
            // note. SpringBoard rendering of indeterminate ProgressView in
            // compact slot is fragile; a plain Text avoids it entirely.
            Text("•••").font(.caption2).foregroundStyle(.orange)
        case .recording:
            Text(timerInterval: state.startedAt ... .distantFuture,
                 countsDown: false)
                .monospacedDigit()
        case .stopping:
            Text("•••").font(.caption2).foregroundStyle(.orange)
        case .ended:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    // Lightweight compact-leading: no animations, no .onAppear side effects,
    // no ProgressView (which itself can fault in compact slot on some iOS
    // builds). Just a single SF Symbol tinted to communicate phase.
    @ViewBuilder
    private func compactLeadingIcon(phase: RecordingAttributes.Phase, isStreaming: Bool) -> some View {
        switch phase {
        case .idle:
            // Same rationale as the lock-screen PhaseIcon: don't display
            // a mic glyph at rest. sparkle reads as "smart action" / AI
            // and doesn't tip bystanders that this is a recorder.
            Image(systemName: "sparkles")
                .foregroundStyle(.white.opacity(0.7))
        case .starting, .stopping:
            Image(systemName: "mic.circle")
                .foregroundStyle(.orange)
        case .recording:
            Image(systemName: "mic.fill")
                .foregroundStyle(isStreaming ? .red : .orange)
        case .ended:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    // Minimal-slot view. iOS forces ALL apps into minimal when two or more
    // Live Activities are concurrently active — so anything important must
    // also fit here, not just compactTrailing. We re-use the timer-interval
    // text so the user sees recording duration whether Island is in compact
    // (one active LA) or minimal (multi-LA mode).
    @ViewBuilder
    private func minimalView(state: RecordingAttributes.ContentState) -> some View {
        switch state.phase {
        case .idle:
            Image(systemName: "sparkles").foregroundStyle(.white.opacity(0.7))
        case .starting:
            Image(systemName: "mic.circle").foregroundStyle(.orange)
        case .recording:
            Text(timerInterval: state.startedAt ... .distantFuture,
                 countsDown: false)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.red)
        case .stopping:
            Image(systemName: "mic.circle").foregroundStyle(.orange)
        case .ended:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    private func bottomCaption(phase: RecordingAttributes.Phase, isStreaming: Bool) -> String {
        switch phase {
        case .idle:      return "Активно"
        case .starting:  return "Starting…"
        case .recording: return isStreaming ? "Recording…" : "Reconnecting…"
        case .stopping:  return "Finalizing…"
        case .ended:     return "Готово · скопировано"
        }
    }

    // Small "mic source" affordance shown in Lock Screen / NC and in Dynamic
    // Island expanded `.bottom`. NOT rendered in compact / minimal slots —
    // those views are rendered out-of-process by SpringBoard and fault on any
    // dynamic content, so they stay strictly statique-only (see
    // fix-dynamic-island.md::Шрам 3). Hidden in `.idle` and `.ended` phases to
    // avoid bystanders seeing a mic name when nothing is being captured —
    // matches the stealth-mode principle in methodology/переносимый-дизайн.md.
    @ViewBuilder
    private func micSourceLine(state: RecordingAttributes.ContentState) -> some View {
        switch state.phase {
        case .idle, .ended:
            EmptyView()
        case .starting, .recording, .stopping:
            HStack(spacing: 4) {
                Image(systemName: micSymbol(kind: state.micSourceKind))
                    .font(.caption2)
                Text(micLabel(kind: state.micSourceKind, name: state.micSourceName))
                    .font(.caption2)
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func micSymbol(kind: RecordingAttributes.MicSourceKind) -> String {
        switch kind {
        case .iphone:     return "iphone.gen3"
        case .airpods:    return "airpods.pro"
        case .headphones: return "headphones"
        case .usb:        return "cable.connector"
        case .unknown:    return "mic"
        }
    }

    // Prefer the iOS-provided port name when present — "AirPods Pro de Fedor",
    // "iPhone Microphone" — so the user instantly recognises the device. Fall
    // back to a generic label when the route hasn't surfaced a name yet (early
    // in cold-launch before activate() lands).
    private func micLabel(kind: RecordingAttributes.MicSourceKind, name: String) -> String {
        if !name.isEmpty { return name }
        switch kind {
        case .iphone:     return "Микрофон iPhone"
        case .airpods:    return "AirPods"
        case .headphones: return "Наушники"
        case .usb:        return "USB-микрофон"
        case .unknown:    return "Микрофон"
        }
    }

    private func elapsedString(from start: Date, to end: Date) -> String {
        let secs = max(0, Int(end.timeIntervalSince(start)))
        let m = secs / 60
        let s = secs % 60
        return String(format: "%d:%02d", m, s)
    }

    // User-configurable trailing pad (8–48 pt), read from App Group.
    private func trailingPadding() -> CGFloat {
        let d = UserDefaults(suiteName: VoiceRecordConfig.appGroup)
        let raw = d?.object(forKey: VoiceRecordConfig.SharedKeys.liveActivityTrailingPadding) as? Double
        let v = raw ?? 8
        return CGFloat(min(max(v, 0), 80))
    }
}

private struct PhaseIcon: View {
    let phase: RecordingAttributes.Phase
    let isStreaming: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            switch phase {
            case .idle:
                // Same stealth-affordance reasoning as the action button:
                // sparkle keeps the row neutral when no recording is live.
                Image(systemName: "sparkles")
                    .foregroundStyle(.white.opacity(0.7))
            case .starting, .stopping:
                ProgressView()
                    .controlSize(.small)
                    .tint(.orange)
            case .recording:
                Circle()
                    .fill(isStreaming ? Color.red : Color.orange)
                    .frame(width: 10, height: 10)
                    .opacity(isStreaming && pulse ? 1 : 0.4)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
            case .ended:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .frame(width: 14, height: 14)
    }
}
