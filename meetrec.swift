import ScreenCaptureKit
import AVFoundation
import CoreMedia
import Darwin

// MARK: - Audio Mixer (combines system audio + mic)

class AudioMixer {
    private var systemAudioBuffer: [(CMSampleBuffer, CMTime)] = []
    private var micAudioBuffer: [(CMSampleBuffer, CMTime)] = []
    private let lock = NSLock()

    func addSystemAudio(_ buffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        systemAudioBuffer.append((buffer, pts))
        // Keep buffer manageable
        if systemAudioBuffer.count > 100 {
            systemAudioBuffer.removeFirst()
        }
    }

    func addMicAudio(_ buffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        micAudioBuffer.append((buffer, pts))
        if micAudioBuffer.count > 100 {
            micAudioBuffer.removeFirst()
        }
    }

    // For simplicity, we'll write system audio directly and mix mic in post if needed
    // Real-time mixing is complex - this version prioritizes system audio (meeting participants)
    // and adds mic as a separate track
}

// MARK: - Meeting Recorder

class MeetingRecorder: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var micAudioInput: AVAssetWriterInput?

    // Microphone capture
    private var micCaptureSession: AVCaptureSession?
    private var micOutput: AVCaptureAudioDataOutput?
    private let micQueue = DispatchQueue(label: "mic.capture")

    // State
    private var isRecording = false
    private var sessionStarted = false
    private var videoStartTime: CMTime?
    private var audioStartTime: CMTime?
    private var micStartTime: CMTime?

    private let outputURL: URL

    init(outputURL: URL) {
        self.outputURL = outputURL
        super.init()
    }

    func start() async throws {
        // Get available content
        let content = try await SCShareableContent.current

        guard let display = content.displays.first else {
            throw RecorderError.noDisplay
        }

        print("Recording display: \(display.width)x\(display.height)")

        // Configure stream
        let config = SCStreamConfiguration()
        config.width = Int(display.width)
        config.height = Int(display.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30) // 30 fps
        config.queueDepth = 5
        config.showsCursor = true

        // Enable audio capture
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 2

        // Create filter for the display
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
        print("Recording started! Press Ctrl+C to stop.")
    }

    private func setupAssetWriter(width: Int, height: Int) throws {
        // Remove existing file if present
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
        micCaptureSession = AVCaptureSession()

        guard let micDevice = AVCaptureDevice.default(for: .audio) else {
            print("Warning: No microphone found, recording without mic")
            return
        }

        let micInput = try AVCaptureDeviceInput(device: micDevice)
        if micCaptureSession?.canAddInput(micInput) == true {
            micCaptureSession?.addInput(micInput)
        }

        micOutput = AVCaptureAudioDataOutput()
        micOutput?.setSampleBufferDelegate(self, queue: micQueue)

        if let micOutput = micOutput, micCaptureSession?.canAddOutput(micOutput) == true {
            micCaptureSession?.addOutput(micOutput)
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false

        print("\nStopping recording...")

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
                print("Recording saved to: \(outputURL.path)")
            } else if let error = assetWriter?.error {
                print("Error saving recording: \(error)")
            }

            // Signal that we're done
            exit(0)
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
            break // We handle mic separately via AVCaptureSession
        @unknown default:
            break
        }
    }

    private func handleVideoSample(_ sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if !sessionStarted {
            assetWriter?.startWriting()
            assetWriter?.startSession(atSourceTime: pts)
            sessionStarted = true
            videoStartTime = pts
        }

        if videoInput?.isReadyForMoreMediaData == true {
            videoInput?.append(sampleBuffer)
        }
    }

    private func handleSystemAudioSample(_ sampleBuffer: CMSampleBuffer) {
        guard sessionStarted else { return }

        if systemAudioInput?.isReadyForMoreMediaData == true {
            systemAudioInput?.append(sampleBuffer)
        }
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isRecording, sessionStarted else { return }

        if micAudioInput?.isReadyForMoreMediaData == true {
            micAudioInput?.append(sampleBuffer)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Stream stopped with error: \(error)")
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

// MARK: - Main

var recorder: MeetingRecorder?

// Handle Ctrl+C
signal(SIGINT) { _ in
    recorder?.stop()
}

signal(SIGTERM) { _ in
    recorder?.stop()
}

// Generate output filename in Recordings folder
let dateFormatter = DateFormatter()
dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
let timestamp = dateFormatter.string(from: Date())

// Get the directory where the executable is located
let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let recordingsDir = executableURL.appendingPathComponent("recordings")

// Create Recordings directory if it doesn't exist
try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)

let outputURL = recordingsDir.appendingPathComponent("meeting_\(timestamp).mp4")

let version = "1.0.0"
print("OpenRecorder v\(version) - Screen + Audio Recorder")
print("Output: \(outputURL.path)")
print("")

recorder = MeetingRecorder(outputURL: outputURL)

// Run async
let semaphore = DispatchSemaphore(value: 0)

Task {
    do {
        try await recorder?.start()
    } catch {
        print("Error: \(error)")
        exit(1)
    }
}

// Keep running
RunLoop.main.run()
