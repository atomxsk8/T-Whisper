import AppKit
import Carbon

/// A Carbon-compatible keyboard chord used for global registration. Persisted values are
/// keycodes and Carbon modifier bits, never localized display text.
public struct KeyboardShortcut: Codable, Equatable, Sendable {
    public let keyCode: UInt32
    public let modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    static let copyLast = KeyboardShortcut(
        keyCode: UInt32(kVK_ANSI_C),
        modifiers: UInt32(cmdKey | controlKey)
    )
    static let pasteLast = KeyboardShortcut(
        keyCode: UInt32(kVK_ANSI_V),
        modifiers: UInt32(cmdKey | controlKey)
    )

    private static let supportedModifiers = UInt32(cmdKey | controlKey | optionKey | shiftKey)
    private static let requiredModifiers = UInt32(cmdKey | controlKey | optionKey)
    private static let modifierKeyCodes: Set<UInt32> = [
        UInt32(kVK_Command), UInt32(kVK_RightCommand),
        UInt32(kVK_Shift), UInt32(kVK_RightShift),
        UInt32(kVK_Control), UInt32(kVK_RightControl),
        UInt32(kVK_Option), UInt32(kVK_RightOption),
        UInt32(kVK_Function), UInt32(kVK_CapsLock)
    ]

    init?(event: NSEvent) {
        guard event.type == .keyDown, !event.isARepeat,
              !Self.modifierKeyCodes.contains(UInt32(event.keyCode)) else {
            return nil
        }

        var carbonModifiers: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if flags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if flags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: carbonModifiers)
    }

    var validationError: String? {
        guard keyCode <= 127, modifiers & ~Self.supportedModifiers == 0 else {
            return "This shortcut is not supported."
        }
        guard keyCode != UInt32(kVK_Escape) else {
            return "Escape is reserved for Cancel."
        }
        guard !Self.modifierKeyCodes.contains(keyCode), modifiers & Self.requiredModifiers != 0 else {
            return "Use Command, Control, or Option with another key."
        }
        guard self != .copyLast, self != .pasteLast else {
            return "This shortcut is reserved by T-Whisper."
        }
        return nil
    }

    var displayName: String {
        let parts = [
            modifiers & UInt32(controlKey) != 0 ? "Control" : nil,
            modifiers & UInt32(optionKey) != 0 ? "Option" : nil,
            modifiers & UInt32(shiftKey) != 0 ? "Shift" : nil,
            modifiers & UInt32(cmdKey) != 0 ? "Command" : nil,
            keyName
        ].compactMap { $0 }
        return parts.joined(separator: "-")
    }

    private var keyName: String {
        let names: [UInt32: String] = [
            UInt32(kVK_Space): "Space", UInt32(kVK_Tab): "Tab", UInt32(kVK_Return): "Return",
            UInt32(kVK_Delete): "Delete", UInt32(kVK_ForwardDelete): "Forward Delete",
            UInt32(kVK_LeftArrow): "Left Arrow", UInt32(kVK_RightArrow): "Right Arrow",
            UInt32(kVK_UpArrow): "Up Arrow", UInt32(kVK_DownArrow): "Down Arrow",
            UInt32(kVK_Home): "Home", UInt32(kVK_End): "End", UInt32(kVK_PageUp): "Page Up",
            UInt32(kVK_PageDown): "Page Down", UInt32(kVK_Help): "Help"
        ]
        if let name = names[keyCode] { return name }
        let functionKeys: [UInt32: String] = [
            UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
            UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
            UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
            UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15", UInt32(kVK_F16): "F16",
            UInt32(kVK_F17): "F17", UInt32(kVK_F18): "F18", UInt32(kVK_F19): "F19", UInt32(kVK_F20): "F20"
        ]
        if let name = functionKeys[keyCode] { return name }
        return translatedKeyName ?? "Key \(keyCode)"
    }

    private var translatedKeyName: String? {
        guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = unsafeBitCast(layoutData, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout -> String? in
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = Array<UniChar>(repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: Int(length)).uppercased()
        }
    }
}
