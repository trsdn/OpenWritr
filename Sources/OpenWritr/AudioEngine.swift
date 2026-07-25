@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import ObjCExceptionCatcher
import os.log

private let audioLog = Logger(subsystem: "com.openwritr.app", category: "AudioEngine")

struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let name: String
    let uid: String

    var isLikelyVirtualRoute: Bool {
        let haystack = "\(name) \(uid)".lowercased()
        return haystack.contains("virtual")
            || haystack.contains("stream")
            || haystack.contains("loopback")
            || haystack.contains("teams")
            || haystack.contains("detail audio")
            || haystack.contains("boomaudio")
            || haystack.contains("rodeconnectaudiodevice_uid")
    }
}

enum AudioEngineError: LocalizedError, Sendable {
    case defaultInputQueryFailed(OSStatus)
    case noDefaultInputDevice
    case inputDeviceUnavailable(AudioDeviceID)
    case inputDeviceAvailabilityCheckFailed(AudioDeviceID, OSStatus)
    case inputDeviceSelectionFailed(AudioDeviceID, OSStatus)
    case inputDeviceRestorationFailed(AudioDeviceID, OSStatus)
    case deviceMonitoringFailed(OSStatus)
    case tapInstallationFailed(String)
    case enginePreparationFailed(String)
    case engineStartFailed(String)
    case unexpectedFailure(String)

    var errorDescription: String? {
        switch self {
        case .defaultInputQueryFailed(let status):
            return "OpenWritr could not read the system input device (\(Self.describe(status)))."
        case .noDefaultInputDevice:
            return "No system input device is currently available."
        case .inputDeviceUnavailable:
            return "The selected microphone is no longer available."
        case .inputDeviceAvailabilityCheckFailed(_, let status):
            return "OpenWritr could not verify the selected microphone (\(Self.describe(status)))."
        case .inputDeviceSelectionFailed(_, let status):
            return "OpenWritr could not select the requested microphone (\(Self.describe(status)))."
        case .inputDeviceRestorationFailed(_, let status):
            return "OpenWritr could not restore the previous system microphone (\(Self.describe(status)))."
        case .deviceMonitoringFailed(let status):
            return "OpenWritr could not monitor microphone changes (\(Self.describe(status)))."
        case .tapInstallationFailed(let reason):
            return "OpenWritr could not access microphone audio: \(reason)"
        case .enginePreparationFailed(let reason):
            return "OpenWritr could not prepare microphone capture: \(reason)"
        case .engineStartFailed(let reason):
            return "OpenWritr could not start microphone capture: \(reason)"
        case .unexpectedFailure(let reason):
            return "OpenWritr encountered an unexpected audio error: \(reason)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .tapInstallationFailed, .enginePreparationFailed, .engineStartFailed:
            return "Check Microphone access in System Settings > Privacy & Security, then retry."
        case .inputDeviceAvailabilityCheckFailed:
            return "Retry the microphone change."
        case .inputDeviceUnavailable, .inputDeviceSelectionFailed:
            return "Reconnect the microphone or choose another input device."
        case .inputDeviceRestorationFailed:
            return "Choose the preferred input device in System Settings > Sound > Input."
        case .defaultInputQueryFailed, .noDefaultInputDevice, .deviceMonitoringFailed, .unexpectedFailure:
            return "Check that a microphone is connected, then retry."
        }
    }

    private static func describe(_ status: OSStatus) -> String {
        let description = NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(status)
        ).localizedDescription
        return "Core Audio error \(status): \(description)"
    }
}

/// Each instance is owned exclusively by one audio-tap callback.
private final class TapConversionState: @unchecked Sendable {
    var converter: AVAudioConverter?
    var inputFormat: AVAudioFormat?
}

final class AudioEngine: @unchecked Sendable {
    private struct CaptureSnapshot {
        let isCapturing: Bool
        let sampleCount: Int
        let revision: UInt64
        let lastSampleAt: ContinuousClock.Instant?
    }

    private var engine = AVAudioEngine()
    private let targetSampleRate: Double = 16_000
    private let captureClock = ContinuousClock()

    private let bufferLock = os_unfair_lock_t.allocate(capacity: 1)
    private var _isCapturing = false
    private var _captureGeneration: UInt64 = 0
    private var _sampleBuffer: [Float] = []
    private var _sampleRevision: UInt64 = 0
    private var _lastSampleAt: ContinuousClock.Instant?
    private var isRunning = false
    private var tapInstalled = false
    private var selectedDeviceID: AudioDeviceID?
    private var previousSystemDefault: AudioDeviceID?
    private var configObserver: Any?
    var onDevicesChanged: (() -> Void)?
    var onFailure: ((AudioEngineError) -> Void)?

