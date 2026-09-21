import Foundation
import AppKit
@testable import TWhisperKit

@MainActor
final class FakeAudioRecorder: AudioCapturing {
    var isRecording = false
    var currentLevel: Float = 0
    var elapsed: TimeInterval = 0
    var onAutoStopReached: (() -> Void)?
    var onMeterUpdate: (() -> Void)?

    var stopResult: Result<URL, Error> = .success(URL(fileURLWithPath: "/tmp/fake.wav"))
    var startError: Error?
    var cleanupCallCount = 0
    var cancelCallCount = 0

    func start() throws {
        if let startError { throw startError }
        isRecording = true
    }

    func stop() throws -> URL {
        isRecording = false
        switch stopResult {
        case .success(let url): return url
        case .failure(let error): throw error
        }
    }

    func cancel() {
        cancelCallCount += 1
        isRecording = false
    }

    func cleanupFile(at url: URL) {
        cleanupCallCount += 1
    }
}

/// Fake Groq backend. Each response is a `Result`, consumed synchronously (no real network).
/// An optional delay lets tests interleave cancellation with in-flight work.
final actor FakeGroqBackend: DictationTranscribing {
    var transcribeResult: Result<String, Error> = .success("transcript")
    var normalizeResult: Result<String, Error> = .success("normalized")
    var transcribeDelayNanoseconds: UInt64 = 0
    var normalizeDelayNanoseconds: UInt64 = 0
    private(set) var transcribeCallCount = 0
    private(set) var normalizeCallCount = 0

    func setTranscribeResult(_ result: Result<String, Error>) { transcribeResult = result }
    func setNormalizeResult(_ result: Result<String, Error>) { normalizeResult = result }
    func setTranscribeDelay(nanoseconds: UInt64) { transcribeDelayNanoseconds = nanoseconds }

    func transcribe(audioURL: URL, language: InputLanguage, vocabulary: String, apiKey: String) async throws -> String {
        transcribeCallCount += 1
        if transcribeDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: transcribeDelayNanoseconds)
        }
        switch transcribeResult {
        case .success(let text): return text
        case .failure(let error): throw error
        }
    }

    func normalize(transcript: String, vocabulary: String, apiKey: String) async throws -> String {
        normalizeCallCount += 1
        if normalizeDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: normalizeDelayNanoseconds)
        }
        switch normalizeResult {
        case .success(let text): return text
        case .failure(let error): throw error
        }
    }
}

@MainActor
final class FakeTextInserter: TextInserting {
    var targetToCapture: InsertionTarget?
    var insertOutcome: InsertionOutcome = .inserted
    private(set) var insertCallCount = 0
    private(set) var lastInsertedText: String?

    func captureTarget() -> InsertionTarget? { targetToCapture }

    func insert(_ text: String, into target: InsertionTarget) async -> InsertionOutcome {
        insertCallCount += 1
        lastInsertedText = text
        return insertOutcome
    }
}

@MainActor
final class NoOpHotkeyManager: HotkeyRegistering {
    var onAction: ((ShortcutAction) -> Void)?
    private(set) var registrationErrors: [ShortcutRegistrationError] = []
    private(set) var cancellationEnabled = false
    private(set) var configureCallCount = 0
    private(set) var lastConfiguredTrigger: HotkeyTrigger?
    private(set) var lastConfiguredMode: RecordingMode?
    private(set) var lastConfiguredShortcut: KeyboardShortcut?

    func configure(trigger: HotkeyTrigger, mode: RecordingMode, customShortcut: KeyboardShortcut?) {
        configureCallCount += 1
        lastConfiguredTrigger = trigger
        lastConfiguredMode = mode
        lastConfiguredShortcut = customShortcut
    }
    func setCancellationEnabled(_ enabled: Bool) { cancellationEnabled = enabled }
    func unregister() {}
}

@MainActor
final class NoOpRecordingPanel: RecordingHUDPresenting {
    private(set) var showCallCount = 0
    private(set) var hideCallCount = 0
    func show(model: AppModel, on screen: NSScreen?) { showCallCount += 1 }
    func hide() { hideCallCount += 1 }
}

final class InMemoryAPIKeyStore: APIKeyStoring {
    var key: String? = "test-api-key"
    func loadAPIKey() throws -> String? { key }
    func saveAPIKey(_ key: String) throws { self.key = key }
    func removeAPIKey() throws { key = nil }
}

struct FakeError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
func makeTestModel(
    audioRecorder: FakeAudioRecorder = FakeAudioRecorder(),
    groqClient: FakeGroqBackend = FakeGroqBackend(),
    textInserter: FakeTextInserter = FakeTextInserter(),
    recordingPanel: NoOpRecordingPanel = NoOpRecordingPanel(),
    apiKeyStore: InMemoryAPIKeyStore = InMemoryAPIKeyStore(),
    defaults: UserDefaults
) -> AppModel {
    AppModel(
        audioRecorder: audioRecorder,
        groqClient: groqClient,
        textInserter: textInserter,
        hotkeyManager: NoOpHotkeyManager(),
        recordingPanel: recordingPanel,
        apiKeyStore: apiKeyStore,
        defaults: defaults
    )
}

/// Creates a fresh, isolated `UserDefaults` suite for one test, plus a cleanup closure that
/// removes its domain. Tests must never touch `.standard`.
func makeIsolatedDefaults() -> (defaults: UserDefaults, cleanup: () -> Void) {
    let suiteName = "app.twhisper.mac.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
}
