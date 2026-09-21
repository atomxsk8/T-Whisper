import Foundation
import CoreGraphics
import IOKit.hid

/// Watches solo presses of the Fn key as T-Whisper's primary trigger, using a listen-only
/// global event tap. A key pressed while Fn is held (e.g. Fn-Delete, brightness, Fn-arrow),
/// or another modifier already active when Fn goes down, means Fn is being used as a
/// modifier/chord rather than a standalone trigger, and never starts or stops a session.
/// Requires Input Monitoring access; unlike the Carbon hotkey combos, macOS has no
/// modifier-only `RegisterEventHotKey` equivalent, so a listen-only `CGEventTap` is the only
/// way to observe solo Fn presses. Internal implementation detail of `HotkeyController`.
@MainActor
final class FnKeyMonitor {
    private static let maxToggleHoldDuration: TimeInterval = 1.5
    private static let watchedModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    /// `.toggle`: solo press-and-release toggles recording (capped at 1.5s). `.holdToTalk`:
    /// press starts recording immediately, release stops it, with no time cap.
    var mode: RecordingMode = .toggle

    /// Invoked on the main actor for each qualifying Fn edge (toggle) or hold transition
    /// (press/release/cancel).
    var onAction: ((ShortcutAction) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnIsDown = false
    private var chordInvalidated = false
    private var fnDownDate: Date?
    private var holdActive = false

    private(set) var isRegistered = false

    static func inputMonitoringGranted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Triggers the system Input Monitoring prompt if access has not yet been decided.
    @discardableResult
    static func requestInputMonitoringPermission() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    func register() -> Result<Void, ShortcutRegistrationError> {
        guard !isRegistered else { return .success(()) }
        guard Self.inputMonitoringGranted() else {
            return .failure(.inputMonitoringNotGranted)
        }

        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: fnKeyTapCallback,
            userInfo: selfPtr
        ) else {
            return .failure(.eventTapCreationFailed)
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            return .failure(.eventTapCreationFailed)
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        isRegistered = true
        return .success(())
    }

    func unregister() {
        invalidateHoldIfActive()
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isRegistered = false
        fnIsDown = false
        chordInvalidated = false
        fnDownDate = nil
    }

    private func invalidateHoldIfActive() {
        guard holdActive else { return }
        holdActive = false
        onAction?(.primaryCancelled)
    }

    private func hasOtherModifiers(_ flags: CGEventFlags) -> Bool {
        !flags.intersection(Self.watchedModifiers).isEmpty
    }

    /// `date` is injectable for deterministic tests; production calls always use the event's
    /// own wall-clock time via the default.
    fileprivate func handle(type: CGEventType, flags: CGEventFlags, date: Date = Date()) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            invalidateHoldIfActive()
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }

        switch type {
        case .flagsChanged:
            let isFnDown = flags.contains(.maskSecondaryFn)
            if isFnDown, !fnIsDown {
                fnIsDown = true
                fnDownDate = date
                chordInvalidated = hasOtherModifiers(flags)
                if mode == .holdToTalk, !chordInvalidated {
                    holdActive = true
                    onAction?(.primaryPressed)
                }
            } else if isFnDown, fnIsDown {
                // Fn still down; another modifier was added to the chord mid-hold.
                guard !chordInvalidated, hasOtherModifiers(flags) else { return }
                chordInvalidated = true
                if mode == .holdToTalk, holdActive {
                    holdActive = false
                    onAction?(.primaryCancelled)
                }
            } else if !isFnDown, fnIsDown {
                fnIsDown = false
                let heldTooLong = fnDownDate.map { date.timeIntervalSince($0) > Self.maxToggleHoldDuration } ?? true
                fnDownDate = nil
                switch mode {
                case .toggle:
                    if !chordInvalidated, !heldTooLong {
                        onAction?(.toggleRecording)
                    }
                case .holdToTalk:
                    if holdActive {
                        holdActive = false
                        onAction?(.primaryReleased)
                    }
                }
                chordInvalidated = false
            }
        case .keyDown:
            if fnIsDown, !chordInvalidated {
                chordInvalidated = true
                if mode == .holdToTalk, holdActive {
                    holdActive = false
                    onAction?(.primaryCancelled)
                }
            }
        default:
            break
        }
    }
}

private func fnKeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        let flags = event.flags
        MainActor.assumeIsolated {
            monitor.handle(type: type, flags: flags)
        }
    }
    return Unmanaged.passUnretained(event)
}

#if DEBUG
extension FnKeyMonitor {
    /// Test-only seam: exercises the tap's event-handling logic with explicit timestamps,
    /// without a real `CGEventTap` or OS key events.
    func debugHandle(type: CGEventType, flags: CGEventFlags, date: Date) {
        handle(type: type, flags: flags, date: date)
    }

    var debugHoldActive: Bool { holdActive }
}
#endif
