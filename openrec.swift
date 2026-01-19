import ScreenCaptureKit
import AVFoundation
import CoreMedia
import Darwin

// MARK: - Disk Space Checker

struct DiskSpaceStatus {
    let availableGB: Double
    let level: Level

    enum Level: String {
        case safe = "SAFE"
        case warn = "WARNING"
        case risk = "RISK"

        var symbol: String {
            switch self {
            case .safe: return "[OK]"
            case .warn: return "[!]"
            case .risk: return "[X]"
            }
        }
    }

    static func check() -> DiskSpaceStatus {
        let fileManager = FileManager.default
        do {
            let attrs = try fileManager.attributesOfFileSystem(forPath: NSHomeDirectory())
            if let freeSpace = attrs[.systemFreeSize] as? Int64 {
                let gb = Double(freeSpace) / 1_000_000_000
                let level: Level
                if gb >= 10 {
                    level = .safe
                } else if gb >= 2 {
                    level = .warn
                } else {
                    level = .risk
                }
                return DiskSpaceStatus(availableGB: gb, level: level)
            }
        } catch {}
        return DiskSpaceStatus(availableGB: 0, level: .risk)
    }

    func display() {
        let formatted = String(format: "%.1f GB", availableGB)
        print("Disk space: \(formatted) \(level.symbol) \(level.rawValue)")
        if level == .warn {
            print("  Consider freeing up space for longer recordings")
        } else if level == .risk {
            print("  LOW DISK SPACE - Recording may fail!")
        }
    }
}

// MARK: - Screen Recorder

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

    private let outputURL: URL

    init(outputURL: URL) {
        self.outputURL = outputURL
        super.init()
    }

    func start() async throws {
        let content = try await SCShareableContent.current

        guard let display = content.displays.first else {
            throw RecorderError.noDisplay
        }

        print("Recording display: \(display.width)x\(display.height)")

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
        print("Recording started! Press Ctrl+C to stop.")
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

            // Use pixel buffer adaptor for ScreenCaptureKit compatibility
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
        micCaptureSession = AVCaptureSession()

        guard let micDevice = AVCaptureDevice.default(for: .audio) else {
            print("Note: No microphone found, recording without mic")
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
                let size = fileSize(at: outputURL)
                print("Recording saved: \(outputURL.path)")
                print("Size: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")

                // Merge audio tracks if ffmpeg is available
                mergeAudioTracks(at: outputURL)
            } else if let error = assetWriter?.error {
                print("Error saving: \(error.localizedDescription)")
            }

            exit(0)
        }
    }

    private func fileSize(at url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.size] as? Int64 ?? 0
    }

    private func mergeAudioTracks(at url: URL) {
        // Check if ffmpeg is available
        guard shellRun("which ffmpeg >/dev/null 2>&1") else {
            print("Note: Install ffmpeg to auto-merge mic audio (brew install ffmpeg)")
            return
        }

        // Check if file has 2 audio tracks using ffprobe
        let probeCmd = "ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 '\(url.path)' 2>/dev/null | wc -l"
        let trackCount = Int(shellOutput(probeCmd).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard trackCount >= 2 else {
            return // Only one audio track, no merge needed
        }

        print("Merging audio tracks...")

        let tempPath = url.deletingLastPathComponent().appendingPathComponent("temp_merged.mp4").path

        // ffmpeg command to mix both audio tracks
        let mergeCmd = """
            ffmpeg -y -i '\(url.path)' \
            -filter_complex '[0:a:0][0:a:1]amix=inputs=2:duration=longest[aout]' \
            -map 0:v -map '[aout]' \
            -c:v copy -c:a aac -b:a 192k \
            '\(tempPath)' </dev/null >/dev/null 2>&1
            """

        if shellRun(mergeCmd) {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.moveItem(atPath: tempPath, toPath: url.path)
            let newSize = fileSize(at: url)
            print("Audio merged! Final size: \(ByteCountFormatter.string(fromByteCount: newSize, countStyle: .file))")
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
        let nsError = error as NSError
        if nsError.code == -3817 {
            print("\nScreen sharing stopped by user")
        } else {
            print("\nStream stopped: \(error.localizedDescription)")
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

// MARK: - Main

var recorder: ScreenRecorder?

signal(SIGINT) { _ in
    recorder?.stop()
}

signal(SIGTERM) { _ in
    recorder?.stop()
}

let dateFormatter = DateFormatter()
dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
let timestamp = dateFormatter.string(from: Date())

let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let recordingsDir = executableURL.appendingPathComponent("recordings")
try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)

let outputURL = recordingsDir.appendingPathComponent("recording_\(timestamp).mp4")

let version = "0.0.5"
print("OpenRec v\(version) - Screen + Audio Recorder")
print("Output: \(outputURL.path)")

let diskStatus = DiskSpaceStatus.check()
diskStatus.display()

if diskStatus.level == .risk {
    print("\nWARNING: Very low disk space!")
}
print("")

recorder = ScreenRecorder(outputURL: outputURL)

Task {
    do {
        try await recorder?.start()
    } catch {
        print("Error: \(error)")
        exit(1)
    }
}

RunLoop.main.run()
