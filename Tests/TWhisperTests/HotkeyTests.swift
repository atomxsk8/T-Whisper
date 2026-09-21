import Testing
import CoreGraphics
import Foundation
import ApplicationServices
import AppKit
import Carbon
@testable import TWhisperKit


@Test @MainActor
func fnToggleModeSoloPressReleaseEmitsToggleOnce() {
    let monitor = FnKeyMonitor()
    monitor.mode = .toggle
    var actions: [ShortcutAction] = []
    monitor.onAction = { actions.append($0) }

    let base = Date()
    monitor.debugHandle(type: .flagsChanged, flags: .maskSecondaryFn, date: base)
    monitor.debugHandle(type: .flagsChanged, flags: [], date: base.addingTimeInterval(0.2))

    #expect(actions == [.toggleRecording])
}

@Test @MainActor
func fnToggleModeHeldTooLongNeverToggles() {
    let monitor = FnKeyMonitor()
    monitor.mode = .toggle
    var actions: [ShortcutAction] = []
    monitor.onAction = { actions.append($0) }

    let base = Date()
    monitor.debugHandle(type: .flagsChanged, flags: .maskSecondaryFn, date: base)
    monitor.debugHandle(type: .flagsChanged, flags: [], date: base.addingTimeInterval(2.0))

    #expect(actions.isEmpty)
}

@Test @MainActor
func fnToggleModeChordSuppressesToggle() {
    let monitor = FnKeyMonitor()
    monitor.mode = .toggle
    var actions: [ShortcutAction] = []
    monitor.onAction = { actions.append($0) }

    let base = Date()
    monitor.debugHandle(type: .flagsChanged, flags: .maskSecondaryFn, date: base)
    monitor.debugHandle(type: .keyDown, flags: .maskSecondaryFn, date: base.addingTimeInterval(0.05))
    monitor.debugHandle(type: .flagsChanged, flags: [], date: base.addingTimeInterval(0.1))

    #expect(actions.isEmpty)
}

@Test @MainActor
func fnHoldModePressAndReleaseEmitPressedThenReleased() {
    let monitor = FnKeyMonitor()
    monitor.mode = .holdToTalk
    var actions: [ShortcutAction] = []
    monitor.onAction = { actions.append($0) }

    let base = Date()
    monitor.debugHandle(type: .flagsChanged, flags: .maskSecondaryFn, date: base)
    #expect(monitor.debugHoldActive)
    // No 1.5s cap in hold mode: a long hold still releases cleanly.
    monitor.debugHandle(type: .flagsChanged, flags: [], date: base.addingTimeInterval(5.0))

    #expect(actions == [.primaryPressed, .primaryReleased])
    #expect(!monitor.debugHoldActive)
}

@Test @MainActor
func fnHoldModeOtherKeyInvalidatesHoldExactlyOnce() {
    let monitor = FnKeyMonitor()
    monitor.mode = .holdToTalk
    var actions: [ShortcutAction] = []
    monitor.onAction = { actions.append($0) }

    let base = Date()
    monitor.debugHandle(type: .flagsChanged, flags: .maskSecondaryFn, date: base)
    monitor.debugHandle(type: .keyDown, flags: .maskSecondaryFn, date: base.addingTimeInterval(0.1))
    // A second key while already invalidated must not emit a second cancellation.
    monitor.debugHandle(type: .keyDown, flags: .maskSecondaryFn, date: base.addingTimeInterval(0.2))
    monitor.debugHandle(type: .flagsChanged, flags: [], date: base.addingTimeInterval(0.3))

    #expect(actions == [.primaryPressed, .primaryCancelled])
}

@Test @MainActor
func fnHoldModeAdditionalModifierMidHoldInvalidatesHold() {
    let monitor = FnKeyMonitor()
    monitor.mode = .holdToTalk
    var actions: [ShortcutAction] = []
    monitor.onAction = { actions.append($0) }

    let base = Date()
    monitor.debugHandle(type: .flagsChanged, flags: .maskSecondaryFn, date: base)
    monitor.debugHandle(type: .flagsChanged, flags: [.maskSecondaryFn, .maskShift], date: base.addingTimeInterval(0.1))
    // Release afterward must not emit a second event.
    monitor.debugHandle(type: .flagsChanged, flags: [.maskShift], date: base.addingTimeInterval(0.2))
    monitor.debugHandle(type: .flagsChanged, flags: [], date: base.addingTimeInterval(0.3))

    #expect(actions == [.primaryPressed, .primaryCancelled])
}

