import Cocoa

@MainActor
final class PasteManager {
    func pasteText(_ text: String) {
        let pasteboard = NSPasteboard.general

        // Save current clipboard contents
        let previousItems = pasteboard.pasteboardItems?.compactMap { item -> (String, NSPasteboard.PasteboardType)? in
            guard let types = item.types.first,
                  let data = item.string(forType: types) else { return nil }
            return (data, types)
        }

        // Set our text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V
        simulatePaste()

        // Restore previous clipboard after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let previousItems, !previousItems.isEmpty {
                pasteboard.clearContents()
                for (content, type) in previousItems {
                    pasteboard.setString(content, forType: type)
                }
            }
        }
    }

    private func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // 0x09 = 'v'
        keyDown?.flags = .maskCommand

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
