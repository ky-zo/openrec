import Foundation
import CoreMedia
import AVFoundation

/// Energy snapshot for a 100ms audio chunk, tracking which source is dominant.
struct AudioEnergySnapshot {
    let timestamp: Double
    let micRMS: Float
    let systemRMS: Float

    var dominantSource: AudioSource {
        let noiseFloor: Float = 0.008
        if micRMS > noiseFloor && systemRMS < noiseFloor {
            return .mic
        }
        if systemRMS > noiseFloor {
            return micRMS > systemRMS * 3.0 ? .mic : .system
        }
        return .system
    }
}

enum AudioSource {
    case mic
    case system
}

/// A timestamped, mono Float32 PCM chunk. The timestamp remains in the capture
/// clock so a recorder can keep it synchronized with ScreenCaptureKit video.
struct TimestampedPCMChunk: @unchecked Sendable {
    static let sampleRate: Double = 48_000

    let data: Data
    let presentationTime: CMTime
    let frameCount: Int
}

/// Mixes system and microphone PCM without doing work on either capture callback.
///
/// `onChunkReady` retains the existing 16 kHz mono Int16 stream used by realtime
/// transcription. `onHighQualityChunkReady` emits the same mix as timestamped
/// 48 kHz mono Float32 PCM for the media encoders.
final class AudioMixer {
    private struct TimedSamples {
        let startFrame: Int64
        let samples: [Float]

        var endFrame: Int64 { startFrame + Int64(samples.count) }
    }

    private enum Source {
        case system
        case mic
    }

    private let processingQueue = DispatchQueue(label: "audiomixer.processing", qos: .userInitiated)
    private let callbackQueue = DispatchQueue(label: "audiomixer.callbacks", qos: .userInitiated)
    private let timelineLock = NSLock()

    private let outputSampleRate = TimestampedPCMChunk.sampleRate
    private let transcriptionSampleRate: Double = 16_000
    private let framesPerChunk = 4_800 // 100 ms at 48 kHz
    private let holdbackFrames = 4_800 // let the other input arrive before mixing
    // macOS input levels leave speech well below system-audio loudness when
    // summed 1:1, which made recorded voices sound too quiet. Boost the mic
    // before mixing; each sample is clamped so a loud close talker cannot wrap.
    private let micGain: Float = 2.0

    private var timer: DispatchSourceTimer?
    private var running = false
    private var finishing = false
    private var timelineOrigin: CMTime?
    private var outputFrame: Int64 = 0
    private var latestInputFrame: Int64 = 0
    private var systemChunks: [TimedSamples] = []
    private var micChunks: [TimedSamples] = []
    private var _energyTimeline: [AudioEnergySnapshot] = []

    var onChunkReady: ((Data) -> Void)?
    var onHighQualityChunkReady: ((TimestampedPCMChunk) -> Void)?

    /// Thread-safe copy of the energy timeline recorded during mixing.
    var energyTimeline: [AudioEnergySnapshot] {
        timelineLock.lock()
        let copy = _energyTimeline
        timelineLock.unlock()
        return copy
    }

