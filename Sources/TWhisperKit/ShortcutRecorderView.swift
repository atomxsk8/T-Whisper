import AppKit
import Carbon
import SwiftUI

/// Local-only shortcut capture. The app's global bindings stay unregistered until every key
/// involved in the capture has been released, so accepting or cancelling a chord cannot start
/// a recording on its release edge.
struct ShortcutRecorderView: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @StateObject private var coordinator: ShortcutCaptureCoordinator

    init(model: AppModel, isPresented: Binding<Bool>) {
        self.model = model
        _isPresented = isPresented
        _coordinator = StateObject(wrappedValue: ShortcutCaptureCoordinator(model: model))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Record Shortcut", systemImage: "keyboard")
                .font(.headline)
            Text("Shortcuts are paused while recording a new shortcut.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(coordinator.candidate?.displayName ?? "Press a shortcut")
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(coordinator.candidate == nil ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 14)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            if let error = coordinator.validationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { coordinator.cancel() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { coordinator.save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!coordinator.canSave)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            coordinator.dismiss = { isPresented = false }
            coordinator.installMonitor()
        }
        .onDisappear { coordinator.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            coordinator.cancel()
        }
    }
}

@MainActor
private final class ShortcutCaptureCoordinator: ObservableObject {
    @Published private(set) var candidate: KeyboardShortcut?
    @Published private(set) var validationError: String?
    @Published private(set) var canSave = false

    private let model: AppModel
    private weak var window: NSWindow?
    private var monitor: Any?
    private var heldKeyCode: UInt32?
    private var isTearingDown = false
    private var hasEndedCapture = false
    var dismiss: (() -> Void)?

    init(model: AppModel) {
        self.model = model
    }

    func installMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if self.window == nil {
                self.window = event.window
            }
            guard event.window == self.window else { return event }
            return self.handle(event)
        }
    }

    func save() {
        guard let candidate, canSave, model.saveCustomShortcut(candidate) else { return }
        teardown()
    }

    func cancel() {
        candidate = nil
        validationError = nil
        teardown()
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyDown:
            if event.keyCode == UInt16(kVK_Escape) {
                heldKeyCode = UInt32(event.keyCode)
                cancel()
                return nil
            }
            guard !event.isARepeat else { return nil }
            guard let shortcut = KeyboardShortcut(event: event) else { return nil }
            heldKeyCode = shortcut.keyCode
            if let error = shortcut.validationError {
                candidate = nil
                validationError = error
            } else {
                candidate = shortcut
                validationError = nil
            }
        case .keyUp:
            if heldKeyCode == UInt32(event.keyCode) {
                heldKeyCode = nil
            }
        case .flagsChanged:
            break
        default:
            return event
        }
        updateCanSave(using: event.modifierFlags)
        return nil
    }

    private func updateCanSave(using flags: NSEvent.ModifierFlags) {
        let shortcutModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        canSave = candidate != nil && heldKeyCode == nil && flags.intersection(shortcutModifiers).isEmpty
    }

    private func teardown() {
        guard !isTearingDown else { return }
        isTearingDown = true
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        waitForRelease()
    }

    private func waitForRelease() {
        let modifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        let keyStillDown = heldKeyCode.map {
            CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0))
        } ?? false
        guard keyStillDown || !NSEvent.modifierFlags.intersection(modifiers).isEmpty else {
            hasEndedCapture = true
            model.endShortcutCapture()
            dismiss?()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.waitForRelease()
        }
    }

    deinit {
        guard !hasEndedCapture else { return }
        hasEndedCapture = true
        let model = self.model
        Task { @MainActor in
            model.endShortcutCapture()
        }
    }
}
