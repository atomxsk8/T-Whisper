import Foundation
import AppKit
import AVFoundation
import ApplicationServices
import Combine

/// Central orchestrator: wires the hotkey backends, recorder, Groq client, and text inserter
/// into one record -> transcribe -> (snippet expansion | text processing) -> insert pipeline.
/// Owns the single cancellable pipeline task and the per-session UUID that keeps stale/
/// cancelled completions from mutating state or inserting text.
@MainActor
public final class AppModel: ObservableObject {
    private enum Keys {
        static let inputLanguage = "inputLanguage"
        static let cleanUpTranscript = "cleanUpTranscript"
        static let customVocabulary = "customVocabulary"
        static let hasLaunchedBefore = "hasLaunchedBefore"
        static let hotkeyTrigger = "hotkeyTrigger"
        static let recordingMode = "recordingMode"
        static let voiceSnippets = "voiceSnippets"
        static let customShortcut = "customShortcut"
    }

    /// Which physical gesture is driving the in-progress session, independent of the saved
    /// primary `recordingMode` (a non-hold session can happen even while hold-to-talk is the
    /// configured mode, e.g. via the menu bar's Start/Stop Recording item, which always
    /// toggles rather than holds).
    enum SessionInputKind {
        case hold
        case handsFree
    }

    @Published public private(set) var phase: DictationPhase = .idle {
        didSet {
            guard oldValue != phase else { return }
            updateEscapeAvailability()
        }
    }
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var rawResult: String?
    @Published public private(set) var finalResult: String?
    @Published public private(set) var lastInsertionOutcome: InsertionOutcome?
    /// In-memory recovery slot for Copy/Paste Last Result. Updated only by a nonempty
    /// successful final result or a current-session processing failure's raw transcript.
    /// Starting or cancelling a later recording never erases it. Never persisted to disk.
    @Published public private(set) var lastResult: String?
    @Published private(set) var sessionInputKind: SessionInputKind = .handsFree

    @Published var inputLanguage: InputLanguage {
        didSet { defaults.set(inputLanguage.rawValue, forKey: Keys.inputLanguage) }
    }
    @Published var cleanUpTranscript: Bool {
        didSet { defaults.set(cleanUpTranscript, forKey: Keys.cleanUpTranscript) }
    }
    @Published var customVocabulary: String {
        didSet { defaults.set(customVocabulary, forKey: Keys.customVocabulary) }
    }
    @Published var hotkeyTrigger: HotkeyTrigger {
        didSet {
            defaults.set(hotkeyTrigger.rawValue, forKey: Keys.hotkeyTrigger)
            reconfigureShortcuts()
        }
    }
    @Published var recordingMode: RecordingMode {
        didSet {
            defaults.set(recordingMode.rawValue, forKey: Keys.recordingMode)
            reconfigureShortcuts()
        }
    }

    @Published public private(set) var customShortcut: KeyboardShortcut?
    @Published public private(set) var shortcutSettingsError: String?
    @Published private(set) var isCapturingShortcut = false

    @Published private(set) var voiceSnippets: [VoiceSnippet] = []
    @Published private(set) var snippetError: String?

    @Published private(set) var hasAPIKey: Bool
    @Published private(set) var keychainError: String?
    @Published private(set) var microphonePermission: AVAuthorizationStatus = AudioRecorder.permissionStatus
    @Published private(set) var accessibilityTrusted: Bool = AXIsProcessTrusted()
    @Published private(set) var inputMonitoringGranted: Bool = FnKeyMonitor.inputMonitoringGranted()
    @Published private(set) var hotkeyError: String?
    /// Whether Escape is actually registered right now (not merely requested). The HUD only
    /// shows its "Esc to cancel" hint when this is true.
    @Published public private(set) var escapeAvailable: Bool = false

    let isFirstLaunch: Bool

    private let audioRecorder: any AudioCapturing
    private let groqClient: any DictationTranscribing
    private let textInserter: any TextInserting
    private let hotkeyManager: any HotkeyRegistering
    private let recordingPanel: any RecordingHUDPresenting
    private let apiKeyStore: any APIKeyStoring
    private let defaults: UserDefaults