    /// Enqueues the buffer and returns immediately to ScreenCaptureKit.
    func appendSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        processingQueue.async { [weak self, sampleBuffer] in
            self?.ingest(sampleBuffer, source: .system)
        }
    }

    /// Enqueues the buffer and returns immediately to AVCaptureSession.
    func appendMicAudio(_ sampleBuffer: CMSampleBuffer) {
        processingQueue.async { [weak self, sampleBuffer] in
            self?.ingest(sampleBuffer, source: .mic)
        }
    }

    func start() {
        processingQueue.sync {
            timer?.cancel()
            timer = nil
            running = true
            finishing = false
            timelineOrigin = nil
            outputFrame = 0
            latestInputFrame = 0
            systemChunks.removeAll(keepingCapacity: true)
            micChunks.removeAll(keepingCapacity: true)
            timelineLock.lock()
            _energyTimeline.removeAll(keepingCapacity: true)
            timelineLock.unlock()

            let timer = DispatchSource.makeTimerSource(queue: processingQueue)
            timer.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(10))
            timer.setEventHandler { [weak self] in
                self?.drainReadyChunks(flush: false)
            }
            timer.resume()
            self.timer = timer
        }
    }

    /// Stops STT-style mixing. Pending audio is intentionally discarded, which
    /// preserves the existing immediate-stop behavior used by transcription.
    func stop() {
        processingQueue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.timer = nil
            self.running = false
            self.finishing = false
            self.systemChunks.removeAll(keepingCapacity: false)
            self.micChunks.removeAll(keepingCapacity: false)
        }
    }

    /// Flushes every queued capture frame, then calls completion only after all
    /// PCM callbacks already emitted by this mixer have returned.
    func finish(completion: @escaping () -> Void) {
        processingQueue.async { [weak self] in
            guard let self else {
                completion()
                return
            }
            guard self.running, !self.finishing else {
                self.callbackQueue.async(execute: completion)
                return
            }
            self.finishing = true
            self.timer?.cancel()
            self.timer = nil
            self.drainReadyChunks(flush: true)
            self.running = false
            self.systemChunks.removeAll(keepingCapacity: false)
            self.micChunks.removeAll(keepingCapacity: false)
            self.callbackQueue.async(execute: completion)
        }
    }

    private func ingest(_ sampleBuffer: CMSampleBuffer, source: Source) {
        guard running, !finishing,
              let extracted = extractMonoPCM(from: sampleBuffer),
              !extracted.samples.isEmpty else { return }

        var resampled = resampleIfNeeded(
            extracted.samples,
            from: extracted.sampleRate,
            to: outputSampleRate
        )
        guard !resampled.isEmpty else { return }
        if source == .mic, micGain != 1 {
            for index in resampled.indices {
                resampled[index] = max(-1, min(1, resampled[index] * micGain))
            }
        }

        let timestamp = extracted.presentationTime.isNumeric
            ? extracted.presentationTime
            : CMClockGetTime(CMClockGetHostTimeClock())
        if timelineOrigin == nil {
            timelineOrigin = timestamp
        }
        guard let timelineOrigin else { return }

        let delta = CMTimeGetSeconds(CMTimeSubtract(timestamp, timelineOrigin))
        var startFrame = delta.isFinite
            ? Int64((delta * outputSampleRate).rounded())
            : latestInputFrame

        // A capture source can occasionally expose a different clock epoch. In
        // that case align its first packet with the live cursor, not hours away.
        if abs(startFrame - outputFrame) > Int64(outputSampleRate * 10) {
            startFrame = max(outputFrame, latestInputFrame)
        }

        var samples = resampled
        if startFrame < outputFrame {
            let consumed = min(samples.count, Int(outputFrame - startFrame))
            samples.removeFirst(consumed)
            startFrame += Int64(consumed)
        }
        guard !samples.isEmpty else { return }

        let chunk = TimedSamples(startFrame: startFrame, samples: samples)
        latestInputFrame = max(latestInputFrame, chunk.endFrame)
        switch source {
        case .system:
            insert(chunk, into: &systemChunks)
        case .mic:
            insert(chunk, into: &micChunks)
        }
    }

    private func insert(_ chunk: TimedSamples, into chunks: inout [TimedSamples]) {
        if chunks.last?.startFrame ?? Int64.min <= chunk.startFrame {
            chunks.append(chunk)
        } else {
            let index = chunks.firstIndex { $0.startFrame > chunk.startFrame } ?? chunks.endIndex
            chunks.insert(chunk, at: index)
        }
    }

    private func drainReadyChunks(flush: Bool) {
        guard running, let origin = timelineOrigin else { return }

        let normalLimit = latestInputFrame - Int64(holdbackFrames)
        let limit = flush ? latestInputFrame : normalLimit
        while outputFrame < limit {
            let remaining = limit - outputFrame
            let frameCount = flush
                ? min(framesPerChunk, Int(remaining))
                : framesPerChunk
            guard frameCount > 0 else { break }
            emitChunk(origin: origin, startFrame: outputFrame, frameCount: frameCount)
            outputFrame += Int64(frameCount)
            pruneConsumedChunks()
        }
    }

    private func emitChunk(origin: CMTime, startFrame: Int64, frameCount: Int) {
        let system = render(chunks: systemChunks, startFrame: startFrame, frameCount: frameCount)
        let mic = render(chunks: micChunks, startFrame: startFrame, frameCount: frameCount)
        let micRMS = rms(mic)
        let systemRMS = rms(system)

        timelineLock.lock()
        _energyTimeline.append(
            AudioEnergySnapshot(
                timestamp: Double(startFrame) / outputSampleRate,
                micRMS: micRMS,
                systemRMS: systemRMS
            )
        )
        timelineLock.unlock()

        var mixed = [Float](repeating: 0, count: frameCount)
        for index in mixed.indices {
            mixed[index] = max(-1, min(1, system[index] + mic[index]))
        }

        let presentationTime = CMTimeAdd(
            origin,
            CMTime(value: startFrame, timescale: CMTimeScale(outputSampleRate))
        )
        let floatData = mixed.withUnsafeBytes { Data($0) }
        let highQualityChunk = TimestampedPCMChunk(
            data: floatData,
            presentationTime: presentationTime,
            frameCount: frameCount
        )

        let transcriptionSamples = resampleIfNeeded(
            mixed,
            from: outputSampleRate,
            to: transcriptionSampleRate
        )
        let int16Samples = transcriptionSamples.map { sample -> Int16 in
            let scaled = max(-1, min(1, sample)) * Float(Int16.max)
            return Int16(scaled.rounded())
        }
        let int16Data = int16Samples.withUnsafeBytes { Data($0) }

        callbackQueue.async { [weak self] in
            guard let self else { return }
            self.onHighQualityChunkReady?(highQualityChunk)
            self.onChunkReady?(int16Data)
        }
    }

    private func render(chunks: [TimedSamples], startFrame: Int64, frameCount: Int) -> [Float] {
        let endFrame = startFrame + Int64(frameCount)
        var rendered = [Float](repeating: 0, count: frameCount)

        for chunk in chunks where chunk.endFrame > startFrame && chunk.startFrame < endFrame {
            let overlapStart = max(startFrame, chunk.startFrame)
            let overlapEnd = min(endFrame, chunk.endFrame)
            guard overlapStart < overlapEnd else { continue }
            let sourceOffset = Int(overlapStart - chunk.startFrame)
            let destinationOffset = Int(overlapStart - startFrame)
            let count = Int(overlapEnd - overlapStart)
            for index in 0..<count {
                rendered[destinationOffset + index] = chunk.samples[sourceOffset + index]
            }
        }
        return rendered
    }

    private func pruneConsumedChunks() {
        systemChunks.removeAll { $0.endFrame <= outputFrame }
        micChunks.removeAll { $0.endFrame <= outputFrame }
    }

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(Float.zero) { $0 + ($1 * $1) }
        return sqrtf(sumSquares / Float(samples.count))
    }

    private func resampleIfNeeded(_ samples: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        guard abs(sourceRate - targetRate) > 0.5, sourceRate > 0 else { return samples }
        let ratio = targetRate / sourceRate
        let outputCount = Int((Double(samples.count) * ratio).rounded())
        guard outputCount > 0 else { return [] }

        var output = [Float](repeating: 0, count: outputCount)
        for index in output.indices {
            let sourceIndex = Double(index) / ratio
            let lower = Int(sourceIndex)
            let fraction = Float(sourceIndex - Double(lower))
            if lower + 1 < samples.count {
                output[index] = samples[lower] * (1 - fraction) + samples[lower + 1] * fraction
            } else if lower < samples.count {
                output[index] = samples[lower]
            }
        }
        return output
    }

    private func extractMonoPCM(from sampleBuffer: CMSampleBuffer) -> (
        samples: [Float],
        sampleRate: Double,
        presentationTime: CMTime
    )? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }
        let asbd = asbdPointer.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mSampleRate > 0,
              asbd.mChannelsPerFrame > 0 else { return nil }

        var requiredSize = 0
        var retainedBlockBuffer: CMBlockBuffer?
        _ = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        )
        guard requiredSize >= MemoryLayout<AudioBufferList>.size else { return nil }

        let rawList = UnsafeMutableRawPointer.allocate(
            byteCount: requiredSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawList.deallocate() }
        let audioBufferList = rawList.bindMemory(to: AudioBufferList.self, capacity: 1)
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: requiredSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0, !buffers.isEmpty else { return nil }

        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        let isNonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bytesPerSample = Int(asbd.mBitsPerChannel / 8)
        guard bytesPerSample > 0, isFloat || isSignedInteger else { return nil }

        var mono = [Float](repeating: 0, count: frameCount)
        var contributingChannels = 0

        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let channelsInBuffer = max(1, Int(buffer.mNumberChannels))
            let interleavedChannels = isNonInterleaved ? 1 : channelsInBuffer
            let availableSamples = Int(buffer.mDataByteSize) / bytesPerSample
            let availableFrames = min(frameCount, availableSamples / interleavedChannels)
            guard availableFrames > 0 else { continue }

            for channel in 0..<channelsInBuffer {
                for frame in 0..<availableFrames {
                    let sampleIndex = isNonInterleaved
                        ? frame
                        : frame * channelsInBuffer + channel
                    mono[frame] += readSample(
                        from: data,
                        index: sampleIndex,
                        bitsPerChannel: Int(asbd.mBitsPerChannel),
                        isFloat: isFloat
                    )
                }
                contributingChannels += 1
            }
        }

        guard contributingChannels > 0 else { return nil }
        let divisor = Float(contributingChannels)
        for index in mono.indices { mono[index] /= divisor }

        return (
            mono,
            asbd.mSampleRate,
            CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        )
    }

    private func readSample(
        from data: UnsafeMutableRawPointer,
        index: Int,
        bitsPerChannel: Int,
        isFloat: Bool
    ) -> Float {
        if isFloat, bitsPerChannel == 32 {
            return data.assumingMemoryBound(to: Float.self)[index]
        }
        if isFloat, bitsPerChannel == 64 {
            return Float(data.assumingMemoryBound(to: Double.self)[index])
        }
        if bitsPerChannel == 16 {
            return Float(data.assumingMemoryBound(to: Int16.self)[index]) / Float(Int16.max)
        }
        if bitsPerChannel == 32 {
            return Float(data.assumingMemoryBound(to: Int32.self)[index]) / Float(Int32.max)
        }
        return 0
    }
}
