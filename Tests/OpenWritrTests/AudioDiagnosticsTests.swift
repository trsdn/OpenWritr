import CoreAudio
import Foundation
import Testing
@testable import OpenWritr

@Suite("Audio diagnostics")
struct AudioDiagnosticsTests {
    @Test func summaryDescribesAnExplicitBluetoothDevice() {
        let diagnostics = AudioDiagnostics(
            selection: .explicit,
            microphoneAccess: "authorized",
            inputDeviceCount: 3,
            device: .init(
                isDefault: false,
                transport: "bluetooth",
                isVirtualRoute: false,
                inputChannels: 1,
                sampleRate: 16_000,
                isAlive: true,
                isRunningElsewhere: true
            )
        )

        #expect(diagnostics.summary == "selection=explicit access=authorized inputs=3 default=false "
            + "transport=bluetooth virtual=false channels=1 rate=16000 alive=yes busy=yes")
    }

    @Test func summaryMarksUnknownValuesAndAnUnresolvedDevice() {
        let unknown = AudioDiagnostics(
            selection: .systemDefault,
            microphoneAccess: "denied",
            inputDeviceCount: 1,
            device: .init(
                isDefault: true,
                transport: "unknown",
                isVirtualRoute: true,
                inputChannels: 0,
                sampleRate: nil,
                isAlive: nil,
                isRunningElsewhere: nil
            )
        )
        let unresolved = AudioDiagnostics(
            selection: .systemDefault,
            microphoneAccess: "authorized",
            inputDeviceCount: 0,
            device: nil
        )

        #expect(unknown.summary.contains("rate=unknown alive=unknown busy=unknown"))
        #expect(unresolved.summary == "selection=system-default access=authorized inputs=0 device=unresolved")
    }

    @Test func transportCodesMapToStableNames() {
        let expected: [(UInt32, String)] = [
            (kAudioDeviceTransportTypeBuiltIn, "built-in"),
            (kAudioDeviceTransportTypeUSB, "usb"),
            (kAudioDeviceTransportTypeBluetooth, "bluetooth"),
            (kAudioDeviceTransportTypeBluetoothLE, "bluetooth-le"),
            (kAudioDeviceTransportTypeAggregate, "aggregate"),
            (kAudioDeviceTransportTypeVirtual, "virtual"),
            (kAudioDeviceTransportTypeUnknown, "unknown"),
            (0x1234_5678, "other"),
        ]
        for (code, name) in expected {
            #expect(AudioDiagnostics.transportName(forCode: code) == name)
        }
    }

    @Test func liveSnapshotNeverIncludesDeviceNamesOrUIDs() {
        let devices = AudioEngine.availableInputDevices()
        let summary = AudioDiagnostics.current(selectedDeviceID: devices.first?.id).summary

        #expect(summary.hasPrefix("selection="))
        for device in devices {
            #expect(!summary.contains(device.name))
            #expect(!summary.contains(device.uid))
        }
    }
}
