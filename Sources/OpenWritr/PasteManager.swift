import Cocoa
import os.log

private let pasteLog = Logger(subsystem: "com.openwritr.app", category: "PasteManager")

struct PasteboardItemContent {
    struct Representation {
        let type: NSPasteboard.PasteboardType
        let data: Data
    }

    let representations: [Representation]
}

@MainActor
protocol PasteboardItemReading {
    var pasteboardTypes: [NSPasteboard.PasteboardType] { get }

    func pasteboardData(forType type: NSPasteboard.PasteboardType) -> Data?
}

@MainActor
protocol PasteboardManaging: AnyObject {
    var changeCount: Int { get }
    var pasteboardItems: [any PasteboardItemReading]? { get }

    func prepareWrite(_ items: [PasteboardItemContent]) -> (any PreparedPasteboardWrite)?

    @discardableResult
    func clearContents() -> Int
}

@MainActor
protocol PreparedPasteboardWrite {
    func write() -> Bool
}

@MainActor
protocol PasteRestoreScheduling {
    func scheduleRestore(_ action: @escaping @MainActor () -> Void)
}

@MainActor
protocol PasteCommandPosting {
    func postPasteCommand()
}

@MainActor
protocol TextPasting: AnyObject {
    var lastError: PasteManagerError? { get }
    var onRestoreFailed: ((PasteManagerError) -> Void)? { get set }

    @discardableResult
    func pasteText(_ text: String) -> PasteOutcome
    @discardableResult
    func copyText(_ text: String) -> PasteOutcome
    func flushPendingRestore()
}

enum PasteOutcome: Sendable, Equatable {
    case pasted
    case copied
    case retained
    case cancelled
}

enum PasteManagerError: LocalizedError, Sendable, Equatable {
    case unreadableRepresentation(String)
    case preparationFailed
    case clipboardChanged
    case writeFailed
    case restoreFailed
    case rollbackFailed

    var errorDescription: String? {
        switch self {
        case .unreadableRepresentation(let type):
            return "OpenWritr could not preserve clipboard content of type \(type)."
        case .preparationFailed:
            return "OpenWritr could not prepare text for the clipboard."
        case .clipboardChanged:
            return "The clipboard changed while OpenWritr was preparing output. No text was written."
        case .writeFailed:
            return "OpenWritr could not write text to the clipboard."
        case .restoreFailed:
            return "OpenWritr could not restore the previous clipboard contents."
        case .rollbackFailed:
            return "Writing text failed, and OpenWritr could not restore the previous clipboard contents."
        }
    }
}

extension TextPasting {
    func outputText(
        _ text: String,
        destination: RecordingOutputDestination,
        autoPasteEnabled: Bool
    ) -> PasteOutcome {
        switch destination {
        case .clipboard:
            return copyText(text)
        case .standard:
            return autoPasteEnabled ? pasteText(text) : .retained
        }
    }
}

extension NSPasteboardItem: PasteboardItemReading {
    var pasteboardTypes: [NSPasteboard.PasteboardType] {
        types
    }

    func pasteboardData(forType type: NSPasteboard.PasteboardType) -> Data? {
        data(forType: type)
    }
}

@MainActor
final class SystemPasteboard: PasteboardManaging {
    private final class PreparedWrite: PreparedPasteboardWrite {
        private let pasteboard: NSPasteboard
        private let items: [NSPasteboardItem]

        init(pasteboard: NSPasteboard, items: [NSPasteboardItem]) {
            self.pasteboard = pasteboard
            self.items = items
        }

        func write() -> Bool {
            items.isEmpty || pasteboard.writeObjects(items)
        }
    }

    private let pasteboard: NSPasteboard

