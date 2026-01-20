import Foundation
import Dispatch
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
    static let underline = "\u{1B}[4m"

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

// MARK: - Recording Name Input

func promptRecordingName() -> String? {
    print("\(CLI.dim)Group into folder name (enter to skip):\(CLI.reset) ", terminator: "")
    fflush(stdout)

    let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines)

    // Clear the prompt line
    print("\(CLI.moveUp)\r\u{1B}[K", terminator: "")
    fflush(stdout)

    if let input = input, !input.isEmpty {
        // Sanitize for filesystem
        let sanitized = input.replacingOccurrences(of: "/", with: "-")
                             .replacingOccurrences(of: ":", with: "-")
        return sanitized
    }
    return nil
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

    // Audio level visualization
    private var micAudioLevel: Float = 0
    private var systemAudioLevel: Float = 0
    private var audioLevelLock = NSLock()

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

        audioLevelLock.lock()
        let micLevel = micAudioLevel
        let sysLevel = systemAudioLevel
        audioLevelLock.unlock()

        let micMeter = formatMeter(micLevel)
        let sysMeter = formatMeter(sysLevel)

        CLI.printStatus("Recording \(duration)  \(CLI.dim)you\(CLI.reset) \(micMeter)  \(CLI.dim)them\(CLI.reset) \(sysMeter)", spinner: true)
    }

    private func formatMeter(_ level: Float) -> String {
        let filled = Int(level * 5)
        var dots = ""
        for i in 0..<5 {
            if i < filled {
                if i >= 4 {
                    dots += "\(CLI.red)●\(CLI.reset)"
                } else if i >= 3 {
                    dots += "\(CLI.purple)●\(CLI.reset)"
                } else {
                    dots += "\(CLI.green)●\(CLI.reset)"
                }
            } else {
                dots += "\(CLI.dim)·\(CLI.reset)"
            }
        }
        return dots
    }

    private func calculateAudioLevel(from sampleBuffer: CMSampleBuffer) -> Float {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return 0 }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let data = dataPointer, length > 0 else { return 0 }

        // Audio is Float32 format
        let samples = UnsafeRawPointer(data).bindMemory(to: Float32.self, capacity: length / 4)
        let sampleCount = length / 4
        var sum: Float = 0

        let count = min(sampleCount, 512)
        for i in 0..<count {
            let sample = samples[i]
            sum += sample * sample
        }

        let rms = sqrt(sum / Float(count))
        // Scale for visibility
        return min(1.0, rms * 12.0)
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

                // Show clickable links
                let folderURL = outputURL.deletingLastPathComponent()
                let folderLink = CLI.link("\(CLI.blue)\(CLI.underline)Folder\(CLI.reset)", url: "file://\(folderURL.path)")
                let fileLink = CLI.link("\(CLI.blue)\(CLI.underline)Recording\(CLI.reset)", url: "file://\(outputURL.path)")

                print("")
                print("  📁 \(folderLink)")
                print("  🎬 \(fileLink)")
                print("")
                print("  \(CLI.dim)cmd+click to open\(CLI.reset)")
                print("  \(CLI.dim)\(folderURL.path)\(CLI.reset)")
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

        // Calculate system audio level for visualization
        let level = calculateAudioLevel(from: sampleBuffer)
        audioLevelLock.lock()
        systemAudioLevel = level
        audioLevelLock.unlock()
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isRecording, sessionStarted else { return }

        if micAudioInput?.isReadyForMoreMediaData == true {
            micAudioInput?.append(sampleBuffer)
        }

        // Calculate mic audio level for visualization
        let level = calculateAudioLevel(from: sampleBuffer)
        audioLevelLock.lock()
        micAudioLevel = level
        audioLevelLock.unlock()
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

// MARK: - Update Checker

struct UpdateChecker {
    struct Version: Comparable, CustomStringConvertible {
        let parts: [Int]
        let original: String

        init?(_ string: String) {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let normalized = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
            let core = normalized.split(separator: "-").first.map(String.init) ?? normalized
            let partStrings = core.split(separator: ".")
            guard !partStrings.isEmpty else { return nil }

            var parsed: [Int] = []
            for part in partStrings {
                guard let number = Int(part) else { return nil }
                parsed.append(number)
            }

            parts = parsed
            original = core
        }

        static func < (lhs: Version, rhs: Version) -> Bool {
            let maxCount = max(lhs.parts.count, rhs.parts.count)
            for i in 0..<maxCount {
                let left = i < lhs.parts.count ? lhs.parts[i] : 0
                let right = i < rhs.parts.count ? rhs.parts[i] : 0
                if left != right {
                    return left < right
                }
            }
            return false
        }

