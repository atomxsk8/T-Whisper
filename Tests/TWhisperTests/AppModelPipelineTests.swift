import Testing
import ApplicationServices
import Foundation
@testable import TWhisperKit

@MainActor
private func makeDummyTarget() -> InsertionTarget {
    InsertionTarget(pid: getpid(), element: AXUIElementCreateApplication(getpid()), selectedRange: nil)
}

@Test @MainActor
func successfulPipelineInsertsExactlyOnce() async throws {
    let (defaults, cleanup) = makeIsolatedDefaults()
    defer { cleanup() }
    let inserter = FakeTextInserter()
    inserter.insertOutcome = .inserted
    let model = makeTestModel(textInserter: inserter, defaults: defaults)
    model.cleanUpTranscript = false

    _ = model.debugBeginRecordingSession(target: makeDummyTarget())
    model.stopRecordingAndProcess()
    await model.debugWaitForPipeline()

    #expect(inserter.insertCallCount == 1)
    #expect(model.phase == .ready)
    #expect(model.lastInsertionOutcome == .inserted)
    #expect(model.lastResult == "transcript")
}

@Test @MainActor
func cancellationDuringPipelinePreventsInsertion() async throws {
    let (defaults, cleanup) = makeIsolatedDefaults()
    defer { cleanup() }
    let groq = FakeGroqBackend()
    await groq.setTranscribeDelay(nanoseconds: 100_000_000)
    let inserter = FakeTextInserter()
    let model = makeTestModel(groqClient: groq, textInserter: inserter, defaults: defaults)

    _ = model.debugBeginRecordingSession(target: makeDummyTarget())
    model.stopRecordingAndProcess()
    model.cancel()

    await model.debugWaitForPipeline()

    #expect(inserter.insertCallCount == 0)
    #expect(model.phase == .idle)
}

@Test @MainActor
func staleSessionCompletionNeverInserts() async throws {
    // Simulates a second recording starting (and finishing) before a stale in-flight
    // pipeline task from an earlier, cancelled session gets a chance to insert.
    let (defaults, cleanup) = makeIsolatedDefaults()
    defer { cleanup() }
    let groq = FakeGroqBackend()
    await groq.setTranscribeDelay(nanoseconds: 100_000_000)
    let inserter = FakeTextInserter()
    let model = makeTestModel(groqClient: groq, textInserter: inserter, defaults: defaults)

    let staleSessionID = model.debugBeginRecordingSession(target: makeDummyTarget())
    model.stopRecordingAndProcess()
    #expect(model.debugCurrentSessionID == staleSessionID)

    // A brand new session starts before the stale one's delayed transcribe() returns.
    let freshSessionID = model.debugBeginRecordingSession(target: makeDummyTarget())
    #expect(freshSessionID != staleSessionID)
    #expect(model.debugCurrentSessionID == freshSessionID)

    await model.debugWaitForPipeline()

    // Only the stale session's completion could have fired; it must have been rejected by
    // the session-ID guard.
    #expect(inserter.insertCallCount == 0)
}

@Test @MainActor
func staleSessionDuringPasteLastResultSkipsOutcome() async throws {
    // pasteLastResult() owns its own, independent copy of the currentSessionID guard
    // (separate from the main pipeline's). Starting a fresh recording session before its
    // insertion task runs makes its eventual completion stale, mirroring how
    // staleSessionCompletionNeverInserts() simulates staleness for the main pipeline.
    let (defaults, cleanup) = makeIsolatedDefaults()
    defer { cleanup() }
    let inserter = FakeTextInserter()
    inserter.targetToCapture = makeDummyTarget()
    let model = makeTestModel(textInserter: inserter, defaults: defaults)

    // Seed lastResult via one full successful pipeline run.
    _ = model.debugBeginRecordingSession(target: makeDummyTarget())
    model.stopRecordingAndProcess()
    await model.debugWaitForPipeline()
    #expect(model.lastResult == "transcript")
    let insertCallsAfterFirstRun = inserter.insertCallCount

    model.pasteLastResult()
    let staleSessionID = model.debugCurrentSessionID
    #expect(model.phase == .inserting)

    // A fresh recording session begins before pasteLastResult()'s own insertion task gets a
    // chance to run.
    let freshSessionID = model.debugBeginRecordingSession(target: makeDummyTarget())
    #expect(freshSessionID != staleSessionID)

    await model.debugWaitForPipeline()

    // The stale pasteLastResult() completion must be rejected by its own guard: it must
    // neither call the inserter again nor overwrite the outcome/phase owned by the fresh
    // session that has since taken over.
    #expect(inserter.insertCallCount == insertCallsAfterFirstRun)
    // debugBeginRecordingSession() already reset lastInsertionOutcome to nil for the fresh
    // session; the stale completion must not overwrite it with its own outcome.
    #expect(model.lastInsertionOutcome == nil)
    #expect(model.phase == .recording)
}

