import SwiftUI
import AVFoundation

public struct SettingsView: View {
    @ObservedObject var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        TabView {
            GeneralSettingsTab(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }

            DictationSettingsTab(model: model)
                .tabItem { Label("Dictation", systemImage: "waveform") }

            SnippetsSettingsTab(model: model)
                .tabItem { Label("Snippets", systemImage: "text.badge.plus") }

            ShortcutsSettingsTab(model: model)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }

            PrivacySettingsTab()
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
        }
        .frame(width: 520, height: 520)
    }
}

private struct GeneralSettingsTab: View {
    @ObservedObject var model: AppModel
    @State private var apiKeyInput: String = ""

    @State private var refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            Form {
                Section {
                    SecureField("Groq API key", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Save") {
                            model.saveAPIKey(apiKeyInput)
                            apiKeyInput = ""
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(apiKeyInput.isEmpty)

                        Button("Remove", role: .destructive) {
                            model.removeAPIKey()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!model.hasAPIKey)

                        Spacer()

                        Label(model.hasAPIKey ? "Key saved" : "No key saved", systemImage: model.hasAPIKey ? "checkmark.circle.fill" : "circle")
                            .font(.caption)
                            .foregroundStyle(model.hasAPIKey ? .green : .secondary)
                    }
                    if let error = model.keychainError {
                        Text(error).foregroundStyle(.red).font(.caption)
                    }
                } header: {
                    Label("Groq API Key", systemImage: "key.fill")
                }

                Section {
                    permissionRow(
                        title: "Microphone",
                        granted: model.microphonePermission == .authorized,
                        statusText: microphoneStatusText,
                        showButton: model.microphonePermission != .authorized,
                        action: model.requestMicrophonePermission
                    )
                    permissionRow(
                        title: "Accessibility",
                        granted: model.accessibilityTrusted,
                        statusText: model.accessibilityTrusted ? "Trusted" : "Not trusted",
                        showButton: !model.accessibilityTrusted,
                        action: model.requestAccessibilityPermission
                    )
                    Text("Only needed to insert text directly into the focused field. Recording, transcription, and Copy still work without it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    permissionRow(
                        title: "Input Monitoring",
                        granted: model.inputMonitoringGranted,
                        statusText: model.inputMonitoringGranted ? "Granted" : "Not granted",
                        showButton: !model.inputMonitoringGranted,
                        action: model.requestInputMonitoringPermission
                    )
                    Text("Only needed for the Fn key shortcut. The menu bar item always works without it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Label("Permissions", systemImage: "checkmark.shield")
                }
            }
            .formStyle(.grouped)
        }
        .onAppear { model.refreshPermissionStatuses() }
        .onReceive(refreshTimer) { _ in model.refreshPermissionStatuses() }
    }

    private func permissionRow(title: String, granted: Bool, statusText: String, showButton: Bool, action: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(granted ? .green : .orange)
                Text(statusText)
                    .foregroundStyle(.secondary)
                if showButton {
                    Button("Grant…", action: action)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    private var microphoneStatusText: String {
        switch model.microphonePermission {
        case .authorized: return "Granted"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not requested"
        @unknown default: return "Unknown"
        }
    }
}

private struct DictationSettingsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            Form {
                Section {
                    Picker("Language", selection: $model.inputLanguage) {
                        ForEach(InputLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    Text(model.inputLanguage.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Label("Language", systemImage: "globe")
                }

                Section {
                    Toggle("Clean up transcript", isOn: $model.cleanUpTranscript)
                    Text("Renders clearly identifiable English/technical terms (e.g. Slack, deploy, staging) in conventional spelling, removes filler words (\"um\", stutters), adds punctuation, formats explicitly spoken lists, and resolves clear self-corrections (\"Friday, actually Monday\" → \"Monday\"). Turn off to insert the raw transcript exactly as spoken.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Label("Text Processing", systemImage: "wand.and.stars")
                }

                Section {
                    TextField("Personal dictionary", text: $model.customVocabulary, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(4...8)
                    Text("Names, project terms, and acronyms Whisper tends to mishear, separated by commas or newlines (e.g. teammate names, repo names). These are spelling hints, not guaranteed replacements: sent as a decoding hint and consulted during text processing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Label("Personal Dictionary", systemImage: "text.book.closed")
                }
            }
            .formStyle(.grouped)
        }
    }
}

private struct SnippetsSettingsTab: View {
    @ObservedObject var model: AppModel
    @State private var editingSnippet: EditableSnippet?
    @State private var showResetSnippetsConfirmation = false

    var body: some View {
        ScrollView {
            Form {
                Section {
                    if model.voiceSnippets.isEmpty {
                        Text("No saved snippets. Add a spoken cue that expands to fixed text, entirely locally — the replacement is never sent to Groq.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.voiceSnippets) { snippet in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(snippet.trigger).font(.system(size: 13, weight: .medium))
                                    Text(snippet.replacement)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                Button {
                                    editingSnippet = EditableSnippet(id: snippet.id, trigger: snippet.trigger, replacement: snippet.replacement)
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.borderless)
                                Button(role: .destructive) {
                                    model.deleteSnippet(id: snippet.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.red)
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    if let error = model.snippetError {
                        Text(error).foregroundStyle(.red).font(.caption)
                    }

                    HStack {
                        Button {
                            editingSnippet = EditableSnippet(id: UUID(), trigger: "", replacement: "")
                        } label: {
                            Label("Add Snippet", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                        Button("Reset Snippets", role: .destructive) {
                            showResetSnippetsConfirmation = true
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.voiceSnippets.isEmpty && model.snippetError == nil)
                    }
                } header: {
                    Label("Voice Snippets", systemImage: "text.badge.plus")
                }
            }
            .formStyle(.grouped)
        }
        .confirmationDialog(
            "Delete all saved snippets?",
            isPresented: $showResetSnippetsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset Snippets", role: .destructive) { model.resetSnippets() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $editingSnippet) { editable in
            SnippetEditorView(model: model, editable: editable, isPresented: Binding(
                get: { editingSnippet != nil },
                set: { if !$0 { editingSnippet = nil } }
            ))
        }
    }
}

private struct ShortcutsSettingsTab: View {
    @ObservedObject var model: AppModel
    @State private var showShortcutRecorder = false

    var body: some View {
        ScrollView {
            Form {
                Section {
                    Picker("Trigger", selection: $model.hotkeyTrigger) {
                        ForEach(HotkeyTrigger.allCases) { trigger in
                            Text(trigger.displayName)
                                .tag(trigger)
                                .disabled(trigger == .custom && model.customShortcut == nil)
                        }
                    }
                    .disabled(model.isSessionActive || model.isCapturingShortcut)
                    Text(model.hotkeyTrigger.explanation(for: model.recordingMode))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button(model.customShortcut == nil ? "Record shortcut…" : "Change shortcut…") {
                            if model.beginShortcutCapture() {
                                showShortcutRecorder = true
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isSessionActive || model.isCapturingShortcut)
                        if let customShortcut = model.customShortcut {
                            ShortcutChip(customShortcut.displayName)
                        }
                    }

                    Picker("Recording mode", selection: $model.recordingMode) {
                        ForEach(RecordingMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .disabled(model.isSessionActive || model.isCapturingShortcut)
                    Text("When recording stops, text is transcribed and inserted automatically into the field where you started. Keep that field focused until insertion finishes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let shortcutSettingsError = model.shortcutSettingsError {
                        Text(shortcutSettingsError).foregroundStyle(.red).font(.caption)
                    }
                    if let hotkeyError = model.hotkeyError {
                        Text(hotkeyError).foregroundStyle(.red).font(.caption)
                        Text("Use the menu bar item's Start/Stop Recording instead.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Label("Recording Trigger", systemImage: "record.circle")
                }

                Section {
                    LabeledContent("Cancel (while recording/processing)") { ShortcutChip("Esc") }
                    LabeledContent("Copy Last Result") { ShortcutChip("⌘⌃C") }
                    LabeledContent("Paste Last Result") { ShortcutChip("⌘⌃V") }
                } header: {
                    Label("Always Available", systemImage: "keyboard")
                }
            }
            .formStyle(.grouped)
        }
        .sheet(isPresented: $showShortcutRecorder) {
            ShortcutRecorderView(model: model, isPresented: $showShortcutRecorder)
        }
    }
}

private struct PrivacySettingsTab: View {
    var body: some View {
        ScrollView {
            Form {
                Section {
                    Text("Recorded audio is sent to Groq for transcription and deleted locally afterward. When text processing is enabled, the transcript text is also sent to Groq; a matched snippet's replacement text never is. Any custom vocabulary you enter is sent to Groq with every request. Snippets and dictionary entries are stored only on this Mac. T-Whisper keeps no transcript history; only the most recent result is kept in memory (for Copy/Paste Last Result) until you quit — starting or cancelling a new recording does not clear it. A pasted or copied result also remains on your system clipboard afterward. A refused insertion always copies the text to the clipboard instead. Groq's data retention is controlled by your organization's Groq account settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Label("Data & Privacy", systemImage: "lock.shield")
                }
            }
            .formStyle(.grouped)
        }
    }
}

private struct EditableSnippet: Identifiable {
    let id: UUID
    var trigger: String
    var replacement: String
}

private struct SnippetEditorView: View {
    @ObservedObject var model: AppModel
    let editable: EditableSnippet
    @Binding var isPresented: Bool

    @State private var trigger: String
    @State private var replacement: String

    init(model: AppModel, editable: EditableSnippet, isPresented: Binding<Bool>) {
        self.model = model
        self.editable = editable
        self._isPresented = isPresented
        self._trigger = State(initialValue: editable.trigger)
        self._replacement = State(initialValue: editable.replacement)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(editable.trigger.isEmpty ? "New Snippet" : "Edit Snippet", systemImage: "text.badge.plus")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Trigger phrase")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("e.g. my signature", text: $trigger)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Replacement text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Replacement text", text: $replacement, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(4...10)
            }

            if let error = model.snippetError {
                Text(error).foregroundStyle(.red).font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { isPresented = false }
                    .buttonStyle(.bordered)
                Button("Save") {
                    let saved = model.saveSnippet(VoiceSnippet(id: editable.id, trigger: trigger, replacement: replacement))
                    if saved { isPresented = false }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
