import Foundation
import AppKit

/// Seams `AppModel` depends on, so pipeline logic (session guarding, cancellation, insertion
/// gating) can be exercised with fakes instead of real audio hardware, AX targets, or network
/// calls. Production code always uses the concrete types (`AudioRecorder`, `GroqClient`,
/// `TextInserter`, `HotkeyManager`, `RecordingPanel`, `SystemKeychainStore`); tests substitute
/// fakes via `AppModel`'s internal init.
@MainActor
protocol AudioCapturing: AnyObject {
    var isRecording: Bool { get }
    var currentLevel: Float { get }
    var elapsed: TimeInterval { get }
    /// Called at most once per recording when the hard duration cap is hit.
    var onAutoStopReached: (() -> Void)? { get set }
    /// Called on every metering tick so observers can republish `currentLevel`/`elapsed`.
    var onMeterUpdate: (() -> Void)? { get set }

    func start() throws
    func stop() throws -> URL
    func cancel()
    func cleanupFile(at url: URL)
}

@MainActor
protocol TextInserting: AnyObject {
    func captureTarget() -> InsertionTarget?
    func insert(_ text: String, into target: InsertionTarget) async -> InsertionOutcome
}

protocol DictationTranscribing: Sendable {
    func transcribe(audioURL: URL, language: InputLanguage, vocabulary: String, apiKey: String) async throws -> String
    func normalize(transcript: String, vocabulary: String, apiKey: String) async throws -> String
}

@MainActor
protocol HotkeyRegistering: AnyObject {
    var onAction: ((ShortcutAction) -> Void)? { get set }
    var registrationErrors: [ShortcutRegistrationError] { get }
    /// Whether Escape is actually registered right now, not merely requested.
    var cancellationEnabled: Bool { get }
    func configure(trigger: HotkeyTrigger, mode: RecordingMode, customShortcut: KeyboardShortcut?)
    func setCancellationEnabled(_ enabled: Bool)
    func unregister()
}

@MainActor
protocol RecordingHUDPresenting: AnyObject {
    func show(model: AppModel, on screen: NSScreen?)
    func hide()
}

/// Abstraction over Groq API key persistence, so pipeline tests never touch the real
/// keychain (which may prompt for access when read by a different signing identity, e.g.
/// the test bundle).
protocol APIKeyStoring {
    func loadAPIKey() throws -> String?
    func saveAPIKey(_ key: String) throws
    func removeAPIKey() throws
}

struct SystemKeychainStore: APIKeyStoring {
    func loadAPIKey() throws -> String? { try KeychainStore.loadAPIKey() }
    func saveAPIKey(_ key: String) throws { try KeychainStore.saveAPIKey(key) }
    func removeAPIKey() throws { try KeychainStore.removeAPIKey() }
}

extension AudioRecorder: AudioCapturing {}
extension TextInserter: TextInserting {}
extension GroqClient: DictationTranscribing {}
extension RecordingPanel: RecordingHUDPresenting {}
