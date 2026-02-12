import Foundation
import CoreMedia
import Combine

enum TranscriptionMode: String, CaseIterable {
    case off = "Off"
    case live = "Live"
    case postRecording = "After"
}

struct DisplaySegment: Identifiable {
    let id = UUID()
    let speakerLabel: String
    let text: String
    let timestamp: Double?
}

@MainActor
class TranscriptionManager: ObservableObject {
    @Published var mode: TranscriptionMode = .off
    @Published var isTranscribing = false
    @Published var showPanel = false
    @Published var partialText: String = ""
    @Published var committedSegments: [DisplaySegment] = []
    @Published var error: String?

    private var realtimeSTT: ElevenLabsRealtimeSTT?
    private var assemblyAISTT: AssemblyAIRealtimeSTT?
    private(set) var audioMixer: AudioMixer?
    private var delegateBridge: STTDelegateBridge?
    private var speakerMap: [String: String] = [:]
    private var nextSpeakerNumber = 1
    /// Saved energy timeline for post-recording speaker labeling.
    private var savedEnergyTimeline: [AudioEnergySnapshot] = []

    let callTipsManager = CallTipsManager()

    private let apiKeyKey = "ElevenLabsAPIKey"
    private let openRouterKeyKey = "OpenRouterAPIKey"
    private let assemblyAIKeyKey = "AssemblyAIAPIKey"

    var openRouterKey: String {
        get { UserDefaults.standard.string(forKey: openRouterKeyKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: openRouterKeyKey); objectWillChange.send() }
    }

    var hasOpenRouterKey: Bool {
        !openRouterKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var apiKey: String {
        get { UserDefaults.standard.string(forKey: apiKeyKey) ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: apiKeyKey)
            objectWillChange.send()
        }
    }

    var assemblyAIKey: String {
        get { UserDefaults.standard.string(forKey: assemblyAIKeyKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: assemblyAIKeyKey); objectWillChange.send() }
    }

