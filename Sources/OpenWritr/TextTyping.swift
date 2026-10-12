import Cocoa
import CoreGraphics
import os.log

private let typingLog = Logger(subsystem: "com.openwritr.app", category: "TextTyping")

/// One step of typing text into another app.
enum TypingUnit: Equatable, Sendable {
    case text(String)
    case returnKey
    case tabKey
}

enum TextTypingPlan {
    /// A keyboard event can carry only a short Unicode string, so longer text is split. The limit
    /// is in UTF-16 units and chunks never split a character, so emoji and accents stay intact.
    static let maximumChunkUTF16Units = 16

    static func units(for text: String) -> [TypingUnit] {
        var units: [TypingUnit] = []
        var chunk = ""

        func flush() {
            if !chunk.isEmpty {
                units.append(.text(chunk))
                chunk = ""
            }
        }

        for character in text {
            // "\r\n" is a single Character in Swift.
            if character == "\n" || character == "\r" || character == "\r\n" {
                flush()
                units.append(.returnKey)
            } else if character == "\t" {
                flush()
                units.append(.tabKey)
            } else {
                if chunk.utf16.count + character.utf16.count > maximumChunkUTF16Units {
                    flush()
                }
                chunk.append(character)
            }
        }
        flush()
        return units
    }
}

@MainActor
protocol TextTyping {
    /// Types `text` as keystrokes into the frontmost app. Returns false if it could not be sent.
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

struct SystemTextTyper: TextTyping {
    private static let returnKeyCode: CGKeyCode = 0x24
    private static let tabKeyCode: CGKeyCode = 0x30

    func typeText(_ text: String) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            typingLog.error("Could not create an event source for typing")
            return false
        }
        for unit in TextTypingPlan.units(for: text) {
            let sent: Bool
            switch unit {
            case .text(let string):
                sent = post(keyCode: 0, unicode: Array(string.utf16), source: source)
            case .returnKey:
                sent = post(keyCode: Self.returnKeyCode, unicode: nil, source: source)
            case .tabKey:
                sent = post(keyCode: Self.tabKeyCode, unicode: nil, source: source)
            }
            guard sent else {
                typingLog.error("Could not create a keyboard event for typing")
                return false
            }
        }
        return true
    }

    private func post(keyCode: CGKeyCode, unicode: [UniChar]?, source: CGEventSource) -> Bool {
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return false }
        for event in [keyDown, keyUp] {
            // The push-to-talk key may still be held; do not let its modifiers change the text.
            event.flags = []
            if let unicode {
                event.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: unicode)
            }
            event.post(tap: .cgAnnotatedSessionEventTap)
        }
        return true
    }
}
