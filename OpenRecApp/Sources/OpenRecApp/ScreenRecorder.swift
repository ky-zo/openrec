import ScreenCaptureKit
import AVFoundation
import CoreMedia

@available(macOS 13.0, *)
class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var systemAudioInput: AVAssetWriterInput?
    private var micAudioInput: AVAssetWriterInput?

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
    private let micDevice: AVCaptureDevice?

    init(outputURL: URL, micDevice: AVCaptureDevice?) {
        self.outputURL = outputURL
        self.micDevice = micDevice
        super.init()
    }

    func start() async throws {
        let content = try await SCShareableContent.current

        guard let display = content.displays.first else {
            throw RecorderError.noDisplay
        }

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

        // Setup asset writer
        try setupAssetWriter(width: display.width, height: display.height)

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

    private func setupAssetWriter(width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: outputURL)

        assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

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

            // Finish writing
            videoInput?.markAsFinished()
            systemAudioInput?.markAsFinished()
            micAudioInput?.markAsFinished()

            await assetWriter?.finishWriting()

            if assetWriter?.status == .completed {
                // Merge audio tracks if ffmpeg is available
                await mergeAudioTracks(at: outputURL)
            }

            onComplete?()
        }
    }

    private func mergeAudioTracks(at url: URL) async {
        // Check if ffmpeg is available
        guard shellRun("which ffmpeg >/dev/null 2>&1") else {
            return
        }

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
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if !sessionStarted {
            assetWriter?.startWriting()
            assetWriter?.startSession(atSourceTime: pts)
            sessionStarted = true
        }

        if videoInput?.isReadyForMoreMediaData == true {
            pixelBufferAdaptor?.append(pixelBuffer, withPresentationTime: pts)
        }
    }

    private func handleSystemAudioSample(_ sampleBuffer: CMSampleBuffer) {
        guard sessionStarted else { return }

        if systemAudioInput?.isReadyForMoreMediaData == true {
            systemAudioInput?.append(sampleBuffer)
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
        guard isRecording, sessionStarted else { return }

        if micAudioInput?.isReadyForMoreMediaData == true {
            micAudioInput?.append(sampleBuffer)
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
}

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