@Test @MainActor
func duplicateStopOnlyInsertsOnce() async throws {
    let (defaults, cleanup) = makeIsolatedDefaults()
    defer { cleanup() }
    let inserter = FakeTextInserter()
    inserter.insertOutcome = .inserted
    let model = makeTestModel(textInserter: inserter, defaults: defaults)

    _ = model.debugBeginRecordingSession(target: makeDummyTarget())
    model.stopRecordingAndProcess()
    model.stopRecordingAndProcess() // duplicate: phase is already .transcribing, must no-op

    await model.debugWaitForPipeline()

    #expect(inserter.insertCallCount == 1)
}

@Test @MainActor
func noSpeechDetectedNeverInserts() async throws {
    let (defaults, cleanup) = makeIsolatedDefaults()
    defer { cleanup() }
    let groq = FakeGroqBackend()
    await groq.setTranscribeResult(.failure(GroqClient.GroqError.noSpeechDetected))
    let inserter = FakeTextInserter()
    let model = makeTestModel(groqClient: groq, textInserter: inserter, defaults: defaults)

    _ = model.debugBeginRecordingSession(target: makeDummyTarget())
    model.stopRecordingAndProcess()
    await model.debugWaitForPipeline()

    #expect(inserter.insertCallCount == 0)
    #expect(model.phase == .failed)
}

@Test @MainActor
func invalidAPIKeyResponseNeverInserts() async throws {
    let (defaults, cleanup) = makeIsolatedDefaults()
    defer { cleanup() }
    let groq = FakeGroqBackend()
    await groq.setTranscribeResult(.failure(GroqClient.GroqError.invalidAPIKey(detail: nil)))
    let inserter = FakeTextInserter()
    let model = makeTestModel(groqClient: groq, textInserter: inserter, defaults: defaults)

    _ = model.debugBeginRecordingSession(target: makeDummyTarget())
    model.stopRecordingAndProcess()
    await model.debugWaitForPipeline()

    #expect(inserter.insertCallCount == 0)
    #expect(model.phase == .failed)
}

@Test @MainActor
func rateLimitedResponseNeverInserts() async throws {
    let (defaults, cleanup) = makeIsolatedDefaults()
    defer { cleanup() }
    let groq = FakeGroqBackend()
    await groq.setTranscribeResult(.failure(GroqClient.GroqError.rateLimited(retryAfter: 30)))
    let inserter = FakeTextInserter()
    let model = makeTestModel(groqClient: groq, textInserter: inserter, defaults: defaults)

    _ = model.debugBeginRecordingSession(target: makeDummyTarget())
    model.stopRecordingAndProcess()
    await model.debugWaitForPipeline()

    #expect(inserter.insertCallCount == 0)
    #expect(model.phase == .failed)
}

@Test @MainActor
func malformedNormalizationResponseNeverInsertsAndKeepsRawTranscript() async throws {
    let (defaults, cleanup) = makeIsolatedDefaults()
    defer { cleanup() }
    let groq = FakeGroqBackend()
    let transcript = "ส่งไฟล์เข้า Slack แล้ว deploy ขึ้น staging"
    await groq.setTranscribeResult(.success(transcript))
    await groq.setNormalizeResult(.failure(GroqClient.GroqError.normalizationMalformed))
    let inserter = FakeTextInserter()
    let model = makeTestModel(groqClient: groq, textInserter: inserter, defaults: defaults)
    model.cleanUpTranscript = true

    _ = model.debugBeginRecordingSession(target: makeDummyTarget())
    model.stopRecordingAndProcess()
    await model.debugWaitForPipeline()

    #expect(inserter.insertCallCount == 0)
    #expect(model.phase == .failed)
    #expect(model.rawResult == transcript)
    #expect(model.finalResult == nil)
    #expect(model.lastResult == transcript)
}

