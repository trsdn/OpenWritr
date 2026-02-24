@preconcurrency import AVFoundation
import Foundation

final class AudioEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let targetSampleRate: Double = 16_000

    // Shared state accessed from realtime audio thread — protected by lock
    private let bufferLock = os_unfair_lock_t.allocate(capacity: 1)
    private var _isCapturing = false
    private var _sampleBuffer: [Float] = []
    private var isPrepared = false

    init() {
        bufferLock.initialize(to: os_unfair_lock())
    }

    deinit {
        bufferLock.deallocate()
    }

    func prepare() {
        guard !isPrepared else { return }
        isPrepared = true
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        let desiredFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        )!

        if inputFormat.sampleRate != targetSampleRate || inputFormat.channelCount != 1 {
            let converter = AVAudioConverter(from: inputFormat, to: desiredFormat)
            let sampleRate = targetSampleRate

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                guard let self else { return }
                os_unfair_lock_lock(self.bufferLock)
                let capturing = self._isCapturing
                os_unfair_lock_unlock(self.bufferLock)
                guard capturing else { return }
                guard let converter else { return }

                let frameCount = AVAudioFrameCount(
                    Double(buffer.frameLength) * sampleRate / inputFormat.sampleRate
                )
                guard frameCount > 0 else { return }
                guard let convertedBuffer = AVAudioPCMBuffer(
                    pcmFormat: desiredFormat,
                    frameCapacity: frameCount
                ) else { return }

                var error: NSError?
                let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }

                if status == .haveData, let channelData = convertedBuffer.floatChannelData {
                    let samples = Array(
                        UnsafeBufferPointer(
                            start: channelData[0],
                            count: Int(convertedBuffer.frameLength)
                        )
                    )
                    os_unfair_lock_lock(self.bufferLock)
                    self._sampleBuffer.append(contentsOf: samples)
                    os_unfair_lock_unlock(self.bufferLock)
                }
            }
        } else {
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: desiredFormat) { [weak self] buffer, _ in
                guard let self else { return }
                os_unfair_lock_lock(self.bufferLock)
                let capturing = self._isCapturing
                os_unfair_lock_unlock(self.bufferLock)
                guard capturing else { return }

                guard let channelData = buffer.floatChannelData else { return }
                let samples = Array(
                    UnsafeBufferPointer(
                        start: channelData[0],
                        count: Int(buffer.frameLength)
                    )
                )
                os_unfair_lock_lock(self.bufferLock)
                self._sampleBuffer.append(contentsOf: samples)
                os_unfair_lock_unlock(self.bufferLock)
            }
        }

        do {
            try engine.start()
        } catch {
            print("AudioEngine: failed to start: \(error)")
        }
    }

    func startCapture() {
        os_unfair_lock_lock(bufferLock)
        _sampleBuffer.removeAll(keepingCapacity: true)
        _isCapturing = true
        os_unfair_lock_unlock(bufferLock)
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
