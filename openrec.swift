import ScreenCaptureKit
import AVFoundation
import CoreMedia
import Darwin

// MARK: - CLI Helpers

class CLI {
    // ANSI colors (bright variants for vivid colors)
    static let blue = "\u{1B}[34m"
    static let green = "\u{1B}[92m"  // Bright green
    static let red = "\u{1B}[91m"    // Bright red
    static let purple = "\u{1B}[95m" // Bright magenta/purple
    static let dim = "\u{1B}[2m"
    static let reset = "\u{1B}[0m"
    static let hideCursor = "\u{1B}[?25l"
    static let showCursor = "\u{1B}[?25h"
    static let moveUp = "\u{1B}[A"
    static let clearToEnd = "\u{1B}[J"

    /// Create a clickable hyperlink (OSC 8)
    static func link(_ text: String, url: String) -> String {
        return "\u{1B}]8;;\(url)\u{1B}\\\(text)\u{1B}]8;;\u{1B}\\"
    }

    static let spinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    static var spinnerIndex = 0

    static func clearLine() {
        print("\r\u{1B}[K", terminator: "")
        fflush(stdout)
    }

    static func printStatus(_ message: String, spinner: Bool = false) {
        clearLine()
        if spinner {
            let s = self.spinner[spinnerIndex % self.spinner.count]
            spinnerIndex += 1
            print("\(blue)\(s)\(reset) \(message)", terminator: "")
        } else {
            print(message, terminator: "")
        }
        fflush(stdout)
    }

    static func printDone(_ message: String) {
        clearLine()
        print("\(green)✓\(reset) \(message)")
    }

    static func printError(_ message: String) {
        clearLine()
        print("\(red)✗\(reset) \(message)")
    }

    static func formatDuration(_ seconds: Int) -> String {
        let hrs = seconds / 3600
        let mins = (seconds % 3600) / 60
        let secs = seconds % 60
        if hrs > 0 {
            return String(format: "%d:%02d:%02d", hrs, mins, secs)
        } else {
            return String(format: "%d:%02d", mins, secs)
        }
    }

    /// Interactive menu with arrow key navigation
    static func selectMenu(title: String, options: [String]) -> Int {
        var selected = 0
        let count = options.count

        // Save terminal state and enable raw mode
        var originalTermios = termios()
        tcgetattr(STDIN_FILENO, &originalTermios)
        var raw = originalTermios
        raw.c_lflag &= ~UInt(ICANON | ECHO)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)

        print(hideCursor, terminator: "")
        fflush(stdout)

        func render() {
            // Move cursor up to redraw (except first render)
            print("\r", terminator: "")

            print("\(dim)\(title)\(reset)")
            for (i, option) in options.enumerated() {
                let bullet = i == selected ? "\(green)●\(reset)" : "\(dim)○\(reset)"
                let text = i == selected ? option : "\(dim)\(option)\(reset)"
                print("  \(bullet) \(text)")
            }
            print("\(dim)  ↑/↓ navigate • enter select\(reset)", terminator: "")
            fflush(stdout)
        }

        func clearMenu() {
            // Clear current line (hint) first, then move up and clear rest
            print("\r\u{1B}[K", terminator: "")
            for _ in 0..<(count + 1) {
                print("\(moveUp)\r\u{1B}[K", terminator: "")
            }
            fflush(stdout)
        }

        render()

        // Read input
        while true {
            var c: UInt8 = 0
            read(STDIN_FILENO, &c, 1)

            if c == 27 { // ESC sequence
                var seq: [UInt8] = [0, 0]
                read(STDIN_FILENO, &seq[0], 1)
                read(STDIN_FILENO, &seq[1], 1)
                if seq[0] == 91 { // [
                    if seq[1] == 65 { // A = Up
                        selected = (selected - 1 + count) % count
                    } else if seq[1] == 66 { // B = Down
                        selected = (selected + 1) % count
                    }
                }
            } else if c == 10 || c == 13 { // Enter
                break
            }

            // Redraw
            clearMenu()
            render()
        }

        // Restore terminal
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &originalTermios)
        print(showCursor, terminator: "")

        // Clear menu and show selection
        clearMenu()
        fflush(stdout)

        return selected
    }
}

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

// MARK: - Microphone Selection

