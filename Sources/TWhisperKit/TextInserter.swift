import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

/// Delivers dictated text into the destination app's focused field. Tries a direct
/// Accessibility write first, falls back to a synthesized paste, and otherwise leaves the
/// text for the user to copy manually. Never reactivates another app and never restores or
/// snapshots the user's prior clipboard contents.
@MainActor
final class TextInserter {
    private var lastExternalFrontmostPID: pid_t?
    private nonisolated(unsafe) var activationObserver: NSObjectProtocol?

    init() {
        lastExternalFrontmostPID = Self.currentExternalFrontmostPID()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            Task { @MainActor [weak self] in
                self?.lastExternalFrontmostPID = app.processIdentifier
            }
        }
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    private static func currentExternalFrontmostPID() -> pid_t? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }
        return app.processIdentifier
    }

    /// Captures the destination app's focused element at the start of a dictation session,
    /// before the recording HUD appears. Falls back to the most recently active external
    /// app when T-Whisper itself is currently frontmost (menu-started recording). Returns
    /// `nil` when there is no unambiguous external target or Accessibility isn't trusted.
    func captureTarget() -> InsertionTarget? {
        guard AXIsProcessTrusted() else { return nil }
        let pid: pid_t
        if let frontmost = Self.currentExternalFrontmostPID() {
            pid = frontmost
        } else if let lastExternalFrontmostPID {
            pid = lastExternalFrontmostPID
        } else {
            return nil
        }
        return Self.captureTarget(pid: pid)
    }

    private static func captureTarget(pid: pid_t) -> InsertionTarget {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef else {
            return InsertionTarget(pid: pid, element: nil, selectedRange: nil)
        }
        // Guarded by the .success check above: this attribute is always an AXUIElement.
        let element = focusedRef as! AXUIElement
        return InsertionTarget(pid: pid, element: element, selectedRange: copySelectedRange(of: element))
    }

    private static func copySelectedRange(of element: AXUIElement) -> CFRange? {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue((rangeValue as! AXValue), .cfRange, &range) else {
            return nil
        }
        return range
    }

    /// Role, subrole, enabled and settability checks for an already-focus-verified element.
    private static func isVerifiedEditable(_ element: AXUIElement) -> Bool {
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String else {
            return false
        }
        let editableRoles: Set<String> = [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String]
        guard editableRoles.contains(role) else { return false }

        var subroleRef: CFTypeRef?
        let subroleStatus = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
        // A hard API error here means the app doesn't expose enough to verify safely.
        guard subroleStatus == .success || subroleStatus == .noValue else { return false }
        if let subrole = subroleRef as? String, subrole == (kAXSecureTextFieldSubrole as String) {
            return false
        }

        var enabledRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabledRef) == .success,
              let enabled = enabledRef as? Bool, enabled else {
            return false
        }

        var settableSelectedText: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settableSelectedText)
        var settableValue: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settableValue)
        return settableSelectedText.boolValue || settableValue.boolValue
    }

    /// Recheck performed immediately before every insertion attempt, and again immediately
    /// before posting a paste keystroke: trust, same frontmost process, same focused element
    /// (`CFEqual`), same selection range when one was captured, and a verified editable,
    /// non-secure target. Returns `nil` immediately when `target.element` is `nil` — there is
    /// nothing to check against, so callers fall back to `verifyFrontmost` instead.
    private static func verify(_ target: InsertionTarget) -> AXUIElement? {
        guard let capturedElement = target.element else { return nil }
        guard AXIsProcessTrusted() else { return nil }
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier == target.pid else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(target.pid)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef else {
            return nil
        }
        let currentElement = focusedRef as! AXUIElement
        guard CFEqual(currentElement, capturedElement) else { return nil }

        if let expectedRange = target.selectedRange {
            guard let currentRange = copySelectedRange(of: currentElement),
                  currentRange.location == expectedRange.location,
                  currentRange.length == expectedRange.length else {
                return nil
            }
        }

        guard isVerifiedEditable(currentElement) else { return nil }
        return currentElement
    }

    /// Minimal safety gate for the blind-paste fallback below: only confirms the destination
    /// app is still frontmost. Used in place of `verify` when the app never exposed a focused
    /// element to check against in the first place (e.g. Dia and other Arc-family browsers,
    /// which don't fully implement the Accessibility API for web content).
    private static func verifyFrontmost(_ target: InsertionTarget) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
        return frontmost.processIdentifier == target.pid
    }

    /// Attempts to deliver `text` into `target`. Observes cancellation after every await and
    /// immediately before any user-visible effect (AX write, clipboard write, key post).
    func insert(_ text: String, into target: InsertionTarget) async -> InsertionOutcome {
        if let element = Self.verify(target) {
            if Task.isCancelled { return .manualCopyRequired(text) }

            var settableSelectedText: DarwinBoolean = false
            AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settableSelectedText)

            if settableSelectedText.boolValue {
                if Task.isCancelled { return .manualCopyRequired(text) }
                let setStatus = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
                if setStatus == .success {
                    return .inserted
                }
                // Ambiguous failure: the write may have partially applied. Never also paste.
                return .manualCopyRequired(text)
            }

            return await pasteFallback(text: text, stillSafe: { Self.verify(target) != nil })
        }

        // No focused element to verify against. If the app never exposed one at all (e.g. Dia
        // and other Arc-family browsers), fall back to a blind paste gated only on the same
        // app still being frontmost — never on the specific field, since there's nothing left
        // to check it against. If it exposed one that's since changed (CFEqual/role/selection
        // mismatch against `target.element`), refuse instead: something in that app definitely
        // changed, and blindly pasting risks the wrong control, including a secure field.
        guard target.element == nil, Self.verifyFrontmost(target) else {
            return .manualCopyRequired(text)
        }
        if Task.isCancelled { return .manualCopyRequired(text) }
        return await pasteFallback(text: text, stillSafe: { Self.verifyFrontmost(target) })
    }

    /// Posts a synthesized ⌘V. `stillSafe` re-gates the send immediately before the clipboard
    /// write and again immediately before the keystroke: full AX re-verification of the known
    /// field for a verified target, or just a same-frontmost-app check in blind mode.
    private func pasteFallback(text: String, stillSafe: () -> Bool) async -> InsertionOutcome {
        guard await Self.waitForModifiersReleased(timeout: 1.0) else {
            return .manualCopyRequired(text)
        }
        if Task.isCancelled { return .manualCopyRequired(text) }

        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyVDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyVUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            return .manualCopyRequired(text)
        }
        keyVDown.flags = .maskCommand
        keyVUp.flags = .maskCommand

        guard stillSafe() else {
            return .manualCopyRequired(text)
        }
        if Task.isCancelled { return .manualCopyRequired(text) }

        let pasteboard = NSPasteboard.general
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        guard pasteboard.setString(text, forType: .string) else {
            return .manualCopyRequired(text)
        }

        guard stillSafe() else {
            // Copied but not pasted: the text stays on the clipboard from the write above.
            return .manualCopyRequired(text)
        }

        keyVDown.post(tap: .cghidEventTap)
        keyVUp.post(tap: .cghidEventTap)
        return .pasteSent
    }

    private static func waitForModifiersReleased(timeout: TimeInterval) async -> Bool {
        let watched: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if NSEvent.modifierFlags.intersection(watched).isEmpty { return true }
            if Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return NSEvent.modifierFlags.intersection(watched).isEmpty
    }
}