    private var currentSessionID: UUID?
    private var processingTask: Task<Void, Never>?
    private var pendingTarget: InsertionTarget?
    private var activeAudioURL: URL?
    /// Session ID of the in-progress recording started by a hold-to-talk press, if any. Only
    /// that session's physical release/chord-cancellation may stop/cancel it.
    private var holdOwnerSessionID: UUID?
    /// Set when saved snippet data on disk couldn't be decoded. Blocks further snippet
    /// mutation until the user explicitly resets, so a save/delete never silently discards
    /// data the user can't currently see.
    private var snippetsLoadFailed = false
    private var isQuitting = false

    var recordingLevel: Float { audioRecorder.currentLevel }
    var recordingElapsed: TimeInterval { audioRecorder.elapsed }

    /// Whether any part of a dictation session is currently active. Settings disables the
    /// trigger/mode pickers while this is true; the shortcut hotkeys governed by it are no-ops
    /// outside of `idle`/`ready`/`failed`.
    var isSessionActive: Bool {
        switch phase {
        case .recording, .transcribing, .normalizing, .inserting: return true
        case .idle, .ready, .failed: return false
        }
    }

    init(
        audioRecorder: any AudioCapturing = AudioRecorder(),
        groqClient: any DictationTranscribing = GroqClient(),
        textInserter: any TextInserting = TextInserter(),
        hotkeyManager: any HotkeyRegistering = HotkeyController(),
        recordingPanel: any RecordingHUDPresenting = RecordingPanel(),
        apiKeyStore: any APIKeyStoring = SystemKeychainStore(),
        defaults: UserDefaults = .standard
    ) {
        self.audioRecorder = audioRecorder
        self.groqClient = groqClient
        self.textInserter = textInserter
        self.hotkeyManager = hotkeyManager
        self.recordingPanel = recordingPanel
        self.apiKeyStore = apiKeyStore
        self.defaults = defaults

        if let raw = defaults.string(forKey: Keys.inputLanguage), let language = InputLanguage(rawValue: raw) {
            inputLanguage = language
        } else {
            inputLanguage = .thai
        }
        customVocabulary = defaults.string(forKey: Keys.customVocabulary) ?? ""

        if let raw = defaults.string(forKey: Keys.recordingMode), let mode = RecordingMode(rawValue: raw) {
            recordingMode = mode
        } else {
            recordingMode = .toggle
        }

        let loadedCustomShortcut = Self.loadCustomShortcut(from: defaults)
        customShortcut = loadedCustomShortcut
        if let raw = defaults.string(forKey: Keys.hotkeyTrigger),
           let trigger = HotkeyTrigger(rawValue: raw) {
            if trigger == .custom, loadedCustomShortcut == nil {
                hotkeyTrigger = .fn
                shortcutSettingsError = "Saved custom shortcut is unavailable. Using the Fn key."
            } else {
                hotkeyTrigger = trigger
                shortcutSettingsError = nil
            }
        } else {
            hotkeyTrigger = .fn
            shortcutSettingsError = nil
        }

        let launchedBefore = defaults.bool(forKey: Keys.hasLaunchedBefore)
        isFirstLaunch = !launchedBefore
        defaults.set(true, forKey: Keys.hasLaunchedBefore)

        // Merged from the previous two-toggle model. A stored opt-out of both legacy toggles
        // carries over as off; anything else — including a fresh install — starts on.
        if let stored = defaults.object(forKey: Keys.cleanUpTranscript) as? Bool {
            cleanUpTranscript = stored
        } else {
            let legacyNormalize = defaults.object(forKey: "normalizeEnglishTerms") as? Bool
            let legacySmart = defaults.object(forKey: "smartFormatting") as? Bool
            let migrated: Bool
            if legacyNormalize == nil, legacySmart == nil {
                migrated = true
            } else {
                migrated = (legacyNormalize ?? false) || (legacySmart ?? false)
            }
            cleanUpTranscript = migrated
            defaults.set(migrated, forKey: Keys.cleanUpTranscript)
            defaults.removeObject(forKey: "normalizeEnglishTerms")
            defaults.removeObject(forKey: "smartFormatting")
        }

        let (loadedSnippets, snippetLoadError) = Self.loadSnippets(from: defaults)
        voiceSnippets = loadedSnippets

        do {
            let loadedKey = try apiKeyStore.loadAPIKey()
            hasAPIKey = (loadedKey?.isEmpty == false)
        } catch {
            hasAPIKey = false
            keychainError = error.localizedDescription
        }

        self.audioRecorder.onMeterUpdate = { [weak self] in self?.objectWillChange.send() }

        self.hotkeyManager.onAction = { [weak self] action in self?.handleShortcutAction(action) }

        snippetsLoadFailed = snippetLoadError != nil
        snippetError = snippetLoadError

        reconfigureShortcuts()
    }