func selectMicrophone() -> AVCaptureDevice? {
    let discoverySession = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.microphone],
        mediaType: .audio,
        position: .unspecified
    )
    let devices = discoverySession.devices

    if devices.isEmpty {
        return nil
    }

    if devices.count == 1 {
        CLI.printDone("Microphone: \(devices[0].localizedName)")
        return devices[0]
    }

    // Interactive menu for multiple mics
    let options = devices.map { $0.localizedName }
    let selected = CLI.selectMenu(title: "Select microphone:", options: options)

    CLI.printDone("Microphone: \(devices[selected].localizedName)")
    return devices[selected]
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
    private var recordingStartTime: Date?
    private var statusTimer: Timer?

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

        let displayWidth = display.width
        let displayHeight = display.height

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
        recordingStartTime = Date()

        // Start status timer on main thread
        DispatchQueue.main.async {
            self.statusTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.updateRecordingStatus()
            }
        }

        CLI.printDone("Recording started")
        print("  Display: \(displayWidth)x\(displayHeight)")
        print("  Press \(CLI.red)[Ctrl+C]\(CLI.reset) to \(CLI.red)stop\(CLI.reset)\n")
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

    private func updateRecordingStatus() {
        guard isRecording, let startTime = recordingStartTime else { return }
        let elapsed = Int(Date().timeIntervalSince(startTime))
        let duration = CLI.formatDuration(elapsed)
        CLI.printStatus("Recording \(duration)", spinner: true)
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false

        // Stop the status timer
        statusTimer?.invalidate()
        statusTimer = nil

        // Calculate final duration
        let duration: String
        if let startTime = recordingStartTime {
            let elapsed = Int(Date().timeIntervalSince(startTime))
            duration = CLI.formatDuration(elapsed)
        } else {
            duration = "0:00"
        }

        CLI.printDone("Recorded \(duration)")

        // Stop captures
        micCaptureSession?.stopRunning()

        Task {
            CLI.printStatus("Saving video...", spinner: true)

            try? await stream?.stopCapture()

            // Finish writing
            videoInput?.markAsFinished()
            systemAudioInput?.markAsFinished()
            micAudioInput?.markAsFinished()

            await assetWriter?.finishWriting()

            if assetWriter?.status == .completed {
                let size = fileSize(at: outputURL)
                CLI.printDone("Video saved (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))")

                // Merge audio tracks if ffmpeg is available
                mergeAudioTracks(at: outputURL)

                print("\n  \(outputURL.path)")
            } else if let error = assetWriter?.error {
                CLI.printError("Failed to save: \(error.localizedDescription)")
            }

            print("")
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
            return
        }

        // Check if file has 2 audio tracks using ffprobe
        let probeCmd = "ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 '\(url.path)' 2>/dev/null | wc -l"
        let trackCount = Int(shellOutput(probeCmd).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard trackCount >= 2 else {
            return // Only one audio track, no merge needed
        }

        // Start spinner for merging
        var merging = true
        let spinnerQueue = DispatchQueue(label: "spinner")
        spinnerQueue.async {
            while merging {
                CLI.printStatus("Mixing audio tracks...", spinner: true)
                Thread.sleep(forTimeInterval: 0.1)
            }
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
        merging = false
        Thread.sleep(forTimeInterval: 0.15) // Let spinner finish

        if success {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.moveItem(atPath: tempPath, toPath: url.path)
            let newSize = fileSize(at: url)
            CLI.printDone("Audio mixed (\(ByteCountFormatter.string(fromByteCount: newSize, countStyle: .file)))")
        } else {
            try? FileManager.default.removeItem(atPath: tempPath)
            CLI.printError("Failed to mix audio")
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
            // User stopped screen sharing via system UI
        } else {
            CLI.printError("Stream error: \(error.localizedDescription)")
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
let fluarLink = CLI.link("fluar.com", url: "https://fluar.com")
print("OpenRec v\(version)")
print("by \(CLI.purple)\(fluarLink)\(CLI.reset)\n")

let diskStatus = DiskSpaceStatus.check()
if diskStatus.level == .risk {
    CLI.printError("Very low disk space (\(String(format: "%.1f GB", diskStatus.availableGB)))")
    print("")
} else if diskStatus.level == .warn {
    print("⚠ Low disk space (\(String(format: "%.1f GB", diskStatus.availableGB)))\n")
}

let selectedMic = selectMicrophone()

recorder = ScreenRecorder(outputURL: outputURL, micDevice: selectedMic)

Task {
    do {
        CLI.printStatus("Starting capture...", spinner: true)
        try await recorder?.start()
    } catch {
        CLI.printError("Failed to start: \(error)")
        exit(1)
    }
}

RunLoop.main.run()
