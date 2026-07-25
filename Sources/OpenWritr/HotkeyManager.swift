import Cocoa

enum HotkeyManagerError: LocalizedError, Sendable {
    case accessibilityPermissionRequired
    case eventTapCreationFailed
    case runLoopSourceCreationFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionRequired: return "Accessibility permission is required for the push-to-talk key."
        case .eventTapCreationFailed: return "OpenWritr could not start the push-to-talk key listener."
        case .runLoopSourceCreationFailed: return "OpenWritr could not attach the push-to-talk key listener."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .accessibilityPermissionRequired: return "Grant Accessibility access in System Settings > Privacy & Security, then retry."
        case .eventTapCreationFailed, .runLoopSourceCreationFailed: return "Verify Accessibility access, then retry initialization."
        }
    }
}

enum RecordingShortcutMode: Sendable {
    case normal
    case enhanced
}

private enum RecordingShortcutAction: Sendable {
    case started(RecordingShortcutMode)
    case stopped(RecordingShortcutMode)
}

@MainActor
final class HotkeyManager {
    var onRecordingStarted: (@Sendable (RecordingShortcutMode) -> Void)?
    var onRecordingStopped: (@Sendable (RecordingShortcutMode) -> Void)?

    // Read from callback thread — use atomic-like access via nonisolated context
    nonisolated(unsafe) var activeFlag: UInt64 = 0x800000 // Fn key default
    nonisolated(unsafe) var activeKeyCode: Int64 = 63 // Fn key default
    nonisolated(unsafe) private var isKeyPressed = false
    nonisolated(unsafe) private var currentMode: RecordingShortcutMode = .normal
    nonisolated(unsafe) private var primaryKeyDown = false
    nonisolated(unsafe) private var shiftKeyDown = false
    nonisolated(unsafe) private var sawShiftDuringCurrentPress = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var contextPtr: UnsafeMutablePointer<HotkeyContext>?

    func start() -> Result<Void, HotkeyManagerError> {
        if let eventTap, runLoopSource != nil {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            return .success(())
        }

        stop()
        guard AXIsProcessTrusted() else {
            return .failure(.accessibilityPermissionRequired)
        }

        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)

        let context = HotkeyContext(manager: self)
        let ptr = UnsafeMutablePointer<HotkeyContext>.allocate(capacity: 1)
        ptr.initialize(to: context)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: hotkeyCallback,
            userInfo: ptr
        ) else {
            ptr.deinitialize(count: 1)
            ptr.deallocate()
            return .failure(.eventTapCreationFailed)
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CGEvent.tapEnable(tap: tap, enable: false)
            ptr.deinitialize(count: 1)
            ptr.deallocate()
            return .failure(.runLoopSourceCreationFailed)
        }

        contextPtr = ptr
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return .success(())
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        contextPtr?.deinitialize(count: 1)
        contextPtr?.deallocate()
        contextPtr = nil
        isKeyPressed = false
        primaryKeyDown = false
        shiftKeyDown = false
        sawShiftDuringCurrentPress = false
    }

    nonisolated fileprivate func processFlagsChanged(_ flags: CGEventFlags, keyCode: Int64) -> RecordingShortcutAction? {
        shiftKeyDown = flags.contains(.maskShift)

        if keyCode == activeKeyCode {
            primaryKeyDown = (flags.rawValue & activeFlag) != 0
        }

        if primaryKeyDown {
            sawShiftDuringCurrentPress = sawShiftDuringCurrentPress || shiftKeyDown
            currentMode = sawShiftDuringCurrentPress ? .enhanced : .normal
        }

        if primaryKeyDown && !isKeyPressed {
            isKeyPressed = true
            sawShiftDuringCurrentPress = shiftKeyDown
            currentMode = sawShiftDuringCurrentPress ? .enhanced : .normal
            return .started(currentMode)
        } else if !primaryKeyDown && isKeyPressed {
            let finishedMode: RecordingShortcutMode = sawShiftDuringCurrentPress ? .enhanced : .normal
            isKeyPressed = false
            currentMode = .normal
            primaryKeyDown = false
            shiftKeyDown = false
            sawShiftDuringCurrentPress = false
            return .stopped(finishedMode)
        }

        return nil
    }

    fileprivate func handleShortcutAction(_ action: RecordingShortcutAction) {
        switch action {
        case .started(let mode):
            onRecordingStarted?(mode)
        case .stopped(let mode):
            onRecordingStopped?(mode)
        }
    }

    fileprivate func reEnableTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }
}

private struct HotkeyContext {
    weak var manager: HotkeyManager?
}

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let contextPtr = userInfo.assumingMemoryBound(to: HotkeyContext.self)
    let manager = contextPtr.pointee.manager

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        DispatchQueue.main.async {
            manager?.reEnableTap()
        }
        return Unmanaged.passUnretained(event)
    }

    guard type == .flagsChanged else {
        return Unmanaged.passUnretained(event)
    }

    let flags = event.flags
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let action = manager?.processFlagsChanged(flags, keyCode: keyCode)
    if let action {
        DispatchQueue.main.async {
            manager?.handleShortcutAction(action)
        }
    }

    return Unmanaged.passUnretained(event)
}