    /// Public entry point used by the app: wires all real dependencies and triggers the
    /// first-launch onboarding prompt. Tests use the designated initializer above directly
    /// with fakes and never touch `NSApp`.
    public convenience init() {
        self.init(
            audioRecorder: AudioRecorder(),
            groqClient: GroqClient(),
            textInserter: TextInserter(),
            hotkeyManager: HotkeyController(),
            recordingPanel: RecordingPanel(),
            apiKeyStore: SystemKeychainStore()
        )
        if isFirstLaunch {
            DispatchQueue.main.async { [weak self] in
                self?.openSettingsWindow()
            }
        }
    }

    // MARK: - Recording lifecycle

    public func toggleRecording() {
        guard !isCapturingShortcut else { return }
        switch phase {
        case .idle, .ready, .failed:
            startRecording()
        case .recording:
            stopRecordingAndProcess()
        case .transcribing, .normalizing, .inserting:
            break
        }
    }

    /// Interprets a dispatched shortcut action against the current session state. The single
    /// entry point both global-shortcut backends funnel into.
    func handleShortcutAction(_ action: ShortcutAction) {
        guard !isCapturingShortcut, !isQuitting else { return }
        switch action {
        case .toggleRecording: toggleRecording()
        case .cancel: cancel()
        case .copyLast: copyLastResult()
        case .pasteLast: pasteLastResult()
        case .primaryPressed: handlePrimaryPressed()
        case .primaryReleased: handlePrimaryReleased()
        case .primaryCancelled: handlePrimaryCancelled()
        }
    }

    private func handlePrimaryPressed() {
        switch phase {
        case .idle, .ready, .failed:
            startRecording()
            if phase == .recording, let sessionID = currentSessionID {
                holdOwnerSessionID = sessionID
                sessionInputKind = .hold
            }
        case .recording, .transcribing, .normalizing, .inserting:
            break
        }
    }

    private func handlePrimaryReleased() {
        guard phase == .recording, let sessionID = currentSessionID, holdOwnerSessionID == sessionID else { return }
        stopRecordingAndProcess()
    }

    private func handlePrimaryCancelled() {
        guard phase == .recording, let sessionID = currentSessionID, holdOwnerSessionID == sessionID else { return }
        cancel()
    }

    /// Starts a session through the menu or a registered shortcut. Capture mode deliberately
    /// blocks this entry point as well as dispatched shortcut actions.
    func startRecording() {
        guard !isCapturingShortcut, !isQuitting else { return }
        guard currentAPIKey() != nil else {
            errorMessage = "Add a Groq API key in Settings before recording."
            openSettingsWindow()
            return
        }

        guard AudioRecorder.permissionStatus == .authorized else {
            Task { [weak self] in
                guard let self else { return }
                let granted = await AudioRecorder.requestPermissionIfNeeded()
                self.microphonePermission = AudioRecorder.permissionStatus
                self.errorMessage = granted
                    ? "Microphone access granted. Refocus your destination and press the shortcut again."
                    : AudioRecorder.RecorderError.microphonePermissionDenied.localizedDescription
            }
            return
        }

        let target = textInserter.captureTarget()
        let sessionID = UUID()
        currentSessionID = sessionID
        pendingTarget = target
        errorMessage = nil
        rawResult = nil
        finalResult = nil
        lastInsertionOutcome = nil

        do {
            audioRecorder.onAutoStopReached = { [weak self] in
                self?.stopRecordingAndProcess()
            }
            try audioRecorder.start()
            phase = .recording
            sessionInputKind = .handsFree
            recordingPanel.show(model: self, on: NSScreen.main)
        } catch {
            phase = .failed
            errorMessage = error.localizedDescription
            currentSessionID = nil
        }
    }

