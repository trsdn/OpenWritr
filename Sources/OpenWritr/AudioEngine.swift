@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
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

struct CaptureHandle: Sendable, Hashable {
    let generation: UInt64
}

enum AudioEngineError: LocalizedError, Sendable {
    case captureCancelled
    case defaultInputQueryFailed(OSStatus)
    case noDefaultInputDevice
    case inputDeviceUnavailable(AudioDeviceID)
    case inputDeviceAvailabilityCheckFailed(AudioDeviceID, OSStatus)
    case inputDeviceSelectionFailed(AudioDeviceID, OSStatus)
    case deviceMonitoringFailed(OSStatus)
    case engineStartFailed(String)
    case unexpectedFailure(String)

    var errorDescription: String? {
        switch self {
        case .captureCancelled:
            return "Microphone capture was cancelled."
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
        case .deviceMonitoringFailed(let status):
            return "OpenWritr could not monitor microphone changes (\(Self.describe(status)))."
        case .engineStartFailed(let reason):
            return "OpenWritr could not start microphone capture: \(reason)"
        case .unexpectedFailure(let reason):
            return "OpenWritr encountered an unexpected audio error: \(reason)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .captureCancelled:
            return nil
        case .engineStartFailed:
            return "Check Microphone access in System Settings > Privacy & Security, then retry."
        case .inputDeviceAvailabilityCheckFailed:
            return "Retry the microphone change."
        case .inputDeviceUnavailable, .inputDeviceSelectionFailed:
            return "Reconnect the microphone or choose another input device."
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

private enum AudioEngineLifecycleState {
    case idle
    case starting
    case capturing
    case recovering
    case stopping
    case failed(AudioEngineError)
}

private final class TapConversionState: @unchecked Sendable {
    var converter: AVAudioConverter?
    var inputFormat: AVAudioFormat?
}

private final class CaptureBufferState: @unchecked Sendable {
    struct Snapshot {
        let isCapturing: Bool
        let generation: UInt64
        let sampleCount: Int
        let revision: UInt64
        let lastSampleAt: ContinuousClock.Instant?
    }

    private let lock = os_unfair_lock_t.allocate(capacity: 1)
    private var isCapturing = false
    private var generation: UInt64 = 0
    private var samples: [Float] = []
    private var revision: UInt64 = 0
    private var lastSampleAt: ContinuousClock.Instant?

    init() {
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    func activate(generation: UInt64) {
        os_unfair_lock_lock(lock)
        samples.removeAll(keepingCapacity: true)
        revision = 0
        lastSampleAt = nil
        self.generation = generation
        isCapturing = true
        os_unfair_lock_unlock(lock)
    }

    func append(_ newSamples: [Float], generation: UInt64, at instant: ContinuousClock.Instant) {
        os_unfair_lock_lock(lock)
        if isCapturing, self.generation == generation {
            samples.append(contentsOf: newSamples)
            revision &+= 1
            lastSampleAt = instant
        }
        os_unfair_lock_unlock(lock)
    }

    func snapshot() -> Snapshot {
        os_unfair_lock_lock(lock)
        let value = Snapshot(
            isCapturing: isCapturing,
            generation: generation,
            sampleCount: samples.count,
            revision: revision,
            lastSampleAt: lastSampleAt
        )
        os_unfair_lock_unlock(lock)
        return value
    }

    func stopAndTakeSamples(generation: UInt64) -> [Float]? {
        os_unfair_lock_lock(lock)
        guard isCapturing, self.generation == generation else {
            os_unfair_lock_unlock(lock)
            return nil
        }
        isCapturing = false
        let captured = samples
        samples.removeAll(keepingCapacity: true)
        lastSampleAt = nil
        os_unfair_lock_unlock(lock)
        return captured
    }

    @discardableResult
    func invalidate(generation: UInt64? = nil) -> Bool {
        os_unfair_lock_lock(lock)
        if let generation, self.generation != generation {
            os_unfair_lock_unlock(lock)
            return false
        }
        let wasActive = isCapturing
        isCapturing = false
        samples.removeAll(keepingCapacity: false)
        lastSampleAt = nil
        os_unfair_lock_unlock(lock)
        return wasActive
    }
}

private final class CaptureCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

#if DEBUG
struct AudioEngineDebugFaults: Sendable {
    var failStartup = false
    var startupDelay: TimeInterval = 0
    var failAfterHandle = false
    var failDuringSettle = false
    var stopEngineForConfigurationChange = false
}
#endif

protocol AudioCapturing: AnyObject, Sendable {
    var onDevicesChanged: (@Sendable () -> Void)? { get set }
    var onFailure: (@Sendable (AudioEngineError) -> Void)? { get set }
    var onAudioLevel: (@Sendable (Float, UInt64) -> Void)? { get set }

    func availableInputDevices() -> [AudioInputDevice]
    func setInputDevice(_ deviceID: AudioDeviceID?) -> Result<Void, AudioEngineError>
    func prepare() -> Result<Void, AudioEngineError>
    func startCapture() async -> Result<CaptureHandle, AudioEngineError>
    /// Waits until the capture has delivered its first audio, which a Bluetooth headset does only
    /// after it has switched to its microphone profile. Returns false if none arrived in time or
    /// the capture ended; the capture itself keeps recording the whole time.
    func waitForFirstAudio(handle: CaptureHandle, timeout: Duration) async -> Bool
    func waitForCaptureToSettle(
        handle: CaptureHandle,
        idleWindow: Duration,
        maxWait: Duration,
        pollInterval: Duration
    ) async
    func stopCapture(handle: CaptureHandle) async -> [Float]?
    func shutdown() -> Result<Void, AudioEngineError>
}

extension AudioCapturing {
    func waitForFirstAudio(handle: CaptureHandle, timeout: Duration) async -> Bool { true }
}

final class AudioEngine: AudioCapturing, @unchecked Sendable {
    private static let maximumRecoveryAttempts = 3
    private let targetSampleRate: Double = 16_000
    private let captureClock = ContinuousClock()
    private let captureBuffer = CaptureBufferState()
    private let lifecycleQueue = DispatchQueue(label: "com.openwritr.audio-engine.lifecycle")
    private let lifecycleQueueKey = DispatchSpecificKey<UInt8>()
    private let shutdownLock = NSLock()
    private let callbackLock = NSLock()

    private var lifecycleState: AudioEngineLifecycleState = .idle
    private var capture: HALInputCapture?
    private var isShuttingDown = false
    private var shutdownRequested = false
    private var nextGeneration: UInt64 = 0
    private var activeGeneration: UInt64?
    private var returnedGeneration: UInt64?
    private var activeDeviceID: AudioDeviceID?
    private var recoveryAttemptCount = 0
    private var pendingConfigurationWork: DispatchWorkItem?
    private var selectedDeviceID: AudioDeviceID?
    private var deviceListListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultInputListenerBlock: AudioObjectPropertyListenerBlock?
    private var devicesChangedCallback: (@Sendable () -> Void)?
    private var failureCallback: (@Sendable (AudioEngineError) -> Void)?
    private var audioLevelCallback: (@Sendable (Float, UInt64) -> Void)?

    var onDevicesChanged: (@Sendable () -> Void)? {
        get {
            callbackLock.lock()
            defer { callbackLock.unlock() }
            return devicesChangedCallback
        }
        set {
            callbackLock.lock()
            devicesChangedCallback = newValue
            callbackLock.unlock()
        }
    }

    var onFailure: (@Sendable (AudioEngineError) -> Void)? {
        get {
            callbackLock.lock()
            defer { callbackLock.unlock() }
            return failureCallback
        }
        set {
            callbackLock.lock()
            failureCallback = newValue
            callbackLock.unlock()
        }
    }

    var onAudioLevel: (@Sendable (Float, UInt64) -> Void)? {
        get {
            callbackLock.lock()
            defer { callbackLock.unlock() }
            return audioLevelCallback
        }
        set {
            callbackLock.lock()
            audioLevelCallback = newValue
            callbackLock.unlock()
        }
    }

    #if DEBUG
    private var debugFaults = AudioEngineDebugFaults()
    #endif

    private let desiredFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    init() {
        lifecycleQueue.setSpecific(key: lifecycleQueueKey, value: 1)
        lifecycleQueue.sync {
            let status = installDeviceListListenersOnQueue()
            if status != noErr {
                audioLog.error("failed to monitor input devices: \(status)")
            }
        }
    }

    deinit {
        if case .failure(let error) = shutdown() {
            audioLog.error("shutdown failed: \(error.localizedDescription, privacy: .public)")
        }
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

    private func selectInputDeviceOnQueue(_ deviceID: AudioDeviceID) throws {
        guard try Self.isInputDeviceAvailable(deviceID) else {
            throw AudioEngineError.inputDeviceUnavailable(deviceID)
        }
        selectedDeviceID = deviceID
    }

    private func clearStaleSelectionOnQueue() throws {
        guard let selected = selectedDeviceID else { return }
        guard try !Self.isInputDeviceAvailable(selected) else { return }

        audioLog.notice("removing unavailable selected input \(selected)")
        selectedDeviceID = nil
    }

    private func resolveCaptureDeviceOnQueue() throws -> AudioDeviceID {
        try clearStaleSelectionOnQueue()
        if let selected = selectedDeviceID {
            guard try Self.isInputDeviceAvailable(selected) else {
                throw AudioEngineError.inputDeviceUnavailable(selected)
            }
            return selected
        }

        let current = try Self.getSystemDefaultInput()
        guard try Self.isInputDeviceAvailable(current) else {
            throw AudioEngineError.inputDeviceUnavailable(current)
        }
        return current
    }

    // MARK: - Engine lifecycle

    private func transitionOnQueue(to newState: AudioEngineLifecycleState, generation: UInt64? = nil) {
        lifecycleState = newState
        let generationText = generation.map(String.init) ?? "-"
        let stateName: String
        switch newState {
        case .idle: stateName = "idle"
        case .starting: stateName = "starting"
        case .capturing: stateName = "capturing"
        case .recovering: stateName = "recovering"
        case .stopping: stateName = "stopping"
        case .failed: stateName = "failed"
        }
        audioLog.debug("lifecycle \(stateName, privacy: .public), generation \(generationText, privacy: .public)")
    }

    private func startInputCaptureOnQueue(deviceID: AudioDeviceID, generation: UInt64) throws {
        let newCapture = HALInputCapture(
            deviceID: deviceID,
            handler: makeBufferHandler(generation: generation),
            deviceLost: { [weak self] in
                self?.lifecycleQueue.async { [weak self] in
                    self?.scheduleConfigurationDecisionOnQueue(generation: generation)
                }
            }
        )
        try newCapture.start()
        capture = newCapture
    }

    private func stopInputCaptureOnQueue() {
        capture?.stop()
        capture = nil
    }

    /// Moves the running capture to the device the system now resolves, for example when the
    /// System Default input changes while recording.
    private func recoverCaptureOnQueue(generation: UInt64, deviceID: AudioDeviceID) throws {
        guard case .recovering = lifecycleState else {
            throw AudioEngineError.captureCancelled
        }
        stopInputCaptureOnQueue()
        guard !shutdownWasRequested() else {
            throw AudioEngineError.captureCancelled
        }
        activeDeviceID = deviceID
        try startInputCaptureOnQueue(deviceID: deviceID, generation: generation)
    }

    /// Converts each buffer to mono 16 kHz, appends it to the capture, and reports its level.
    private func makeBufferHandler(generation: UInt64) -> HALInputCapture.BufferHandler {
        let state = captureBuffer
        let target = desiredFormat
        let clock = captureClock
        let conversionState = TapConversionState()
        let levelHandler: @Sendable ([Float]) -> Void = { [weak self] samples in
            guard let self else { return }
            self.notifyAudioLevel(Self.rawRMSLevel(samples), generation: generation)
        }

        return { buffer in
            let bufferFormat = buffer.format
            if bufferFormat.sampleRate == target.sampleRate && bufferFormat.channelCount == 1 {
                guard let channel = buffer.floatChannelData else { return }
                let samples = Array(
                    UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength))
                )
                state.append(samples, generation: generation, at: clock.now)
                levelHandler(samples)
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
            guard status == .haveData, let channel = converted.floatChannelData else { return }
            let samples = Array(
                UnsafeBufferPointer(start: channel[0], count: Int(converted.frameLength))
            )
            state.append(samples, generation: generation, at: clock.now)
            levelHandler(samples)
        }
    }

    private func cleanupGenerationOnQueue(
        _ generation: UInt64,
        discardSamples: Bool,
        finalState: AudioEngineLifecycleState
    ) {
        pendingConfigurationWork?.cancel()
        pendingConfigurationWork = nil
        if discardSamples {
            if captureBuffer.invalidate(generation: generation) {
                audioLog.notice("discarded capture generation \(generation)")
            }
        }
        stopInputCaptureOnQueue()
        if activeGeneration == generation {
            activeGeneration = nil
            activeDeviceID = nil
        }
        if returnedGeneration == generation {
            returnedGeneration = nil
        }
        if case .idle = finalState {
            recoveryAttemptCount = 0
        }
        transitionOnQueue(to: finalState, generation: generation)
    }

    // MARK: - Configuration changes

    private func scheduleConfigurationDecisionOnQueue(generation: UInt64) {
        guard !isShuttingDown, activeGeneration == generation else { return }
        switch lifecycleState {
        case .capturing, .recovering:
            break
        default:
            return
        }

        pendingConfigurationWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.handleConfigurationDecisionOnQueue(generation: generation)
        }
        pendingConfigurationWork = item
        audioLog.debug("debounced configuration change for generation \(generation)")
        lifecycleQueue.asyncAfter(deadline: .now() + .milliseconds(250), execute: item)
    }

    private func handleConfigurationDecisionOnQueue(generation: UInt64) {
        pendingConfigurationWork = nil
        guard !isShuttingDown, activeGeneration == generation else { return }
        switch lifecycleState {
        case .capturing, .recovering:
            break
        default:
            return
        }

        do {
            guard let deviceID = activeDeviceID,
                  try Self.isInputDeviceAvailable(deviceID)
            else {
                failActiveGenerationOnQueue(
                    generation,
                    error: .inputDeviceUnavailable(activeDeviceID ?? kAudioObjectUnknown)
                )
                return
            }

            // A change of sample rate (for example a Bluetooth headset switching to its microphone
            // profile) does not interrupt the input callback, so only a stopped capture needs work.
            if capture?.isRunning == true {
                audioLog.debug("benign configuration change for generation \(generation)")
                return
            }

            guard recoveryAttemptCount < Self.maximumRecoveryAttempts else {
                failActiveGenerationOnQueue(
                    generation,
                    error: .engineStartFailed("The microphone stopped repeatedly during recovery.")
                )
                return
            }

            recoveryAttemptCount += 1
            transitionOnQueue(to: .recovering, generation: generation)
            try recoverCaptureOnQueue(generation: generation, deviceID: deviceID)
            guard !shutdownWasRequested(), activeGeneration == generation else {
                cleanupGenerationOnQueue(generation, discardSamples: true, finalState: .idle)
                return
            }
            transitionOnQueue(to: .capturing, generation: generation)
            audioLog.notice(
                "recovered capture generation \(generation), attempt \(self.recoveryAttemptCount)"
            )
        } catch let error as AudioEngineError {
            failActiveGenerationOnQueue(generation, error: error)
        } catch {
            failActiveGenerationOnQueue(
                generation,
                error: .unexpectedFailure(error.localizedDescription)
            )
        }
    }

    private func failActiveGenerationOnQueue(_ generation: UInt64, error: AudioEngineError) {
        guard activeGeneration == generation else { return }
        let shouldNotify = returnedGeneration == generation
        cleanupGenerationOnQueue(generation, discardSamples: true, finalState: .failed(error))
        audioLog.error(
            "capture generation \(generation) failed: \(error.localizedDescription, privacy: .public)"
        )
        if shouldNotify {
            notifyFailure(error)
        }
    }

    // MARK: - Device list listeners

    @discardableResult
    private func installDeviceListListenersOnQueue() -> OSStatus {
        if deviceListListenerBlock != nil, defaultInputListenerBlock != nil {
            return noErr
        }

        var installedDevicesBlock: AudioObjectPropertyListenerBlock?
        if deviceListListenerBlock == nil {
            var devicesAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.handleDeviceListChangedOnQueue()
            }
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &devicesAddress,
                lifecycleQueue,
                block
            )
            guard status == noErr else { return status }
            deviceListListenerBlock = block
            installedDevicesBlock = block
        }

        if defaultInputListenerBlock == nil {
            var defaultInputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.handleDeviceListChangedOnQueue()
            }
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultInputAddress,
                lifecycleQueue,
                block
            )
            guard status == noErr else {
                if let installedDevicesBlock {
                    var devicesAddress = AudioObjectPropertyAddress(
                        mSelector: kAudioHardwarePropertyDevices,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain
                    )
                    let removalStatus = AudioObjectRemovePropertyListenerBlock(
                        AudioObjectID(kAudioObjectSystemObject),
                        &devicesAddress,
                        lifecycleQueue,
                        installedDevicesBlock
                    )
                    if removalStatus != noErr {
                        audioLog.error("failed to roll back input device monitoring: \(removalStatus)")
                    } else {
                        deviceListListenerBlock = nil
                    }
                }
                return status
            }
            defaultInputListenerBlock = block
        }

