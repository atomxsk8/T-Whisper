import AppKit
import SwiftUI

/// The `MenuBarExtra` status item. Wraps `AppModel` in `@ObservedObject` so the mark
/// actually re-renders on phase changes — reading `model.phase` from a non-observing context
/// (e.g. directly in the scene's `label:` closure against the `AppDelegate`) registers no
/// SwiftUI dependency and the icon never updates.
public struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        switch model.phase {
        case .recording:
            Image(systemName: "mic.fill")
        case .transcribing, .normalizing, .inserting:
            Image(systemName: "waveform")
        case .failed:
            Image(systemName: "exclamationmark.triangle")
        case .idle, .ready:
            Image(systemName: "mic")
        }
    }
}


/// The `MenuBarExtra` popover content: a compact native control center for status, start/stop,
/// setup/error alerts, the last result, and quick settings.
public struct MenuBarContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusHeader
            primaryActionButton
            alertRows
            lastResultBlock
            quickSettings
            Divider()
            MenuActionRow(title: "Settings…", icon: "gearshape", shortcut: "⌘,") {
                openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
            MenuActionRow(title: "Quit T-Whisper", icon: "power", shortcut: "⌘Q") {
                model.prepareForQuit()
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(12)
        .frame(width: 300)
        .onAppear { model.refreshPermissionStatuses() }
    }

    // MARK: - Status header

    private var statusHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(statusTitle)
                    .font(.system(size: 13, weight: .semibold))
                Text(statusSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ShortcutChip(triggerLabel)
        }
    }

    private var statusColor: Color {
        switch model.phase {
        case .idle: return .secondary
        case .ready: return .green
        case .recording: return .red
        case .transcribing, .normalizing, .inserting: return .accentColor
        case .failed: return .orange
        }
    }

    private var statusTitle: String {
        switch model.phase {
        case .idle: return "Ready"
        case .ready: return "Done"
        case .recording: return "Listening"
        case .transcribing: return "Transcribing"
        case .normalizing: return "Cleaning up"
        case .inserting: return "Inserting"
        case .failed: return "Failed"
        }
    }

    private var statusSubtitle: String {
        switch model.phase {
        case .idle, .ready: return startHint
        case .recording: return recordingSubtitle
        case .transcribing: return "Sending audio to Groq"
        case .normalizing: return "Polishing the transcript"
        case .inserting: return "Writing into the focused field"
        case .failed: return model.errorMessage ?? "Something went wrong"
        }
    }

    private var triggerLabel: String {
        model.hotkeyTrigger == .fn ? "Fn" : (model.customShortcut?.displayName ?? "Fn")
    }

    private var startHint: String {
        model.recordingMode == .toggle ? "Press \(triggerLabel) to start" : "Hold \(triggerLabel) to talk"
    }

    private var recordingSubtitle: String {
        let elapsed = elapsedText
        switch model.sessionInputKind {
        case .hold: return "\(elapsed) · Release to stop"
        case .handsFree: return "\(elapsed) · Press \(triggerLabel) again to stop"
        }
    }

    private var elapsedText: String {
        let total = Int(model.recordingElapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Primary action

    @ViewBuilder
    private var primaryActionButton: some View {
        switch model.phase {
        case .idle, .ready, .failed:
            Button {
                dismissThenRun { model.toggleRecording() }
            } label: {
                Label("Start Dictation", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.hasAPIKey)
        case .recording:
            Button {
                dismissThenRun { model.toggleRecording() }
            } label: {
                Label("Stop & Transcribe", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.red)
        case .transcribing, .normalizing, .inserting:
            Button {
                model.cancel()
            } label: {
                Label("Cancel", systemImage: "xmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    /// Deactivates T-Whisper before running `action` so the previous app regains focus (the
    /// `.window`-style popover closes on resign-key) and `TextInserter`'s frontmost-app check
    /// at insert time doesn't reject the write because the popover itself was frontmost.
    private func dismissThenRun(_ action: () -> Void) {
        NSApp.deactivate()
        action()
    }

    // MARK: - Alert rows

    @ViewBuilder
    private var alertRows: some View {
        if !model.hasAPIKey {
            alertRow(
                icon: "key.slash",
                tint: .orange,
                text: "No Groq API key saved",
                actionTitle: "Add Key…"
            ) { openSettings() }
        }
        if model.microphonePermission != .authorized {
            alertRow(
                icon: "mic.slash",
                tint: .orange,
                text: "Microphone access needed",
                actionTitle: "Grant…"
            ) { model.requestMicrophonePermission() }
        }
        if model.hotkeyTrigger == .fn, !model.inputMonitoringGranted {
            alertRow(
                icon: "keyboard",
                tint: .orange,
                text: "Fn shortcut needs Input Monitoring",
                actionTitle: "Grant…"
            ) { model.requestInputMonitoringPermission() }
        }
        if let hotkeyError = model.hotkeyError {
            alertRow(icon: "keyboard", tint: .orange, text: hotkeyError, actionTitle: nil, action: nil)
        }
        if let errorMessage = model.errorMessage, model.phase != .failed {
            alertRow(icon: "exclamationmark.triangle.fill", tint: .orange, text: errorMessage, actionTitle: nil, action: nil)
        }
    }

    private func alertRow(icon: String, tint: Color, text: String, actionTitle: String?, action: (() -> Void)?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(0.12))
        )
    }

    // MARK: - Last result

    @ViewBuilder
    private var lastResultBlock: some View {
        if let last = model.lastResult, !last.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Last Result")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(last)
                    .font(.callout)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
                if let outcomeCaption {
                    Text(outcomeCaption)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                HStack {
                    Button {
                        model.copyLastResult()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.isSessionActive)
                    Spacer()
                    ShortcutChip("⌘⌃C")
                }
                Text("Paste into the focused app with ⌘⌃V")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var outcomeCaption: String? {
        switch model.lastInsertionOutcome {
        case .inserted: return "Inserted into the focused field"
        case .pasteSent: return "Pasted into the focused field"
        case .manualCopyRequired: return "Couldn't insert — copied to the clipboard"
        case nil: return nil
        }
    }

    // MARK: - Quick settings

    private var quickSettings: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Language")
                    .font(.system(size: 12))
                Spacer()
                Picker("", selection: $model.inputLanguage) {
                    ForEach(InputLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }
            Toggle("Clean up transcript", isOn: $model.cleanUpTranscript)
                .font(.system(size: 12))
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

/// A hoverable footer row used for the Settings…/Quit actions, matching the plain, secondary
/// styling native macOS menu items use while still supporting a trailing shortcut chip.
private struct MenuActionRow: View {
    let title: String
    let icon: String
    let shortcut: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.system(size: 12))
                Spacer()
                ShortcutChip(shortcut)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovering ? Color.primary.opacity(0.08) : Color.clear)
        )
        .onHover { isHovering = $0 }
        .contentShape(Rectangle())
    }
}
