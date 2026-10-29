import Carbon.HIToolbox
import Cocoa
import CoreGraphics
import IOKit.hidsystem
import os.log

private let typingLog = Logger(subsystem: "com.openwritr.app", category: "TextTyping")

/// A physical key on the Mac keyboard, optionally with Shift held.
struct KeyStroke: Equatable, Sendable {
    let keyCode: CGKeyCode
    let shift: Bool
}

struct TypingPlan: Equatable, Sendable {
    var strokes: [KeyStroke]
    /// Characters that no key of the current layout produces, so they cannot be typed.
    var skippedCharacters: Int
}

enum TextTypingPlanner {
    static let returnStroke = KeyStroke(keyCode: 0x24, shift: false)
    static let tabStroke = KeyStroke(keyCode: 0x30, shift: false)

    /// Turns `text` into key strokes using `layout`, which maps each typeable character to the
    /// key that produces it. Remote desktop clients send physical key codes, not Unicode text, so
    /// only characters on the keyboard can be typed. Typographic characters are replaced by their
    /// plain equivalents; anything else is skipped and counted.
    static func plan(for text: String, layout: [Character: KeyStroke]) -> TypingPlan {
        var strokes: [KeyStroke] = []
        var skipped = 0

        for character in text.precomposedStringWithCanonicalMapping {
            switch character {
            case "\n", "\r", "\r\n":
                strokes.append(returnStroke)
            case "\t":
                strokes.append(tabStroke)
            default:
                if let stroke = layout[character] {
                    strokes.append(stroke)
                } else if let replacement = substitute(for: character),
                          replacement.allSatisfy({ layout[$0] != nil }) {
                    strokes.append(contentsOf: replacement.compactMap { layout[$0] })
                } else {
                    skipped += 1
                }
            }
        }
        return TypingPlan(strokes: strokes, skippedCharacters: skipped)
    }

    static func substitute(for character: Character) -> String? {
        switch character {
        case "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}", "\u{00AB}", "\u{00BB}": return "\""
        case "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}": return "'"
        case "\u{2013}", "\u{2014}", "\u{2212}": return "-"
        case "\u{2026}": return "..."
        case "\u{00A0}", "\u{202F}", "\u{2009}": return " "
        default: return nil
        }
    }
}

/// Text Input Source Services must be called on the main thread, so this is main-actor isolated.
@MainActor
enum SystemKeyboardLayout {
    /// Maps each character the current keyboard layout can type without dead keys to the key
    /// (with or without Shift) that produces it. Unshifted keys win over shifted ones.
    static func currentCharacterMap() -> [Character: KeyStroke]? {
        guard let layoutData = unicodeLayoutData(), let bytes = CFDataGetBytePtr(layoutData) else {
            return nil
        }
        let keyboardType = UInt32(LMGetKbdType())

        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            var map: [Character: KeyStroke] = [:]
            for shift in [false, true] {
                let modifiers: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
                for keyCode in 0..<128 {
                    guard let character = translate(
                        layout: layout,
                        keyCode: UInt16(keyCode),
                        modifiers: modifiers,
                        keyboardType: keyboardType
                    ) else { continue }
                    if map[character] == nil {
                        map[character] = KeyStroke(keyCode: CGKeyCode(keyCode), shift: shift)
                    }
                }
            }
            return map
        }
    }

    /// The character the current layout produces for a key press, used to verify the map.
    static func character(forKeyCode keyCode: CGKeyCode, shift: Bool) -> Character? {
        guard let layoutData = unicodeLayoutData(), let bytes = CFDataGetBytePtr(layoutData) else {
            return nil
        }
        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            translate(
                layout: layout,
                keyCode: UInt16(keyCode),
                modifiers: shift ? UInt32(shiftKey >> 8) & 0xFF : 0,
                keyboardType: UInt32(LMGetKbdType())
            )
        }
    }

    private static func unicodeLayoutData() -> CFData? {
        for source in [
            TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
        ] {
            guard let source,
                  let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            else { continue }
            return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        }
        return nil
    }

    /// The single printable character a key produces, or nil for dead keys, function keys and
    /// control characters.
    private static func translate(
        layout: UnsafePointer<UCKeyboardLayout>,
        keyCode: UInt16,
        modifiers: UInt32,
        keyboardType: UInt32
    ) -> Character? {
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
            layout,
            keyCode,
            UInt16(kUCKeyActionDown),
            modifiers,
            keyboardType,
            0,
            &deadKeyState,
            characters.count,
            &length,
            &characters
        )
        guard status == noErr, deadKeyState == 0, length > 0 else { return nil }
        let string = String(utf16CodeUnits: characters, count: length)
        guard string.count == 1, let character = string.first,
              let scalar = string.unicodeScalars.first,
              scalar.value >= 0x20, scalar.value != 0x7F,
              !(0xF700...0xF8FF).contains(scalar.value)
        else { return nil }
        return character
    }
}

