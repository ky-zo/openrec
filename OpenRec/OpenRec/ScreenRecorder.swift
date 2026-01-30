import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CoreGraphics

@available(macOS 13.0, *)
class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var systemAudioInput: AVAssetWriterInput?
    private var micAudioInput: AVAssetWriterInput?
    private var segmentStartTime: CMTime?
    private var segmentIndex = 0
    private var segmentURLs: [URL] = []
    private var segmentsDirectory: URL?
    private let segmentDuration = CMTime(seconds: 120, preferredTimescale: 600)
    private let writerQueue = DispatchQueue(label: "screenrec.writer")
    private let segmentGroup = DispatchGroup()

    // Microphone capture
    private var micCaptureSession: AVCaptureSession?
    private var micOutput: AVCaptureAudioDataOutput?
    private let micQueue = DispatchQueue(label: "mic.capture")

    // State
    private var isRecording = false
    private var sessionStarted = false

    // Audio levels
    private var audioLevelLock = NSLock()
    private var _micLevel: Float = 0
    private var _systemLevel: Float = 0

    var onAudioLevels: ((Float, Float) -> Void)?
    var onComplete: (() -> Void)?

    private let outputURL: URL
    private let audioOutputURL: URL?
    private let micDevice: AVCaptureDevice?
    private(set) var recordingDisplayID: CGDirectDisplayID?
    private var recordingWidth: Int = 0
    private var recordingHeight: Int = 0

    init(outputURL: URL, audioOutputURL: URL?, micDevice: AVCaptureDevice?) {
        self.outputURL = outputURL
        self.audioOutputURL = audioOutputURL
        self.micDevice = micDevice
        super.init()
    }

    func start() async throws {
        let content = try await SCShareableContent.current

        guard let display = content.displays.first else {
            throw RecorderError.noDisplay
        }
        recordingDisplayID = display.displayID

        // Configure stream
        let config = SCStreamConfiguration()
        config.width = Int(display.width)
        config.height = Int(display.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 5
        config.showsCursor = true
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 2

        let filter = SCContentFilter(display: display, excludingWindows: [])

        recordingWidth = Int(display.width)
        recordingHeight = Int(display.height)

        // Prepare segments directory
        let baseDir = outputURL.deletingLastPathComponent()
        let segmentsDir = baseDir.appendingPathComponent("segments", isDirectory: true)
        do {
            try? FileManager.default.removeItem(at: segmentsDir)
            try FileManager.default.createDirectory(at: segmentsDir, withIntermediateDirectories: true)
            segmentsDirectory = segmentsDir
        } catch {
            throw RecorderError.setupFailed("Unable to create segments folder.")
        }
        segmentIndex = 0
        segmentURLs = []
        segmentStartTime = nil
        sessionStarted = false

        // Setup microphone
        try setupMicrophone()

        // Create and start stream
        stream = SCStream(filter: filter, configuration: config, delegate: self)
        let streamQueue = DispatchQueue(label: "screen.capture")
        try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: streamQueue)
        try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: streamQueue)

        try await stream?.startCapture()

        // Start mic capture
        micCaptureSession?.startRunning()

        isRecording = true
    }

    private func setupAssetWriter(for url: URL, width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: url)

        assetWriter = try AVAssetWriter(outputURL: url, fileType: .mp4)

        // Video input
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput?.expectsMediaDataInRealTime = true

        if let videoInput = videoInput, assetWriter?.canAdd(videoInput) == true {
            assetWriter?.add(videoInput)

            pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: nil
            )
        }

        // System audio input
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128000
        ]

        systemAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        systemAudioInput?.expectsMediaDataInRealTime = true

        if let systemAudioInput = systemAudioInput, assetWriter?.canAdd(systemAudioInput) == true {
            assetWriter?.add(systemAudioInput)
        }

        // Microphone audio input (separate track)
        micAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        micAudioInput?.expectsMediaDataInRealTime = true

        if let micAudioInput = micAudioInput, assetWriter?.canAdd(micAudioInput) == true {
            assetWriter?.add(micAudioInput)
        }
    }

    private func setupMicrophone() throws {
        guard let device = micDevice else {
            return
        }

        micCaptureSession = AVCaptureSession()

        let micInput = try AVCaptureDeviceInput(device: device)
        if micCaptureSession?.canAddInput(micInput) == true {
            micCaptureSession?.addInput(micInput)
        }

        micOutput = AVCaptureAudioDataOutput()
        micOutput?.setSampleBufferDelegate(self, queue: micQueue)

        if let micOutput = micOutput, micCaptureSession?.canAddOutput(micOutput) == true {
            micCaptureSession?.addOutput(micOutput)
        }
    }

    private func calculateAudioLevel(from sampleBuffer: CMSampleBuffer) -> Float {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return 0 }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let data = dataPointer, length > 0 else { return 0 }

        let samples = UnsafeRawPointer(data).bindMemory(to: Float32.self, capacity: length / 4)
        let sampleCount = length / 4
        var sum: Float = 0

        let count = min(sampleCount, 512)
        for i in 0..<count {
            let sample = samples[i]
            sum += sample * sample
        }

        let rms = sqrt(sum / Float(count))
        return min(1.0, rms * 12.0)
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false

        // Stop captures
        micCaptureSession?.stopRunning()

        Task {
            try? await stream?.stopCapture()

            let segments = await finalizeSegments()

            if segments.isEmpty {
                onComplete?()
                return
            }

            if segments.count == 1 {
                try? FileManager.default.removeItem(at: outputURL)
                try? FileManager.default.moveItem(at: segments[0], to: outputURL)
            } else {
                _ = await mergeSegments(segments, into: outputURL)
            }

            if FileManager.default.fileExists(atPath: outputURL.path) {
                let hasFFmpeg = shellRun("which ffmpeg >/dev/null 2>&1")

                // Merge audio tracks if ffmpeg is available
                await mergeAudioTracks(at: outputURL, ffmpegAvailable: hasFFmpeg)

                if let audioOutputURL = audioOutputURL {
                    _ = exportAudioMp3(from: outputURL, to: audioOutputURL, ffmpegAvailable: hasFFmpeg)
                }

                cleanupSegments()
            }

            onComplete?()
        }
    }

    private func mergeAudioTracks(at url: URL, ffmpegAvailable: Bool) async {
        guard ffmpegAvailable else { return }

        // Check if file has 2 audio tracks using ffprobe
        let probeCmd = "ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 '\(url.path)' 2>/dev/null | wc -l"
        let trackCount = Int(shellOutput(probeCmd).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard trackCount >= 2 else {
            return // Only one audio track, no merge needed
        }

        let tempPath = url.deletingLastPathComponent().appendingPathComponent("temp_merged.mp4").path

        // ffmpeg command to mix both audio tracks
        let mergeCmd = """
            ffmpeg -y -i '\(url.path)' \
            -filter_complex '[0:a:0][0:a:1]amix=inputs=2:duration=longest[aout]' \
            -map 0:v -map '[aout]' \
            -c:v copy -c:a aac -b:a 192k \
            '\(tempPath)' </dev/null >/dev/null 2>&1
            """

        let success = shellRun(mergeCmd)

        if success {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.moveItem(atPath: tempPath, toPath: url.path)
        } else {
            try? FileManager.default.removeItem(atPath: tempPath)
        }
    }

    private func exportAudioMp3(from url: URL, to audioURL: URL, ffmpegAvailable: Bool) -> Bool {
        guard ffmpegAvailable else { return false }

        let exportCmd = """
            ffmpeg -y -i '\(url.path)' \
            -vn -c:a libmp3lame -q:a 2 \
            '\(audioURL.path)' </dev/null >/dev/null 2>&1
            """

        return shellRun(exportCmd)
    }

    private func shellRun(_ command: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func shellOutput(_ command: String) -> String {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard isRecording, CMSampleBufferDataIsReady(sampleBuffer) else { return }

        switch type {
        case .screen:
            handleVideoSample(sampleBuffer)
        case .audio:
            handleSystemAudioSample(sampleBuffer)
        case .microphone:
            break
        @unknown default:
            break
        }
    }

    private func handleVideoSample(_ sampleBuffer: CMSampleBuffer) {
        writerQueue.async { [weak self] in
            guard let self else { return }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                return
            }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            do {
                try self.ensureSegment(for: pts)
            } catch {
                return
            }

            if self.videoInput?.isReadyForMoreMediaData == true {
                self.pixelBufferAdaptor?.append(pixelBuffer, withPresentationTime: pts)
            }
        }
    }

    private func handleSystemAudioSample(_ sampleBuffer: CMSampleBuffer) {
        writerQueue.async { [weak self] in
            guard let self else { return }
            guard self.sessionStarted else { return }
            if self.systemAudioInput?.isReadyForMoreMediaData == true {
                self.systemAudioInput?.append(sampleBuffer)
            }
        }

        // Calculate and report audio level
        let level = calculateAudioLevel(from: sampleBuffer)
        audioLevelLock.lock()
        _systemLevel = level
        let micLevel = _micLevel
        audioLevelLock.unlock()

        onAudioLevels?(micLevel, level)
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isRecording else { return }

        writerQueue.async { [weak self] in
            guard let self else { return }
            guard self.sessionStarted else { return }
            if self.micAudioInput?.isReadyForMoreMediaData == true {
                self.micAudioInput?.append(sampleBuffer)
            }
        }

        // Calculate and store mic level
        let level = calculateAudioLevel(from: sampleBuffer)
        audioLevelLock.lock()
        _micLevel = level
        audioLevelLock.unlock()
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let nsError = error as NSError
        if nsError.code != -3817 {
            // Not a user-initiated stop
            print("Stream error: \(error.localizedDescription)")
        }
        stop()
    }

    private func ensureSegment(for pts: CMTime) throws {
        if let segmentStartTime {
            let elapsed = CMTimeSubtract(pts, segmentStartTime)
            if elapsed >= segmentDuration {
                finalizeCurrentSegment()
                try startNewSegment(at: pts)
                return
            }
        }

        if !sessionStarted {
            try startNewSegment(at: pts)
        }
    }

    private func startNewSegment(at pts: CMTime) throws {
        guard let segmentsDirectory else {
            return
        }

        segmentIndex += 1
        let filename = String(format: "segment_%04d.mp4", segmentIndex)
        let segmentURL = segmentsDirectory.appendingPathComponent(filename)

        try setupAssetWriter(for: segmentURL, width: recordingWidth, height: recordingHeight)
        segmentURLs.append(segmentURL)

        assetWriter?.startWriting()
        assetWriter?.startSession(atSourceTime: pts)
        segmentStartTime = pts
        sessionStarted = true
    }

    private func finalizeCurrentSegment() {
        guard sessionStarted, let writer = assetWriter else { return }

        videoInput?.markAsFinished()
        systemAudioInput?.markAsFinished()
        micAudioInput?.markAsFinished()

        segmentGroup.enter()
        writer.finishWriting { [weak self] in
            self?.segmentGroup.leave()
        }

        assetWriter = nil
        videoInput = nil
        pixelBufferAdaptor = nil
        systemAudioInput = nil
        micAudioInput = nil
        segmentStartTime = nil
        sessionStarted = false
    }

    private func finalizeSegments() async -> [URL] {
        await withCheckedContinuation { continuation in
            writerQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: [])
                    return
                }
                self.finalizeCurrentSegment()
                let urls = self.segmentURLs
                self.segmentGroup.notify(queue: self.writerQueue) {
                    continuation.resume(returning: urls)
                }
            }
        }
    }

    private func mergeSegments(_ segments: [URL], into outputURL: URL) async -> Bool {
        let composition = AVMutableComposition()
        guard let compositionVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            return false
        }
        let compositionSystemAudio = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )
        let compositionMicAudio = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var currentTime = CMTime.zero
        var appliedVideoTransform = false

        for url in segments {
            let asset = AVAsset(url: url)
            let duration: CMTime
            do {
                duration = try await asset.load(.duration)
            } catch {
                return false
            }

            let videoTracks: [AVAssetTrack]
            do {
                videoTracks = try await asset.loadTracks(withMediaType: .video)
            } catch {
                return false
            }

            if let videoTrack = videoTracks.first {
                let timeRange: CMTimeRange
                do {
                    timeRange = try await videoTrack.load(.timeRange)
                } catch {
                    return false
                }

                do {
                    try compositionVideo.insertTimeRange(timeRange, of: videoTrack, at: currentTime)
                    if !appliedVideoTransform {
                        let transform = try await videoTrack.load(.preferredTransform)
                        compositionVideo.preferredTransform = transform
                        appliedVideoTransform = true
                    }
                } catch {
                    return false
                }
            }

            let audioTracks: [AVAssetTrack]
            do {
                audioTracks = try await asset.loadTracks(withMediaType: .audio)
            } catch {
                return false
            }

            if let systemTrack = audioTracks.first, let compositionSystemAudio {
                let timeRange: CMTimeRange
                do {
                    timeRange = try await systemTrack.load(.timeRange)
                } catch {
                    return false
                }
                do {
                    try compositionSystemAudio.insertTimeRange(timeRange, of: systemTrack, at: currentTime)
                } catch {
                    return false
                }
            }

            if audioTracks.count > 1, let compositionMicAudio {
                let micTrack = audioTracks[1]
                let timeRange: CMTimeRange
                do {
                    timeRange = try await micTrack.load(.timeRange)
                } catch {
                    return false
                }
                do {
                    try compositionMicAudio.insertTimeRange(timeRange, of: micTrack, at: currentTime)
                } catch {
                    return false
                }
            }

            currentTime = CMTimeAdd(currentTime, duration)
        }

        try? FileManager.default.removeItem(at: outputURL)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            return false
        }
        export.outputURL = outputURL
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = false

        await export.export()
        return export.status == .completed
    }

    private func cleanupSegments() {
        guard let segmentsDirectory else { return }
        try? FileManager.default.removeItem(at: segmentsDirectory)
    }
}

// Access is synchronized via writerQueue/audio locks; safe for @unchecked Sendable.
extension ScreenRecorder: @unchecked Sendable {}

// MARK: - Error Types

enum RecorderError: Error, CustomStringConvertible {
    case noDisplay
    case setupFailed(String)

    var description: String {
        switch self {
        case .noDisplay:
            return "No display found to record"
        case .setupFailed(let reason):
            return "Setup failed: \(reason)"
        }
    }
}
