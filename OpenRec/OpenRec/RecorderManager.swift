import Foundation
import AppKit
import AVFoundation
import Combine

struct MeetingSaveRecovery: Equatable {
    let screenURL: URL?
    let cloudMediaAvailable: Bool
    let unavailableReason: String?

    var canRetry: Bool { screenURL != nil || cloudMediaAvailable }

    static func evaluate(
        for meeting: MeetingRecord,
        fileExists: (String) -> Bool
    ) -> MeetingSaveRecovery {
        guard meeting.saveStatus == .failed else {
            return MeetingSaveRecovery(screenURL: nil, cloudMediaAvailable: false, unavailableReason: nil)
        }
        if meeting.hasAudioRecording || meeting.hasScreenRecording {
            return MeetingSaveRecovery(screenURL: nil, cloudMediaAvailable: true, unavailableReason: nil)
        }
        guard let path = meeting.localScreenPath, !path.isEmpty else {
            return MeetingSaveRecovery(
                screenURL: nil,
                cloudMediaAvailable: false,
                unavailableReason: "This cloud stream ended before a playable recording was finalized, so there is nothing to retry."
            )
        }
        guard fileExists(path) else {
            let displayPath = (path as NSString).abbreviatingWithTildeInPath
            return MeetingSaveRecovery(
                screenURL: nil,
                cloudMediaAvailable: false,
                unavailableReason: "Retry is unavailable because the local recovery recording is missing from \(displayPath). Restore that file, then reopen the meeting."
            )
        }
        return MeetingSaveRecovery(
            screenURL: URL(fileURLWithPath: path),
            cloudMediaAvailable: false,
            unavailableReason: nil
        )
    }

    static func live(for meeting: MeetingRecord) -> MeetingSaveRecovery {
        evaluate(for: meeting) { FileManager.default.fileExists(atPath: $0) }
    }
}

struct CloudTranscriptRetentionPolicy {
    static func shouldAttemptTranscription(
        storedTranscript: String?,
        hasStoredInsights: Bool,
        hasRetryMedia: Bool,
        storeTranscriptInCloud: Bool
    ) -> Bool {
        guard hasRetryMedia else { return false }
        let transcriptIsEmpty = storedTranscript?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ?? true
        if storeTranscriptInCloud {
            return transcriptIsEmpty
        }
        return transcriptIsEmpty && !hasStoredInsights
    }

    static let noSpeechFailureMessage =
        "AssemblyAI processed the recording but did not detect any spoken words — the API key and connection are fine. OpenRec kept the recording needed for retry in case the call did contain speech; check the selected microphone before the next call."

    static func validatedTranscript(
        _ transcript: String,
        required: Bool,
        failure: Error? = nil
    ) throws -> String {
        guard required else { return transcript }

        if let failure {
            if case OpenRecError.noSpeechDetected = failure {
                throw OpenRecError.recordingFailed(noSpeechFailureMessage)
            }
            if AssemblyAIService.isAuthenticationFailure(failure) {
                throw OpenRecError.recordingFailed(
                    "AssemblyAI rejected the API key, so this recording was not transcribed. OpenRec kept the recording needed for retry. Fix the AssemblyAI API key in Settings, then retry this meeting."
                )
            }
            var description = failure.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            while description.hasSuffix(".") { description.removeLast() }
            throw OpenRecError.recordingFailed(
                "The requested transcript could not be created: \(description). OpenRec kept the recording needed for retry. Check your internet connection, then retry this meeting."
            )
        }

        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenRecError.recordingFailed(noSpeechFailureMessage)
        }
        return transcript
    }

    static func shouldKeepMediaAfterSuccessfulProcessing(
        retentionRequested: Bool,
        preserveWebhookRecovery: Bool,
        deletionScheduled: Bool
    ) -> Bool {
        retentionRequested || preserveWebhookRecovery || deletionScheduled
    }
}

private struct LegacyRecordingArtifacts {
    let screenURL: URL
    let audioURL: URL?
}

@MainActor
final class RecorderManager: ObservableObject {
    @Published var isRecording = false
    @Published var isProcessing = false
    @Published var isStarting = false
    @Published var duration: TimeInterval = 0
    @Published var micLevel: Float = 0
    @Published var systemLevel: Float = 0
    @Published var clientNameInput = ""
    @Published var lastErrorMessage: String?
    @Published var savePhase: SavePhase = .idle
    @Published var showRecordingBorder = true
    @Published var callDetectionEnabled: Bool {
        didSet { UserDefaults.standard.set(callDetectionEnabled, forKey: "CallDetectionEnabled") }
    }
    @Published var microphoneDevices: [AVCaptureDevice] = []
    @Published var selectedMicrophoneID: String?
    @Published var callPreferences: CallPreferences {
        didSet { savePreferences() }
    }
    @Published private(set) var activeCallPreferences: CallPreferences?
    @Published var detectedCall: DetectedCall?
    @Published var lastSavedMeetingID: UUID?
    @Published private(set) var cloudUploadProgress: MediaStreamingProgress?
    @Published private(set) var upcomingEvents: [UpcomingCalendarEvent] = []
    @Published private(set) var isLoadingUpcomingEvents = false
    /// True when the Google Calendar feed answered the last refresh — i.e. the
    /// signed-in Google account is actually serving calendar events, not just
    /// signed in.
    @Published private(set) var googleCalendarActive = false

    let transcriptionManager = TranscriptionManager()
    let cloudStorage = CloudStorageManager()
    let webhookSettings = WebhookSettings()
    private let calendarSuggester = CalendarMeetingSuggester()
    private var lastSuggestedMeetingName: String?

    private var recorder: ScreenRecorder?
    private var mediaStreamingSession: MediaStreamingSession?
    private let mediaAppendGroup = DispatchGroup()
    private var mediaAppendError: Error?
    private var durationTimer: Timer?
    private var recordingStartTime: Date?
    private let overlayWindow = RecordingOverlayWindow()
    private var lastRecordingURL: URL?
    private var lastAudioURL: URL?
    private var lastOutputDir: URL?
    private var lastArtifacts: LegacyRecordingArtifacts?
    private var pendingMeetingID: UUID?
    private var pendingPreferences = CallPreferences()
    private var pendingStorageMode: StorageMode = .managed
    private var pendingStorageContext: CloudStorageContext?
    private var pendingDuration = 0
    private var pendingStartedAt: Date?
    private var pendingEndedAt: Date?
    private var pendingManualTitle: String?
    private var audioMixerRef: AudioMixer?
    private var cancellables = Set<AnyCancellable>()
    private var deferredMediaCleanupTasks: [UUID: Task<Void, Never>] = [:]
    private var startupCancellationRequested = false
    private var discardRecorderOnCompletion = false

    private static let webhookMediaAccessLifetime: TimeInterval = 60 * 60
    private static let webhookMediaCleanupGrace: TimeInterval = 65 * 60

    var onRecordingStateChange: ((Bool) -> Void)?
    var onProcessingComplete: (() -> Void)?

    private let lastClientNameKey = "LastClientName"
    private let showBorderKey = "ShowRecordingBorder"
    private let selectedMicrophoneKey = "SelectedMicrophoneID"

