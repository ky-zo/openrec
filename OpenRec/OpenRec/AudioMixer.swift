import Foundation
import CoreMedia
import AVFoundation

/// Energy snapshot for a 100ms audio chunk, tracking which source is dominant.
struct AudioEnergySnapshot {
    let timestamp: Double // seconds since mixer start
    let micRMS: Float
    let systemRMS: Float

    var dominantSource: AudioSource {
        let noiseFloor: Float = 0.008
        // When mic is active but system is silent → definitely "Me" speaking
        if micRMS > noiseFloor && systemRMS < noiseFloor {
            return .mic
        }
        // When system audio is active, mic also picks it up via speaker bleed.
        // Only attribute to "Me" if mic is overwhelmingly louder (3x+).
        if systemRMS > noiseFloor {
            return micRMS > systemRMS * 3.0 ? .mic : .system
        }
        // Both quiet → neutral
        return .system
    }
}

enum AudioSource {
    case mic
    case system
}

/// Mixes system + mic Float32 PCM into mono Int16 PCM chunks for STT.
class AudioMixer {
    private let lock = NSLock()
    private var systemBuffer: [Float] = []
    private var micBuffer: [Float] = []
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "audiomixer.timer")
    private let targetSampleRate: Double = 16000
    private var startTime: Date?
    private var _energyTimeline: [AudioEnergySnapshot] = []

    var onChunkReady: ((Data) -> Void)?

    /// Thread-safe copy of the energy timeline recorded during mixing.
    var energyTimeline: [AudioEnergySnapshot] {
        lock.lock()
        let copy = _energyTimeline
        lock.unlock()
        return copy
    }

    func appendSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let samples = extractFloat32Samples(from: sampleBuffer) else { return }
        let mono = stereoToMono(samples)
        let resampled = resampleIfNeeded(mono, from: 48000, to: targetSampleRate)
        lock.lock()
        systemBuffer.append(contentsOf: resampled)
        lock.unlock()
    }

    func appendMicAudio(_ sampleBuffer: CMSampleBuffer) {
        let sourceSampleRate = getSampleRate(from: sampleBuffer) ?? 48000
        guard let samples = extractFloat32Samples(from: sampleBuffer) else { return }
        let channelCount = getChannelCount(from: sampleBuffer)
        let mono = channelCount > 1 ? stereoToMono(samples) : samples
        let resampled = resampleIfNeeded(mono, from: sourceSampleRate, to: targetSampleRate)
        lock.lock()
        micBuffer.append(contentsOf: resampled)
        lock.unlock()
    }

    func start() {
        lock.lock()
        startTime = Date()
        _energyTimeline.removeAll()
        lock.unlock()

        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in
            self?.drainAndMix()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        lock.lock()
        systemBuffer.removeAll()
        micBuffer.removeAll()
        lock.unlock()
    }

    private func drainAndMix() {
        lock.lock()
        let sys = systemBuffer
        let mic = micBuffer
        let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
        systemBuffer.removeAll(keepingCapacity: true)
        micBuffer.removeAll(keepingCapacity: true)
        lock.unlock()

        let count = max(sys.count, mic.count)
        guard count > 0 else { return }

        // Compute RMS energy for each source
        let micRMS = rms(mic)
        let sysRMS = rms(sys)

        let snapshot = AudioEnergySnapshot(timestamp: elapsed, micRMS: micRMS, systemRMS: sysRMS)
        lock.lock()
        _energyTimeline.append(snapshot)
        lock.unlock()

        var mixed = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let s = i < sys.count ? sys[i] : 0
            let m = i < mic.count ? mic[i] : 0
            mixed[i] = max(-1.0, min(1.0, s + m))
        }

        // Convert to Int16 PCM
        var int16Data = Data(capacity: count * 2)
        for sample in mixed {
            var value = Int16(sample * 32767)
            int16Data.append(Data(bytes: &value, count: 2))
        }

        onChunkReady?(int16Data)
    }

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSquares: Float = 0
        for s in samples { sumSquares += s * s }
        return sqrtf(sumSquares / Float(samples.count))
    }

    private func extractFloat32Samples(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        guard status == noErr, let data = dataPointer, length > 0 else { return nil }

        let floatCount = length / MemoryLayout<Float>.size
        let floatPointer = UnsafeRawPointer(data).bindMemory(to: Float.self, capacity: floatCount)
        return Array(UnsafeBufferPointer(start: floatPointer, count: floatCount))
    }

    private func stereoToMono(_ samples: [Float]) -> [Float] {
        guard samples.count >= 2 else { return samples }
        var mono = [Float](repeating: 0, count: samples.count / 2)
        for i in 0..<mono.count {
            mono[i] = (samples[i * 2] + samples[i * 2 + 1]) * 0.5
        }
        return mono
    }

    private func resampleIfNeeded(_ samples: [Float], from sourceSR: Double, to targetSR: Double) -> [Float] {
        guard sourceSR != targetSR, sourceSR > 0 else { return samples }
        let ratio = targetSR / sourceSR
        let outputCount = Int(Double(samples.count) * ratio)
        guard outputCount > 0 else { return [] }
        var output = [Float](repeating: 0, count: outputCount)
        for i in 0..<outputCount {
            let srcIndex = Double(i) / ratio
            let idx = Int(srcIndex)
            let frac = Float(srcIndex - Double(idx))
            if idx + 1 < samples.count {
                output[i] = samples[idx] * (1 - frac) + samples[idx + 1] * frac
            } else if idx < samples.count {
                output[i] = samples[idx]
            }
        }
        return output
    }

    private func getSampleRate(from sampleBuffer: CMSampleBuffer) -> Double? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        return asbd?.pointee.mSampleRate
    }

    private func getChannelCount(from sampleBuffer: CMSampleBuffer) -> Int {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return 1 }
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return 1 }
        return Int(asbd.pointee.mChannelsPerFrame)
    }
}
