import Foundation
import AppKit
import AVFoundation
import Combine

@MainActor
class RecorderManager: ObservableObject {
    @Published var isRecording = false
    @Published var isProcessing = false
    @Published var duration: TimeInterval = 0
    @Published var micLevel: Float = 0
    @Published var systemLevel: Float = 0

    private var recorder: ScreenRecorder?
    private var durationTimer: Timer?
    private var recordingStartTime: Date?

    var onRecordingStateChange: ((Bool) -> Void)?

    private let recordingsDirectoryKey = "RecordingsDirectory"

    var recordingsDirectory: URL {
        if let savedPath = UserDefaults.standard.string(forKey: recordingsDirectoryKey) {
            return URL(fileURLWithPath: savedPath)
        }
        let moviesURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        return moviesURL.appendingPathComponent("OpenRec")
    }

    var recordingsPathDisplay: String {
        let path = recordingsDirectory.path
        if path.hasPrefix(NSHomeDirectory()) {
            return "~" + path.dropFirst(NSHomeDirectory().count)
        }
        return path
    }

    func startRecording() async {
        guard !isRecording else { return }

        // Create recordings directory
        try? FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)

        // Generate output filename
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        let outputURL = recordingsDirectory.appendingPathComponent("recording_\(timestamp).mp4")

        // Get default microphone
        let mic = AVCaptureDevice.default(for: .audio)

        // Create recorder
        recorder = ScreenRecorder(outputURL: outputURL, micDevice: mic)

        // Set up audio level callback
        recorder?.onAudioLevels = { [weak self] micLevel, systemLevel in
            Task { @MainActor in
                self?.micLevel = micLevel
                self?.systemLevel = systemLevel
            }
        }

        // Set up completion callback
        recorder?.onComplete = { [weak self] in
            Task { @MainActor in
                self?.isProcessing = false
            }
        }

        do {
            try await recorder?.start()

            isRecording = true
            recordingStartTime = Date()
            onRecordingStateChange?(true)

            // Start duration timer
            durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self = self, let startTime = self.recordingStartTime else { return }
                    self.duration = Date().timeIntervalSince(startTime)
                }
            }
        } catch {
            print("Failed to start recording: \(error)")
        }
    }

    func stopRecording() {
        guard isRecording else { return }

        durationTimer?.invalidate()
        durationTimer = nil

        isRecording = false
        isProcessing = true
        duration = 0
        micLevel = 0
        systemLevel = 0
        recordingStartTime = nil
        onRecordingStateChange?(false)

        recorder?.stop()
    }

    func openRecordingsFolder() {
        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)

        NSWorkspace.shared.open(recordingsDirectory)
    }

    func chooseRecordingsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Select a folder for recordings"
        panel.directoryURL = recordingsDirectory

        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: recordingsDirectoryKey)
            objectWillChange.send()
        }
    }
}
