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
    private var _sampleBuffer: [Float] = []
    private var _sampleRevision: UInt64 = 0
    private var _lastSampleAt: ContinuousClock.Instant?
    private var isRunning = false
    private var selectedDeviceID: AudioDeviceID?
    private var previousSystemDefault: AudioDeviceID?
    private var configObserver: Any?
    var onDevicesChanged: (() -> Void)?

    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private let desiredFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private var deviceListListenerBlock: AudioObjectPropertyListenerBlock?

    init() {
        bufferLock.initialize(to: os_unfair_lock())
        installDeviceListListeners()
    }

    deinit {
        removeConfigObserver()
        removeDeviceListListeners()
        bufferLock.deallocate()
    }

    // MARK: - System default input device

    private static func getSystemDefaultInput() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return deviceID
    }

    static func currentSystemDefaultInputDeviceID() -> AudioDeviceID {
        getSystemDefaultInput()
    }

    private static func setSystemDefaultInput(_ deviceID: AudioDeviceID) {
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
        if status != noErr {
            audioLog.error("setSystemDefaultInput failed: \(status)")
        }
    }

    // MARK: - Engine lifecycle

    private func resetEngine() {
        removeConfigObserver()
        stopEngine()

        engine = AVAudioEngine()
        installTapAndStart()
        addConfigObserver()
    }

    private func stopEngine() {
        if isRunning {
            var err: NSError?
            let e = engine
            ObjCTryCatch({ e.inputNode.removeTap(onBus: 0) }, &err)
            engine.stop()
            isRunning = false
        }
        converter = nil
        converterInputFormat = nil
    }

    private func installTapAndStart() {
        let inputNode = engine.inputNode
        let bufLock = bufferLock
        let target = desiredFormat

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            os_unfair_lock_lock(bufLock)
            let capturing = self._isCapturing
            os_unfair_lock_unlock(bufLock)
            guard capturing else { return }

            let bufferFormat = buffer.format

            if bufferFormat.sampleRate == target.sampleRate && bufferFormat.channelCount == 1 {
                guard let ch = buffer.floatChannelData else { return }
                let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(buffer.frameLength)))
                os_unfair_lock_lock(bufLock)
                self._sampleBuffer.append(contentsOf: samples)
                self._sampleRevision &+= 1
                self._lastSampleAt = self.captureClock.now
                os_unfair_lock_unlock(bufLock)
                return
            }

            if self.converterInputFormat != bufferFormat {
                self.converter = AVAudioConverter(from: bufferFormat, to: target)
                self.converterInputFormat = bufferFormat
            }
            guard let converter = self.converter else { return }

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
                self._sampleBuffer.append(contentsOf: samples)
                self._sampleRevision &+= 1
                self._lastSampleAt = self.captureClock.now
                os_unfair_lock_unlock(bufLock)
            }
        }

        do {
            try engine.start()
            isRunning = true
            audioLog.info("running, device: \(Self.getSystemDefaultInput())")
        } catch {
            audioLog.error("failed to start: \(error.localizedDescription, privacy: .public)")
            var rmErr: NSError?
            ObjCTryCatch({ inputNode.removeTap(onBus: 0) }, &rmErr)
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
            self.resetEngine()
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

    private func installDeviceListListeners() {
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let devicesBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onDevicesChanged?()
        }
        deviceListListenerBlock = devicesBlock
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &devicesAddress, DispatchQueue.main, devicesBlock
        )
    }

    private func removeDeviceListListeners() {
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if let block = deviceListListenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &devicesAddress, DispatchQueue.main, block
            )
        }
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
    func setInputDevice(_ deviceID: AudioDeviceID?) {
        if let deviceID {
            // Save current default so we could restore later if needed
            if selectedDeviceID == nil {
                previousSystemDefault = Self.getSystemDefaultInput()
            }
            selectedDeviceID = deviceID
            Self.setSystemDefaultInput(deviceID)
        } else {
            // "System Default" selected — restore previous if we changed it
            if let prev = previousSystemDefault {
                Self.setSystemDefaultInput(prev)
                previousSystemDefault = nil
            }
            selectedDeviceID = nil
        }
        // Engine will pick up the change via config change notification
    }

    func prepare() {
        guard !isRunning else { return }
        resetEngine()
    }

    func restartForCapture() {
        resetEngine()
    }

    func startCapture() {
        os_unfair_lock_lock(bufferLock)
        _sampleBuffer.removeAll(keepingCapacity: true)
        _sampleRevision = 0
        _lastSampleAt = nil
        _isCapturing = true
        os_unfair_lock_unlock(bufferLock)

        audioLog.info("startCapture selectedDeviceID=\(self.selectedDeviceID ?? 0) systemDefault=\(Self.getSystemDefaultInput())")
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

            guard snapshot.sampleCount > 0 else {
                try? await Task.sleep(for: pollInterval)
                continue
            }

            guard let lastSampleAt = snapshot.lastSampleAt else {
                try? await Task.sleep(for: pollInterval)
                continue
            }

            let quietFor = captureClock.now - lastSampleAt
            if quietFor >= idleWindow {
                audioLog.info("capture settled after \(snapshot.sampleCount) samples and \(snapshot.revision) buffers")
                return
            }

            let remainingQuietTime = idleWindow - quietFor
            let nextSleep = remainingQuietTime < pollInterval ? remainingQuietTime : pollInterval
            try? await Task.sleep(for: nextSleep)
        }

        audioLog.info("capture settle timed out")
    }

    func stopCapture() -> [Float] {
        os_unfair_lock_lock(bufferLock)
        _isCapturing = false
        let samples = _sampleBuffer
        let revisions = _sampleRevision
        _sampleBuffer.removeAll(keepingCapacity: true)
        os_unfair_lock_unlock(bufferLock)

        audioLog.info("stopCapture samples=\(samples.count) buffers=\(revisions)")
        return samples
    }
}
