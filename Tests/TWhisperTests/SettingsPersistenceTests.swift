import Testing
import Foundation
import Carbon
@testable import TWhisperKit

@Test @MainActor
func cleanUpTranscriptDefaultsOnAndMigratesLegacyDoubleOptOut() {
    let (freshDefaults, cleanupFresh) = makeIsolatedDefaults()
    defer { cleanupFresh() }
    #expect(makeTestModel(defaults: freshDefaults).cleanUpTranscript)

    let (legacyDefaults, cleanupLegacy) = makeIsolatedDefaults()
    defer { cleanupLegacy() }
    legacyDefaults.set(true, forKey: "hasLaunchedBefore")
    legacyDefaults.set(false, forKey: "normalizeEnglishTerms")
    legacyDefaults.set(false, forKey: "smartFormatting")

    let migrated = makeTestModel(defaults: legacyDefaults)
    #expect(!migrated.cleanUpTranscript)
    #expect(legacyDefaults.object(forKey: "normalizeEnglishTerms") == nil)
    #expect(legacyDefaults.object(forKey: "smartFormatting") == nil)
    #expect(!makeTestModel(defaults: legacyDefaults).cleanUpTranscript)
}

@Test @MainActor
func dictationSettingsSurviveRecreationWithSameDefaults() {
    let (defaults, cleanup) = makeIsolatedDefaults()
    defer { cleanup() }

    let first = makeTestModel(defaults: defaults)
    first.recordingMode = .holdToTalk
    first.cleanUpTranscript = false
    first.customVocabulary = "Alex, Groq"

    let second = makeTestModel(defaults: defaults)
    #expect(second.recordingMode == .holdToTalk)
    #expect(!second.cleanUpTranscript)
    #expect(second.customVocabulary == "Alex, Groq")
}

@Test @MainActor
func customShortcutAndRecordingModeSurviveRecreationAndPresetsRetainShortcut() {
    let (defaults, cleanup) = makeIsolatedDefaults()
    defer { cleanup() }
    let shortcut = KeyboardShortcut(
        keyCode: UInt32(kVK_ANSI_D),
        modifiers: UInt32(controlKey | optionKey)
    )

    let first = makeTestModel(defaults: defaults)
    #expect(first.saveCustomShortcut(shortcut))
    first.recordingMode = .holdToTalk
    first.hotkeyTrigger = .fn
    first.hotkeyTrigger = .custom

    let second = makeTestModel(defaults: defaults)
    #expect(second.hotkeyTrigger == .custom)
    #expect(second.customShortcut == shortcut)
    #expect(second.recordingMode == .holdToTalk)

    #expect(!second.saveCustomShortcut(.copyLast))
    #expect(second.customShortcut == shortcut)
    #expect(second.hotkeyTrigger == .custom)
}

@Test @MainActor
func malformedCustomShortcutFallsBackWithoutOverwritingStoredData() {
    let (defaults, cleanup) = makeIsolatedDefaults()
    defer { cleanup() }
    let malformed = Data("not json".utf8)
    defaults.set(malformed, forKey: "customShortcut")
    defaults.set(HotkeyTrigger.custom.rawValue, forKey: "hotkeyTrigger")

    let model = makeTestModel(defaults: defaults)

    #expect(model.hotkeyTrigger == .fn)
    #expect(model.customShortcut == nil)
    #expect(model.shortcutSettingsError != nil)
    #expect(defaults.data(forKey: "customShortcut") == malformed)
}

@Test @MainActor
func savedSnippetsSurviveRecreationWithSameDefaults() {
    let (defaults, cleanup) = makeIsolatedDefaults()
    defer { cleanup() }

    let first = makeTestModel(defaults: defaults)
    let saved = first.saveSnippet(VoiceSnippet(id: UUID(), trigger: "my email", replacement: "alex@example.com"))
    #expect(saved)

    let second = makeTestModel(defaults: defaults)
    #expect(second.voiceSnippets.count == 1)
    #expect(second.voiceSnippets.first?.trigger == "my email")
    #expect(second.voiceSnippets.first?.replacement == "alex@example.com")
}

@Test @MainActor
func malformedStoredSnippetsSurfaceErrorWithoutOverwritingData() {
    let (defaults, cleanup) = makeIsolatedDefaults()
    defer { cleanup() }
    defaults.set(Data("not valid json".utf8), forKey: "voiceSnippets")

    let model = makeTestModel(defaults: defaults)
    #expect(model.voiceSnippets.isEmpty)
    #expect(model.snippetError != nil)

    // Saving is refused until the user explicitly resets, so the unreadable data isn't
    // silently discarded by an unrelated save.
    let saved = model.saveSnippet(VoiceSnippet(id: UUID(), trigger: "new", replacement: "text"))
    #expect(!saved)
    #expect(model.voiceSnippets.isEmpty)

    model.resetSnippets()
    #expect(model.snippetError == nil)
    let savedAfterReset = model.saveSnippet(VoiceSnippet(id: UUID(), trigger: "new", replacement: "text"))
    #expect(savedAfterReset)
    #expect(model.voiceSnippets.count == 1)
}

@Test @MainActor
func saveSnippetRejectsBlankTriggerBlankReplacementAndDuplicateTrigger() {
    let (defaults, cleanup) = makeIsolatedDefaults()
    defer { cleanup() }
    let model = makeTestModel(defaults: defaults)

    #expect(!model.saveSnippet(VoiceSnippet(id: UUID(), trigger: "   ", replacement: "text")))
    #expect(!model.saveSnippet(VoiceSnippet(id: UUID(), trigger: "trigger", replacement: "   ")))
    #expect(model.voiceSnippets.isEmpty)

    #expect(model.saveSnippet(VoiceSnippet(id: UUID(), trigger: "hello", replacement: "world")))
    #expect(!model.saveSnippet(VoiceSnippet(id: UUID(), trigger: "Hello.", replacement: "world again")))
    #expect(model.voiceSnippets.count == 1)
}

@Test @MainActor
func deletingLastSnippetPersistsEmptyListNotMissingPreference() {
    let (defaults, cleanup) = makeIsolatedDefaults()
    defer { cleanup() }
    let model = makeTestModel(defaults: defaults)
    let id = UUID()
    _ = model.saveSnippet(VoiceSnippet(id: id, trigger: "hello", replacement: "world"))
    model.deleteSnippet(id: id)

    #expect(model.voiceSnippets.isEmpty)
    #expect(defaults.data(forKey: "voiceSnippets") != nil)

    let recreated = makeTestModel(defaults: defaults)
    #expect(recreated.voiceSnippets.isEmpty)
    #expect(recreated.snippetError == nil)
}

@Test @MainActor
func dictionaryTermsNormalizationTrimsDeduplicatesAndJoins() {
    #expect(DictionaryTerms.normalizedVocabulary("Alex, alex\nGroq,  , Slack") == "Alex, Groq, Slack")
    #expect(DictionaryTerms.normalizedVocabulary("") == "")
    #expect(DictionaryTerms.normalizedVocabulary("  \n , ,") == "")
}
