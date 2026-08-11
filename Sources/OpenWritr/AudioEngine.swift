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
    case inputDeviceRestorationFailed(AudioDeviceID, OSStatus)
    case deviceMonitoringFailed(OSStatus)
    case tapInstallationFailed(String)
    case enginePreparationFailed(String)
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
        case .captureCancelled:
            return nil
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

final class AudioEngine: @unchecked Sendable {
    private let targetSampleRate: Double = 16_000
    private let captureClock = ContinuousClock()
    private let captureBuffer = CaptureBufferState()
    private let lifecycleQueue = DispatchQueue(label: "com.openwritr.audio-engine.lifecycle")
    private let lifecycleQueueKey = DispatchSpecificKey<UInt8>()
    private let shutdownLock = NSLock()
    private let callbackLock = NSLock()

    private var lifecycleState: AudioEngineLifecycleState = .idle
    private var engine: AVAudioEngine?
    private var isRunning = false
    private var tapInstalled = false
    private var isShuttingDown = false
    private var shutdownRequested = false
    private var nextGeneration: UInt64 = 0
    private var activeGeneration: UInt64?
    private var returnedGeneration: UInt64?
    private var activeDeviceID: AudioDeviceID?
    private var recoveryAttemptedGeneration: UInt64?
    private var pendingConfigurationWork: DispatchWorkItem?
    private var selectedDeviceID: AudioDeviceID?
    private var previousSystemDefault: AudioDeviceID?
    private var configObserver: Any?
    private var deviceListListenerBlock: AudioObjectPropertyListenerBlock?
    private var devicesChangedCallback: (@Sendable () -> Void)?
    private var failureCallback: (@Sendable (AudioEngineError) -> Void)?

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

    private func selectInputDeviceOnQueue(_ deviceID: AudioDeviceID) throws {
        guard try Self.isInputDeviceAvailable(deviceID) else {
            throw AudioEngineError.inputDeviceUnavailable(deviceID)
        }
        if previousSystemDefault == nil {
            previousSystemDefault = try Self.getSystemDefaultInput()
        }
        try Self.setSystemDefaultInput(deviceID, restoring: false)
        selectedDeviceID = deviceID
    }

    private func restorePreviousSystemDefaultOnQueue() throws {
        guard let previous = previousSystemDefault else {
            selectedDeviceID = nil
            return
        }
        selectedDeviceID = nil
        previousSystemDefault = nil
        guard try Self.isInputDeviceAvailable(previous) else {
            audioLog.warning("previous system input \(previous) is no longer available")
            return
        }
        try Self.setSystemDefaultInput(previous, restoring: true)
    }

    private func clearStaleSelectionOnQueue() throws {
        guard let selected = selectedDeviceID else {
            if previousSystemDefault != nil {
                try restorePreviousSystemDefaultOnQueue()
            }
            return
        }
        guard try !Self.isInputDeviceAvailable(selected) else { return }

        audioLog.notice("removing unavailable selected input \(selected)")
        let previous = previousSystemDefault
        selectedDeviceID = nil
        previousSystemDefault = nil
        if let previous,
           try Self.isInputDeviceAvailable(previous) {
            try Self.setSystemDefaultInput(previous, restoring: true)
        }
    }

