@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os.log

private let captureLog = Logger(subsystem: "com.openwritr.app", category: "AudioEngine")

/// The sample types input devices deliver through a Core Audio I/O callback.
enum HALSampleKind: Equatable, Sendable {
    case float32
    case int16
    case int32

    /// Nil for formats OpenWritr cannot read: compressed, big-endian, or other bit depths.
    init?(_ format: AudioStreamBasicDescription) {
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
        else { return nil }
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        switch (format.mBitsPerChannel, isFloat, isSignedInteger) {
        case (32, true, _): self = .float32
        case (16, false, true): self = .int16
        case (32, false, true): self = .int32
        default: return nil
        }
    }

    var bytesPerSample: Int {
        switch self {
        case .float32, .int32: return 4
        case .int16: return 2
        }
    }
}

enum HALSampleConverter {
    /// The first channel of an interleaved (or single-channel) buffer as Float samples in -1...1.
    static func firstChannel(
        of raw: UnsafeRawPointer,
        byteCount: Int,
        channels: Int,
        kind: HALSampleKind
    ) -> [Float] {
        guard channels > 0 else { return [] }
        let frames = byteCount / (kind.bytesPerSample * channels)
        guard frames > 0 else { return [] }
        var samples = [Float](repeating: 0, count: frames)
        switch kind {
        case .float32:
            let source = raw.assumingMemoryBound(to: Float.self)
            for frame in 0..<frames { samples[frame] = source[frame * channels] }
        case .int16:
            let source = raw.assumingMemoryBound(to: Int16.self)
            for frame in 0..<frames { samples[frame] = Float(source[frame * channels]) / 32_768 }
        case .int32:
            let source = raw.assumingMemoryBound(to: Int32.self)
            for frame in 0..<frames { samples[frame] = Float(source[frame * channels]) / 2_147_483_648 }
        }
        return samples
    }
}

/// Captures audio from one input device without `AVAudioEngine`.
///
/// `AVAudioEngine` couples input and output in a single I/O unit, so a capture depends on the
/// current output device too. With a Bluetooth headset that made capture unreliable: the engine
/// stopped when the headset switched its profile (the output changes as well), and binding the
/// built-in microphone while the headset was the output produced no samples. This reads the input
/// device directly through a Core Audio I/O callback, so the output device is irrelevant.
final class HALInputCapture: @unchecked Sendable {
    /// Called on a dedicated queue with mono Float32 audio at the device's current sample rate.
    typealias BufferHandler = @Sendable (AVAudioPCMBuffer) -> Void
    /// Called on the audio queue when the device stops being available.
    typealias DeviceLostHandler = @Sendable () -> Void

    private let deviceID: AudioDeviceID
    private let handler: BufferHandler
    private let deviceLost: DeviceLostHandler
    private let queue = DispatchQueue(label: "com.openwritr.audio-input", qos: .userInteractive)
    private let lock = NSLock()

    private var procID: AudioDeviceIOProcID?
    private var aliveListener: AudioObjectPropertyListenerBlock?
    private var started = false

    init(deviceID: AudioDeviceID, handler: @escaping BufferHandler, deviceLost: @escaping DeviceLostHandler) {
        self.deviceID = deviceID
        self.handler = handler
        self.deviceLost = deviceLost
    }

    deinit {
        stop()
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }

        let format = try Self.inputStreamFormat(of: deviceID)
        guard HALSampleKind(format) != nil else {
            throw AudioEngineError.engineStartFailed("The input device uses an audio format OpenWritr cannot read.")
        }

        var newProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&newProcID, deviceID, queue) { [weak self] _, input, _, _, _ in
            self?.handleInput(input)
        }
        guard createStatus == noErr, let newProcID else {
            throw AudioEngineError.inputDeviceSelectionFailed(deviceID, createStatus)
        }
        procID = newProcID

        installAliveListener()
        let startStatus = AudioDeviceStart(deviceID, newProcID)
        guard startStatus == noErr else {
            removeAliveListener()
            AudioDeviceDestroyIOProcID(deviceID, newProcID)
            procID = nil
            throw AudioEngineError.inputDeviceSelectionFailed(deviceID, startStatus)
        }
        started = true
        captureLog.notice(
            "started input capture on device \(self.deviceID) \(AudioDiagnostics.deviceFormatSummary(for: self.deviceID), privacy: .public)"
        )
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let procID else { return }
        started = false
        removeAliveListener()
        AudioDeviceStop(deviceID, procID)
        AudioDeviceDestroyIOProcID(deviceID, procID)
        self.procID = nil
    }

    // MARK: - Audio callback

    /// Runs on `queue`. Takes the first channel of the first buffer, which is the microphone for
    /// the mono and interleaved layouts input devices use, and hands it on as a mono Float32 buffer
    /// at the device's current sample rate. The device's format is read for every callback, so a
    /// change while capturing is followed: a Bluetooth headset switching to its microphone profile
    /// changes the rate, and a device may change its sample type.
    private func handleInput(_ input: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = list.first,
              let data = first.mData,
              first.mDataByteSize > 0,
              first.mNumberChannels > 0,
              let streamFormat = try? Self.inputStreamFormat(of: deviceID),
              let kind = HALSampleKind(streamFormat)
        else { return }

        let samples = HALSampleConverter.firstChannel(
            of: UnsafeRawPointer(data),
            byteCount: Int(first.mDataByteSize),
            channels: Int(first.mNumberChannels),
            kind: kind
        )
        guard !samples.isEmpty,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: streamFormat.mSampleRate,
                  channels: 1,
                  interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let destination = buffer.floatChannelData?[0]
        else { return }

        destination.update(from: samples, count: samples.count)
        buffer.frameLength = AVAudioFrameCount(samples.count)
        handler(buffer)
    }

    // MARK: - Device liveness

    private func installAliveListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, !Self.isAlive(self.deviceID) else { return }
            self.deviceLost()
        }
        if AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, block) == noErr {
            aliveListener = block
        }
    }

    private func removeAliveListener() {
        guard let aliveListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, aliveListener)
        self.aliveListener = nil
    }

    // MARK: - Device properties

    private static func inputStreamFormat(of deviceID: AudioDeviceID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &format)
        guard status == noErr, format.mSampleRate > 0, format.mChannelsPerFrame > 0 else {
            throw AudioEngineError.inputDeviceAvailabilityCheckFailed(deviceID, status)
        }
        return format
    }

    private static func isAlive(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var alive: UInt32 = 1
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &alive) == noErr else {
            return false
        }
        return alive != 0
    }
}
