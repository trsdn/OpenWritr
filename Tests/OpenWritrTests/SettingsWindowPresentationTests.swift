import AppKit
import Testing
@testable import OpenWritr

@MainActor
@Suite("Settings window presentation")
struct SettingsWindowPresentationTests {
    @Test func closingSettingsDoesNotTerminateTheUtility() {
        let delegate = OpenWritrApplicationDelegate()
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    @Test func delayedWindowAttachmentRegistersTheActualWindow() {
        _ = NSApplication.shared
        let view = SettingsWindowHostingView()
        #expect(view.window == nil)
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = view

        #expect(SettingsWindowPresentation.window === window)
        #expect(window.level.rawValue == NSWindow.Level.floating.rawValue + 1)
        #expect(window.collectionBehavior.contains(.moveToActiveSpace))
        window.contentView = nil
    }

    @Test func anExistingSettingsWindowCanBeReopened() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        SettingsWindowPresentation.attach(window)
        SettingsWindowPresentation.bringToFront()
        #expect(window.isVisible)
        window.orderOut(nil)
        #expect(!window.isVisible)
        SettingsWindowPresentation.bringToFront()
        #expect(window.isVisible)
        window.orderOut(nil)
    }
}
