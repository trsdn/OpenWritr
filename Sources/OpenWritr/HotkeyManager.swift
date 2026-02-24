import Cocoa

@MainActor
final class HotkeyManager {
    var onRecordingStarted: (@Sendable () -> Void)?
    var onRecordingStopped: (@Sendable () -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var contextPtr: UnsafeMutablePointer<HotkeyContext>?
    private var isFnPressed = false

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

    fileprivate func handleFlagsChanged(_ flags: CGEventFlags) {
        let fnFlag: UInt64 = 0x800000
        let fnIsDown = (flags.rawValue & fnFlag) != 0

        if fnIsDown && !isFnPressed {
            isFnPressed = true
            onRecordingStarted?()
        } else if !fnIsDown && isFnPressed {
            isFnPressed = false
            onRecordingStopped?()
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
    DispatchQueue.main.async {
        manager?.handleFlagsChanged(flags)
    }

    return Unmanaged.passUnretained(event)
}