@Test @MainActor
func insertionWithoutVerifiedTargetYieldsManualCopy() async throws {
    // Exercises the real TextInserter (not a fake): with no Accessibility trust, or with the
    // dummy target's process not actually frontmost, `insert` must fail closed to manual copy
    // rather than posting a paste or guessing at a write.
    let inserter = TextInserter()
    let target = makeDummyTarget()

    let outcome = await inserter.insert("hello", into: target)

    guard case .manualCopyRequired(let text) = outcome else {
        Issue.record("expected manualCopyRequired for an unverified target, got \(outcome)")
        return
    }
    #expect(text == "hello")
}

@Test @MainActor
func cleanUpOffWithFailingProcessorStillInsertsRawTranscript() async throws {
    // With cleanUpTranscript off, no text-processing request should even happen — a failing
    // fake normalize() must never block raw insertion.
    let (defaults, cleanup) = makeIsolatedDefaults()
    defer { cleanup() }
    let groq = FakeGroqBackend()
    await groq.setNormalizeResult(.failure(GroqClient.GroqError.normalizationMalformed))
    let inserter = FakeTextInserter()
    inserter.insertOutcome = .inserted
    let model = makeTestModel(groqClient: groq, textInserter: inserter, defaults: defaults)
    model.cleanUpTranscript = false

    _ = model.debugBeginRecordingSession(target: makeDummyTarget())
    model.stopRecordingAndProcess()
    await model.debugWaitForPipeline()

    let normalizeCalls = await groq.normalizeCallCount
    #expect(normalizeCalls == 0)
    #expect(inserter.insertCallCount == 1)
    #expect(model.phase == .ready)
    #expect(model.finalResult == "transcript")
}

@Test @MainActor
func settingsChangeDuringInFlightRequestDoesNotAffectItsProcessingChoice() async throws {
    let (defaults, cleanup) = makeIsolatedDefaults()
    defer { cleanup() }
    let groq = FakeGroqBackend()
    await groq.setTranscribeDelay(nanoseconds: 150_000_000)
    let inserter = FakeTextInserter()
    let model = makeTestModel(groqClient: groq, textInserter: inserter, defaults: defaults)
    model.cleanUpTranscript = false

    _ = model.debugBeginRecordingSession(target: makeDummyTarget())
    model.stopRecordingAndProcess()

    // Flip every processing option on while the transcribe() call for this session is still
    // in flight; the snapshot taken at stop time must govern this session's outcome.
    model.cleanUpTranscript = true

    await model.debugWaitForPipeline()

    let normalizeCalls = await groq.normalizeCallCount
    #expect(normalizeCalls == 0)
    #expect(model.finalResult == "transcript")
}

@Test @MainActor
func successfulSessionHidesHUDImmediately() async throws {
    let (defaults, cleanup) = makeIsolatedDefaults()
    defer { cleanup() }
    let panel = NoOpRecordingPanel()
    let model = makeTestModel(recordingPanel: panel, defaults: defaults)
    model.cleanUpTranscript = false

    _ = model.debugBeginRecordingSession(target: makeDummyTarget())
    model.stopRecordingAndProcess()
    await model.debugWaitForPipeline()

    #expect(model.phase == .ready)
    #expect(panel.hideCallCount == 1)
}

@Test @MainActor
func failedSessionKeepsHUDVisibleBriefly() async throws {
    let (defaults, cleanup) = makeIsolatedDefaults()
    defer { cleanup() }
    let groq = FakeGroqBackend()
    await groq.setTranscribeResult(.failure(FakeError(message: "boom")))
    let panel = NoOpRecordingPanel()
    let model = makeTestModel(groqClient: groq, recordingPanel: panel, defaults: defaults)
    model.cleanUpTranscript = false

    _ = model.debugBeginRecordingSession(target: makeDummyTarget())
    model.stopRecordingAndProcess()
    await model.debugWaitForPipeline()

    #expect(model.phase == .failed)
    #expect(model.errorMessage == "boom")
    #expect(panel.hideCallCount == 0)
}