        return noErr
    }

    private func removeDeviceListListenersOnQueue() {
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if let block = deviceListListenerBlock {
            let status = AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &devicesAddress,
                lifecycleQueue,
                block
            )
            if status == noErr {
                deviceListListenerBlock = nil
            } else {
                audioLog.error("failed to stop monitoring input devices: \(status)")
            }
        }

        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if let block = defaultInputListenerBlock {
            let status = AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultInputAddress,
                lifecycleQueue,
                block
            )
            if status == noErr {
                defaultInputListenerBlock = nil
            } else {
                audioLog.error("failed to stop monitoring the default input device: \(status)")
            }
        }
    }

    private func handleDeviceListChangedOnQueue() {
        guard !isShuttingDown else { return }
        do {
            try clearStaleSelectionOnQueue()
            if let generation = activeGeneration {
                scheduleConfigurationDecisionOnQueue(generation: generation)
            }
        } catch let error as AudioEngineError {
            audioLog.error("device list validation failed: \(error.localizedDescription, privacy: .public)")
            if let generation = activeGeneration, returnedGeneration == generation {
                failActiveGenerationOnQueue(generation, error: error)
            }
        } catch {
            let typedError = AudioEngineError.unexpectedFailure(error.localizedDescription)
            audioLog.error("device list validation failed: \(typedError.localizedDescription, privacy: .public)")
            if let generation = activeGeneration, returnedGeneration == generation {
                failActiveGenerationOnQueue(generation, error: typedError)
            }
        }
        notifyDevicesChanged()
    }

    private func notifyDevicesChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.callbackLock.lock()
            let callback = self.devicesChangedCallback
            self.callbackLock.unlock()
            callback?()
        }
    }

    private func notifyFailure(_ error: AudioEngineError) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.callbackLock.lock()
            let callback = self.failureCallback
            self.callbackLock.unlock()
            callback?(error)
        }
    }

    private func notifyAudioLevel(_ level: Float, generation: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.callbackLock.lock()
            let callback = self.audioLevelCallback
            self.callbackLock.unlock()
            callback?(level, generation)
        }
    }

    private static func rawRMSLevel(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let meanSquare = samples.reduce(Float.zero) { partialResult, sample in
            partialResult + sample * sample
        } / Float(samples.count)
        guard meanSquare.isFinite, meanSquare >= 0 else { return 0 }
        let rms = sqrt(meanSquare)
        guard rms.isFinite else { return 0 }
        return min(max(rms, 0), 1)
    }

    // MARK: - Public API

    static func availableInputDevices() -> [AudioInputDevice] {
        var propSize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize
        ) == noErr else { return [] }
        let count = Int(propSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize, &ids
        ) == noErr else { return [] }

        return ids.compactMap { deviceID -> AudioInputDevice? in
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var inputSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(
                deviceID, &inputAddress, 0, nil, &inputSize
            ) == noErr, inputSize > 0 else { return nil }
            let pointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(inputSize))
            defer { pointer.deallocate() }
            guard AudioObjectGetPropertyData(
                deviceID, &inputAddress, 0, nil, &inputSize, pointer
            ) == noErr else { return nil }
            let channelCount = UnsafeMutableAudioBufferListPointer(pointer)
                .reduce(0) { $0 + Int($1.mNumberChannels) }
            guard channelCount > 0 else { return nil }

            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameReference: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(
                deviceID, &nameAddress, 0, nil, &nameSize, &nameReference
            ) == noErr,
                let name = nameReference?.takeUnretainedValue()
            else { return nil }

            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidReference: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(
                deviceID, &uidAddress, 0, nil, &uidSize, &uidReference
            ) == noErr,
                let uid = uidReference?.takeUnretainedValue()
            else { return nil }

            return AudioInputDevice(id: deviceID, name: name as String, uid: uid as String)
        }
    }

    func availableInputDevices() -> [AudioInputDevice] {
        Self.availableInputDevices()
    }

    func setInputDevice(_ deviceID: AudioDeviceID?) -> Result<Void, AudioEngineError> {
        syncOnLifecycleQueue {
            guard !isShuttingDown else { return .failure(.captureCancelled) }
            let listenerStatus = installDeviceListListenersOnQueue()
            guard listenerStatus == noErr else {
                return .failure(.deviceMonitoringFailed(listenerStatus))
            }
            do {
                if let deviceID {
                    try selectInputDeviceOnQueue(deviceID)
                } else {
                    selectedDeviceID = nil
                }
                if let generation = activeGeneration {
                    scheduleConfigurationDecisionOnQueue(generation: generation)
                }
                return .success(())
            } catch let error as AudioEngineError {
                return .failure(error)
            } catch {
                return .failure(.unexpectedFailure(error.localizedDescription))
            }
        }
    }

    func prepare() -> Result<Void, AudioEngineError> {
        syncOnLifecycleQueue {
            guard !isShuttingDown else { return .failure(.captureCancelled) }
            let listenerStatus = installDeviceListListenersOnQueue()
            guard listenerStatus == noErr else {
                return .failure(.deviceMonitoringFailed(listenerStatus))
            }
            guard activeGeneration == nil else {
                return .failure(.captureCancelled)
            }
            do {
                try clearStaleSelectionOnQueue()
                let device = try Self.getSystemDefaultInput()
                guard try Self.isInputDeviceAvailable(device) else {
                    throw AudioEngineError.inputDeviceUnavailable(device)
                }
                transitionOnQueue(to: .idle)
                audioLog.notice("non-streaming microphone validation succeeded")
                return .success(())
            } catch let error as AudioEngineError {
                transitionOnQueue(to: .failed(error))
                audioLog.error("microphone validation failed: \(error.localizedDescription, privacy: .public)")
                return .failure(error)
            } catch {
                let error = AudioEngineError.unexpectedFailure(error.localizedDescription)
                transitionOnQueue(to: .failed(error))
                return .failure(error)
            }
        }
    }

    func startCapture() async -> Result<CaptureHandle, AudioEngineError> {
        let cancellation = CaptureCancellationToken()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lifecycleQueue.async { [self] in
                    let result = startCaptureOnQueue(cancellation: cancellation)
                    if case .success(let handle) = result {
                        returnedGeneration = handle.generation
                    }
                    continuation.resume(returning: result)
                    #if DEBUG
                    if case .success(let handle) = result {
                        scheduleDebugPostStartFaultsOnQueue(handle: handle)
                    }
                    #endif
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func startCaptureOnQueue(
        cancellation: CaptureCancellationToken
    ) -> Result<CaptureHandle, AudioEngineError> {
        guard !isShuttingDown, !shutdownWasRequested(), !cancellation.isCancelled else {
            return .failure(.captureCancelled)
        }
        guard activeGeneration == nil else {
            return .failure(.captureCancelled)
        }

        nextGeneration &+= 1
        let generation = nextGeneration
        activeGeneration = generation
        returnedGeneration = nil
        recoveryAttemptCount = 0
        transitionOnQueue(to: .starting, generation: generation)

        do {
            #if DEBUG
            if debugFaults.startupDelay > 0 {
                Thread.sleep(forTimeInterval: debugFaults.startupDelay)
            }
            if debugFaults.failStartup {
                debugFaults.failStartup = false
                throw AudioEngineError.engineStartFailed("Injected startup failure.")
            }
            #endif

            guard !shutdownWasRequested(), !cancellation.isCancelled else {
                throw AudioEngineError.captureCancelled
            }
            activeDeviceID = try resolveCaptureDeviceOnQueue()
            guard !shutdownWasRequested(), !cancellation.isCancelled, let deviceID = activeDeviceID else {
                throw AudioEngineError.captureCancelled
            }
            captureBuffer.activate(generation: generation)
            try startInputCaptureOnQueue(deviceID: deviceID, generation: generation)
            guard !shutdownWasRequested(), !cancellation.isCancelled else {
                throw AudioEngineError.captureCancelled
            }
            transitionOnQueue(to: .capturing, generation: generation)
            audioLog.notice("capture generation \(generation) started on device \(self.activeDeviceID ?? 0)")
            return .success(CaptureHandle(generation: generation))
        } catch let error as AudioEngineError {
            cleanupGenerationOnQueue(
                generation,
                discardSamples: true,
                finalState: error.isCancellation ? .idle : .failed(error)
            )
            return .failure(error)
        } catch {
            let typedError = AudioEngineError.unexpectedFailure(error.localizedDescription)
            cleanupGenerationOnQueue(generation, discardSamples: true, finalState: .failed(typedError))
            return .failure(typedError)
        }
    }

    func waitForFirstAudio(handle: CaptureHandle, timeout: Duration = .seconds(2)) async -> Bool {
        let startedAt = captureClock.now
        while captureClock.now - startedAt < timeout {
            if Task.isCancelled { return false }
            let snapshot = captureBuffer.snapshot()
            guard snapshot.isCapturing, snapshot.generation == handle.generation else { return false }
            if snapshot.sampleCount > 0 {
                let parts = (captureClock.now - startedAt).components
                let milliseconds = Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
                audioLog.notice("first audio for generation \(handle.generation) after \(milliseconds) ms")
                return true
            }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                return false
            }
        }
        audioLog.notice("no audio arrived for generation \(handle.generation) within the timeout")
        return false
    }

    func waitForCaptureToSettle(
        handle: CaptureHandle,
        idleWindow: Duration = .milliseconds(70),
        maxWait: Duration = .milliseconds(350),
        pollInterval: Duration = .milliseconds(10)
    ) async {
        let startedAt = captureClock.now
        while captureClock.now - startedAt < maxWait {
            if Task.isCancelled { return }
            let snapshot = captureBuffer.snapshot()
            guard snapshot.isCapturing, snapshot.generation == handle.generation else { return }

            #if DEBUG
            if await consumeSettleFailureIfNeeded(handle: handle) {
                return
            }
            #endif

            guard snapshot.sampleCount > 0, let lastSampleAt = snapshot.lastSampleAt else {
                do {
                    try await Task.sleep(for: pollInterval)
                } catch {
                    return
                }
                continue
            }
            let quietFor = captureClock.now - lastSampleAt
            if quietFor >= idleWindow { return }
            do {
                try await Task.sleep(for: min(idleWindow - quietFor, pollInterval))
            } catch {
                return
            }
        }
    }

    func stopCapture(handle: CaptureHandle) async -> [Float]? {
        await withCheckedContinuation { continuation in
            lifecycleQueue.async { [self] in
                guard !isShuttingDown,
                      activeGeneration == handle.generation,
                      let samples = captureBuffer.stopAndTakeSamples(generation: handle.generation)
                else {
                    continuation.resume(returning: nil)
                    return
                }

                transitionOnQueue(to: .stopping, generation: handle.generation)
                pendingConfigurationWork?.cancel()
                pendingConfigurationWork = nil
                stopInputCaptureOnQueue()
                activeGeneration = nil
                returnedGeneration = nil
                activeDeviceID = nil
                recoveryAttemptCount = 0
                transitionOnQueue(to: .idle, generation: handle.generation)
                audioLog.notice("capture generation \(handle.generation) stopped with \(samples.count) samples")
                continuation.resume(returning: samples)
            }
        }
    }

    func shutdown() -> Result<Void, AudioEngineError> {
        markShutdownRequested()
        return syncOnLifecycleQueue {
            if isShuttingDown {
                return .success(())
            }
            isShuttingDown = true
            pendingConfigurationWork?.cancel()
            pendingConfigurationWork = nil
            if let generation = activeGeneration {
                captureBuffer.invalidate(generation: generation)
                audioLog.notice("invalidated capture generation \(generation) for shutdown")
            } else {
                captureBuffer.invalidate()
            }
            activeGeneration = nil
            returnedGeneration = nil
            activeDeviceID = nil
            recoveryAttemptCount = 0
            stopInputCaptureOnQueue()
            removeDeviceListListenersOnQueue()
            selectedDeviceID = nil
            transitionOnQueue(to: .idle)
            return .success(())
        }
    }

    #if DEBUG
    func configureDebugFaults(_ faults: AudioEngineDebugFaults) {
        syncOnLifecycleQueue {
            debugFaults = faults
        }
    }

    func injectDebugPostHandleDeviceFailure(handle: CaptureHandle) {
        lifecycleQueue.async { [weak self] in
            guard let self, self.returnedGeneration == handle.generation else { return }
            self.failActiveGenerationOnQueue(
                handle.generation,
                error: .inputDeviceUnavailable(self.activeDeviceID ?? kAudioObjectUnknown)
            )
        }
    }

    func injectDebugStoppedEngineConfigurationChange(handle: CaptureHandle) {
        lifecycleQueue.async { [weak self] in
            guard let self,
                  self.returnedGeneration == handle.generation,
                  let capture = self.capture
            else { return }
            capture.stop()
            self.scheduleConfigurationDecisionOnQueue(generation: handle.generation)
        }
    }

    private func scheduleDebugPostStartFaultsOnQueue(handle: CaptureHandle) {
        if debugFaults.failAfterHandle {
            debugFaults.failAfterHandle = false
            injectDebugPostHandleDeviceFailure(handle: handle)
        }
        if debugFaults.stopEngineForConfigurationChange {
            debugFaults.stopEngineForConfigurationChange = false
            injectDebugStoppedEngineConfigurationChange(handle: handle)
        }
    }

    private func consumeSettleFailureIfNeeded(handle: CaptureHandle) async -> Bool {
        await withCheckedContinuation { continuation in
            lifecycleQueue.async { [self] in
                guard debugFaults.failDuringSettle,
                      activeGeneration == handle.generation
                else {
                    continuation.resume(returning: false)
                    return
                }
                debugFaults.failDuringSettle = false
                failActiveGenerationOnQueue(
                    handle.generation,
                    error: .engineStartFailed("Injected settle failure.")
                )
                continuation.resume(returning: true)
            }
        }
    }
    #endif

    // MARK: - Queue helpers

    private func syncOnLifecycleQueue<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: lifecycleQueueKey) != nil {
            return work()
        }
        return lifecycleQueue.sync(execute: work)
    }

    private func markShutdownRequested() {
        shutdownLock.lock()
        shutdownRequested = true
        shutdownLock.unlock()
    }

    private func shutdownWasRequested() -> Bool {
        shutdownLock.lock()
        defer { shutdownLock.unlock() }
        return shutdownRequested
    }
}

private extension AudioEngineError {
    var isCancellation: Bool {
        if case .captureCancelled = self {
            return true
        }
        return false
    }
}
