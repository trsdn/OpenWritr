import CoreGraphics
import IOKit.hidsystem
import XCTest
@testable import OpenWritr

@MainActor
final class HotkeyManagerTests: XCTestCase {
    private let standard = RecordingShortcut()
    private let clipboard = RecordingShortcut(destination: .clipboard)
    private let enhancedClipboard = RecordingShortcut(mode: .enhanced, destination: .clipboard)

    private func manager(for choice: HotkeyChoice) -> HotkeyManager {
        let manager = HotkeyManager()
        manager.activeFlag = choice.flag
        manager.activeKeyCode = choice.keyCode
        return manager
    }

    private func flags(for choice: HotkeyChoice) -> CGEventFlags {
        CGEventFlags(rawValue: choice.flag)
    }

    private var leftOption: CGEventFlags {
        CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | UInt64(NX_DEVICELALTKEYMASK))
    }

    func testEveryPrimaryHotkeyKeepsStandardBehavior() {
        for choice in HotkeyChoice.allCases {
            let manager = manager(for: choice)
            XCTAssertEqual(manager.processFlagsChanged(flags(for: choice), keyCode: choice.keyCode), .started(standard))
            XCTAssertEqual(manager.processFlagsChanged([], keyCode: choice.keyCode), .stopped(standard))
        }
    }

    func testOptionBeforeRecordingAndReleaseBeforePrimary() {
        for choice in HotkeyChoice.allCases {
            let manager = manager(for: choice)
            XCTAssertNil(manager.processFlagsChanged(leftOption, keyCode: 58))
            XCTAssertEqual(manager.processFlagsChanged(flags(for: choice).union(leftOption), keyCode: choice.keyCode), .started(clipboard))
            XCTAssertNil(manager.processFlagsChanged(flags(for: choice), keyCode: 58))
            XCTAssertEqual(manager.processFlagsChanged([], keyCode: choice.keyCode), .stopped(clipboard))
            XCTAssertEqual(manager.processFlagsChanged(flags(for: choice), keyCode: choice.keyCode), .started(standard))
            manager.stop()
        }
    }

    func testOptionDuringRecordingIsLatched() {
        for choice in HotkeyChoice.allCases {
            let manager = manager(for: choice)
            let primary = flags(for: choice)
            XCTAssertEqual(manager.processFlagsChanged(primary, keyCode: choice.keyCode), .started(standard))
            XCTAssertEqual(manager.processFlagsChanged(primary.union(leftOption), keyCode: 58), .modeChanged(clipboard))
            XCTAssertNil(manager.processFlagsChanged(primary, keyCode: 58))
            XCTAssertEqual(manager.processFlagsChanged([], keyCode: choice.keyCode), .stopped(clipboard))
        }
    }

    func testShiftAndOptionLatchIndependentlyInEitherOrder() {
        for choice in HotkeyChoice.allCases {
            for shiftFirst in [true, false] {
                let manager = manager(for: choice)
                let primary = flags(for: choice)
                XCTAssertEqual(manager.processFlagsChanged(primary, keyCode: choice.keyCode), .started(standard))
                let first = shiftFirst ? CGEventFlags.maskShift : leftOption
                let firstShortcut = shiftFirst ? RecordingShortcut(mode: .enhanced) : clipboard
                XCTAssertEqual(
                    manager.processFlagsChanged(primary.union(first), keyCode: shiftFirst ? 56 : 58),
                    .modeChanged(firstShortcut)
                )
                XCTAssertEqual(
                    manager.processFlagsChanged(primary.union(leftOption).union(.maskShift), keyCode: shiftFirst ? 58 : 56),
                    .modeChanged(enhancedClipboard)
                )
                XCTAssertNil(manager.processFlagsChanged(primary, keyCode: 56))
                XCTAssertEqual(manager.processFlagsChanged([], keyCode: choice.keyCode), .stopped(enhancedClipboard))
            }
        }
    }

    func testRightOptionAloneDoesNotSelectClipboard() {
        let manager = manager(for: .rightOption)
        let rightOnly = flags(for: .rightOption).union(.maskAlternate)
        XCTAssertEqual(manager.processFlagsChanged(rightOnly, keyCode: 61), .started(standard))
        XCTAssertEqual(manager.processFlagsChanged([], keyCode: 61), .stopped(standard))
    }

    func testLeftOptionHeldAfterRightOptionReleaseDoesNotRestartRecording() {
        let manager = manager(for: .rightOption)
        XCTAssertEqual(manager.processFlagsChanged(flags(for: .rightOption).union(leftOption), keyCode: 61), .started(clipboard))
        XCTAssertEqual(manager.processFlagsChanged(leftOption, keyCode: 61), .stopped(clipboard))
        XCTAssertNil(manager.processFlagsChanged([], keyCode: 58))
    }

    func testEitherOptionWorksWithFnAndRightCommand() {
        let rightOption = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | UInt64(NX_DEVICERALTKEYMASK))
        for choice in [HotkeyChoice.fn, .rightCommand] {
            let manager = manager(for: choice)
            XCTAssertEqual(
                manager.processFlagsChanged(flags(for: choice).union(rightOption), keyCode: choice.keyCode),
                .started(clipboard)
            )
            manager.stop()
        }
    }

    func testListenerStopResetsAllLatches() {
        let manager = manager(for: .fn)
        let primary = flags(for: .fn)
        XCTAssertEqual(manager.processFlagsChanged(primary.union(leftOption).union(.maskShift), keyCode: 63), .started(enhancedClipboard))
        manager.stop()
        XCTAssertEqual(manager.processFlagsChanged(primary, keyCode: 63), .started(standard))
        XCTAssertEqual(manager.processFlagsChanged([], keyCode: 63), .stopped(standard))
    }

    func testEnhancementResolutionDoesNotDependOnDestination() {
        for mode in [RecordingShortcutMode.normal, .enhanced] {
            XCTAssertEqual(mode.resolved(enhancementEnabled: false, alwaysEnhanced: false), .normal)
            XCTAssertEqual(mode.resolved(enhancementEnabled: false, alwaysEnhanced: true), .normal)
            XCTAssertEqual(mode.resolved(enhancementEnabled: true, alwaysEnhanced: false), mode)
            XCTAssertEqual(
                mode.resolved(enhancementEnabled: true, alwaysEnhanced: true),
                mode == .normal ? .enhanced : .normal
            )
        }
    }
}
