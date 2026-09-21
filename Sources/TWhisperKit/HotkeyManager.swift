import Carbon
import AppKit

/// `RegisterEventHotKey`: a configurable primary combo, copy/paste-last-result, and a scoped
/// Escape cancellation binding. All registration and state mutation happens on the main
/// actor. Internal implementation detail of `HotkeyController`; not used directly by
/// `AppModel`.
@MainActor
final class HotkeyManager {
    fileprivate nonisolated static let signature: OSType = 0x54575350 // 'TWSP'

    enum BindingID: UInt32, CaseIterable {
        case primary = 1
        case copyLast = 3
        case pasteLast = 4
        case escape = 5
    }

    private static let fixedShortcuts: [BindingID: KeyboardShortcut] = [
        .copyLast: .copyLast,
        .pasteLast: .pasteLast,
        .escape: KeyboardShortcut(keyCode: UInt32(kVK_Escape), modifiers: 0)
    ]

    /// Which behavior the primary binding's press/release edges dispatch. Read by the Carbon
    /// callback on the main actor; only ever written on the main actor.
    var primaryMode: RecordingMode = .toggle

    private var refs: [BindingID: EventHotKeyRef] = [:]
    private var keyDownLatch: Set<BindingID> = []
    private var eventHandlerRef: EventHandlerRef?

    var onAction: ((ShortcutAction) -> Void)?

    var isEscapeRegistered: Bool { refs[.escape] != nil }

    private func ensureHandlerInstalled() -> OSStatus {
        guard eventHandlerRef == nil else { return noErr }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var handlerRef: EventHandlerRef?
        let status = InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 2, &eventTypes, selfPtr, &handlerRef)
        if status == noErr {
            eventHandlerRef = handlerRef
        }
        return status
    }

    private func register(_ id: BindingID, shortcut: KeyboardShortcut) -> Result<Void, ShortcutRegistrationError> {
        guard refs[id] == nil else { return .success(()) }

        let installStatus = ensureHandlerInstalled()
        guard installStatus == noErr else {
            return .failure(.comboHandlerInstallFailed(shortcut: shortcut.displayName, status: installStatus))
        }

        var ref: EventHotKeyRef?
        let hotKeyIDStruct = EventHotKeyID(signature: Self.signature, id: id.rawValue)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyIDStruct,
            GetApplicationEventTarget(),
            UInt32(kEventHotKeyExclusive),
            &ref
        )
        guard status == noErr, let ref else {
            if status == OSStatus(eventHotKeyExistsErr) {
                return .failure(.comboConflict(shortcut: shortcut.displayName))
            }
            return .failure(.comboRegistrationFailed(shortcut: shortcut.displayName, status: status))
        }

        refs[id] = ref
        return .success(())
    }

    private func unregister(_ id: BindingID) {
        if let ref = refs[id] {
            UnregisterEventHotKey(ref)
            refs[id] = nil
        }
        keyDownLatch.remove(id)
    }

    func registerPrimary(_ shortcut: KeyboardShortcut) -> Result<Void, ShortcutRegistrationError> {
        guard shortcut.validationError == nil else { return .failure(.invalidCustomShortcut) }
        return register(.primary, shortcut: shortcut)
    }

    func unregisterPrimary() {
        unregister(.primary)
    }

    /// Registers the always-available copy/paste-last-result bindings. Independent per
    /// binding: a conflict on one never disables the others.
    func registerFixedBindings() -> [ShortcutRegistrationError] {
        let fixedIDs: [BindingID] = [.copyLast, .pasteLast]
        return fixedIDs.compactMap { id -> ShortcutRegistrationError? in
            if case .failure(let error) = register(id, shortcut: Self.fixedShortcuts[id]!) { return error }
            return nil
        }
    }

    func setEscapeEnabled(_ enabled: Bool) -> Result<Void, ShortcutRegistrationError> {
        if enabled {
            return register(.escape, shortcut: Self.fixedShortcuts[.escape]!)
        }
        unregister(.escape)
        return .success(())
    }

    func unregisterAll() {
        for id in BindingID.allCases {
            unregister(id)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    fileprivate func handlePressed(id: BindingID) {
        guard !keyDownLatch.contains(id) else { return }
        keyDownLatch.insert(id)
        switch id {
        case .primary:
            switch primaryMode {
            case .toggle: onAction?(.toggleRecording)
            case .holdToTalk: onAction?(.primaryPressed)
            }
        case .copyLast: onAction?(.copyLast)
        case .pasteLast: onAction?(.pasteLast)
        case .escape: onAction?(.cancel)
        }
    }

    fileprivate func handleReleased(id: BindingID) {
        guard keyDownLatch.remove(id) != nil else { return }
        if id == .primary, primaryMode == .holdToTalk {
            onAction?(.primaryReleased)
        }
    }
}

private func hotKeyEventHandler(nextHandler: EventHandlerCallRef?, event: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()

    var hotKeyID = EventHotKeyID()
    let paramStatus = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard paramStatus == noErr else { return paramStatus }
    guard hotKeyID.signature == HotkeyManager.signature, let id = HotkeyManager.BindingID(rawValue: hotKeyID.id) else {
        return OSStatus(eventNotHandledErr)
    }

    let kind = GetEventKind(event)
    // Dispatched synchronously in event order, on the main run loop that
    // GetApplicationEventTarget() delivers on — mirrors FnKeyMonitor's tap callback.
    MainActor.assumeIsolated {
        if kind == UInt32(kEventHotKeyPressed) {
            manager.handlePressed(id: id)
        } else if kind == UInt32(kEventHotKeyReleased) {
            manager.handleReleased(id: id)
        }
    }
    return noErr
}

#if DEBUG
extension HotkeyManager {
    /// Test-only Carbon dispatch seam. It exercises the same latch and action mapping as the
    /// installed event handler without registering a real system hotkey.
    func debugHandlePressed(_ id: BindingID) {
        handlePressed(id: id)
    }

    func debugHandleReleased(_ id: BindingID) {
        handleReleased(id: id)
    }
}
#endif