    var lastClientNameDisplay: String? {
        let value = UserDefaults.standard.string(forKey: lastClientNameKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    init() {
        showRecordingBorder = UserDefaults.standard.object(forKey: showBorderKey) as? Bool ?? true
        callDetectionEnabled = UserDefaults.standard.object(forKey: "CallDetectionEnabled") as? Bool ?? true
        callPreferences = Self.loadPreferences()
        if let last = lastClientNameDisplay { clientNameInput = last }
        refreshMicrophones()

        transcriptionManager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        cloudStorage.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        cloudStorage.recoverInterruptedSaves()
        cloudStorage.$libraryMeetings
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.resumeDeferredMediaCleanup() }
            .store(in: &cancellables)
        webhookSettings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        resumeDeferredMediaCleanup()
        refreshMeetingNameSuggestion()
    }

    /// Pre-fill the call-name field with the calendar meeting happening now,
    /// preferring the connected Google Calendar (managed cloud) and falling
    /// back to the Mac's local calendars. Never overwrites a name typed this
    /// session — only an empty field, the restored previous call name, or an
    /// earlier suggestion.
    func refreshMeetingNameSuggestion() {
        guard !isRecording, !isStarting, !isProcessing else { return }
        Task { [weak self] in
            guard let self else { return }
            var suggestion = ((try? await self.cloudStorage.currentCalendarCall()) ?? nil)?.title
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if suggestion?.isEmpty != false {
                suggestion = await self.calendarSuggester.currentMeetingTitle()
            }
            guard let suggestion, !suggestion.isEmpty else { return }
            let current = self.clientNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
            let replaceable = current.isEmpty
                || current == self.lastSuggestedMeetingName
                || current == self.lastClientNameDisplay
            guard replaceable, current != suggestion else { return }
            self.lastSuggestedMeetingName = suggestion
            self.clientNameInput = suggestion
        }
    }

    /// Load ongoing/upcoming calendar events for the Meetings window's
    /// "Coming up" list, merging the connected Google Calendar (managed cloud)
    /// with the Mac's local calendars.
    func refreshUpcomingEvents(withinDays days: Int = 7) {
        guard !isLoadingUpcomingEvents else { return }
        isLoadingUpcomingEvents = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isLoadingUpcomingEvents = false }
            async let cloudEvents = self.cloudStorage.upcomingCalendarEvents(withinDays: days)
            async let localEvents = self.calendarSuggester.upcomingEvents(withinDays: days)
            let cloud = await cloudEvents
            self.googleCalendarActive = cloud != nil
            let merged = (cloud ?? []) + (await localEvents)
            // The same meeting often exists in both sources; treat identical
            // title + start minute as one event.
            var seen = Set<String>()
            self.upcomingEvents = merged
                .sorted { $0.start < $1.start }
                .filter { event in
                    let key = "\(event.title.lowercased())|\(Int(event.start.timeIntervalSince1970 / 60))"
                    return seen.insert(key).inserted
                }
        }
    }

    /// Prompt for access to the Mac's calendars (onboarding's optional step).
    func requestLocalCalendarAccess() async -> Bool {
        let granted = await calendarSuggester.requestAccess()
        if granted { refreshMeetingNameSuggestion() }
        return granted
    }

    /// Use an upcoming calendar event as the next call's name.
    func adoptUpcomingEvent(_ event: UpcomingCalendarEvent) {
        guard !isRecording, !isStarting, !isProcessing else { return }
        lastSuggestedMeetingName = event.title
        clientNameInput = event.title
    }

    func startRecording() async {
        guard !isRecording, !isProcessing, !isStarting else { return }
        guard transcriptionManager.hasAssemblyAIAPIKey else {
            lastErrorMessage = "Open Settings and add your AssemblyAI API key before recording."
            return
        }
        guard transcriptionManager.isAssemblyAIAPIKeyVerified else {
            lastErrorMessage = "Open Settings and test your AssemblyAI API key before recording."
            return
        }
        guard transcriptionManager.hasOpenAIAPIKey else {
            lastErrorMessage = "Open Settings and add your OpenAI API key for meeting summaries and next steps."
            return
        }
        guard transcriptionManager.isOpenAIAPIKeyVerified else {
            lastErrorMessage = "Open Settings and test your OpenAI API key before recording."
            return
        }
        guard cloudStorage.isReady else {
            lastErrorMessage = cloudStorage.mode == .managed
                ? "Continue with Google before recording so the call has a cloud home."
                : "Complete your R2 account, bucket, access key, and secret key before recording."
            return
        }
        if cloudStorage.mode == .managed && callPreferences.storeTranscriptInCloud && !cloudStorage.canStoreTranscriptInCloud {
            lastErrorMessage = "Sign in to OpenRec Cloud or turn off transcript sync before recording."
            return
        }
        if callPreferences.sendToWebhook && !webhookSettings.isConfigured {
            lastErrorMessage = "Add a valid HTTPS webhook URL or turn off webhook delivery."
            return
        }
        let storageContext: CloudStorageContext
        do {
            storageContext = try cloudStorage.captureStorageContext()
        } catch {
            lastErrorMessage = error.localizedDescription
            return
        }
        lastErrorMessage = nil
        savePhase = .idle
        startupCancellationRequested = false
        discardRecorderOnCompletion = false
        isStarting = true
        activeCallPreferences = callPreferences
        pendingStorageMode = storageContext.mode
        pendingStorageContext = storageContext
        pendingMeetingID = nil
        pendingStartedAt = nil
        pendingEndedAt = nil

        if let calendar = try? await cloudStorage.currentCalendarCall(storageContext: storageContext),
           !calendar.participants.isEmpty || detectedCall?.title == nil {
            detectedCall = DetectedCall(
                appName: detectedCall?.appName ?? "Google Calendar",
                title: detectedCall?.title ?? calendar.title,
                participants: calendar.participants.isEmpty ? (detectedCall?.participants ?? []) : calendar.participants
            )
        }
        if startupCancellationRequested {
            finishCancelledStartup()
            return
        }

        lastArtifacts = nil
        mediaAppendError = nil
        cloudUploadProgress = nil
        transcriptionManager.resetTranscript()

        let clientName = resolveClientName()
        pendingManualTitle = clientName
        if let clientName { UserDefaults.standard.set(clientName, forKey: lastClientNameKey) }
        lastRecordingURL = nil
        lastAudioURL = nil
        lastOutputDir = nil

        let meetingID = UUID()
        let provisionalStart = Date()
        pendingMeetingID = meetingID
        pendingStartedAt = provisionalStart
        pendingPreferences = activeCallPreferences ?? callPreferences

        let initialTitle = detectedCall?.displayTitle ?? clientName ?? "Untitled call"
        let pendingRecord = MeetingRecord(
            id: meetingID,
            startedAt: provisionalStart,
            endedAt: provisionalStart,
            durationSeconds: 0,
            callApp: detectedCall?.appName,
            callTitle: detectedCall?.title ?? clientName,
            transcript: nil,
            insights: MeetingInsights(title: initialTitle, participants: detectedCall?.participants ?? []),
            hasScreenRecording: false,
            hasAudioRecording: false,
            screenFileExtension: "mp4",
            audioFileExtension: "m4a",
            localScreenPath: nil,
            localAudioPath: nil,
            storageMode: pendingStorageMode,
            preferences: pendingPreferences,
            saveStatus: .processing,
            saveStage: .finalizing,
            errorMessage: nil,
            createdAt: provisionalStart,
            updatedAt: provisionalStart
        )
        try? cloudStorage.upsertLocalMeeting(pendingRecord)

        let mic = selectedMicrophoneDevice() ?? AVCaptureDevice.default(for: .audio)

        do {
            let upload = try await cloudStorage.beginMediaStreaming(
                meetingID: meetingID,
                kinds: [.screen, .audio],
                startedAt: provisionalStart,
                callApp: detectedCall?.appName,
                callTitle: detectedCall?.title ?? clientName,
                storageContext: storageContext,
                progress: { [weak self] progress in
                    self?.handleStreamingProgress(progress)
                }
            )
            mediaStreamingSession = upload
            if startupCancellationRequested {
                await upload.abort()
                mediaStreamingSession = nil
                await discardAbandonedPendingMeeting(orMarkFailedWith: "Recording startup was cancelled.")
                finishCancelledStartup()
                return
            }

            let recorder = ScreenRecorder(micDevice: mic, recordsScreen: true, recordsAudio: true)
            self.recorder = recorder
            recorder.onAudioLevels = { [weak self] mic, system in
                Task { @MainActor in self?.micLevel = mic; self?.systemLevel = system }
            }
            recorder.onSystemAudioSample = { [weak self] sample in self?.audioMixerRef?.appendSystemAudio(sample) }
            recorder.onMicAudioSample = { [weak self] sample in self?.audioMixerRef?.appendMicAudio(sample) }
            let appendGroup = mediaAppendGroup
            recorder.onSegment = { [weak self] segment in
                // Enter on ScreenRecorder's serial delivery queue before the
                // completion callback can be emitted. Main-actor Task ordering
                // is not guaranteed, but the group now always observes every
                // final CMAF segment before multipart completion starts.
                appendGroup.enter()
                Task { @MainActor [weak self] in
                    defer { appendGroup.leave() }
                    await self?.appendCloudSegment(segment)
                }
            }
            recorder.onComplete = { [weak self] result in
                Task { @MainActor in await self?.handleRecorderCompletion(result) }
            }

            if transcriptionManager.mode == .live {
                transcriptionManager.startLiveTranscription()
            } else {
                transcriptionManager.startEnergyTracking()
            }
            audioMixerRef = transcriptionManager.getAudioMixer()

            try await recorder.start()
            let actualStart = Date()
            if startupCancellationRequested {
                isRecording = true
                isStarting = false
                recordingStartTime = actualStart
                pendingStartedAt = actualStart
                discardRecorderOnCompletion = true
                transitionRecordingToProcessing(stoppedAt: actualStart)
                recorder.stop()
                return
            }
            isRecording = true
            isStarting = false
            startupCancellationRequested = false
            recordingStartTime = actualStart
            pendingStartedAt = actualStart
            onRecordingStateChange?(true)
            if showRecordingBorder { overlayWindow.show(displayID: recorder.recordingDisplayID) }
            durationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let start = self.recordingStartTime else { return }
                    self.duration = Date().timeIntervalSince(start)
                }
            }
        } catch {
            let wasCancelled = startupCancellationRequested
            activeCallPreferences = nil
            if transcriptionManager.mode == .live { transcriptionManager.stopLiveTranscription() }
            else { transcriptionManager.stopEnergyTracking() }
            audioMixerRef = nil
            if let mediaStreamingSession { await mediaStreamingSession.abort() }
            self.mediaStreamingSession = nil
            lastErrorMessage = startErrorMessage(from: error)
            await discardAbandonedPendingMeeting(orMarkFailedWith: lastErrorMessage ?? error.localizedDescription)
            if wasCancelled {
                finishCancelledStartup()
            } else {
                isStarting = false
                startupCancellationRequested = false
            }
        }
    }

    /// Keeps application termination pending until any provisional cloud row and
    /// multipart sessions created during startup have been cleaned up.
    func cancelStartingRecordingForTermination() {
        guard isStarting else { return }
        startupCancellationRequested = true
    }

    private func finishCancelledStartup() {
        startupCancellationRequested = false
        discardRecorderOnCompletion = false
        isStarting = false
        isRecording = false
        isProcessing = false
        savePhase = .idle
        activeCallPreferences = nil
        recorder = nil
        audioMixerRef = nil
        if pendingMeetingID == nil {
            pendingStartedAt = nil
            pendingEndedAt = nil
            pendingManualTitle = nil
            pendingStorageContext = nil
        }
        durationTimer?.invalidate()
        durationTimer = nil
        recordingStartTime = nil
        duration = 0
        micLevel = 0
        systemLevel = 0
        onRecordingStateChange?(false)
        overlayWindow.hide()
        onProcessingComplete?()
    }

    func stopRecording() {
        guard isRecording else { return }
        transitionRecordingToProcessing(stoppedAt: Date())
        recorder?.stop()
    }

    /// Stops capture and permanently discards everything this call produced:
    /// media already streamed to cloud storage, the provisional meeting row,
    /// and the live transcript. The caller is responsible for confirming with
    /// the user first — this is not undoable.
    func cancelRecording() {
        guard isRecording else { return }
        discardRecorderOnCompletion = true
        transitionRecordingToProcessing(stoppedAt: Date())
        // The stop transition prepares the notes panel for processing; a
        // discarded call has nothing to show, so keep the panel closed.
        transcriptionManager.showPanel = false
        transcriptionManager.resetTranscript()
        recorder?.stop()
    }

    private func transitionRecordingToProcessing(stoppedAt: Date) {
        guard isRecording else { return }
        let startedAt = recordingStartTime ?? stoppedAt.addingTimeInterval(-duration)
        durationTimer?.invalidate()
        durationTimer = nil
        if transcriptionManager.mode == .live { transcriptionManager.stopLiveTranscription() }
        else { transcriptionManager.stopEnergyTracking() }
        audioMixerRef = nil

        pendingPreferences = activeCallPreferences ?? callPreferences
        activeCallPreferences = nil
        pendingDuration = max(0, Int(stoppedAt.timeIntervalSince(startedAt).rounded()))
        pendingStartedAt = startedAt
        pendingEndedAt = stoppedAt
        let meetingID = pendingMeetingID ?? UUID()
        pendingMeetingID = meetingID
        let initialTitle = detectedCall?.displayTitle ?? pendingManualTitle ?? "Untitled call"
        let pendingRecord = MeetingRecord(
            id: meetingID,
            startedAt: startedAt,
            endedAt: stoppedAt,
            durationSeconds: pendingDuration,
            callApp: detectedCall?.appName,
            callTitle: detectedCall?.title ?? pendingManualTitle,
            transcript: nil,
            insights: MeetingInsights(title: initialTitle, participants: detectedCall?.participants ?? []),
            hasScreenRecording: false,
            hasAudioRecording: false,
            screenFileExtension: "mp4",
            audioFileExtension: "m4a",
            localScreenPath: nil,
            localAudioPath: nil,
            storageMode: pendingStorageMode,
            preferences: pendingPreferences,
            saveStatus: .processing,
            saveStage: .finalizing,
            errorMessage: nil,
            createdAt: stoppedAt,
            updatedAt: stoppedAt
        )
        try? cloudStorage.upsertLocalMeeting(pendingRecord)
        isRecording = false
        isProcessing = true
        savePhase = .finalizing
        duration = 0
        micLevel = 0
        systemLevel = 0
        recordingStartTime = nil
        onRecordingStateChange?(false)
        overlayWindow.hide()
        transcriptionManager.showPanel = true
    }

    func retryLastSave() {
        guard let artifacts = lastArtifacts,
              FileManager.default.fileExists(atPath: artifacts.screenURL.path),
              !isProcessing else { return }
        isProcessing = true
        lastErrorMessage = nil
        Task { await processLegacy(artifacts: artifacts) }
    }

    func retryFailedMeeting(_ meeting: MeetingRecord) {
        guard meeting.saveStatus == .failed, !isRecording, !isProcessing, !isStarting else { return }
        let recovery = MeetingSaveRecovery.live(for: meeting)
        if recovery.cloudMediaAvailable {
            let storageContext: CloudStorageContext
            do {
                storageContext = try cloudStorage.captureStorageContext(for: meeting.storageMode)
            } catch {
                lastErrorMessage = error.localizedDescription
                return
            }
            transcriptionManager.resetTranscript()
            pendingMeetingID = meeting.id
            pendingDuration = meeting.durationSeconds
            pendingStartedAt = meeting.startedAt
            pendingEndedAt = meeting.endedAt
            pendingPreferences = meeting.preferences
            pendingStorageMode = meeting.storageMode
            pendingStorageContext = storageContext
            pendingManualTitle = meeting.callTitle
            detectedCall = meeting.callApp.map {
                DetectedCall(appName: $0, title: meeting.callTitle, participants: meeting.insights.participants)
            }
            isProcessing = true
            lastErrorMessage = nil
            Task { await processRecoveredCloudMeeting(meeting) }
            return
        }
        guard let screenURL = recovery.screenURL else {
            lastErrorMessage = recovery.unavailableReason
            return
        }
        let artifacts = LegacyRecordingArtifacts(screenURL: screenURL, audioURL: meeting.localAudioURL)
        let storageContext: CloudStorageContext
        do {
            storageContext = try cloudStorage.captureStorageContext(for: meeting.storageMode)
        } catch {
            lastErrorMessage = error.localizedDescription
            return
        }
        lastArtifacts = artifacts
        lastRecordingURL = screenURL
        lastAudioURL = meeting.localAudioURL
        lastOutputDir = screenURL.deletingLastPathComponent()
        pendingMeetingID = meeting.id
        pendingDuration = meeting.durationSeconds
        pendingStartedAt = meeting.startedAt
        pendingEndedAt = meeting.endedAt
        pendingPreferences = meeting.preferences
        pendingStorageMode = meeting.storageMode
        pendingStorageContext = storageContext
        pendingManualTitle = meeting.callTitle
        detectedCall = meeting.callApp.map {
            DetectedCall(appName: $0, title: meeting.callTitle, participants: meeting.insights.participants)
        }
        isProcessing = true
        lastErrorMessage = nil
        Task { await processLegacy(artifacts: artifacts) }
    }

    private func handleRecorderCompletion(_ result: Result<ScreenRecorder.Completion, Error>) async {
        // ScreenCaptureKit can stop capture on its own (display removal,
        // permission revocation, encoder failure). Mirror the normal Stop
        // transition before processing so the timer, icon, preferences, and
        // durable meeting timestamps cannot remain stuck in recording state.
        if isRecording {
            transitionRecordingToProcessing(stoppedAt: Date())
        }
        if discardRecorderOnCompletion {
            discardRecorderOnCompletion = false
            if let mediaStreamingSession { await mediaStreamingSession.abort() }
            self.mediaStreamingSession = nil
            await discardAbandonedPendingMeeting(orMarkFailedWith: "Recording startup was cancelled.")
            finishCancelledStartup()
            return
        }
        switch result {
        case .success:
            await processCloudRecording()
        case .failure(let error):
            if let mediaStreamingSession { await mediaStreamingSession.abort() }
            self.mediaStreamingSession = nil
            let message = "Recording finalization failed: \(error.localizedDescription)"
            await discardAbandonedPendingMeeting(orMarkFailedWith: message)
            failSaving(message, markMeetingFailed: false)
        }
    }

    private func appendCloudSegment(_ segment: ScreenRecorder.CMAFSegment) async {
        guard let mediaStreamingSession else { return }
        let kind: MeetingMediaKind = segment.stream == .screen ? .screen : .audio
        do {
            _ = try await mediaStreamingSession.append(
                segment.data,
                kind: kind,
                sequence: segment.sequence
            )
        } catch {
            if mediaAppendError == nil { mediaAppendError = error }
            lastErrorMessage = error.localizedDescription
            if isRecording { stopRecording() }
        }
    }

    private func waitForCloudSegments() async {
        await withCheckedContinuation { continuation in
            mediaAppendGroup.notify(queue: .global(qos: .utility)) {
                continuation.resume()
            }
        }
    }

    private func handleStreamingProgress(_ progress: MediaStreamingProgress) {
        cloudUploadProgress = progress
        if let message = progress.errorMessage {
            lastErrorMessage = message
            if isRecording { stopRecording() }
        }
    }

    private func processCloudRecording() async {
        guard let mediaStreamingSession,
              let meetingID = pendingMeetingID,
              let storageContext = pendingStorageContext else {
            let message = "The cloud recording session is unavailable."
            await discardAbandonedPendingMeeting(orMarkFailedWith: message)
            failSaving(message, markMeetingFailed: false)
            return
        }
        await waitForCloudSegments()
        if let mediaAppendError {
            await mediaStreamingSession.abort()
            self.mediaStreamingSession = nil
            let message = mediaAppendError.localizedDescription
            await discardAbandonedPendingMeeting(orMarkFailedWith: message)
            failSaving(message, markMeetingFailed: false)
            return
        }

        var meeting = cloudStorage.localMeeting(id: meetingID) ?? pendingMeetingRecord(id: meetingID)
        var warnings: [String] = []
        do {
            savePhase = .uploading
            meeting.saveStatus = .processing
            meeting.saveStage = .uploadingMedia
            meeting.updatedAt = Date()
            try cloudStorage.upsertLocalMeeting(meeting)

            _ = try await mediaStreamingSession.finish()
            meeting.hasScreenRecording = true
            meeting.hasAudioRecording = true
            meeting.updatedAt = Date()
            try cloudStorage.upsertLocalMeeting(meeting)

            savePhase = .transcribing
            meeting.saveStage = .transcribing
            meeting.updatedAt = Date()
            try cloudStorage.upsertLocalMeeting(meeting)
            var transcriptionFailure: Error?
            do {
                let audioAccess = try await mediaStreamingSession.accessURL(for: .audio, ttl: 60 * 60)
                try await transcriptionManager.transcribeCloudRecording(audioURL: audioAccess.url)
            } catch {
                transcriptionFailure = error
                warnings.append("Transcription failed: \(error.localizedDescription)")
            }

            let transcript = try CloudTranscriptRetentionPolicy.validatedTranscript(
                transcriptionManager.fullTranscriptText(),
                required: pendingPreferences.storeTranscriptInCloud,
                failure: transcriptionFailure
            )
            meeting.transcript = pendingPreferences.storeTranscriptInCloud ? transcript : nil

            savePhase = .analyzing
            meeting.saveStage = .analyzing
            meeting.updatedAt = Date()
            try cloudStorage.upsertLocalMeeting(meeting)
            let insights: MeetingInsights
            do {
                let generated = try await transcriptionManager.analyze(callTitle: detectedCall?.title ?? pendingManualTitle)
                let verified = detectedCall?.participants ?? meeting.insights.participants
                let participants = (verified + generated.participants).reduce(into: [String]()) { result, participant in
                    if !result.contains(where: { $0.caseInsensitiveCompare(participant) == .orderedSame }) {
                        result.append(participant)
                    }
                }
                insights = MeetingInsights(
                    title: generated.title,
                    summary: generated.summary,
                    aiNotes: generated.aiNotes,
                    participants: participants,
                    actionItems: generated.actionItems,
                    decisions: generated.decisions
                )
                transcriptionManager.insights = insights
            } catch {
                insights = MeetingInsights(
                    title: detectedCall?.displayTitle ?? pendingManualTitle ?? meeting.title,
                    participants: detectedCall?.participants ?? meeting.insights.participants
                )
                if !transcript.isEmpty { warnings.append("Meeting analysis failed: \(error.localizedDescription)") }
            }

            let startedAt = pendingStartedAt ?? meeting.startedAt
            let endedAt = pendingEndedAt ?? Date()
            let payload = MeetingPayload(
                id: meetingID,
                startedAt: startedAt,
                endedAt: endedAt,
                callApp: detectedCall?.appName ?? meeting.callApp,
                callTitle: detectedCall?.title ?? pendingManualTitle ?? meeting.callTitle,
                transcript: transcript,
                insights: insights,
                durationSeconds: pendingDuration
            )
            meeting.startedAt = startedAt
            meeting.endedAt = endedAt
            meeting.durationSeconds = pendingDuration
            meeting.callApp = payload.callApp
            meeting.callTitle = payload.callTitle
            meeting.insights = insights
            meeting.saveStage = .storingMetadata
            meeting.updatedAt = Date()
            try cloudStorage.upsertLocalMeeting(meeting)

            // Commit useful metadata before optional delivery and retention.
            // If the app exits during either step, both raw objects remain safe.
            try await cloudStorage.saveMeeting(
                payload,
                includeTranscript: pendingPreferences.storeTranscriptInCloud,
                hasScreenRecording: true,
                hasAudioRecording: true,
                isFinal: false,
                storageContext: storageContext
            )

            var preserveWebhookRecovery = false
            if pendingPreferences.sendToWebhook {
                savePhase = .deliveringWebhook
                meeting.saveStage = .deliveringWebhook
                meeting.webhookDeliveryStatus = .pending
                meeting.webhookErrorMessage = nil
                meeting.updatedAt = Date()
                try cloudStorage.upsertLocalMeeting(meeting)
                do {
                    guard let webhookURL = URL(string: webhookSettings.url) else {
                        throw OpenRecError.invalidConfiguration("The webhook URL is invalid.")
                    }
                    async let screenAccess = mediaStreamingSession.accessURL(
                        for: .screen,
                        ttl: Self.webhookMediaAccessLifetime
                    )
                    async let audioAccess = mediaStreamingSession.accessURL(
                        for: .audio,
                        ttl: Self.webhookMediaAccessLifetime
                    )
                    let access = try await (screenAccess, audioAccess)
                    try await WebhookDeliveryService(url: webhookURL, secret: webhookSettings.secret).deliverCloud(
                        payload: payload,
                        screenURL: access.0.url,
                        audioURL: access.1.url
                    )
                    meeting.webhookDeliveryStatus = .delivered
                } catch {
                    preserveWebhookRecovery = true
                    meeting.webhookDeliveryStatus = .failed
                    meeting.webhookErrorMessage = error.localizedDescription
                    warnings.append("Webhook delivery failed: \(error.localizedDescription)")
                }
            }

            if meeting.webhookDeliveryStatus == .delivered {
                let cleanupAt = Date().addingTimeInterval(Self.webhookMediaCleanupGrace)
                if !pendingPreferences.keepScreenRecording {
                    meeting.screenDeletionScheduledAt = cleanupAt
                }
                if !pendingPreferences.keepAudioRecording {
                    meeting.audioDeletionScheduledAt = cleanupAt
                }
            }

            savePhase = .cleaningUp
            meeting.saveStage = .cleaningUp
            meeting.updatedAt = Date()
            try cloudStorage.upsertLocalMeeting(meeting)

            var keepScreen = CloudTranscriptRetentionPolicy.shouldKeepMediaAfterSuccessfulProcessing(
                retentionRequested: pendingPreferences.keepScreenRecording,
                preserveWebhookRecovery: preserveWebhookRecovery,
                deletionScheduled: meeting.screenDeletionScheduledAt != nil
            )
            var keepAudio = CloudTranscriptRetentionPolicy.shouldKeepMediaAfterSuccessfulProcessing(
                retentionRequested: pendingPreferences.keepAudioRecording,
                preserveWebhookRecovery: preserveWebhookRecovery,
                deletionScheduled: meeting.audioDeletionScheduledAt != nil
            )
            if !keepScreen {
                do { try await mediaStreamingSession.deleteMedia(.screen) }
                catch {
                    keepScreen = true
                    warnings.append("The temporary screen recording could not be deleted: \(error.localizedDescription)")
                }
            }
            if !keepAudio {
                do { try await mediaStreamingSession.deleteMedia(.audio) }
                catch {
                    keepAudio = true
                    warnings.append("The temporary audio recording could not be deleted: \(error.localizedDescription)")
                }
            }

            try await cloudStorage.saveMeeting(
                payload,
                includeTranscript: pendingPreferences.storeTranscriptInCloud,
                hasScreenRecording: keepScreen,
                hasAudioRecording: keepAudio,
                isFinal: true,
                storageContext: storageContext
            )

            meeting.hasScreenRecording = keepScreen
            meeting.hasAudioRecording = keepAudio
            meeting.localScreenPath = nil
            meeting.localAudioPath = nil
            meeting.saveStatus = .saved
            meeting.saveStage = .complete
            meeting.errorMessage = nil
            meeting.updatedAt = Date()
            try cloudStorage.upsertLocalMeeting(meeting)
            scheduleDeferredMediaCleanup(for: meeting)

            self.mediaStreamingSession = nil
            finishSuccessfulSave(meetingID: meetingID, warnings: warnings)
        } catch {
            let completedKinds = await mediaStreamingSession.completedMediaKinds()
            let hasScreen = completedKinds.contains(.screen)
            let hasAudio = completedKinds.contains(.audio)
            if hasScreen || hasAudio {
                await mediaStreamingSession.abort(deleteCompleted: false)
                meeting.hasScreenRecording = hasScreen
                meeting.hasAudioRecording = hasAudio
                meeting.saveStatus = .failed
                meeting.errorMessage = "The recording reached cloud storage, but meeting processing stopped: \(error.localizedDescription)"
                meeting.updatedAt = Date()
                try? cloudStorage.upsertLocalMeeting(meeting)
                self.mediaStreamingSession = nil
                failSaving(meeting.errorMessage ?? error.localizedDescription, markMeetingFailed: false)
            } else {
                await mediaStreamingSession.abort()
                self.mediaStreamingSession = nil
                let message = error.localizedDescription
                await discardAbandonedPendingMeeting(orMarkFailedWith: message)
                failSaving(message, markMeetingFailed: false)
            }
        }
    }

    /// Resumes transcription, analysis, retention, and webhook delivery from a
    /// recording that already made it to cloud storage before the app exited or
    /// a later processing stage failed. No local media file is required.
    private func processRecoveredCloudMeeting(_ record: MeetingRecord) async {
        guard let storageContext = pendingStorageContext else {
            failSaving("The cloud recording context is unavailable.", markMeetingFailed: false)
            return
        }
        var meeting = record
        var warnings: [String] = []
        do {
            savePhase = .transcribing
            meeting.saveStatus = .processing
            meeting.saveStage = .transcribing
            meeting.errorMessage = nil
            meeting.updatedAt = Date()
            try cloudStorage.upsertLocalMeeting(meeting)

            let hasStoredInsights = !meeting.insights.summary.isEmpty
                || !meeting.insights.actionItems.isEmpty
                || !meeting.insights.decisions.isEmpty
            let shouldAttemptTranscription = CloudTranscriptRetentionPolicy.shouldAttemptTranscription(
                storedTranscript: meeting.transcript,
                hasStoredInsights: hasStoredInsights,
                hasRetryMedia: meeting.hasAudioRecording || meeting.hasScreenRecording,
                storeTranscriptInCloud: meeting.preferences.storeTranscriptInCloud
            )
            var transcriptionFailure: Error?
            if shouldAttemptTranscription {
                do {
                    let sourceKind: MeetingMediaKind = meeting.hasAudioRecording ? .audio : .screen
                    let access = try await cloudStorage.accessURL(
                        meetingID: meeting.id,
                        kind: sourceKind,
                        ttl: 60 * 60,
                        storageContext: storageContext
                    )
                    try await transcriptionManager.transcribeCloudRecording(audioURL: access.url)
                } catch {
                    transcriptionFailure = error
                    warnings.append("Transcription failed: \(error.localizedDescription)")
                }
            }

            let newlyTranscribed = transcriptionManager.fullTranscriptText()
            let availableTranscript = newlyTranscribed.isEmpty ? (meeting.transcript ?? "") : newlyTranscribed
            let transcript = try CloudTranscriptRetentionPolicy.validatedTranscript(
                availableTranscript,
                required: meeting.preferences.storeTranscriptInCloud,
                failure: transcriptionFailure
            )
            meeting.transcript = meeting.preferences.storeTranscriptInCloud ? transcript : nil

            savePhase = .analyzing
            meeting.saveStage = .analyzing
            meeting.updatedAt = Date()
            try cloudStorage.upsertLocalMeeting(meeting)
            if hasStoredInsights {
                transcriptionManager.insights = meeting.insights
            } else if !transcript.isEmpty {
                do {
                    let generated = try await analyzeRecoveredTranscript(
                        transcript,
                        callTitle: meeting.callTitle
                    )
                    let participants = (meeting.insights.participants + generated.participants)
                        .reduce(into: [String]()) { result, participant in
                            if !result.contains(where: { $0.caseInsensitiveCompare(participant) == .orderedSame }) {
                                result.append(participant)
                            }
                        }
                    meeting.insights = MeetingInsights(
                        title: generated.title,
                        summary: generated.summary,
                        aiNotes: generated.aiNotes,
                        participants: participants,
                        actionItems: generated.actionItems,
                        decisions: generated.decisions
                    )
                    transcriptionManager.insights = meeting.insights
                } catch {
                    if !transcript.isEmpty {
                        warnings.append("Meeting analysis failed: \(error.localizedDescription)")
                    }
                }
            }

            meeting.saveStage = .storingMetadata
            meeting.updatedAt = Date()
            try cloudStorage.upsertLocalMeeting(meeting)
            try await cloudStorage.saveMeeting(
                meeting.payload,
                includeTranscript: meeting.preferences.storeTranscriptInCloud,
                hasScreenRecording: meeting.hasScreenRecording,
                hasAudioRecording: meeting.hasAudioRecording,
                isFinal: false,
                storageContext: storageContext
            )

            var preserveWebhookRecovery = false
            if meeting.preferences.sendToWebhook && meeting.webhookDeliveryStatus != .delivered {
                savePhase = .deliveringWebhook
                meeting.saveStage = .deliveringWebhook
                meeting.webhookDeliveryStatus = .pending
                meeting.webhookErrorMessage = nil
                meeting.updatedAt = Date()
                try cloudStorage.upsertLocalMeeting(meeting)
                do {
                    guard let webhookURL = URL(string: webhookSettings.url), webhookSettings.isConfigured else {
                        throw OpenRecError.invalidConfiguration("Configure the HTTPS webhook in Settings, then retry this meeting.")
                    }
                    var media = try await cloudStorage.webhookMediaURLs(for: meeting, storageContext: storageContext)
                    var resolved = [media.screen, media.audio].compactMap { $0 }
                    if resolved.contains(where: \.isFileURL),
                       resolved.contains(where: { !$0.isFileURL }) {
                        let localScreen = media.screen?.isFileURL == true ? media.screen : nil
                        let localAudio = media.audio?.isFileURL == true ? media.audio : nil
                        try await cloudStorage.uploadMedia(
                            meetingID: meeting.id,
                            screenURL: localScreen,
                            audioURL: localAudio,
                            storageContext: storageContext
                        )
                        if localScreen != nil { meeting.hasScreenRecording = true }
                        if localAudio != nil { meeting.hasAudioRecording = true }
                        try await cloudStorage.saveMeeting(
                            meeting.payload,
                            includeTranscript: meeting.preferences.storeTranscriptInCloud,
                            hasScreenRecording: meeting.hasScreenRecording,
                            hasAudioRecording: meeting.hasAudioRecording,
                            isFinal: false,
                            storageContext: storageContext
                        )
                        media = try await cloudStorage.webhookMediaURLs(for: meeting, storageContext: storageContext)
                        resolved = [media.screen, media.audio].compactMap { $0 }
                    }
                    let webhook = WebhookDeliveryService(url: webhookURL, secret: webhookSettings.secret)
                    if resolved.allSatisfy({ !$0.isFileURL }) {
                        try await webhook.deliverCloud(
                            payload: meeting.payload,
                            screenURL: media.screen,
                            audioURL: media.audio
                        )
                    } else {
                        try await webhook.deliver(
                            payload: meeting.payload,
                            screenURL: media.screen,
                            audioURL: media.audio
                        )
                    }
                    meeting.webhookDeliveryStatus = .delivered
                    meeting.webhookErrorMessage = nil
                } catch {
                    preserveWebhookRecovery = true
                    meeting.webhookDeliveryStatus = .failed
                    meeting.webhookErrorMessage = error.localizedDescription
                    warnings.append("Webhook delivery failed: \(error.localizedDescription)")
                }
            }

            if meeting.webhookDeliveryStatus == .delivered {
                let cleanupAt = Date().addingTimeInterval(Self.webhookMediaCleanupGrace)
                if !meeting.preferences.keepScreenRecording, meeting.hasScreenRecording {
                    meeting.screenDeletionScheduledAt = cleanupAt
                }
                if !meeting.preferences.keepAudioRecording, meeting.hasAudioRecording {
                    meeting.audioDeletionScheduledAt = cleanupAt
                }
            }

            savePhase = .cleaningUp
            meeting.saveStage = .cleaningUp
            meeting.updatedAt = Date()
            try cloudStorage.upsertLocalMeeting(meeting)
            let keepScreen = CloudTranscriptRetentionPolicy.shouldKeepMediaAfterSuccessfulProcessing(
                retentionRequested: meeting.preferences.keepScreenRecording,
                preserveWebhookRecovery: preserveWebhookRecovery,
                deletionScheduled: meeting.screenDeletionScheduledAt != nil
            )
            if meeting.hasScreenRecording, !keepScreen {
                do {
                    try await cloudStorage.deleteMedia(
                        meetingID: meeting.id,
                        kind: .screen,
                        storageContext: storageContext
                    )
                    meeting.hasScreenRecording = false
                } catch {
                    warnings.append("The temporary screen recording could not be deleted: \(error.localizedDescription)")
                }
            }
            let keepAudio = CloudTranscriptRetentionPolicy.shouldKeepMediaAfterSuccessfulProcessing(
                retentionRequested: meeting.preferences.keepAudioRecording,
                preserveWebhookRecovery: preserveWebhookRecovery,
                deletionScheduled: meeting.audioDeletionScheduledAt != nil
            )
            if meeting.hasAudioRecording, !keepAudio {
                do {
                    try await cloudStorage.deleteMedia(
                        meetingID: meeting.id,
                        kind: .audio,
                        storageContext: storageContext
                    )
                    meeting.hasAudioRecording = false
                } catch {
                    warnings.append("The temporary audio recording could not be deleted: \(error.localizedDescription)")
                }
            }

            try await cloudStorage.saveMeeting(
                meeting.payload,
                includeTranscript: meeting.preferences.storeTranscriptInCloud,
                hasScreenRecording: meeting.hasScreenRecording,
                hasAudioRecording: meeting.hasAudioRecording,
                isFinal: true,
                storageContext: storageContext
            )
            meeting.saveStatus = .saved
            meeting.saveStage = .complete
            meeting.errorMessage = nil
            meeting.localScreenPath = nil
            meeting.localAudioPath = nil
            meeting.updatedAt = Date()
            try cloudStorage.upsertLocalMeeting(meeting)
            scheduleDeferredMediaCleanup(for: meeting)
            finishSuccessfulSave(meetingID: meeting.id, warnings: warnings)
        } catch {
            meeting.saveStatus = .failed
            meeting.errorMessage = "Cloud recovery stopped: \(error.localizedDescription)"
            meeting.updatedAt = Date()
            try? cloudStorage.upsertLocalMeeting(meeting)
            failSaving(meeting.errorMessage ?? error.localizedDescription, markMeetingFailed: false)
        }
    }

    private func analyzeRecoveredTranscript(
        _ transcript: String,
        callTitle: String?
    ) async throws -> MeetingInsights {
        guard transcriptionManager.hasOpenAIAPIKey else {
            throw OpenRecError.invalidConfiguration("Add your OpenAI API key to generate meeting memory.")
        }
        transcriptionManager.isAnalyzing = true
        defer { transcriptionManager.isAnalyzing = false }
        do {
            let generated = try await OpenAIService(apiKey: transcriptionManager.openAIAPIKey)
                .generateInsights(transcript: transcript, callTitle: callTitle)
            transcriptionManager.insights = generated
            return generated
        } catch {
            transcriptionManager.error = error.localizedDescription
            throw error
        }
    }

    private func processLegacy(artifacts: LegacyRecordingArtifacts) async {
        guard let outputDir = lastOutputDir else {
            failSaving("The recording folder is unavailable.")
            return
        }
        guard let storageContext = pendingStorageContext else {
            failSaving("The storage connection for this legacy recovery is unavailable.")
            return
        }
        let existing = pendingMeetingID.flatMap { cloudStorage.localMeeting(id: $0) }
        let startedAt = existing?.startedAt ?? pendingStartedAt ?? Date().addingTimeInterval(TimeInterval(-pendingDuration))
        let endedAt = existing?.endedAt ?? pendingEndedAt ?? startedAt.addingTimeInterval(TimeInterval(pendingDuration))
        let meetingID = pendingMeetingID ?? UUID()
        pendingMeetingID = meetingID
        let now = Date()
        var meeting = existing ?? MeetingRecord(
            id: meetingID,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: pendingDuration,
            callApp: detectedCall?.appName,
            callTitle: detectedCall?.title ?? pendingManualTitle,
            transcript: nil,
            insights: MeetingInsights(
                title: detectedCall?.displayTitle ?? pendingManualTitle ?? "Untitled call",
                participants: detectedCall?.participants ?? []
            ),
            hasScreenRecording: false,
            hasAudioRecording: false,
            screenFileExtension: artifacts.screenURL.pathExtension,
            audioFileExtension: artifacts.audioURL?.pathExtension,
            localScreenPath: artifacts.screenURL.path,
            localAudioPath: artifacts.audioURL?.path,
            storageMode: pendingStorageMode,
            preferences: pendingPreferences,
            saveStatus: .processing,
            saveStage: .transcribing,
            errorMessage: nil,
            createdAt: now,
            updatedAt: now
        )
        do {
            meeting.saveStatus = .processing
            meeting.saveStage = .storingMetadata
            meeting.errorMessage = nil
            meeting.updatedAt = Date()
            try cloudStorage.upsertLocalMeeting(meeting)

            // Protect the raw call first. The metadata row owns the media paths,
            // so create/update it before beginning the resumable upload.
            savePhase = .uploading
            try await cloudStorage.saveMeeting(
                meeting.payload,
                includeTranscript: false,
                isFinal: false,
                storageContext: storageContext
            )
            meeting.saveStage = .uploadingMedia
            meeting.updatedAt = Date()
            try cloudStorage.upsertLocalMeeting(meeting)
            try await cloudStorage.uploadMedia(
                meetingID: meetingID,
                screenURL: pendingPreferences.keepScreenRecording ? artifacts.screenURL : nil,
                audioURL: pendingPreferences.keepAudioRecording ? artifacts.audioURL : nil,
                storageContext: storageContext
            )
            meeting.hasScreenRecording = pendingPreferences.keepScreenRecording
            meeting.hasAudioRecording = pendingPreferences.keepAudioRecording && artifacts.audioURL != nil
            meeting.updatedAt = Date()
            try cloudStorage.upsertLocalMeeting(meeting)
            if storageContext.mode == .ownR2 {
                try await cloudStorage.saveMeeting(
                    meeting.payload,
                    includeTranscript: false,
                    hasScreenRecording: meeting.hasScreenRecording,
                    hasAudioRecording: meeting.hasAudioRecording,
                    isFinal: false,
                    storageContext: storageContext
                )
            }

            savePhase = .transcribing
            meeting.saveStage = .transcribing
            meeting.updatedAt = Date()
            try cloudStorage.upsertLocalMeeting(meeting)
            let transcriptionFile = artifacts.audioURL ?? artifacts.screenURL
            do {
                try await transcriptionManager.transcribeRecording(audioURL: transcriptionFile)
            } catch {
                if pendingPreferences.storeTranscriptInCloud {
                    _ = try CloudTranscriptRetentionPolicy.validatedTranscript(
                        "",
                        required: true,
                        failure: error
                    )
                }
                throw error
            }
            let transcript = try CloudTranscriptRetentionPolicy.validatedTranscript(
                transcriptionManager.fullTranscriptText(),
                required: pendingPreferences.storeTranscriptInCloud
            )
            let baseName = artifacts.screenURL.deletingPathExtension().lastPathComponent
            if pendingPreferences.storeTranscriptInCloud {
                try transcriptionManager.saveTranscript(to: outputDir, baseName: baseName)
                meeting.transcript = transcript
            } else {
                meeting.transcript = nil
            }

            savePhase = .analyzing
            meeting.saveStage = .analyzing
            meeting.updatedAt = Date()
            try cloudStorage.upsertLocalMeeting(meeting)
            let insights: MeetingInsights
            do {
                let generated = try await transcriptionManager.analyze(callTitle: detectedCall?.title ?? pendingManualTitle)
                let verified = detectedCall?.participants ?? []
                let participants = (verified + generated.participants).reduce(into: [String]()) { result, participant in
                    if !result.contains(where: { $0.caseInsensitiveCompare(participant) == .orderedSame }) {
                        result.append(participant)
                    }
                }
                insights = MeetingInsights(
                    title: generated.title,
                    summary: generated.summary,
                    aiNotes: generated.aiNotes,
                    participants: participants,
                    actionItems: generated.actionItems,
                    decisions: generated.decisions
                )
                transcriptionManager.insights = insights
            } catch {
                insights = MeetingInsights(
                    title: detectedCall?.displayTitle ?? "Untitled call",
                    participants: detectedCall?.participants ?? []
                )
            }

            let payload = MeetingPayload(
                id: meetingID,
                startedAt: startedAt,
                endedAt: endedAt,
                callApp: detectedCall?.appName,
                callTitle: detectedCall?.title ?? pendingManualTitle,
                transcript: transcript,
                insights: insights,
                durationSeconds: pendingDuration
            )

            meeting.callApp = payload.callApp
            meeting.callTitle = payload.callTitle
            meeting.insights = insights
            meeting.saveStage = .storingMetadata
            meeting.updatedAt = Date()
            try cloudStorage.upsertLocalMeeting(meeting)

            try await cloudStorage.saveMeeting(
                payload,
                includeTranscript: pendingPreferences.storeTranscriptInCloud,
                hasScreenRecording: meeting.hasScreenRecording,
                hasAudioRecording: meeting.hasAudioRecording,
                isFinal: true,
                storageContext: storageContext
            )

            var webhookWarning: String?
            if pendingPreferences.sendToWebhook {
                savePhase = .deliveringWebhook
                meeting.saveStage = .deliveringWebhook
                meeting.webhookDeliveryStatus = .pending
                meeting.webhookErrorMessage = nil
                meeting.updatedAt = Date()
                try cloudStorage.upsertLocalMeeting(meeting)
                do {
                    guard let webhookURL = URL(string: webhookSettings.url) else {
                        throw OpenRecError.invalidConfiguration("The webhook URL is invalid.")
                    }
                    try await WebhookDeliveryService(url: webhookURL, secret: webhookSettings.secret).deliver(
                        payload: payload,
                        screenURL: artifacts.screenURL,
                        audioURL: artifacts.audioURL
                    )
                    meeting.webhookDeliveryStatus = .delivered
                } catch {
                    webhookWarning = "The meeting is safe, but webhook delivery failed: \(error.localizedDescription)"
                    meeting.webhookDeliveryStatus = .failed
                    meeting.webhookErrorMessage = error.localizedDescription
                }
                meeting.updatedAt = Date()
                try cloudStorage.upsertLocalMeeting(meeting)
            }

            savePhase = .cleaningUp
            meeting.saveStage = .cleaningUp
            meeting.updatedAt = Date()
            try cloudStorage.upsertLocalMeeting(meeting)
            let preserveWebhookRecovery = meeting.webhookDeliveryStatus == .failed
            if !pendingPreferences.keepScreenRecording && !preserveWebhookRecovery { try? FileManager.default.removeItem(at: artifacts.screenURL) }
            if !pendingPreferences.keepAudioRecording && !preserveWebhookRecovery, let audio = artifacts.audioURL { try? FileManager.default.removeItem(at: audio) }
            if !pendingPreferences.storeTranscriptInCloud {
                let transcriptURL = outputDir.appendingPathComponent("\(baseName)_transcript.txt")
                try? FileManager.default.removeItem(at: transcriptURL)
            }

            meeting.localScreenPath = pendingPreferences.keepScreenRecording || preserveWebhookRecovery ? artifacts.screenURL.path : nil
            meeting.localAudioPath = pendingPreferences.keepAudioRecording || preserveWebhookRecovery ? artifacts.audioURL?.path : nil
            meeting.saveStatus = .saved
            meeting.saveStage = .complete
            meeting.errorMessage = nil
            meeting.updatedAt = Date()
            try cloudStorage.upsertLocalMeeting(meeting)

            isProcessing = false
            if let webhookWarning {
                savePhase = .completeWithWarning(webhookWarning)
                lastErrorMessage = webhookWarning
            } else {
                savePhase = .complete
                lastErrorMessage = nil
            }
            lastSavedMeetingID = meetingID
            pendingMeetingID = nil
            pendingStartedAt = nil
            pendingEndedAt = nil
            pendingManualTitle = nil
            pendingStorageContext = nil
            detectedCall = nil
            onProcessingComplete?()
        } catch {
            failSaving(error.localizedDescription)
        }
    }

    private func pendingMeetingRecord(id: UUID) -> MeetingRecord {
        let startedAt = pendingStartedAt ?? Date()
        let endedAt = pendingEndedAt ?? startedAt
        return MeetingRecord(
            id: id,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: pendingDuration,
            callApp: detectedCall?.appName,
            callTitle: detectedCall?.title ?? pendingManualTitle,
            transcript: nil,
            insights: MeetingInsights(
                title: detectedCall?.displayTitle ?? pendingManualTitle ?? "Untitled call",
                participants: detectedCall?.participants ?? []
            ),
            hasScreenRecording: false,
            hasAudioRecording: false,
            screenFileExtension: "mp4",
            audioFileExtension: "m4a",
            localScreenPath: nil,
            localAudioPath: nil,
            storageMode: pendingStorageMode,
            preferences: pendingPreferences,
            saveStatus: .processing,
            saveStage: .finalizing,
            errorMessage: nil,
            createdAt: endedAt,
            updatedAt: endedAt
        )
    }

    private func finishSuccessfulSave(meetingID: UUID, warnings: [String]) {
        isProcessing = false
        recorder = nil
        mediaAppendError = nil
        let distinctWarnings = warnings.reduce(into: [String]()) { result, value in
            if !result.contains(value) { result.append(value) }
        }
        if distinctWarnings.isEmpty {
            savePhase = .complete
            lastErrorMessage = nil
        } else {
            let message = distinctWarnings.joined(separator: "\n")
            savePhase = .completeWithWarning(message)
            lastErrorMessage = message
        }
        lastSavedMeetingID = meetingID
        pendingMeetingID = nil
        pendingStartedAt = nil
        pendingEndedAt = nil
        pendingManualTitle = nil
        pendingStorageContext = nil
        detectedCall = nil
        onProcessingComplete?()
    }

    private func resumeDeferredMediaCleanup() {
        let scheduledMeetings = cloudStorage.libraryMeetings.filter {
            $0.screenDeletionScheduledAt != nil || $0.audioDeletionScheduledAt != nil
        }
        let scheduledIDs = Set(scheduledMeetings.map(\.id))
        let obsoleteIDs = deferredMediaCleanupTasks.keys.filter { !scheduledIDs.contains($0) }
        for id in obsoleteIDs {
            deferredMediaCleanupTasks[id]?.cancel()
            deferredMediaCleanupTasks[id] = nil
        }
        for meeting in scheduledMeetings where deferredMediaCleanupTasks[meeting.id] == nil {
            scheduleDeferredMediaCleanup(for: meeting)
        }
    }

    private func scheduleDeferredMediaCleanup(for meeting: MeetingRecord) {
        let dates = [meeting.screenDeletionScheduledAt, meeting.audioDeletionScheduledAt].compactMap { $0 }
        guard let deadline = dates.min() else {
            deferredMediaCleanupTasks[meeting.id]?.cancel()
            deferredMediaCleanupTasks[meeting.id] = nil
            return
        }

        deferredMediaCleanupTasks[meeting.id]?.cancel()
        deferredMediaCleanupTasks[meeting.id] = Task { [weak self] in
            let delay = max(0, deadline.timeIntervalSinceNow)
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            await self?.performDeferredMediaCleanup(meetingID: meeting.id)
        }
    }

    private func performDeferredMediaCleanup(meetingID: UUID) async {
        guard var meeting = cloudStorage.localMeeting(id: meetingID) else {
            deferredMediaCleanupTasks[meetingID] = nil
            return
        }
        let now = Date()
        let retryAt = now.addingTimeInterval(15 * 60)
        let storageContext: CloudStorageContext
        do {
            storageContext = try cloudStorage.captureStorageContext(for: meeting.storageMode)
        } catch {
            if meeting.screenDeletionScheduledAt.map({ $0 <= now }) == true {
                meeting.screenDeletionScheduledAt = retryAt
            }
            if meeting.audioDeletionScheduledAt.map({ $0 <= now }) == true {
                meeting.audioDeletionScheduledAt = retryAt
            }
            try? cloudStorage.upsertLocalMeeting(meeting)
            cloudStorage.libraryError = "Temporary webhook media cleanup is waiting for its storage account. \(error.localizedDescription)"
            scheduleDeferredMediaCleanup(for: meeting)
            return
        }

        var failures: [String] = []
        if meeting.screenDeletionScheduledAt.map({ $0 <= now }) == true {
            do {
                try await cloudStorage.deleteMedia(
                    meetingID: meeting.id,
                    kind: .screen,
                    storageContext: storageContext
                )
                meeting.hasScreenRecording = false
                meeting.screenDeletionScheduledAt = nil
            } catch {
                meeting.screenDeletionScheduledAt = retryAt
                failures.append("screen: \(error.localizedDescription)")
            }
        }
        if meeting.audioDeletionScheduledAt.map({ $0 <= now }) == true {
            do {
                try await cloudStorage.deleteMedia(
                    meetingID: meeting.id,
                    kind: .audio,
                    storageContext: storageContext
                )
                meeting.hasAudioRecording = false
                meeting.audioDeletionScheduledAt = nil
            } catch {
                meeting.audioDeletionScheduledAt = retryAt
                failures.append("audio: \(error.localizedDescription)")
            }
        }

        do {
            try await cloudStorage.saveMeeting(
                meeting.payload,
                includeTranscript: meeting.preferences.storeTranscriptInCloud,
                hasScreenRecording: meeting.hasScreenRecording,
                hasAudioRecording: meeting.hasAudioRecording,
                isFinal: true,
                storageContext: storageContext
            )
        } catch {
            if meeting.screenDeletionScheduledAt == nil, !meeting.preferences.keepScreenRecording {
                meeting.screenDeletionScheduledAt = retryAt
            }
            if meeting.audioDeletionScheduledAt == nil, !meeting.preferences.keepAudioRecording {
                meeting.audioDeletionScheduledAt = retryAt
            }
            failures.append("meeting index: \(error.localizedDescription)")
        }
        meeting.updatedAt = Date()
        try? cloudStorage.upsertLocalMeeting(meeting)

        if failures.isEmpty {
            cloudStorage.libraryError = nil
        } else {
            cloudStorage.libraryError = "Temporary webhook media cleanup will retry. \(failures.joined(separator: "; "))"
        }
        scheduleDeferredMediaCleanup(for: meeting)
    }

    private func markPendingMeetingFailed(_ message: String) {
        guard let id = pendingMeetingID else { return }
        var meeting = cloudStorage.localMeeting(id: id) ?? pendingMeetingRecord(id: id)
        meeting.saveStatus = .failed
        meeting.errorMessage = message
        meeting.updatedAt = Date()
        try? cloudStorage.upsertLocalMeeting(meeting)
    }

    private func discardAbandonedPendingMeeting(orMarkFailedWith message: String) async {
        guard let id = pendingMeetingID else { return }
        let storageMode = pendingStorageMode
        let storageContext = pendingStorageContext
        do {
            try await cloudStorage.discardAbandonedMeeting(
                meetingID: id,
                storageMode: storageMode,
                storageContext: storageContext
            )
            guard pendingMeetingID == id else { return }
            pendingMeetingID = nil
            pendingStartedAt = nil
            pendingEndedAt = nil
            pendingManualTitle = nil
            pendingStorageContext = nil
        } catch {
            guard pendingMeetingID == id else { return }
            markPendingMeetingFailed("\(message) Cleanup also failed: \(error.localizedDescription)")
        }
    }

    func retryWebhook(for record: MeetingRecord) {
        guard record.webhookDeliveryStatus == .failed, !isRecording, !isProcessing, !isStarting else { return }
        guard webhookSettings.isConfigured, let webhookURL = URL(string: webhookSettings.url) else {
            lastErrorMessage = "Configure a valid HTTPS webhook in Settings before retrying delivery."
            return
        }

        let storageContext: CloudStorageContext
        do {
            storageContext = try cloudStorage.captureStorageContext(for: record.storageMode)
        } catch {
            lastErrorMessage = error.localizedDescription
            return
        }

        isProcessing = true
        savePhase = .deliveringWebhook
        lastErrorMessage = nil
        cloudStorage.libraryError = nil
        Task { @MainActor in
            var meeting = record
            meeting.webhookDeliveryStatus = .pending
            meeting.webhookErrorMessage = nil
            meeting.updatedAt = Date()
            try? cloudStorage.upsertLocalMeeting(meeting)
            var webhookDelivered = false
            do {
                var media: WebhookMediaURLs
                do {
                    media = try await cloudStorage.webhookMediaURLs(
                        for: meeting,
                        storageContext: storageContext
                    )
                } catch {
                    let message = "Webhook retry could not prepare the retained recording: \(error.localizedDescription)"
                    cloudStorage.libraryError = message
                    throw OpenRecError.invalidResponse(message)
                }
                let service = WebhookDeliveryService(url: webhookURL, secret: webhookSettings.secret)
                var resolved = [media.screen, media.audio].compactMap { $0 }
                let mixesLocalAndCloud = resolved.contains(where: \.isFileURL)
                    && resolved.contains(where: { !$0.isFileURL })
                if mixesLocalAndCloud {
                    // A partially uploaded legacy meeting must not make the Mac
                    // download the cloud half just to rebuild a multipart body.
                    // Promote the remaining local artifact, then send two
                    // short-lived cloud URLs like every new recording.
                    let localScreen = media.screen?.isFileURL == true ? media.screen : nil
                    let localAudio = media.audio?.isFileURL == true ? media.audio : nil
                    try await cloudStorage.uploadMedia(
                        meetingID: meeting.id,
                        screenURL: localScreen,
                        audioURL: localAudio,
                        storageContext: storageContext
                    )
                    if localScreen != nil { meeting.hasScreenRecording = true }
                    if localAudio != nil { meeting.hasAudioRecording = true }
                    try await cloudStorage.saveMeeting(
                        meeting.payload,
                        includeTranscript: meeting.preferences.storeTranscriptInCloud,
                        hasScreenRecording: meeting.hasScreenRecording,
                        hasAudioRecording: meeting.hasAudioRecording,
                        isFinal: false,
                        storageContext: storageContext
                    )
                    media = try await cloudStorage.webhookMediaURLs(
                        for: meeting,
                        storageContext: storageContext
                    )
                    resolved = [media.screen, media.audio].compactMap { $0 }
                }
                let deliveredByReference = resolved.allSatisfy({ !$0.isFileURL })
                if deliveredByReference {
                    try await service.deliverCloud(
                        payload: meeting.payload,
                        screenURL: media.screen,
                        audioURL: media.audio
                    )
                } else {
                    try await service.deliver(
                        payload: meeting.payload,
                        screenURL: media.screen,
                        audioURL: media.audio
                    )
                }
                webhookDelivered = true
                meeting.webhookDeliveryStatus = .delivered
                meeting.webhookErrorMessage = nil
                let cleanupAt = Date().addingTimeInterval(Self.webhookMediaCleanupGrace)
                if deliveredByReference,
                   !meeting.preferences.keepScreenRecording,
                   meeting.hasScreenRecording {
                    meeting.screenDeletionScheduledAt = cleanupAt
                }
                if deliveredByReference,
                   !meeting.preferences.keepAudioRecording,
                   meeting.hasAudioRecording {
                    meeting.audioDeletionScheduledAt = cleanupAt
                }
                meeting.updatedAt = Date()
                try cloudStorage.upsertLocalMeeting(meeting)
                scheduleDeferredMediaCleanup(for: meeting)

                if !meeting.preferences.keepScreenRecording, let path = meeting.localScreenPath {
                    try? FileManager.default.removeItem(atPath: path)
                    meeting.localScreenPath = nil
                }
                if !meeting.preferences.keepScreenRecording, meeting.hasScreenRecording {
                    if !deliveredByReference {
                        try await cloudStorage.deleteMedia(
                            meetingID: meeting.id,
                            kind: .screen,
                            storageContext: storageContext
                        )
                        meeting.hasScreenRecording = false
                    }
                }
                if !meeting.preferences.keepAudioRecording, let path = meeting.localAudioPath {
                    try? FileManager.default.removeItem(atPath: path)
                    meeting.localAudioPath = nil
                }
                if !meeting.preferences.keepAudioRecording, meeting.hasAudioRecording {
                    if !deliveredByReference {
                        try await cloudStorage.deleteMedia(
                            meetingID: meeting.id,
                            kind: .audio,
                            storageContext: storageContext
                        )
                        meeting.hasAudioRecording = false
                    }
                }
                meeting.updatedAt = Date()
                try await cloudStorage.saveMeeting(
                    meeting.payload,
                    includeTranscript: meeting.preferences.storeTranscriptInCloud,
                    hasScreenRecording: meeting.hasScreenRecording,
                    hasAudioRecording: meeting.hasAudioRecording,
                    isFinal: true,
                    storageContext: storageContext
                )
                try cloudStorage.upsertLocalMeeting(meeting)
                scheduleDeferredMediaCleanup(for: meeting)
                savePhase = .complete
                lastErrorMessage = nil
            } catch {
                if webhookDelivered {
                    meeting.webhookDeliveryStatus = .delivered
                    meeting.webhookErrorMessage = nil
                    let cleanupAt = Date().addingTimeInterval(Self.webhookMediaCleanupGrace)
                    if !meeting.preferences.keepScreenRecording,
                       meeting.hasScreenRecording,
                       meeting.screenDeletionScheduledAt == nil {
                        meeting.screenDeletionScheduledAt = cleanupAt
                    }
                    if !meeting.preferences.keepAudioRecording,
                       meeting.hasAudioRecording,
                       meeting.audioDeletionScheduledAt == nil {
                        meeting.audioDeletionScheduledAt = cleanupAt
                    }
                } else {
                    meeting.webhookDeliveryStatus = .failed
                    meeting.webhookErrorMessage = error.localizedDescription
                }
                meeting.updatedAt = Date()
                try? cloudStorage.upsertLocalMeeting(meeting)
                if webhookDelivered { scheduleDeferredMediaCleanup(for: meeting) }
                let warning = webhookDelivered
                    ? "The webhook received the meeting, but OpenRec could not finish cleanup: \(error.localizedDescription)"
                    : "The meeting is safe, but webhook delivery failed: \(error.localizedDescription)"
                savePhase = .completeWithWarning(warning)
                lastErrorMessage = warning
            }
            isProcessing = false
            onProcessingComplete?()
        }
    }

    private func failSaving(_ message: String, markMeetingFailed: Bool = true) {
        isProcessing = false
        lastErrorMessage = message
        savePhase = .failed(message)
        overlayWindow.hide()
        if markMeetingFailed { markPendingMeetingFailed(message) }
        onProcessingComplete?()
    }

    var currentCallPreferences: CallPreferences { activeCallPreferences ?? callPreferences }
    var cloudUploadStatusText: String {
        guard let progress = cloudUploadProgress else { return "Preparing cloud upload" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        if let error = progress.errorMessage { return error }
        if progress.pendingBytes > 0 {
            let buffered = formatter.string(fromByteCount: Int64(progress.pendingBytes))
            if progress.pendingFraction >= 0.9 {
                return "Cloud connection is falling behind · \(buffered) buffered · recording will stop before memory becomes unbounded"
            }
            if progress.pendingFraction >= 0.7 {
                return "Cloud connection is slow · \(buffered) buffered safely"
            }
            return "Streaming · \(buffered) buffered"
        }
        return progress.uploadedBytes > 0 ? "Streaming securely · caught up" : "Streaming securely"
    }

    var cloudUploadHasFailed: Bool { cloudUploadProgress?.errorMessage != nil }
    var cloudUploadNeedsAttention: Bool {
        guard !cloudUploadHasFailed else { return true }
        return (cloudUploadProgress?.pendingFraction ?? 0) >= 0.7
    }

    var canRetryLastSave: Bool {
        guard let artifacts = lastArtifacts else { return false }
        return FileManager.default.fileExists(atPath: artifacts.screenURL.path)
            && !isRecording
            && !isProcessing
            && !isStarting
    }

    func setActiveCallPreference(_ path: WritableKeyPath<CallPreferences, Bool>, to value: Bool) {
        guard var preferences = activeCallPreferences else { return }
        preferences[keyPath: path] = value
        activeCallPreferences = preferences
    }

    func refreshMicrophones() {
        let types: [AVCaptureDevice.DeviceType] = {
            if #available(macOS 14, *) { return [.microphone] }
            return [.builtInMicrophone, .externalUnknown]
        }()
        microphoneDevices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .audio, position: .unspecified).devices
        let saved = UserDefaults.standard.string(forKey: selectedMicrophoneKey)
        selectedMicrophoneID = saved.flatMap { id in microphoneDevices.contains(where: { $0.uniqueID == id }) ? id : nil }
            ?? microphoneDevices.first?.uniqueID
    }

    func setShowRecordingBorder(_ value: Bool) {
        showRecordingBorder = value
        UserDefaults.standard.set(value, forKey: showBorderKey)
        if value && isRecording { overlayWindow.show(displayID: recorder?.recordingDisplayID) }
        else { overlayWindow.hide() }
    }

    func setSelectedMicrophoneID(_ id: String?) {
        selectedMicrophoneID = id
        UserDefaults.standard.set(id, forKey: selectedMicrophoneKey)
    }

    func selectedMicrophoneDevice() -> AVCaptureDevice? {
        guard let id = selectedMicrophoneID else { return nil }
        return microphoneDevices.first(where: { $0.uniqueID == id })
    }

    private func resolveClientName() -> String? {
        let trimmed = clientNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? (lastClientNameDisplay ?? "") : trimmed
        let sanitized = candidate.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if sanitized != clientNameInput && !trimmed.isEmpty { clientNameInput = sanitized }
        return sanitized.isEmpty ? nil : sanitized
    }

    private func startErrorMessage(from error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain.contains("ScreenCaptureKit") && nsError.code == -3801 {
            return "Screen Recording permission is required. Open System Settings → Privacy & Security → Screen Recording."
        }
        return "Could not start recording: \(error.localizedDescription)"
    }

    private func savePreferences() {
        if let data = try? JSONEncoder().encode(callPreferences) { UserDefaults.standard.set(data, forKey: "CallPreferences") }
    }

    private static func loadPreferences() -> CallPreferences {
        guard let data = UserDefaults.standard.data(forKey: "CallPreferences"),
              let value = try? JSONDecoder().decode(CallPreferences.self, from: data) else { return CallPreferences() }
        return value
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter
    }()
}