    init(_ pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int {
        pasteboard.changeCount
    }

    var pasteboardItems: [any PasteboardItemReading]? {
        pasteboard.pasteboardItems
    }

    func prepareWrite(_ items: [PasteboardItemContent]) -> (any PreparedPasteboardWrite)? {
        let pasteboardItems = items.compactMap { item -> NSPasteboardItem? in
            let pasteboardItem = NSPasteboardItem()
            for representation in item.representations {
                guard pasteboardItem.setData(representation.data, forType: representation.type) else {
                    return nil
                }
            }
            return pasteboardItem
        }
        guard pasteboardItems.count == items.count else {
            return nil
        }
        return PreparedWrite(pasteboard: pasteboard, items: pasteboardItems)
    }

    @discardableResult
    func clearContents() -> Int {
        pasteboard.clearContents()
    }
}

struct SystemPasteCommandPoster: PasteCommandPosting {
    func postPasteCommand() {
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        keyDown?.flags = .maskCommand

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }
}

struct SystemPasteRestoreScheduler: PasteRestoreScheduling {
    func scheduleRestore(_ action: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            action()
        }
    }
}

@MainActor
final class PasteManager: TextPasting {
    private(set) var lastError: PasteManagerError?
    var onRestoreFailed: ((PasteManagerError) -> Void)?

    private struct PasteboardSnapshot {
        let items: [PasteboardItemContent]
    }

    private struct PendingRestore {
        let id: UUID
        let snapshot: PasteboardSnapshot
        let expectedChangeCount: Int
    }

    private var pendingRestore: PendingRestore?
    private var hasUnreportedRestoreFailure = false
    private let pasteboard: any PasteboardManaging
    private let commandPoster: any PasteCommandPosting
    private let restoreScheduler: any PasteRestoreScheduling
    private let errorLogger: any ErrorLogging

    init(
        pasteboard: any PasteboardManaging = SystemPasteboard(),
        commandPoster: any PasteCommandPosting = SystemPasteCommandPoster(),
        restoreScheduler: any PasteRestoreScheduling = SystemPasteRestoreScheduler(),
        errorLogger: any ErrorLogging = UnifiedErrorLogger(category: "PasteManager")
    ) {
        self.pasteboard = pasteboard
        self.commandPoster = commandPoster
        self.restoreScheduler = restoreScheduler
        self.errorLogger = errorLogger
    }

    @discardableResult
    func pasteText(_ text: String) -> PasteOutcome {
        writeText(text, destination: .standard)
    }

    @discardableResult
    func copyText(_ text: String) -> PasteOutcome {
        writeText(text, destination: .clipboard)
    }

    private func writeText(_ text: String, destination: RecordingOutputDestination) -> PasteOutcome {
        if hasUnreportedRestoreFailure {
            hasUnreportedRestoreFailure = false
            return .cancelled
        }

        lastError = nil
        guard flushPendingRestore(matching: nil) else {
            return .cancelled
        }

        let originalChangeCount = pasteboard.changeCount

        guard let snapshot = snapshot(of: pasteboard) else {
            return .cancelled
        }

        let transcriptItem = PasteboardItemContent(
            representations: [
                .init(type: .string, data: Data(text.utf8))
            ]
        )

        guard pasteboard.changeCount == originalChangeCount else {
            lastError = .clipboardChanged
            pasteLog.notice("Clipboard changed while it was being saved; cancelling paste")
            return .cancelled
        }

        guard let preparedTranscript = pasteboard.prepareWrite([transcriptItem]) else {
            recordError(.preparationFailed, message: "Failed to prepare transcript for the pasteboard")
            return .cancelled
        }

        guard pasteboard.changeCount == originalChangeCount else {
            lastError = .clipboardChanged
            pasteLog.notice("Clipboard changed while the transcript was being prepared; cancelling paste")
            return .cancelled
        }

        let transcriptOwnershipChangeCount = pasteboard.clearContents()
        guard preparedTranscript.write() else {
            recordError(.writeFailed, message: "Failed to write transcript to the pasteboard")
            if !restore(snapshot, to: pasteboard, ifUnchangedSince: transcriptOwnershipChangeCount) {
                recordError(.rollbackFailed, message: "Failed to roll back a failed clipboard write")
            }
            return .cancelled
        }

        if destination == .clipboard {
            return .copied
        }

        let transcriptChangeCount = pasteboard.changeCount
        let transactionID = UUID()
        pendingRestore = .init(
            id: transactionID,
            snapshot: snapshot,
            expectedChangeCount: transcriptChangeCount
        )
        commandPoster.postPasteCommand()

        restoreScheduler.scheduleRestore { [weak self] in
            guard let self else { return }
            if !self.flushPendingRestore(matching: transactionID) {
                self.reportRestoreFailure()
            }
        }
        return .pasted
    }