        var description: String {
            original
        }
    }

    struct UpdateInfo {
        let latestVersion: Version
        let tag: String
        let releaseURL: String
        let downloadURL: String?
    }

    private static let checkInterval: TimeInterval = 60 * 60 * 24
    private static let repoOwner = "ky-zo"
    private static let repoName = "openrec"
    private static let releasePageURL = "https://github.com/\(repoOwner)/\(repoName)/releases/latest"
    private static let releaseAPIURL = URL(
        string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
    )!

    private static let assetName: String = {
#if arch(arm64)
        return "openrec-macos-arm64.zip"
#elseif arch(x86_64)
        return "openrec-macos-x86_64.zip"
#else
        return "openrec-macos.zip"
#endif
    }()

    static func checkIfNeeded(currentVersion: String) {
        guard shouldCheck() else { return }
        defer { saveLastCheck() }

        guard let current = Version(currentVersion) else { return }
        guard let info = fetchLatestRelease() else { return }

        if info.latestVersion > current {
            print("")
            print("Update available: \(info.tag) (installed v\(current))")
            let link = info.downloadURL ?? info.releaseURL
            print("Download: \(link)")
            print("")
        }
    }

    private static func shouldCheck() -> Bool {
        guard let lastCheck = loadLastCheck() else { return true }
        return Date().timeIntervalSince(lastCheck) >= checkInterval
    }

    private static func loadLastCheck() -> Date? {
        let url = stateFileURL()
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let timestamp = TimeInterval(trimmed) else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    private static func saveLastCheck() {
        let url = stateFileURL()
        let timestamp = String(Int(Date().timeIntervalSince1970))
        try? timestamp.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func stateFileURL() -> URL {
        let fileManager = FileManager.default
        let baseDir = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        let appDir = baseDir.appendingPathComponent("openrec", isDirectory: true)
        try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("update-check.txt")
    }

    private static func fetchLatestRelease() -> UpdateInfo? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 3
        let session = URLSession(configuration: config)

        var request = URLRequest(url: releaseAPIURL)
        request.timeoutInterval = 3
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("OpenRec", forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        var result: UpdateInfo?

        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if error != nil {
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                return
            }
            guard let data = data else { return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            guard let tag = json["tag_name"] as? String else { return }
            guard let latestVersion = Version(tag) else { return }

            let releaseURL = (json["html_url"] as? String) ?? releasePageURL
            var downloadURL: String?

            if let assets = json["assets"] as? [[String: Any]] {
                if let asset = assets.first(where: { ($0["name"] as? String) == assetName }) {
                    downloadURL = asset["browser_download_url"] as? String
                }
            }

            result = UpdateInfo(
                latestVersion: latestVersion,
                tag: tag,
                releaseURL: releaseURL,
                downloadURL: downloadURL
            )
        }

        task.resume()
        _ = semaphore.wait(timeout: .now() + 4)
        return result
    }
}

func loadAppVersion(from directory: URL) -> String {
    let versionURL = directory.appendingPathComponent("VERSION")
    if let contents = try? String(contentsOf: versionURL, encoding: .utf8) {
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
    }
    return "dev"
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

let rawVersion = loadAppVersion(from: executableURL)
let displayVersion = rawVersion.hasPrefix("v") ? String(rawVersion.dropFirst()) : rawVersion
let fluarLink = CLI.link("fluar.com", url: "https://fluar.com")
print("OpenRec v\(displayVersion)")
print("by \(CLI.purple)\(fluarLink)\(CLI.reset)\n")

let diskStatus = DiskSpaceStatus.check()
if diskStatus.level == .risk {
    CLI.printError("Very low disk space (\(String(format: "%.1f GB", diskStatus.availableGB)))")
    print("")
} else if diskStatus.level == .warn {
    print("⚠ Low disk space (\(String(format: "%.1f GB", diskStatus.availableGB)))\n")
}

UpdateChecker.checkIfNeeded(currentVersion: rawVersion)

let selectedMic = selectMicrophone()
let recordingName = promptRecordingName()

// Build output path based on name
let outputURL: URL
if let name = recordingName {
    // recordings/{name}/{timestamp}/{name}_recording_{timestamp}.mp4
    let namedDir = recordingsDir.appendingPathComponent(name).appendingPathComponent(timestamp)
    try? FileManager.default.createDirectory(at: namedDir, withIntermediateDirectories: true)
    outputURL = namedDir.appendingPathComponent("\(name)_recording_\(timestamp).mp4")
    CLI.printDone("Folder: \(name)")
} else {
    // recordings/recording_{timestamp}.mp4
    try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
    outputURL = recordingsDir.appendingPathComponent("recording_\(timestamp).mp4")
}

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
