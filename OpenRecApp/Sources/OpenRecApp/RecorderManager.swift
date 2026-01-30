import Foundation
import AppKit
import AVFoundation
import Combine

@MainActor
class RecorderManager: ObservableObject {
    @Published var isRecording = false
    @Published var isProcessing = false
    @Published var isStarting = false
    @Published var duration: TimeInterval = 0
    @Published var micLevel: Float = 0
    @Published var systemLevel: Float = 0
    @Published var clientNameInput = ""
    @Published var lastErrorMessage: String?
    @Published var showRecordingBorder = true
    @Published var microphoneDevices: [AVCaptureDevice] = []
    @Published var selectedMicrophoneID: String?

    private var recorder: ScreenRecorder?
    private var durationTimer: Timer?
    private var recordingStartTime: Date?
    private let overlayWindow = RecordingOverlayWindow()
    private var lastRecordingURL: URL?
    private var revealAfterSave = false

    var onRecordingStateChange: ((Bool) -> Void)?
    var onProcessingComplete: (() -> Void)?

    private let recordingsDirectoryKey = "RecordingsDirectory"
    private let lastClientNameKey = "LastClientName"
    private let showBorderKey = "ShowRecordingBorder"
    private let selectedMicrophoneKey = "SelectedMicrophoneID"

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

    var lastClientNameDisplay: String? {
        let saved = UserDefaults.standard.string(forKey: lastClientNameKey)
        let trimmed = saved?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    init() {
        showRecordingBorder = UserDefaults.standard.object(forKey: showBorderKey) as? Bool ?? true
        if let last = lastClientNameDisplay {
            clientNameInput = last
        }
        refreshMicrophones()
    }

    func startRecording() async {
        guard !isRecording, !isProcessing, !isStarting else { return }
        lastErrorMessage = nil
        isStarting = true

        // Generate output filename
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        let baseName = "recording_\(timestamp)"
        let clientName = resolveClientName()

        if let clientName = clientName {
            UserDefaults.standard.set(clientName, forKey: lastClientNameKey)
        }

        let outputDir: URL
        if let clientName = clientName {
            outputDir = recordingsDirectory
                .appendingPathComponent(clientName)
                .appendingPathComponent(timestamp)
        } else {
            outputDir = recordingsDirectory.appendingPathComponent(baseName)
        }

        // Create recordings directory
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let outputURL = outputDir.appendingPathComponent("\(baseName).mp4")
        let audioURL = outputDir.appendingPathComponent("\(baseName).mp3")
        lastRecordingURL = outputURL

        let mic = selectedMicrophoneDevice() ?? AVCaptureDevice.default(for: .audio)

        // Create recorder
        recorder = ScreenRecorder(outputURL: outputURL, audioOutputURL: audioURL, micDevice: mic)

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
                self?.overlayWindow.hide()
                self?.revealRecordingIfNeeded()
                self?.onProcessingComplete?()
            }
        }

        do {
            try await recorder?.start()

            isRecording = true
            isStarting = false
            recordingStartTime = Date()
            onRecordingStateChange?(true)
            if showRecordingBorder {
                overlayWindow.show(displayID: recorder?.recordingDisplayID)
            }

            // Start duration timer
            durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self = self, let startTime = self.recordingStartTime else { return }
                    self.duration = Date().timeIntervalSince(startTime)
                }
            }
        } catch {
            isStarting = false
            lastErrorMessage = startErrorMessage(from: error)
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
        overlayWindow.hide()
        revealAfterSave = true

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

    func refreshMicrophones() {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.microphone]
        } else {
            deviceTypes = [.builtInMicrophone, .externalUnknown]
        }

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        )
        microphoneDevices = discoverySession.devices

        let savedID = UserDefaults.standard.string(forKey: selectedMicrophoneKey)
        if let savedID = savedID, microphoneDevices.contains(where: { $0.uniqueID == savedID }) {
            selectedMicrophoneID = savedID
        } else {
            selectedMicrophoneID = microphoneDevices.first?.uniqueID
        }
    }

    func setShowRecordingBorder(_ value: Bool) {
        showRecordingBorder = value
        UserDefaults.standard.set(value, forKey: showBorderKey)
        if value {
            if isRecording {
                overlayWindow.show(displayID: recorder?.recordingDisplayID)
            }
        } else {
            overlayWindow.hide()
        }
    }

    func setSelectedMicrophoneID(_ id: String?) {
        selectedMicrophoneID = id
        UserDefaults.standard.set(id, forKey: selectedMicrophoneKey)
    }

    func selectedMicrophoneDevice() -> AVCaptureDevice? {
        guard let selectedID = selectedMicrophoneID else { return nil }
        return microphoneDevices.first(where: { $0.uniqueID == selectedID })
    }

    private func resolveClientName() -> String? {
        let trimmedInput = clientNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedInput.isEmpty {
            return lastClientNameDisplay
        }
        let sanitized = sanitizeClientName(trimmedInput)
        if sanitized != trimmedInput {
            clientNameInput = sanitized
        }
        return sanitized.isEmpty ? nil : sanitized
    }

    private func sanitizeClientName(_ name: String) -> String {
        return name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    private func startErrorMessage(from error: Error) -> String {
        let nsError = error as NSError
        print("Recording error: domain=\(nsError.domain) code=\(nsError.code) desc=\(error.localizedDescription)")
        if nsError.domain.contains("ScreenCaptureKit") && nsError.code == -3801 {
            return "Screen Recording permission is required."
        }
        return "Error: \(error.localizedDescription)"
    }

    private func revealRecordingIfNeeded() {
        guard revealAfterSave else { return }
        revealAfterSave = false

        if let url = lastRecordingURL, FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(recordingsDirectory)
        }
    }
}