@MainActor
protocol TextTyping {
    /// Types `text` as key strokes into the frontmost app. Returns false if nothing could be sent.
    func typeText(_ text: String) -> Bool
}

@MainActor
protocol RemoteDesktopDetecting {
    func isRemoteDesktopFrontmost() -> Bool
}

/// Apps whose clipboard is synchronised with the remote machine only after leaving their window,
/// so a pasted clipboard value is not available remotely yet. Typing avoids the clipboard.
struct SystemRemoteDesktopDetector: RemoteDesktopDetecting {
    nonisolated static let bundleIdentifiers: Set<String> = [
        "com.microsoft.rdc.macos",
    ]

    func isRemoteDesktopFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            .map(Self.bundleIdentifiers.contains) ?? false
    }
}

/// One key press per group (Shift down, key down, key up, Shift up), so a group is never split.
private struct EventBatch: @unchecked Sendable {
    let groups: [[CGEvent]]
}

enum TypingDelivery {
    /// Posts each group in order, but only while `stillTargeted` holds before the group starts.
    /// Returns how many whole groups were posted; a group is never posted partially.
    @discardableResult
    nonisolated static func deliver<Event>(
        _ groups: [[Event]],
        stillTargeted: () -> Bool,
        post: (Event) -> Void,
        pause: () -> Void
    ) -> Int {
        var delivered = 0
        for group in groups {
            guard stillTargeted() else { break }
            for event in group {
                post(event)
                pause()
            }
            delivered += 1
        }
        return delivered
    }
}

struct SystemTextTyper: TextTyping {
    private static let shiftKeyCode: CGKeyCode = 0x38
    // Remote clients can track left/right modifiers using the device-dependent flags.
    private static let shiftFlags = CGEventFlags.maskShift.union(
        CGEventFlags(rawValue: UInt64(NX_DEVICELSHIFTKEYMASK))
    )
    /// Remote desktop clients can drop key events that arrive faster than they are forwarded.
    private nonisolated static let eventSpacing: useconds_t = 3_000
    private nonisolated static let queue = DispatchQueue(label: "com.openwritr.text-typing")

    func typeText(_ text: String) -> Bool {
        guard let layout = SystemKeyboardLayout.currentCharacterMap() else {
            typingLog.error("Could not read the current keyboard layout")
            return false
        }
        let plan = TextTypingPlanner.plan(for: text, layout: layout)
        if plan.skippedCharacters > 0 {
            typingLog.notice("Skipped \(plan.skippedCharacters) characters that no key can type")
        }
        if plan.strokes.isEmpty { return text.isEmpty }

        guard let target = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let source = CGEventSource(stateID: .hidSystemState),
              let groups = Self.eventGroups(for: plan.strokes, source: source)
        else {
            typingLog.error("Could not create keyboard events for typing")
            return false
        }

        // Posted off the main thread, in order, with a short pause between events. Typing can take
        // seconds, so it stops as soon as the target app is no longer frontmost: the rest of the
        // transcript must never be typed into a different app.
        let batch = EventBatch(groups: groups)
        Self.queue.async {
            let delivered = TypingDelivery.deliver(
                batch.groups,
                stillTargeted: { Self.isFrontmost(processIdentifier: target) },
                post: { $0.post(tap: .cgAnnotatedSessionEventTap) },
                pause: { usleep(Self.eventSpacing) }
            )
            if delivered < batch.groups.count {
                typingLog.notice("Stopped typing after \(delivered) of \(batch.groups.count) keys: focus changed")
            }
        }
        return true
    }

    private nonisolated static func isFrontmost(processIdentifier: pid_t) -> Bool {
        DispatchQueue.main.sync {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier
        }
    }

    static func eventGroups(for strokes: [KeyStroke], source: CGEventSource) -> [[CGEvent]]? {
        var groups: [[CGEvent]] = []
        for stroke in strokes {
            var events: [CGEvent] = []
            let flags: CGEventFlags = stroke.shift ? shiftFlags : []
            if stroke.shift {
                guard let shiftDown = modifierEvent(source: source, down: true) else { return nil }
                events.append(shiftDown)
            }
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: stroke.keyCode, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: stroke.keyCode, keyDown: false)
            else { return nil }
            keyDown.flags = flags
            keyUp.flags = flags
            events.append(keyDown)
            events.append(keyUp)
            if stroke.shift {
                guard let shiftUp = modifierEvent(source: source, down: false) else { return nil }
                events.append(shiftUp)
            }
            groups.append(events)
        }
        return groups
    }

    /// Shift is sent as a real modifier key event, because a remote desktop client tracks modifier
    /// changes rather than trusting the flags of a key event.
    private static func modifierEvent(source: CGEventSource, down: Bool) -> CGEvent? {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: shiftKeyCode, keyDown: down)
        else { return nil }
        event.type = .flagsChanged
        event.flags = down ? shiftFlags : []
        return event
    }
}