@Test @MainActor
func fnHoldModeFnEngagedWithModifierAlreadyDownNeverStartsHold() {
    let monitor = FnKeyMonitor()
    monitor.mode = .holdToTalk
    var actions: [ShortcutAction] = []
    monitor.onAction = { actions.append($0) }

    let base = Date()
    // Option was already held; Fn goes down while it's active — never a solo trigger.
    monitor.debugHandle(type: .flagsChanged, flags: [.maskSecondaryFn, .maskAlternate], date: base)
    monitor.debugHandle(type: .flagsChanged, flags: [.maskAlternate], date: base.addingTimeInterval(0.2))

    #expect(actions.isEmpty)
    #expect(!monitor.debugHoldActive)
}

@Test @MainActor
func fnUnregisterDuringActiveHoldInvalidatesIt() {
    let monitor = FnKeyMonitor()
    monitor.mode = .holdToTalk
    var actions: [ShortcutAction] = []
    monitor.onAction = { actions.append($0) }

    monitor.debugHandle(type: .flagsChanged, flags: .maskSecondaryFn, date: Date())
    #expect(monitor.debugHoldActive)

    monitor.unregister()

    #expect(actions == [.primaryPressed, .primaryCancelled])
}

// MARK: - AppModel hold-to-talk session ownership

@MainActor
private func makeDummyTarget() -> InsertionTarget {
    InsertionTarget(pid: getpid(), element: AXUIElementCreateApplication(getpid()), selectedRange: nil)
}

@Test @MainActor
func holdReleaseStopsOnlyTheOwnedSession() async throws {
    let (defaults, cleanup) = makeIsolatedDefaults()
    defer { cleanup() }
    let inserter = FakeTextInserter()
    inserter.insertOutcome = .inserted
    let model = makeTestModel(textInserter: inserter, defaults: defaults)

    let sessionID = model.debugBeginRecordingSession(target: makeDummyTarget(), asHold: true)
    #expect(model.debugHoldOwnerSessionID == sessionID)

    model.handleShortcutAction(.primaryReleased)
    await model.debugWaitForPipeline()

    #expect(inserter.insertCallCount == 1)
    #expect(model.debugHoldOwnerSessionID == nil)
    #expect(inserter.lastInsertedText == "normalized")
}

@Test @MainActor
func nonHoldSessionIsUnaffectedByPrimaryReleased() async throws {
    let (defaults, cleanup) = makeIsolatedDefaults()
    defer { cleanup() }
    let inserter = FakeTextInserter()
    let model = makeTestModel(textInserter: inserter, defaults: defaults)

    _ = model.debugBeginRecordingSession(target: makeDummyTarget(), asHold: false)
    model.handleShortcutAction(.primaryReleased)

    // A non-hold session has no hold owner, so a stray primaryReleased must not stop it.
    #expect(model.phase == .recording)
    #expect(inserter.insertCallCount == 0)
}

@Test @MainActor
func releaseAfterCancelNeverStartsOrStopsAnotherSession() async throws {
    let (defaults, cleanup) = makeIsolatedDefaults()
    defer { cleanup() }
    let inserter = FakeTextInserter()
    let model = makeTestModel(textInserter: inserter, defaults: defaults)

    _ = model.debugBeginRecordingSession(target: makeDummyTarget(), asHold: true)
    model.cancel()
    #expect(model.phase == .idle)

    // The physical key release arrives after cancellation already tore the session down.
    model.handleShortcutAction(.primaryReleased)

    #expect(model.phase == .idle)
    #expect(inserter.insertCallCount == 0)
}

@Test @MainActor
func chordInvalidationCancelsOnlyTheOwnedHoldSession() async throws {
    let (defaults, cleanup) = makeIsolatedDefaults()
    defer { cleanup() }
    let inserter = FakeTextInserter()
    let model = makeTestModel(textInserter: inserter, defaults: defaults)

    _ = model.debugBeginRecordingSession(target: makeDummyTarget(), asHold: true)
    model.handleShortcutAction(.primaryCancelled)

    #expect(model.phase == .idle)
    #expect(inserter.insertCallCount == 0)
    #expect(model.debugHoldOwnerSessionID == nil)
}