    func stopRecordingAndProcess() {
        guard phase == .recording, let sessionID = currentSessionID else { return }
        // Any path that stops this session — physical release, auto-stop, the dedicated
        // toggle, or the menu button — ends hold ownership here so a later physical release
        // of a hold-to-talk press is a no-op.
        if holdOwnerSessionID == sessionID { holdOwnerSessionID = nil }
        audioRecorder.onAutoStopReached = nil

        let url: URL
        do {
            url = try audioRecorder.stop()
        } catch {
            phase = .failed
            errorMessage = error.localizedDescription
            scheduleHUDDismiss(sessionID: sessionID)
            return
        }

        guard let apiKey = currentAPIKey() else {
            phase = .failed
            errorMessage = "Add a Groq API key in Settings before recording."
            audioRecorder.cleanupFile(at: url)
            scheduleHUDDismiss(sessionID: sessionID)
            return
        }

        let language = inputLanguage
        let cleanUp = cleanUpTranscript
        let vocabulary = DictionaryTerms.normalizedVocabulary(customVocabulary)
        let snippets = voiceSnippets
        let target = pendingTarget
        activeAudioURL = url
        phase = .transcribing

        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.handlePipeline(
                sessionID: sessionID,
                audioURL: url,
                language: language,
                cleanUp: cleanUp,
                vocabulary: vocabulary,
                snippets: snippets,
                apiKey: apiKey,
                target: target
            )
            if self.activeAudioURL == url {
                self.audioRecorder.cleanupFile(at: url)
                self.activeAudioURL = nil
            }
        }
    }

    private func handlePipeline(
        sessionID: UUID,
        audioURL: URL,
        language: InputLanguage,
        cleanUp: Bool,
        vocabulary: String,
        snippets: [VoiceSnippet],
        apiKey: String,
        target: InsertionTarget?
    ) async {
        do {
            let transcript = try await groqClient.transcribe(audioURL: audioURL, language: language, vocabulary: vocabulary, apiKey: apiKey)
            guard sessionID == currentSessionID, !Task.isCancelled else { return }
            rawResult = transcript

            var textToInsert = transcript

            if let expansion = SnippetExpander.expansion(for: transcript, snippets: snippets) {
                finalResult = expansion
                textToInsert = expansion
            } else if cleanUp {
                phase = .normalizing
                do {
                    let processed = try await groqClient.normalize(transcript: transcript, vocabulary: vocabulary, apiKey: apiKey)
                    guard sessionID == currentSessionID, !Task.isCancelled else { return }
                    finalResult = processed
                    textToInsert = processed
                } catch {
                    guard sessionID == currentSessionID, !Task.isCancelled else { return }
                    phase = .failed
                    errorMessage = "Text processing failed — original transcript available"
                    lastResult = transcript
                    scheduleHUDDismiss(sessionID: sessionID)
                    return
                }
            } else {
                finalResult = transcript
            }

            guard sessionID == currentSessionID, !Task.isCancelled else { return }
            phase = .inserting

            if let target {
                let outcome = await textInserter.insert(textToInsert, into: target)
                guard sessionID == currentSessionID else { return }
                applyInsertionOutcome(outcome)
            } else {
                applyInsertionOutcome(.manualCopyRequired(textToInsert))
            }

            guard sessionID == currentSessionID else { return }
            if !textToInsert.isEmpty {
                lastResult = textToInsert
            }
            phase = .ready
            recordingPanel.hide()
        } catch is CancellationError {
            return
        } catch {
            guard sessionID == currentSessionID, !Task.isCancelled else { return }
            phase = .failed
            errorMessage = error.localizedDescription
            scheduleHUDDismiss(sessionID: sessionID)
        }
    }

    /// Cancels an in-progress recording or pipeline. A single synchronous insertion that has
    /// already completed cannot be retracted; cancellation only prevents work still in flight.
    public func cancel() {
        holdOwnerSessionID = nil
        switch phase {
        case .recording:
            audioRecorder.onAutoStopReached = nil
            audioRecorder.cancel()
            resetToIdleAfterCancel()
        case .transcribing, .normalizing, .inserting:
            processingTask?.cancel()
            processingTask = nil
            if let url = activeAudioURL {
                audioRecorder.cleanupFile(at: url)
                activeAudioURL = nil
            }
            resetToIdleAfterCancel()
        case .idle, .ready, .failed:
            break
        }
    }

    private func resetToIdleAfterCancel() {
        currentSessionID = nil
        pendingTarget = nil
        phase = .idle
        errorMessage = nil
        recordingPanel.hide()
    }

    /// Failure-only dismissal: a successful session hides the HUD immediately (see
    /// `handlePipeline`/`pasteLastResult`), so this is only ever scheduled after a failure,
    /// leaving the error visible for a few seconds before it clears.
    private func scheduleHUDDismiss(sessionID: UUID) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self else { return }
            guard sessionID == self.currentSessionID else { return }
            guard self.phase == .failed else { return }
            self.recordingPanel.hide()
        }
    }

    // MARK: - Copy / paste last result

    /// Copies `lastResult` to the clipboard. A no-op without a saved result, or while any
    /// session is recording/processing/inserting.
    public func copyLastResult() {
        guard !isSessionActive, let text = lastResult, !text.isEmpty else { return }
        writeToPasteboard(text)
    }

    /// Inserts `lastResult` into whatever is focused right now, via the same guarded
    /// Accessibility-write/paste-fallback/manual-copy path as the main pipeline. Performs no
    /// ASR or text-processing call. A no-op without a saved result, or while any session is
    /// recording/processing/inserting.
    public func pasteLastResult() {
        guard !isSessionActive, let text = lastResult, !text.isEmpty else { return }
        // Captured synchronously, before any UI change, so a focus change afterward is
        // caught by TextInserter's own re-verification rather than racing this call.
        let target = textInserter.captureTarget()

        let sessionID = UUID()
        currentSessionID = sessionID
        phase = .inserting

        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard sessionID == self.currentSessionID else { return }
            if let target {
                let outcome = await self.textInserter.insert(text, into: target)
                guard sessionID == self.currentSessionID else { return }
                self.applyInsertionOutcome(outcome)
            } else {
                self.applyInsertionOutcome(.manualCopyRequired(text))
            }
            guard sessionID == self.currentSessionID else { return }
            self.phase = .ready
            self.recordingPanel.hide()
        }
    }

    private func writeToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(text, forType: .string)
    }

    /// Records the outcome and, when insertion wasn't possible, writes the text to the
    /// clipboard immediately so the user only needs a plain ⌘V rather than an extra explicit
    /// Copy step. Safe to call for a `.manualCopyRequired` that already wrote the clipboard
    /// itself (`TextInserter.pasteFallback`'s ambiguous-failure case): the write is idempotent.
    private func applyInsertionOutcome(_ outcome: InsertionOutcome) {
        lastInsertionOutcome = outcome
        if case .manualCopyRequired(let text) = outcome {
            writeToPasteboard(text)
        }
    }

    // MARK: - Voice snippets

    private static func loadSnippets(from defaults: UserDefaults) -> (list: [VoiceSnippet], error: String?) {
        guard let data = defaults.data(forKey: Keys.voiceSnippets) else { return ([], nil) }
        do {
            let list = try JSONDecoder().decode([VoiceSnippet].self, from: data)
            return (list, nil)
        } catch {
            return ([], "Saved snippets could not be read: \(error.localizedDescription)")
        }
    }

    private func persistSnippets(_ snippets: [VoiceSnippet]) -> Bool {
        guard let data = try? JSONEncoder().encode(snippets) else { return false }
        defaults.set(data, forKey: Keys.voiceSnippets)
        return true
    }

    /// Saves a new or edited snippet. Rejects a blank normalized trigger, a blank replacement
    /// body, or a trigger that (after normalization) duplicates another saved snippet. On any
    /// rejection or encoding failure, the previously saved list is left unchanged and
    /// `snippetError` explains why.
    @discardableResult
    func saveSnippet(_ snippet: VoiceSnippet) -> Bool {
        guard !snippetsLoadFailed else {
            snippetError = "Saved snippets could not be read. Use Reset Snippets before adding new ones."
            return false
        }

        let normalizedTrigger = SnippetExpander.normalizedTrigger(snippet.trigger)
        guard !normalizedTrigger.isEmpty else {
            snippetError = "The trigger phrase can't be empty."
            return false
        }
        guard !snippet.replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            snippetError = "The replacement text can't be empty."
            return false
        }
        let isDuplicate = voiceSnippets.contains {
            $0.id != snippet.id && SnippetExpander.normalizedTrigger($0.trigger) == normalizedTrigger
        }
        guard !isDuplicate else {
            snippetError = "Another snippet already uses that trigger phrase."
            return false
        }

        var updated = voiceSnippets
        if let index = updated.firstIndex(where: { $0.id == snippet.id }) {
            updated[index] = snippet
        } else {
            updated.append(snippet)
        }

        guard persistSnippets(updated) else {
            snippetError = "Could not save the snippet."
            return false
        }
        voiceSnippets = updated
        snippetError = nil
        return true
    }

    func deleteSnippet(id: UUID) {
        guard !snippetsLoadFailed else {
            snippetError = "Saved snippets could not be read. Use Reset Snippets before deleting."
            return
        }
        let updated = voiceSnippets.filter { $0.id != id }
        guard persistSnippets(updated) else {
            snippetError = "Could not delete the snippet."
            return
        }
        voiceSnippets = updated
        snippetError = nil
    }

    /// Discards saved snippet data (including any unreadable data left from a prior malformed
    /// write) and persists an empty list. The only way to clear a load failure.
    func resetSnippets() {
        guard persistSnippets([]) else {
            snippetError = "Could not reset snippets."
            return
        }
        voiceSnippets = []
        snippetsLoadFailed = false
        snippetError = nil
    }

    // MARK: - API key

    private func currentAPIKey() -> String? {
        do {
            let key = try apiKeyStore.loadAPIKey()?.trimmingCharacters(in: .whitespacesAndNewlines)
            keychainError = nil
            hasAPIKey = (key?.isEmpty == false)
            return (key?.isEmpty == false) ? key : nil
        } catch {
            keychainError = error.localizedDescription
            return nil
        }
    }

    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            keychainError = "The API key is empty."
            return
        }
        do {
            try apiKeyStore.saveAPIKey(trimmed)
            hasAPIKey = true
            keychainError = nil
        } catch {
            keychainError = error.localizedDescription
        }
    }

    func removeAPIKey() {
        do {
            try apiKeyStore.removeAPIKey()
            hasAPIKey = false
            keychainError = nil
        } catch {
            keychainError = error.localizedDescription
        }
    }

    // MARK: - Permissions

    func refreshPermissionStatuses() {
        microphonePermission = AudioRecorder.permissionStatus
        accessibilityTrusted = AXIsProcessTrusted()
        inputMonitoringGranted = FnKeyMonitor.inputMonitoringGranted()
    }

    func requestMicrophonePermission() {
        Task { [weak self] in
            guard let self else { return }
            _ = await AudioRecorder.requestPermissionIfNeeded()
            self.microphonePermission = AudioRecorder.permissionStatus
        }
    }

    func requestAccessibilityPermission() {
        // kAXTrustedCheckOptionPrompt's CFString value is documented as this literal; using
        // the literal avoids touching the non-Sendable global symbol under strict concurrency.
        let options: [String: Any] = ["AXTrustedCheckOptionPrompt": true]
        accessibilityTrusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        // macOS only shows that system prompt once per denial; once it stops appearing, this
        // is the only remaining way for the user to reach the toggle.
        if !accessibilityTrusted {
            Self.openPrivacySettingsPane(anchor: "Privacy_Accessibility")
        }
    }

    func requestInputMonitoringPermission() {
        _ = FnKeyMonitor.requestInputMonitoringPermission()
        inputMonitoringGranted = FnKeyMonitor.inputMonitoringGranted()
        if !inputMonitoringGranted {
            Self.openPrivacySettingsPane(anchor: "Privacy_ListenEvent")
        }
        if hotkeyTrigger == .fn {
            reconfigureShortcuts()
        }
    }

    private static func openPrivacySettingsPane(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Shortcuts

    private static func loadCustomShortcut(from defaults: UserDefaults) -> KeyboardShortcut? {
        guard let data = defaults.data(forKey: Keys.customShortcut),
              let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data),
              shortcut.validationError == nil else {
            return nil
        }
        return shortcut
    }

    @discardableResult
    func saveCustomShortcut(_ shortcut: KeyboardShortcut) -> Bool {
        guard !isSessionActive else {
            shortcutSettingsError = "Finish dictation before changing the shortcut."
            return false
        }
        if let validationError = shortcut.validationError {
            shortcutSettingsError = validationError
            return false
        }
        guard let data = try? JSONEncoder().encode(shortcut) else {
            shortcutSettingsError = "Could not save the shortcut."
            return false
        }

        defaults.set(data, forKey: Keys.customShortcut)
        customShortcut = shortcut
        shortcutSettingsError = nil
        if hotkeyTrigger == .custom {
            reconfigureShortcuts()
        } else {
            hotkeyTrigger = .custom
        }
        return true
    }

    func beginShortcutCapture() -> Bool {
        guard !isSessionActive, !isCapturingShortcut, !isQuitting else { return false }
        isCapturingShortcut = true
        holdOwnerSessionID = nil
        hotkeyManager.unregister()
        escapeAvailable = false
        hotkeyError = nil
        return true
    }

    func endShortcutCapture() {
        guard isCapturingShortcut else { return }
        isCapturingShortcut = false
        reconfigureShortcuts()
    }

    private func reconfigureShortcuts() {
        guard !isCapturingShortcut, !isQuitting else { return }
        holdOwnerSessionID = nil
        hotkeyManager.configure(trigger: hotkeyTrigger, mode: recordingMode, customShortcut: customShortcut)
        updateEscapeAvailability()
    }

    /// Escape is only ever registered while a session is actually in flight, so it can never
    /// be "stolen" from other apps while T-Whisper is idle.
    private func updateEscapeAvailability() {
        guard !isCapturingShortcut, !isQuitting else {
            escapeAvailable = false
            return
        }
        let shouldEnable: Bool
        switch phase {
        case .recording, .transcribing, .normalizing, .inserting: shouldEnable = true
        case .idle, .ready, .failed: shouldEnable = false
        }
        hotkeyManager.setCancellationEnabled(shouldEnable)
        escapeAvailable = hotkeyManager.cancellationEnabled
        updateHotkeyError()
    }

    private func updateHotkeyError() {
        let messages = hotkeyManager.registrationErrors.compactMap { $0.errorDescription }
        hotkeyError = messages.isEmpty ? nil : messages.joined(separator: " ")
    }
    // MARK: - App lifecycle

    func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    public func prepareForQuit() {
        isQuitting = true
        isCapturingShortcut = false
        hotkeyManager.unregister()
        processingTask?.cancel()
        processingTask = nil
        holdOwnerSessionID = nil
        switch phase {
        case .recording:
            audioRecorder.cancel()
        default:
            if let url = activeAudioURL {
                audioRecorder.cleanupFile(at: url)
                activeAudioURL = nil
            }
        }
        currentSessionID = nil
    }
}

#if DEBUG
extension AppModel {
    /// Test-only seam: places the model directly into an active recording session without
    /// touching real audio hardware or system permissions. Only compiled into debug builds
    /// (`swift test`), never into the release `.app` bundle produced by `scripts/build-app.sh`.
    /// `asHold` associates the session with hold-to-talk ownership, so
    /// `handleShortcutAction(.primaryReleased/.primaryCancelled)` can be exercised without a
    /// real hotkey backend.
    func debugBeginRecordingSession(target: InsertionTarget?, asHold: Bool = false) -> UUID {
        let sessionID = UUID()
        currentSessionID = sessionID
        pendingTarget = target
        errorMessage = nil
        rawResult = nil
        finalResult = nil
        lastInsertionOutcome = nil
        phase = .recording
        sessionInputKind = asHold ? .hold : .handsFree
        holdOwnerSessionID = asHold ? sessionID : nil
        return sessionID
    }

    var debugCurrentSessionID: UUID? { currentSessionID }
    var debugHoldOwnerSessionID: UUID? { holdOwnerSessionID }

    /// Awaits the in-flight pipeline task, if any, so tests can observe its final state
    /// deterministically instead of sleeping.
    func debugWaitForPipeline() async {
        await processingTask?.value
    }
}
#endif
