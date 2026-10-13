@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os.log

private let captureLog = Logger(subsystem: "com.openwritr.app", category: "AudioEngine")

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
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32
        else {
            throw AudioEngineError.engineStartFailed("The input device does not provide 32-bit float audio.")
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
    /// the mono and interleaved layouts input devices use, and hands it on as a mono buffer at the
    /// device's current sample rate (which can change while capturing, for example when a Bluetooth
    /// headset switches to its microphone profile).
    private func handleInput(_ input: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = list.first,
              let data = first.mData?.assumingMemoryBound(to: Float.self),
              first.mDataByteSize > 0,
              first.mNumberChannels > 0,
              let sampleRate = Self.nominalSampleRate(of: deviceID), sampleRate > 0
        else { return }

        let channels = Int(first.mNumberChannels)
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
        guard frames > 0,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let destination = buffer.floatChannelData?[0]
        else { return }

        if channels == 1 {
            destination.update(from: data, count: frames)
        } else {
            for frame in 0..<frames {
                destination[frame] = data[frame * channels]
            }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
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

    private static func nominalSampleRate(of deviceID: AudioDeviceID) -> Float64? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate) == noErr else {
            return nil
        }
        return rate
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