    private let desiredFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private var deviceListListenerBlock: AudioObjectPropertyListenerBlock?

    init() {
        bufferLock.initialize(to: os_unfair_lock())
        _ = installDeviceListListeners()
    }

    deinit {
        if case .failure(let error) = shutdown() {
            audioLog.error("shutdown failed: \(error.localizedDescription, privacy: .public)")
        }
        bufferLock.deinitialize(count: 1)
        bufferLock.deallocate()
    }

    // MARK: - System default input device

    private static func getSystemDefaultInput() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr else {
            throw AudioEngineError.defaultInputQueryFailed(status)
        }
        guard deviceID != kAudioObjectUnknown else {
            throw AudioEngineError.noDefaultInputDevice
        }
        return deviceID
    }

    static func currentSystemDefaultInputDeviceID() throws -> AudioDeviceID {
        try getSystemDefaultInput()
    }

    private static func setSystemDefaultInput(_ deviceID: AudioDeviceID, restoring: Bool) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &id
        )
        guard status == noErr else {
            if restoring {
                throw AudioEngineError.inputDeviceRestorationFailed(deviceID, status)
            }
            throw AudioEngineError.inputDeviceSelectionFailed(deviceID, status)
        }
    }

    private static func isInputDeviceAvailable(_ deviceID: AudioDeviceID) throws -> Bool {
        guard deviceID != kAudioObjectUnknown else { return false }

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devicesSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress, 0, nil, &devicesSize
        )
        guard status == noErr else {
            throw AudioEngineError.inputDeviceAvailabilityCheckFailed(deviceID, status)
        }

        let deviceCount = Int(devicesSize) / MemoryLayout<AudioDeviceID>.size
        guard deviceCount > 0 else { return false }
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress, 0, nil, &devicesSize, &deviceIDs
        )
        guard status == noErr else {
            throw AudioEngineError.inputDeviceAvailabilityCheckFailed(deviceID, status)
        }
        guard deviceIDs.contains(deviceID) else { return false }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard status == noErr else {
            throw AudioEngineError.inputDeviceAvailabilityCheckFailed(deviceID, status)
        }
        guard size > 0 else { return false }

        let pointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
        defer { pointer.deallocate() }
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        guard status == noErr else {
            throw AudioEngineError.inputDeviceAvailabilityCheckFailed(deviceID, status)
        }
        return UnsafeMutableAudioBufferListPointer(pointer).contains { $0.mNumberChannels > 0 }
    }

    private func selectInputDevice(_ deviceID: AudioDeviceID) throws {
        guard try Self.isInputDeviceAvailable(deviceID) else {
            throw AudioEngineError.inputDeviceUnavailable(deviceID)
        }

        let defaultToRestore = try previousSystemDefault ?? Self.getSystemDefaultInput()
        try Self.setSystemDefaultInput(deviceID, restoring: false)

        previousSystemDefault = defaultToRestore
        selectedDeviceID = deviceID
    }

    private func restorePreviousSystemDefault() throws {
        guard let previous = previousSystemDefault else {
            selectedDeviceID = nil
            return
        }
        guard try Self.isInputDeviceAvailable(previous) else {
            audioLog.warning("previous system input \(previous) is no longer available")
            selectedDeviceID = nil
            previousSystemDefault = nil
            return
        }

        try Self.setSystemDefaultInput(previous, restoring: true)
        selectedDeviceID = nil
        previousSystemDefault = nil
    }

    // MARK: - Engine lifecycle

    private func resetEngine() throws {
        removeConfigObserver()
        stopEngine()

        engine = AVAudioEngine()
        try installTapAndStart()
        addConfigObserver()
    }

    private func stopEngine() {
        if isRunning || engine.isRunning {
            let currentEngine = engine
            var stopError: NSError?
            if !ObjCTryCatch({ currentEngine.stop() }, &stopError) {
                audioLog.error(
                    "failed to stop audio engine: \(stopError?.localizedDescription ?? "unknown error", privacy: .public)"
                )
            }
        }
        isRunning = false
        removeInstalledTap()
    }

    private func removeInstalledTap() {
        guard tapInstalled else { return }
        tapInstalled = false

        let inputNode = engine.inputNode
        var removeError: NSError?
        if !ObjCTryCatch({ inputNode.removeTap(onBus: 0) }, &removeError) {
            audioLog.error(
                "failed to remove audio tap: \(removeError?.localizedDescription ?? "unknown error", privacy: .public)"
            )
        }
    }

    private func installTapAndStart() throws {
        let inputNode = engine.inputNode
        let bufLock = bufferLock
        let target = desiredFormat
        let conversionState = TapConversionState()

        let tapBlock: AVAudioNodeTapBlock = { [weak self] buffer, _ in
            guard let self else { return }
            os_unfair_lock_lock(bufLock)
            let capturing = self._isCapturing
            let captureGeneration = self._captureGeneration
            os_unfair_lock_unlock(bufLock)
            guard capturing else { return }

            let bufferFormat = buffer.format

            if bufferFormat.sampleRate == target.sampleRate && bufferFormat.channelCount == 1 {
                guard let ch = buffer.floatChannelData else { return }
                let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(buffer.frameLength)))
                os_unfair_lock_lock(bufLock)
                if self._isCapturing, self._captureGeneration == captureGeneration {
                    self._sampleBuffer.append(contentsOf: samples)
                    self._sampleRevision &+= 1
                    self._lastSampleAt = self.captureClock.now
                }
                os_unfair_lock_unlock(bufLock)
                return
            }

            if conversionState.inputFormat != bufferFormat {
                conversionState.converter = AVAudioConverter(from: bufferFormat, to: target)
                conversionState.inputFormat = bufferFormat
            }
            guard let converter = conversionState.converter else { return }

            let ratio = target.sampleRate / bufferFormat.sampleRate
            let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            guard frameCount > 0,
                  let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: frameCount)
            else { return }

            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            if status == .haveData, let ch = converted.floatChannelData {
                let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(converted.frameLength)))
                os_unfair_lock_lock(bufLock)
                if self._isCapturing, self._captureGeneration == captureGeneration {
                    self._sampleBuffer.append(contentsOf: samples)
                    self._sampleRevision &+= 1
                    self._lastSampleAt = self.captureClock.now
                }
                os_unfair_lock_unlock(bufLock)
            }
        }

        var tapError: NSError?
        guard ObjCTryCatch({
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil, block: tapBlock)
        }, &tapError) else {
            throw AudioEngineError.tapInstallationFailed(
                tapError?.localizedDescription ?? "The audio input rejected the capture format."
            )
        }
        tapInstalled = true

        var preparationError: NSError?
        guard ObjCTryCatch({ self.engine.prepare() }, &preparationError) else {
            removeInstalledTap()
            throw AudioEngineError.enginePreparationFailed(
                preparationError?.localizedDescription ?? "The audio engine rejected its configuration."
            )
        }

        do {
            try engine.start()
            isRunning = true
            if let deviceID = try? Self.getSystemDefaultInput() {
                audioLog.info("running, device: \(deviceID)")
            } else {
                audioLog.info("running")
            }
        } catch {
            stopEngine()
            throw AudioEngineError.engineStartFailed(error.localizedDescription)
        }
    }

    // MARK: - Config change observer

    private func addConfigObserver() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            audioLog.info("config changed, rebuilding")
            do {
                try self.resetEngine()
            } catch let error as AudioEngineError {
                self.reportFailure(error)
            } catch {
                self.reportFailure(.engineStartFailed(error.localizedDescription))
            }
            self.onDevicesChanged?()
        }
    }

    private func removeConfigObserver() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
    }

    // MARK: - Device list listeners

    @discardableResult
    private func installDeviceListListeners() -> OSStatus {
        guard deviceListListenerBlock == nil else { return noErr }

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let devicesBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDeviceListChanged()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &devicesAddress, DispatchQueue.main, devicesBlock
        )
        if status == noErr {
            deviceListListenerBlock = devicesBlock
        } else {
            audioLog.error("failed to monitor input devices: \(status)")
        }
        return status
    }

    private func removeDeviceListListeners() {
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if let block = deviceListListenerBlock {
            let status = AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &devicesAddress, DispatchQueue.main, block
            )
            if status == noErr {
                deviceListListenerBlock = nil
            } else {
                audioLog.error("failed to stop monitoring input devices: \(status)")
            }
        }
    }

    private func handleDeviceListChanged() {
        do {
            if let selectedDeviceID,
               try !Self.isInputDeviceAvailable(selectedDeviceID) {
                // The selection is stale, but the previous default remains pending until restored.
                self.selectedDeviceID = nil
                try restorePreviousSystemDefault()
            } else if selectedDeviceID == nil, previousSystemDefault != nil {
                try restorePreviousSystemDefault()
            }
        } catch let error as AudioEngineError {
            reportFailure(error)
        } catch {
            reportFailure(.unexpectedFailure(error.localizedDescription))
        }
        onDevicesChanged?()
    }

    private func reportFailure(_ error: AudioEngineError) {
        audioLog.error("\(error.localizedDescription, privacy: .public)")
        onFailure?(error)
    }

    // MARK: - Public API

    static func availableInputDevices() -> [AudioInputDevice] {
        var propSize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize) == noErr else { return [] }
        let count = Int(propSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize, &ids) == noErr else { return [] }

        return ids.compactMap { deviceID -> AudioInputDevice? in
            var inputAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var inputSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &inputAddr, 0, nil, &inputSize) == noErr, inputSize > 0 else { return nil }
            let ptr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(inputSize))
            defer { ptr.deallocate() }
            guard AudioObjectGetPropertyData(deviceID, &inputAddr, 0, nil, &inputSize, ptr) == noErr else { return nil }
            let ch = UnsafeMutableAudioBufferListPointer(ptr).reduce(0) { $0 + Int($1.mNumberChannels) }
            guard ch > 0 else { return nil }

            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameRef: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, &nameRef) == noErr,
                  let name = nameRef?.takeUnretainedValue() else { return nil }

            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidRef: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(deviceID, &uidAddr, 0, nil, &uidSize, &uidRef) == noErr,
                  let uid = uidRef?.takeUnretainedValue() else { return nil }

            return AudioInputDevice(id: deviceID, name: name as String, uid: uid as String)
        }
    }

    /// Switch input device by changing the macOS system default input.
    /// AVAudioEngine always uses the system default — this is the only
    /// reliable way to switch devices, especially for Bluetooth (AirPods).
    /// The running engine picks up a successful change via its configuration observer.
    func setInputDevice(_ deviceID: AudioDeviceID?) -> Result<Void, AudioEngineError> {
        do {
            if let deviceID {
                let listenerStatus = installDeviceListListeners()
                guard listenerStatus == noErr else {
                    return .failure(.deviceMonitoringFailed(listenerStatus))
                }
                try selectInputDevice(deviceID)
            } else {
                try restorePreviousSystemDefault()
            }
            return .success(())
        } catch let error as AudioEngineError {
            return .failure(error)
        } catch {
            return .failure(.unexpectedFailure(error.localizedDescription))
        }
    }

    func prepare() -> Result<Void, AudioEngineError> {
        let listenerStatus = installDeviceListListeners()
        guard listenerStatus == noErr else {
            return .failure(.deviceMonitoringFailed(listenerStatus))
        }
        guard !isRunning || !engine.isRunning else { return .success(()) }

        do {
            try resetEngine()
            return .success(())
        } catch let error as AudioEngineError {
            return .failure(error)
        } catch {
            return .failure(.unexpectedFailure(error.localizedDescription))
        }
    }

    /// Stops capture and restores any system input changed by OpenWritr.
    /// This method is idempotent and should be called during normal app shutdown.
    func shutdown() -> Result<Void, AudioEngineError> {
        removeConfigObserver()
        stopEngine()
        removeDeviceListListeners()

        os_unfair_lock_lock(bufferLock)
        _isCapturing = false
        _sampleBuffer.removeAll(keepingCapacity: false)
        os_unfair_lock_unlock(bufferLock)

        do {
            try restorePreviousSystemDefault()
            return .success(())
        } catch let error as AudioEngineError {
            return .failure(error)
        } catch {
            return .failure(.unexpectedFailure(error.localizedDescription))
        }
    }

    func restartForCapture() -> Result<Void, AudioEngineError> {
        prepare()
    }

    func startCapture() {
        os_unfair_lock_lock(bufferLock)
        _sampleBuffer.removeAll(keepingCapacity: true)
        _sampleRevision = 0
        _lastSampleAt = nil
        _captureGeneration &+= 1
        _isCapturing = true
        os_unfair_lock_unlock(bufferLock)
    }

    private func captureSnapshot() -> CaptureSnapshot {
        os_unfair_lock_lock(bufferLock)
        let snapshot = CaptureSnapshot(
            isCapturing: _isCapturing,
            sampleCount: _sampleBuffer.count,
            revision: _sampleRevision,
            lastSampleAt: _lastSampleAt
        )
        os_unfair_lock_unlock(bufferLock)
        return snapshot
    }

    func waitForCaptureToSettle(
        idleWindow: Duration = .milliseconds(70),
        pollInterval: Duration = .milliseconds(20),
        maxWait: Duration = .milliseconds(350)
    ) async {
        let startedAt = captureClock.now
        while captureClock.now - startedAt < maxWait {
            let snapshot = captureSnapshot()
            guard snapshot.isCapturing else { return }
            guard snapshot.sampleCount > 0, let lastSampleAt = snapshot.lastSampleAt else {
                try? await Task.sleep(for: pollInterval)
                continue
            }
            let quietFor = captureClock.now - lastSampleAt
            if quietFor >= idleWindow { return }
            try? await Task.sleep(for: min(idleWindow - quietFor, pollInterval))
        }
    }

    func stopCapture() -> [Float] {
        os_unfair_lock_lock(bufferLock)
        _isCapturing = false
        let samples = _sampleBuffer
        _sampleBuffer.removeAll(keepingCapacity: true)
        os_unfair_lock_unlock(bufferLock)
        return samples
    }
}