    private func resolveCaptureDeviceOnQueue() throws -> AudioDeviceID {
        try clearStaleSelectionOnQueue()
        if let selected = selectedDeviceID {
            guard try Self.isInputDeviceAvailable(selected) else {
                throw AudioEngineError.inputDeviceUnavailable(selected)
            }
            if previousSystemDefault == nil {
                previousSystemDefault = try Self.getSystemDefaultInput()
            }
            try Self.setSystemDefaultInput(selected, restoring: false)
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

    private func constructFreshEngineOnQueue(generation: UInt64) throws {
        guard case .starting = lifecycleState else {
            throw AudioEngineError.captureCancelled
        }
        let newEngine = AVAudioEngine()
        engine = newEngine
        try installTapOnQueue(engine: newEngine, generation: generation)
    }

    private func recoverEngineOnQueue(generation: UInt64) throws {
        guard case .recovering = lifecycleState else {
            throw AudioEngineError.captureCancelled
        }
        removeConfigObserverOnQueue()
        stopEngineOnQueue()
        guard !shutdownWasRequested() else {
            throw AudioEngineError.captureCancelled
        }
        activeDeviceID = try resolveCaptureDeviceOnQueue()
        guard !shutdownWasRequested() else {
            throw AudioEngineError.captureCancelled
        }
        let recoveredEngine = AVAudioEngine()
        engine = recoveredEngine
        try installTapOnQueue(engine: recoveredEngine, generation: generation)
        try prepareAndStartEngineOnQueue(recoveredEngine)
        addConfigObserverOnQueue(engine: recoveredEngine, generation: generation)
    }

    private func installTapOnQueue(engine: AVAudioEngine, generation: UInt64) throws {
        let inputNode = engine.inputNode
        let state = captureBuffer
        let target = desiredFormat
        let clock = captureClock
        let conversionState = TapConversionState()

        let tapBlock: AVAudioNodeTapBlock = { buffer, _ in
            let bufferFormat = buffer.format
            if bufferFormat.sampleRate == target.sampleRate && bufferFormat.channelCount == 1 {
                guard let channel = buffer.floatChannelData else { return }
                let samples = Array(
                    UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength))
                )
                state.append(samples, generation: generation, at: clock.now)
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
    }

    private func prepareAndStartEngineOnQueue(_ engine: AVAudioEngine) throws {
        guard !shutdownWasRequested() else {
            throw AudioEngineError.captureCancelled
        }
        var preparationError: NSError?
        guard ObjCTryCatch({ engine.prepare() }, &preparationError) else {
            throw AudioEngineError.enginePreparationFailed(
                preparationError?.localizedDescription ?? "The audio engine rejected its configuration."
            )
        }

        guard !shutdownWasRequested() else {
            throw AudioEngineError.captureCancelled
        }
        do {
            try engine.start()
            isRunning = true
        } catch {
            throw AudioEngineError.engineStartFailed(error.localizedDescription)
        }
    }

    private func stopEngineOnQueue() {
        guard let engine else {
            isRunning = false
            tapInstalled = false
            return
        }
        if isRunning || engine.isRunning {
            var stopError: NSError?
            if !ObjCTryCatch({ engine.stop() }, &stopError) {
                audioLog.error(
                    "failed to stop audio engine: \(stopError?.localizedDescription ?? "unknown error", privacy: .public)"
                )
            }
        }
        isRunning = false
        removeInstalledTapOnQueue()
        self.engine = nil
    }

    private func removeInstalledTapOnQueue() {
        guard tapInstalled, let engine else { return }
        tapInstalled = false
        let inputNode = engine.inputNode
        var removeError: NSError?
        if !ObjCTryCatch({ inputNode.removeTap(onBus: 0) }, &removeError) {
            audioLog.error(
                "failed to remove audio tap: \(removeError?.localizedDescription ?? "unknown error", privacy: .public)"
            )
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
        removeConfigObserverOnQueue()
        stopEngineOnQueue()
        if activeGeneration == generation {
            activeGeneration = nil
            activeDeviceID = nil
        }
        if returnedGeneration == generation {
            returnedGeneration = nil
        }
        if case .idle = finalState {
            recoveryAttemptedGeneration = nil
        }
        transitionOnQueue(to: finalState, generation: generation)
    }

    // MARK: - Configuration changes

    private func addConfigObserverOnQueue(engine: AVAudioEngine, generation: UInt64) {
        removeConfigObserverOnQueue()
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.lifecycleQueue.async { [weak self] in
                self?.scheduleConfigurationDecisionOnQueue(generation: generation)
            }
        }
    }

    private func removeConfigObserverOnQueue() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
    }

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

            if let engine, isRunning, engine.isRunning {
                audioLog.debug("benign configuration change for generation \(generation)")
                return
            }

            guard recoveryAttemptedGeneration != generation else {
                failActiveGenerationOnQueue(
                    generation,
                    error: .engineStartFailed("The audio engine stopped again after recovery.")
                )
                return
            }

            recoveryAttemptedGeneration = generation
            transitionOnQueue(to: .recovering, generation: generation)
            try recoverEngineOnQueue(generation: generation)
            guard !shutdownWasRequested(), activeGeneration == generation else {
                cleanupGenerationOnQueue(generation, discardSamples: true, finalState: .idle)
                return
            }
            transitionOnQueue(to: .capturing, generation: generation)
            audioLog.notice("recovered capture generation \(generation)")
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
        guard deviceListListenerBlock == nil else { return noErr }

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let devicesBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDeviceListChangedOnQueue()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            lifecycleQueue,
            devicesBlock
        )
        if status == noErr {
            deviceListListenerBlock = devicesBlock
        }
        return status
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
    }

    private func handleDeviceListChangedOnQueue() {
        guard !isShuttingDown else { return }
        do {
            try clearStaleSelectionOnQueue()
            _ = try Self.getSystemDefaultInput()
            if let generation = activeGeneration {
                scheduleConfigurationDecisionOnQueue(generation: generation)
            }
        } catch let error as AudioEngineError {
            audioLog.error("device list validation failed: \(error.localizedDescription, privacy: .public)")
            if let generation = activeGeneration, returnedGeneration == generation {
                failActiveGenerationOnQueue(generation, error: error)
            } else {
                transitionOnQueue(to: .failed(error))
                notifyFailure(error)
            }
        } catch {
            let typedError = AudioEngineError.unexpectedFailure(error.localizedDescription)
            audioLog.error("device list validation failed: \(typedError.localizedDescription, privacy: .public)")
            if let generation = activeGeneration, returnedGeneration == generation {
                failActiveGenerationOnQueue(generation, error: typedError)
            } else {
                transitionOnQueue(to: .failed(typedError))
                notifyFailure(typedError)
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
                    try restorePreviousSystemDefaultOnQueue()
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
        recoveryAttemptedGeneration = nil
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
            try constructFreshEngineOnQueue(generation: generation)
            guard !shutdownWasRequested(), !cancellation.isCancelled, let engine else {
                throw AudioEngineError.captureCancelled
            }
            captureBuffer.activate(generation: generation)
            try prepareAndStartEngineOnQueue(engine)
            guard !shutdownWasRequested(), !cancellation.isCancelled else {
                throw AudioEngineError.captureCancelled
            }
            addConfigObserverOnQueue(engine: engine, generation: generation)
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
                removeConfigObserverOnQueue()
                stopEngineOnQueue()
                activeGeneration = nil
                returnedGeneration = nil
                activeDeviceID = nil
                recoveryAttemptedGeneration = nil
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
            recoveryAttemptedGeneration = nil
            removeConfigObserverOnQueue()
            stopEngineOnQueue()
            removeDeviceListListenersOnQueue()

            do {
                try restorePreviousSystemDefaultOnQueue()
                transitionOnQueue(to: .idle)
                return .success(())
            } catch let error as AudioEngineError {
                transitionOnQueue(to: .failed(error))
                return .failure(error)
            } catch {
                let error = AudioEngineError.unexpectedFailure(error.localizedDescription)
                transitionOnQueue(to: .failed(error))
                return .failure(error)
            }
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
                  let engine = self.engine
            else { return }
            engine.stop()
            self.isRunning = false
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
