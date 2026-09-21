import Foundation
import ApplicationServices

/// Language hint sent to Groq's transcription endpoint.
enum InputLanguage: String, CaseIterable, Identifiable, Codable {
    case thai
    case english

    var id: String { rawValue }

    /// ISO-639-1 code sent as the `language` form field.
    var groqLanguageCode: String {
        switch self {
        case .thai: return "th"
        case .english: return "en"
        }
    }

    var displayName: String {
        switch self {
        case .thai: return "Thai"
        case .english: return "English"
        }
    }

    var explanation: String {
        switch self {
        case .thai:
            return "Best for Thai-dominant speech mixed with English terms."
        case .english:
            return "Best for English-only dictation."
        }
    }
}

/// Lifecycle of one dictation session. Error text and the last result are tracked
/// separately from the phase itself.
public enum DictationPhase: Equatable {
    case idle
    case recording
    case transcribing
    case normalizing
    case inserting
    case ready
    case failed
}

/// Outcome of attempting to deliver text into the user's focused field.
public enum InsertionOutcome: Equatable {
    /// Text was written directly via the Accessibility API. Verified insertion.
    case inserted
    /// A paste keystroke sequence was posted. Not acknowledged by the receiving app.
    case pasteSent
    /// Neither path was safe/possible; the text is returned for an explicit Copy action.
    /// Does not imply the clipboard was written — callers must copy it themselves.
    case manualCopyRequired(String)
}

/// A captured destination for text insertion: the app process, its focused AX element at
/// capture time, and the selected text range if the element exposed one. `element` is `nil`
/// when the app never exposed a focused element via Accessibility at all (e.g. Dia and other
/// Arc-family browsers) — `TextInserter` then only has the app itself to gate a blind paste.
struct InsertionTarget {
    let pid: pid_t
    let element: AXUIElement?
    let selectedRange: CFRange?
}

/// Which global input toggles a dictation session.
enum HotkeyTrigger: String, CaseIterable, Identifiable, Codable {
    case fn
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fn: return "Fn key"
        case .custom: return "Custom shortcut"
        }
    }

    func explanation(for mode: RecordingMode) -> String {
        let action: String
        switch mode {
        case .toggle: action = "Press to start, then press again to finish."
        case .holdToTalk: action = "Hold to record, then release to finish."
        }
        switch self {
        case .fn:
            return "\(action) Fn must be pressed alone; Fn chords such as Fn-Delete or brightness keys are ignored. Requires Input Monitoring access."
        case .custom:
            return "\(action) No extra permission required."
        }
    }
}

/// Failure modes shared by both global-shortcut backends (Carbon hotkey combos and the Fn
/// event tap), so `AppModel` can surface either through one `hotkeyError` string.
enum ShortcutRegistrationError: LocalizedError {
    case comboConflict(shortcut: String)
    case comboRegistrationFailed(shortcut: String, status: OSStatus)
    case comboHandlerInstallFailed(shortcut: String, status: OSStatus)
    case invalidCustomShortcut
    case inputMonitoringNotGranted
    case eventTapCreationFailed

    var errorDescription: String? {
        switch self {
        case .comboConflict(let shortcut):
            return "\(shortcut) is already registered by another app. Use the menu bar item to start/stop recording instead."
        case .comboRegistrationFailed(let shortcut, let status):
            return "Failed to register \(shortcut) (status \(status))."
        case .comboHandlerInstallFailed(let shortcut, let status):
            return "Failed to install the \(shortcut) event handler (status \(status))."
        case .invalidCustomShortcut:
            return "Set a valid custom shortcut in Settings."
        case .inputMonitoringNotGranted:
            return "Fn key shortcut needs Input Monitoring access. Grant it in Settings, then reselect Fn key."
        case .eventTapCreationFailed:
            return "Failed to listen for the Fn key. Use the menu bar item to start/stop recording instead."
        }
    }
}

/// Pure helper for the manual personal-dictionary field: splits on commas/newlines, trims,
/// and deduplicates case-insensitively while keeping the first exact spelling.
enum DictionaryTerms {
    static func normalizedVocabulary(_ text: String) -> String {
        let entries = text
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var seenLowercased = Set<String>()
        var result: [String] = []
        for entry in entries {
            let key = entry.lowercased()
            if seenLowercased.insert(key).inserted {
                result.append(entry)
            }
        }
        return result.joined(separator: ", ")
    }
}

/// Which physical gesture starts/stops a dictation session on the primary trigger.
/// Auxiliary shortcuts (copy/paste last result, Escape) are unaffected.
enum RecordingMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case toggle
    case holdToTalk

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .toggle: return "Toggle"
        case .holdToTalk: return "Hold to talk"
        }
    }

    var explanation: String {
        switch self {
        case .toggle: return "Press the trigger once to start, again to stop."
        case .holdToTalk: return "Hold the trigger down to record; release it to stop."
        }
    }
}

/// A user-defined spoken cue that expands verbatim to fixed text, entirely locally — the
/// replacement body is never sent to Groq.
struct VoiceSnippet: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var trigger: String
    var replacement: String
}

/// Actions dispatched by either global-shortcut backend. `AppModel.handleShortcutAction`
/// is the single entry point that interprets these against the current session state.
enum ShortcutAction {
    case primaryPressed
    case primaryReleased
    case primaryCancelled
    case toggleRecording
    case cancel
    case copyLast
    case pasteLast
}
