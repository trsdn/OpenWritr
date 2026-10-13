@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// A privacy-safe description of the microphone state, appended to audio error logs.
///
/// Error logs are filed as public GitHub issues, so this never includes device names or UIDs,
/// which often contain a person's name. It keeps what is needed to tell device-specific
/// Core Audio failures apart: how the device was chosen, its transport, format, and whether
/// another process is already using it.
struct AudioDiagnostics: Equatable, Sendable {
    enum Selection: String, Sendable {
        case systemDefault = "system-default"
        case explicit
    }

    struct Device: Equatable, Sendable {
        let isDefault: Bool
        let transport: String
        let isVirtualRoute: Bool
        let inputChannels: Int
        let sampleRate: Double?
        let isAlive: Bool?
        let isRunningElsewhere: Bool?
    }

    let selection: Selection
    let microphoneAccess: String
    let inputDeviceCount: Int
    /// `nil` when the device could not be resolved, for example if it just disappeared.
    let device: Device?

    var summary: String {
        var parts = [
            "selection=\(selection.rawValue)",
            "access=\(microphoneAccess)",
            "inputs=\(inputDeviceCount)",
        ]
        guard let device else {
            parts.append("device=unresolved")
            return parts.joined(separator: " ")
        }
        parts.append("default=\(device.isDefault)")
        parts.append("transport=\(device.transport)")
        parts.append("virtual=\(device.isVirtualRoute)")
        parts.append("channels=\(device.inputChannels)")
        parts.append("rate=\(device.sampleRate.map { String(Int($0.rounded())) } ?? "unknown")")
        parts.append("alive=\(Self.describe(device.isAlive))")
        parts.append("busy=\(Self.describe(device.isRunningElsewhere))")
        return parts.joined(separator: " ")
    }

    /// `selectedDeviceID` is the explicit user choice, or `nil` to follow System Default.
    static func current(selectedDeviceID: AudioDeviceID?) -> AudioDiagnostics {
        let devices = AudioEngine.availableInputDevices()
        let defaultID = try? AudioEngine.currentSystemDefaultInputDeviceID()
        let resolvedID = selectedDeviceID ?? defaultID
        let device = resolvedID.flatMap { id in
            devices.first { $0.id == id }.map { input in
                Device(
                    isDefault: id == defaultID,
                    transport: transportName(of: id),
                    isVirtualRoute: input.isLikelyVirtualRoute,
                    inputChannels: inputChannelCount(of: id),
                    sampleRate: property(of: id, selector: kAudioDevicePropertyNominalSampleRate) as Float64?,
                    isAlive: (property(of: id, selector: kAudioDevicePropertyDeviceIsAlive) as UInt32?)
                        .map { $0 != 0 },
                    isRunningElsewhere: (
                        property(of: id, selector: kAudioDevicePropertyDeviceIsRunningSomewhere) as UInt32?
                    ).map { $0 != 0 }
                )
            }
        }
        return AudioDiagnostics(
            selection: selectedDeviceID == nil ? .systemDefault : .explicit,
            microphoneAccess: accessName(AVCaptureDevice.authorizationStatus(for: .audio)),
            inputDeviceCount: devices.count,
            device: device
        )
    }

    static func transportName(forCode code: UInt32) -> String {
        switch code {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeBluetooth: return "bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "bluetooth-le"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeThunderbolt: return "thunderbolt"
        case kAudioDeviceTransportTypeHDMI: return "hdmi"
        case kAudioDeviceTransportTypeDisplayPort: return "displayport"
        case kAudioDeviceTransportTypeAirPlay: return "airplay"
        case kAudioDeviceTransportTypeFireWire: return "firewire"
        case kAudioDeviceTransportTypePCI: return "pci"
        case kAudioDeviceTransportTypeAutoAggregate: return "auto-aggregate"
        case kAudioDeviceTransportTypeUnknown: return "unknown"
        default: return "other"
        }
    }

    private static func describe(_ value: Bool?) -> String {
        value.map { $0 ? "yes" : "no" } ?? "unknown"
    }

    private static func accessName(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not-determined"
        @unknown default: return "unknown"
        }
    }

    private static func transportName(of deviceID: AudioDeviceID) -> String {
        (property(of: deviceID, selector: kAudioDevicePropertyTransportType) as UInt32?)
            .map(transportName(forCode:)) ?? "unknown"
    }

    private static func property<Value>(
        of deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> Value? where Value: BitwiseCopyable {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<Value>.size)
        let buffer = UnsafeMutablePointer<Value>.allocate(capacity: 1)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, buffer) == noErr else {
            return nil
        }
        return buffer.pointee
    }

    private static func inputChannelCount(of deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0
        else { return 0 }
        let pointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer) == noErr else {
            return 0
        }
        return UnsafeMutableAudioBufferListPointer(pointer).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
