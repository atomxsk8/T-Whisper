import Testing
import Foundation
import ApplicationServices
@testable import TWhisperKit

@Test
func snippetWholeUtteranceMatchIgnoresCaseAndTrailingPunctuation() {
    let snippet = VoiceSnippet(id: UUID(), trigger: "my signature", replacement: "Best,\nAlex\nCEO, Acme")
    #expect(SnippetExpander.expansion(for: "My signature.", snippets: [snippet]) == snippet.replacement)
    #expect(SnippetExpander.expansion(for: "  MY   SIGNATURE  ", snippets: [snippet]) == snippet.replacement)
    #expect(SnippetExpander.expansion(for: "my signature!", snippets: [snippet]) == snippet.replacement)
}

@Test
func snippetNeverMatchesAsSubstringOfLongerSentence() {
    let snippet = VoiceSnippet(id: UUID(), trigger: "my signature", replacement: "Best,\nAlex")
    #expect(SnippetExpander.expansion(for: "Please change my signature.", snippets: [snippet]) == nil)
    #expect(SnippetExpander.expansion(for: "my signature please", snippets: [snippet]) == nil)
}

@Test
func snippetExpansionPreservesReplacementWhitespaceByteForByte() {
    let replacement = "Line one\n\nLine two with  double  spaces\tand a tab"
    let snippet = VoiceSnippet(id: UUID(), trigger: "boilerplate", replacement: replacement)
    #expect(SnippetExpander.expansion(for: "boilerplate", snippets: [snippet]) == replacement)
}

@Test
func snippetAmbiguousDuplicateMatchProducesNoExpansion() {
    let a = VoiceSnippet(id: UUID(), trigger: "my signature", replacement: "A")
    let b = VoiceSnippet(id: UUID(), trigger: "My Signature", replacement: "B")
    #expect(SnippetExpander.expansion(for: "my signature", snippets: [a, b]) == nil)
}

@Test
func emptySnippetListNeverExpands() {
    #expect(SnippetExpander.expansion(for: "anything", snippets: []) == nil)
}

@Test
func normalizedTriggerCollapsesInternalWhitespaceButKeepsInternalPunctuation() {
    #expect(SnippetExpander.normalizedTrigger("  Hello,   World!  ") == "hello, world")
    #expect(SnippetExpander.normalizedTrigger("Hello\tWorld\n") == "hello world")
}

@Test @MainActor
func matchingSnippetInsertsExactBodyWithoutProcessingDependency() async throws {
    // A snippet match must bypass text processing entirely: a failing fake normalize() must
    // never block insertion of the snippet's exact replacement.
    let (defaults, cleanup) = makeIsolatedDefaults()
    defer { cleanup() }
    let groq = FakeGroqBackend()
    await groq.setTranscribeResult(.success("my signature"))
    await groq.setNormalizeResult(.failure(FakeError(message: "processing should never be called")))
    let inserter = FakeTextInserter()
    inserter.insertOutcome = .inserted
    let model = makeTestModel(groqClient: groq, textInserter: inserter, defaults: defaults)
    model.cleanUpTranscript = true

    let saved = model.saveSnippet(VoiceSnippet(id: UUID(), trigger: "my signature", replacement: "Best,\nAlex"))
    #expect(saved)

    let target = InsertionTarget(pid: getpid(), element: AXUIElementCreateApplication(getpid()), selectedRange: nil)
    _ = model.debugBeginRecordingSession(target: target)
    model.stopRecordingAndProcess()
    await model.debugWaitForPipeline()

    let normalizeCalls = await groq.normalizeCallCount
    #expect(normalizeCalls == 0)
    #expect(inserter.insertCallCount == 1)
    #expect(inserter.lastInsertedText == "Best,\nAlex")
    #expect(model.phase == .ready)
    #expect(model.finalResult == "Best,\nAlex")
}