    var hasAssemblyAIKey: Bool {
        !assemblyAIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True if ElevenLabs key is configured (used for both live and post-recording)
    var hasAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func startLiveTranscription() {
        guard hasAPIKey, mode == .live else { return }
        reset()
        isTranscribing = true

        let mixer = AudioMixer()
        audioMixer = mixer

        let bridge = STTDelegateBridge(manager: self)
        delegateBridge = bridge

        let stt = ElevenLabsRealtimeSTT(apiKey: apiKey)
        realtimeSTT = stt
        stt.delegate = bridge
        mixer.onChunkReady = { [weak stt] data in
            stt?.sendAudioChunk(data)
        }
        stt.connect()

        mixer.start()
    }

    /// Start only the audio mixer for energy tracking (used in post-recording mode).
    func startEnergyTracking() {
        let mixer = AudioMixer()
        audioMixer = mixer
        mixer.onChunkReady = { _ in } // discard audio, we only need energy data
        mixer.start()
    }

    /// Stop energy tracking and save the timeline.
    func stopEnergyTracking() {
        if let mixer = audioMixer {
            savedEnergyTimeline = mixer.energyTimeline
        }
        audioMixer?.stop()
        audioMixer = nil
    }

    func stopLiveTranscription() {
        // Save energy timeline before stopping mixer
        if let mixer = audioMixer {
            savedEnergyTimeline = mixer.energyTimeline
        }
        audioMixer?.stop()
        audioMixer = nil
        realtimeSTT?.disconnect()
        realtimeSTT = nil
        assemblyAISTT?.disconnect()
        assemblyAISTT = nil
        delegateBridge = nil
        isTranscribing = false
    }

    /// Returns the current AudioMixer reference so callers on audio threads can call it directly.
    /// AudioMixer is thread-safe via internal NSLock.
    func getAudioMixer() -> AudioMixer? {
        return audioMixer
    }

    func transcribeRecording(audioURL: URL, outputDir: URL) {
        guard hasAPIKey, mode == .postRecording else { return }
        reset()
        isTranscribing = true

        let batch = ElevenLabsBatchSTT(apiKey: apiKey)

        // Prefer mp3 if it exists, otherwise use mp4
        let mp3URL = audioURL.deletingPathExtension().appendingPathExtension("mp3")
        let fileToTranscribe = FileManager.default.fileExists(atPath: mp3URL.path) ? mp3URL : audioURL

        batch.transcribe(fileURL: fileToTranscribe) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let segments):
                    for segment in segments {
                        let timestamp = segment.words.first?.start
                        let label = self.speakerLabelFromEnergy(at: timestamp)
                        self.committedSegments.append(DisplaySegment(
                            speakerLabel: label,
                            text: segment.text,
                            timestamp: timestamp
                        ))
                    }
                    self.isTranscribing = false

                    // Auto-save transcript
                    let baseName = audioURL.deletingPathExtension().lastPathComponent
                    self.saveTranscript(to: outputDir, baseName: baseName)

                    // Fire a single tips request after batch transcription
                    if self.hasOpenRouterKey {
                        self.callTipsManager.requestOnce(transcriptionManager: self)
                    }
                case .failure(let error):
                    self.error = error.localizedDescription
                    self.isTranscribing = false
                }
            }
        }
    }

    func saveTranscript(to directory: URL, baseName: String) {
        guard !committedSegments.isEmpty else { return }
        let text = fullTranscriptText()
        let fileURL = directory.appendingPathComponent("\(baseName)_transcript.txt")
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func fullTranscriptText() -> String {
        committedSegments.map { "[\($0.speakerLabel)] \($0.text)" }.joined(separator: "\n")
    }

    func reset() {
        partialText = ""
        committedSegments = []
        error = nil
        speakerMap = [:]
        nextSpeakerNumber = 1
        savedEnergyTimeline = []
    }

    fileprivate func speakerLabel(for speakerID: String?) -> String {
        guard let speakerID, !speakerID.isEmpty else { return "Speaker" }
        if let existing = speakerMap[speakerID] { return existing }
        let label = "Speaker \(nextSpeakerNumber)"
        nextSpeakerNumber += 1
        speakerMap[speakerID] = label
        return label
    }

    /// Determine speaker label from audio energy at the given timestamp.
    fileprivate func speakerLabelFromEnergy(at timestamp: Double?) -> String {
        guard let timestamp else { return "Others" }

        // Get the energy timeline from the live mixer or saved copy
        let timeline: [AudioEnergySnapshot]
        if let mixer = audioMixer {
            timeline = mixer.energyTimeline
        } else {
            timeline = savedEnergyTimeline
        }
        guard !timeline.isEmpty else { return "Others" }

        // Find the closest snapshot to this timestamp
        var closest = timeline[0]
        var bestDiff = abs(closest.timestamp - timestamp)
        for snapshot in timeline {
            let diff = abs(snapshot.timestamp - timestamp)
            if diff < bestDiff {
                bestDiff = diff
                closest = snapshot
            }
            // Timeline is sorted, so if we're past the timestamp we can stop
            if snapshot.timestamp > timestamp + 1.0 { break }
        }

        return closest.dominantSource == .mic ? "Me" : "Others"
    }

    fileprivate func handlePartialTranscript(_ text: String) {
        partialText = text
    }

    fileprivate func handleCommittedTranscript(_ segment: TranscriptSegment) {
        partialText = ""
        let timestamp = segment.words.first?.start
        let label = speakerLabelFromEnergy(at: timestamp)
        committedSegments.append(DisplaySegment(
            speakerLabel: label,
            text: segment.text,
            timestamp: timestamp
        ))
    }

    fileprivate func handleDisconnect(error: Error?) {
        if let error {
            self.error = error.localizedDescription
        }
        isTranscribing = false
    }
}

// MARK: - Delegate Bridge (nonisolated → @MainActor)

private class STTDelegateBridge: ElevenLabsSTTDelegate {
    private weak var manager: TranscriptionManager?

    init(manager: TranscriptionManager) {
        self.manager = manager
    }

    func sttDidReceivePartialTranscript(_ text: String) {
        Task { @MainActor [weak self] in
            self?.manager?.handlePartialTranscript(text)
        }
    }

    func sttDidReceiveCommittedTranscript(_ segment: TranscriptSegment) {
        Task { @MainActor [weak self] in
            self?.manager?.handleCommittedTranscript(segment)
        }
    }

    func sttDidDisconnect(error: Error?) {
        Task { @MainActor [weak self] in
            self?.manager?.handleDisconnect(error: error)
        }
    }
}