@Test @MainActor
func toggleStoppingHoldOwnedSessionClearsOwnershipBeforeLaterRelease() async throws {
    let (defaults, cleanup) = makeIsolatedDefaults()
    defer { cleanup() }
    let inserter = FakeTextInserter()
    inserter.insertOutcome = .inserted
    let model = makeTestModel(textInserter: inserter, defaults: defaults)

    let sessionID = model.debugBeginRecordingSession(target: makeDummyTarget(), asHold: true)
    #expect(model.debugHoldOwnerSessionID == sessionID)

    // The toggle action stops the hold-owned session directly.
    model.handleShortcutAction(.toggleRecording)
    #expect(model.debugHoldOwnerSessionID == nil)

    await model.debugWaitForPipeline()
    #expect(inserter.insertCallCount == 1)

    // A later physical release of the original hold press must be a no-op.
    model.handleShortcutAction(.primaryReleased)
    #expect(inserter.insertCallCount == 1)
}

@Test @MainActor
func carbonShortcutValidationAndDispatchRespectModifiersAndEdges() {
    let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [.control, .option],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "d",
        charactersIgnoringModifiers: "d",
        isARepeat: false,
        keyCode: UInt16(kVK_ANSI_D)
    )!
    let shortcut = KeyboardShortcut(event: event)
    #expect(shortcut == KeyboardShortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey)))
    #expect(shortcut?.validationError == nil)
    #expect(KeyboardShortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(shiftKey)).validationError != nil)
    #expect(KeyboardShortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: 0).validationError != nil)

    let manager = HotkeyManager()
    var actions: [ShortcutAction] = []
    manager.onAction = { actions.append($0) }
    manager.primaryMode = .toggle
    manager.debugHandlePressed(.primary)
    manager.debugHandlePressed(.primary)
    manager.debugHandleReleased(.primary)
    #expect(actions == [.toggleRecording])

    manager.primaryMode = .holdToTalk
    manager.debugHandlePressed(.primary)
    manager.debugHandleReleased(.primary)
    manager.debugHandleReleased(.primary)
    manager.debugHandleReleased(.copyLast)
    #expect(actions == [.toggleRecording, .primaryPressed, .primaryReleased])
}

@Test @MainActor
func shortcutCaptureBlocksDictationAndRestoresSavedConfiguration() {
    let (defaults, cleanup) = makeIsolatedDefaults()
    defer { cleanup() }
    let hotkeys = NoOpHotkeyManager()
    let model = AppModel(
        audioRecorder: FakeAudioRecorder(),
        groqClient: FakeGroqBackend(),
        textInserter: FakeTextInserter(),
        hotkeyManager: hotkeys,
        recordingPanel: NoOpRecordingPanel(),
        apiKeyStore: InMemoryAPIKeyStore(),
        defaults: defaults
    )
    let shortcut = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey))
    #expect(model.saveCustomShortcut(shortcut))
    let beforeCapture = hotkeys.configureCallCount

    #expect(model.beginShortcutCapture())
    hotkeys.onAction?(.toggleRecording)
    hotkeys.onAction?(.copyLast)
    #expect(model.phase == .idle)
    model.endShortcutCapture()

    #expect(model.hotkeyTrigger == .custom)
    #expect(model.customShortcut == shortcut)
    #expect(hotkeys.configureCallCount == beforeCapture + 1)
    #expect(hotkeys.lastConfiguredShortcut == shortcut)
}

@Test @MainActor
func toggleStopProcessesAndInsertsOnce() async throws {
    let (defaults, cleanup) = makeIsolatedDefaults()
    defer { cleanup() }
    let inserter = FakeTextInserter()
    let model = makeTestModel(textInserter: inserter, defaults: defaults)

    _ = model.debugBeginRecordingSession(target: makeDummyTarget())
    model.toggleRecording()
    await model.debugWaitForPipeline()

    #expect(inserter.insertCallCount == 1)
    #expect(inserter.lastInsertedText == "normalized")
}