    func flushPendingRestore() {
        if !flushPendingRestore(matching: nil) {
            reportRestoreFailure()
        }
    }

    private func flushPendingRestore(matching transactionID: UUID?) -> Bool {
        guard let pendingRestore else {
            return true
        }
        guard transactionID == nil || pendingRestore.id == transactionID else {
            return true
        }

        self.pendingRestore = nil
        return restore(
            pendingRestore.snapshot,
            to: pasteboard,
            ifUnchangedSince: pendingRestore.expectedChangeCount
        )
    }

    private func snapshot(of pasteboard: any PasteboardManaging) -> PasteboardSnapshot? {
        let originalChangeCount = pasteboard.changeCount
        let pasteboardItems = pasteboard.pasteboardItems ?? []
        var snapshotItems: [PasteboardItemContent] = []

        for item in pasteboardItems {
            let types = item.pasteboardTypes
            var representations: [PasteboardItemContent.Representation] = []

            for type in types {
                // Some representations cannot be read: protected content (e.g. from
                // managed apps) or promised data that never materialises. Cancel the
                // paste rather than restore an incomplete version of the clipboard.
                guard let data = item.pasteboardData(forType: type) else {
                    guard pasteboard.changeCount == originalChangeCount else {
                        lastError = .clipboardChanged
                        pasteLog.notice("Clipboard changed while reading a representation; cancelling output")
                        return nil
                    }
                    lastError = .unreadableRepresentation(type.rawValue)
                    pasteLog.notice(
                        "Clipboard representation \(type.rawValue, privacy: .public) could not be preserved; cancelling paste"
                    )
                    return nil
                }

                representations.append(.init(type: type, data: data))
            }

            guard !representations.isEmpty else {
                lastError = .preparationFailed
                pasteLog.notice("Clipboard item has no restorable representations; cancelling paste")
                return nil
            }

            snapshotItems.append(PasteboardItemContent(representations: representations))
        }

        pasteLog.debug("Saved clipboard: \(snapshotItems.count) items, change count \(pasteboard.changeCount)")
        return PasteboardSnapshot(items: snapshotItems)
    }

    private func restore(
        _ snapshot: PasteboardSnapshot,
        to pasteboard: any PasteboardManaging,
        ifUnchangedSince expectedChangeCount: Int
    ) -> Bool {
        guard pasteboard.changeCount == expectedChangeCount else {
            return true
        }
        guard let preparedRestore = pasteboard.prepareWrite(snapshot.items) else {
            recordError(.restoreFailed, message: "Failed to prepare clipboard contents for restoration")
            return false
        }

        guard pasteboard.changeCount == expectedChangeCount else {
            return true
        }

        pasteboard.clearContents()

        guard preparedRestore.write() else {
            recordError(.restoreFailed, message: "Failed to restore clipboard contents")
            return false
        }

        return true
    }

    private func recordError(_ error: PasteManagerError, message: String) {
        lastError = error
        errorLogger.logError(message)
    }

    private func reportRestoreFailure() {
        if let onRestoreFailed {
            onRestoreFailed(.restoreFailed)
        } else {
            hasUnreportedRestoreFailure = true
        }
    }
}
