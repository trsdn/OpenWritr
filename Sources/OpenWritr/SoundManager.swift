import AVFoundation

@MainActor
final class SoundManager {
    private var startPlayer: AVAudioPlayer?
    private var stopPlayer: AVAudioPlayer?

    init() {
        startPlayer = generateTone(frequency: 440, duration: 0.08, ascending: true)
        stopPlayer = generateTone(frequency: 330, duration: 0.08, ascending: false)
    }

    func playStartSound() {
        startPlayer?.currentTime = 0
        startPlayer?.play()
    }

    func playStopSound() {
        stopPlayer?.currentTime = 0
        stopPlayer?.play()
    }

    private func generateTone(frequency: Double, duration: Double, ascending: Bool) -> AVAudioPlayer? {
        let sampleRate: Double = 44100
        let frameCount = Int(sampleRate * duration)
        var samples = [Float](repeating: 0, count: frameCount)

        for i in 0..<frameCount {
            let t = Double(i) / sampleRate
            let progress = t / duration

            let freqMultiplier = ascending ? (0.8 + 0.4 * progress) : (1.2 - 0.4 * progress)
            let freq = frequency * freqMultiplier

            let envelope = ascending
                ? Float(min(1.0, progress * 10) * pow(1.0 - progress, 2))
                : Float(min(1.0, progress * 10) * pow(1.0 - progress, 3))

            samples[i] = envelope * Float(sin(2.0 * .pi * freq * t)) * 0.3
        }

        return createWavPlayer(from: samples, sampleRate: Int(sampleRate))
    }

    private func createWavPlayer(from samples: [Float], sampleRate: Int) -> AVAudioPlayer? {
        let headerSize = 44
        let dataSize = samples.count * MemoryLayout<Float>.size
        let totalSize = headerSize + dataSize

        var wavData = Data(capacity: totalSize)

        wavData.append(contentsOf: "RIFF".utf8)
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(totalSize - 8).littleEndian) { Array($0) })
        wavData.append(contentsOf: "WAVE".utf8)

        wavData.append(contentsOf: "fmt ".utf8)
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(3).littleEndian) { Array($0) }) // IEEE float
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // mono
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate * 4).littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(4).littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(32).littleEndian) { Array($0) })

        wavData.append(contentsOf: "data".utf8)
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })
        samples.withUnsafeBufferPointer { ptr in
            wavData.append(UnsafeBufferPointer(start: UnsafeRawPointer(ptr.baseAddress!).assumingMemoryBound(to: UInt8.self), count: dataSize))
        }

        return try? AVAudioPlayer(data: wavData)
    }
}
