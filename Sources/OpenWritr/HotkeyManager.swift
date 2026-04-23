import Cocoa

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

    func start() {
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
            print("HotkeyManager: Failed to create event tap. Ensure Accessibility permission is granted.")
            ptr.deinitialize(count: 1)
            ptr.deallocate()
            return
        }

        contextPtr = ptr
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
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

    if type == .tapDisabledByTimeout {
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
