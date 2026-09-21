import Foundation

/// Owns both global-shortcut backends: the Carbon combo manager (primary Control-Option-Space
/// combo, copy/paste-last-result, and scoped Escape) and the Fn event tap (used only when Fn
/// is the selected primary trigger). This is the concrete type `AppModel` uses in production;
/// tests inject a `NoOpHotkeyManager` instead.
@MainActor
final class HotkeyController: HotkeyRegistering {
    private let comboManager = HotkeyManager()
    private let fnMonitor = FnKeyMonitor()
    private var fixedBindingsRegistered = false

    private var fixedBindingErrors: [ShortcutRegistrationError] = []
    private var primaryError: ShortcutRegistrationError?
    private var escapeError: ShortcutRegistrationError?

    var onAction: ((ShortcutAction) -> Void)? {
        didSet {
            comboManager.onAction = onAction
            fnMonitor.onAction = onAction
        }
    }

    var registrationErrors: [ShortcutRegistrationError] {
        fixedBindingErrors + (primaryError.map { [$0] } ?? []) + (escapeError.map { [$0] } ?? [])
    }

    var cancellationEnabled: Bool { comboManager.isEscapeRegistered }

    /// Activates `trigger` as the primary binding in `mode`, and ensures the always-available
    /// fixed bindings (copy, paste) are registered. Unregisters whichever primary backend was
    /// previously active first, so switching triggers/modes never leaves a stale registration
    /// behind.
    func configure(trigger: HotkeyTrigger, mode: RecordingMode, customShortcut: KeyboardShortcut?) {
        fnMonitor.unregister()
        comboManager.unregisterPrimary()

        fnMonitor.mode = mode
        comboManager.primaryMode = mode

        if !fixedBindingsRegistered {
            fixedBindingErrors = comboManager.registerFixedBindings()
            fixedBindingsRegistered = true
        }

        primaryError = nil
        switch trigger {
        case .fn:
            if case .failure(let error) = fnMonitor.register() { primaryError = error }
        case .custom:
            guard let customShortcut, customShortcut.validationError == nil else {
                primaryError = .invalidCustomShortcut
                return
            }
            if case .failure(let error) = comboManager.registerPrimary(customShortcut) { primaryError = error }
        }

    }

    func setCancellationEnabled(_ enabled: Bool) {
        switch comboManager.setEscapeEnabled(enabled) {
        case .success: escapeError = nil
        case .failure(let error): escapeError = error
        }
    }

    func unregister() {
        fnMonitor.unregister()
        comboManager.unregisterAll()
        fixedBindingsRegistered = false
        fixedBindingErrors = []
        primaryError = nil
        escapeError = nil
    }
}
