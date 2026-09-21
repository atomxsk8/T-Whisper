import SwiftUI

/// A small keycap-style label used to display keyboard shortcuts throughout the UI
/// (menu bar quick actions, Settings' Shortcuts pane, the shortcut recorder sheet).
public struct ShortcutChip: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}
