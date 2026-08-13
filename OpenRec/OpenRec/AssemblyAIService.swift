import Foundation

enum AssemblyAIConfiguration {
    static let batchModel = "universal-3-5-pro"
    static let realtimeModel = "universal-3-5-pro"
    static let defaultPollInterval: TimeInterval = 3
    static let defaultPollTimeout: TimeInterval = 30 * 60
    static let realtimeSampleRate = 16_000
}

struct AssemblyAITranscriptRequestBody: Codable, Equatable {
    let audioURL: String
    let speechModels: [String]
    let speakerLabels: Bool
    let languageDetection: Bool

    init(
        audioURL: String,
        speechModels: [String] = [AssemblyAIConfiguration.batchModel],
        speakerLabels: Bool = true,
        languageDetection: Bool = true
    ) {
        self.audioURL = audioURL
        self.speechModels = speechModels
        self.speakerLabels = speakerLabels
        self.languageDetection = languageDetection
    }

    private enum CodingKeys: String, CodingKey {
        case audioURL = "audio_url"
        case speechModels = "speech_models"
        case speakerLabels = "speaker_labels"
        case languageDetection = "language_detection"
    }
}

struct AssemblyAIUploadResponse: Decodable, Equatable {
    let uploadURL: String

    private enum CodingKeys: String, CodingKey {
        case uploadURL = "upload_url"
    }
}

enum AssemblyAITranscriptStatus: String, Decodable, Equatable {
    case queued
    case processing
    case completed
    case error
}

struct AssemblyAIUtterance: Decodable, Equatable {
    let speaker: String
    let text: String
    let start: Double
    let end: Double
}

struct AssemblyAITranscriptResponse: Decodable, Equatable {
    let id: String
    let status: AssemblyAITranscriptStatus
    let text: String?
    let error: String?
    let utterances: [AssemblyAIUtterance]?
    let speechModelUsed: String?

    private enum CodingKeys: String, CodingKey {
        case id, status, text, error, utterances
        case speechModelUsed = "speech_model_used"
    }
}

struct AssemblyAIRequestBuilder {
    let baseURL: URL

    init(baseURL: URL = URL(string: "https://api.assemblyai.com")!) {
        self.baseURL = baseURL
    }

    func validationRequest(apiKey: String) throws -> URLRequest {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("v2/transcript"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "limit", value: "1")]
        guard let url = components?.url else {
            throw OpenRecError.invalidConfiguration("Invalid AssemblyAI endpoint.")
        }
        var request = authorizedRequest(url: url, apiKey: apiKey)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        return request
    }

    func uploadRequest(apiKey: String) -> URLRequest {
        var request = authorizedRequest(
            url: baseURL.appendingPathComponent("v2/upload"),
            apiKey: apiKey
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 60 * 60
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        return request
    }

    func submitRequest(apiKey: String, audioURL: String) throws -> URLRequest {
        var request = authorizedRequest(
            url: baseURL.appendingPathComponent("v2/transcript"),
            apiKey: apiKey
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(AssemblyAITranscriptRequestBody(audioURL: audioURL))
        return request
    }

    func pollRequest(apiKey: String, transcriptID: String) -> URLRequest {
        var request = authorizedRequest(
            url: baseURL
                .appendingPathComponent("v2/transcript")
                .appendingPathComponent(transcriptID),
            apiKey: apiKey
        )
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        return request
    }

    func deleteRequest(apiKey: String, transcriptID: String) -> URLRequest {
        var request = pollRequest(apiKey: apiKey, transcriptID: transcriptID)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 10
        return request
    }

    private func authorizedRequest(url: URL, apiKey: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "authorization")
        return request
    }
}

enum AssemblyAITranscriptMapper {
    static func displaySegments(from response: AssemblyAITranscriptResponse) throws -> [DisplaySegment] {
        guard response.status == .completed else {
            throw OpenRecError.invalidResponse("AssemblyAI returned a transcript before it was complete.")
        }
        guard response.speechModelUsed == AssemblyAIConfiguration.batchModel else {
            let actual = response.speechModelUsed ?? "unknown"
            throw OpenRecError.invalidResponse(
                "AssemblyAI used \(actual) instead of \(AssemblyAIConfiguration.batchModel)."
            )
        }

        let segments = (response.utterances ?? []).compactMap { utterance -> DisplaySegment? in
            let text = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let speaker = utterance.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
            let speakerLabel = speaker.isEmpty || speaker.uppercased() == "UNKNOWN"
                ? "Speaker"
                : "Speaker \(speaker)"
            return DisplaySegment(
                speakerLabel: speakerLabel,
                text: text,
                timestamp: max(0, utterance.start / 1_000)
            )
        }
        if !segments.isEmpty { return segments }

        if let text = response.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return [DisplaySegment(speakerLabel: "Conversation", text: text, timestamp: 0)]
        }
        throw OpenRecError.invalidResponse("AssemblyAI returned an empty transcript.")
    }
}

struct AssemblyAIService {
    typealias Sleeper = (UInt64) async throws -> Void
    typealias Clock = () -> Date

    let apiKey: String
    let session: URLSession
    let requestBuilder: AssemblyAIRequestBuilder
    let pollInterval: TimeInterval
    let pollTimeout: TimeInterval
    let performsRemoteCleanup: Bool
    let sleeper: Sleeper
    let now: Clock

    init(
        apiKey: String,
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.assemblyai.com")!,
        pollInterval: TimeInterval = AssemblyAIConfiguration.defaultPollInterval,
        pollTimeout: TimeInterval = AssemblyAIConfiguration.defaultPollTimeout,
        performsRemoteCleanup: Bool = true,
        sleeper: @escaping Sleeper = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        },
        now: @escaping Clock = { Date() }
    ) {
        self.apiKey = apiKey
        self.session = session
        self.requestBuilder = AssemblyAIRequestBuilder(baseURL: baseURL)
        self.pollInterval = pollInterval
        self.pollTimeout = pollTimeout
        self.performsRemoteCleanup = performsRemoteCleanup
        self.sleeper = sleeper
        self.now = now
    }

    static func isAuthenticationFailure(_ error: Error) -> Bool {
        guard case .requestFailed(let status, _) = error as? OpenRecError else { return false }
        return status == 401 || status == 403
    }

    func validateAccess() async throws {
        try validateAPIKey()
        let request = try requestBuilder.validationRequest(apiKey: apiKey)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
    }

    func transcribe(fileURL: URL) async throws -> [DisplaySegment] {
        try validateAPIKey()
        try Task.checkCancellation()
        guard fileURL.isFileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
            throw OpenRecError.invalidConfiguration("The recording for transcription is missing.")
        }
        let fileSize = ((try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0 else {
            throw OpenRecError.recordingFailed("The recording for transcription is empty.")
        }

        let uploadRequest = requestBuilder.uploadRequest(apiKey: apiKey)
        let (uploadData, uploadResponse) = try await session.upload(for: uploadRequest, fromFile: fileURL)
        try validate(response: uploadResponse, data: uploadData)
        let uploaded: AssemblyAIUploadResponse
        do {
            uploaded = try JSONDecoder().decode(AssemblyAIUploadResponse.self, from: uploadData)
        } catch {
            throw OpenRecError.invalidResponse("AssemblyAI returned an unreadable upload response.")
        }
        guard URL(string: uploaded.uploadURL) != nil else {
            throw OpenRecError.invalidResponse("AssemblyAI returned an invalid upload URL.")
        }

        return try await transcribeUploadedAudioURL(uploaded.uploadURL)
    }

    /// Submit media that is already in private cloud storage through a
    /// short-lived download URL. This avoids downloading the call to the Mac
    /// only to upload the same bytes to AssemblyAI again.
    func transcribe(audioURL: URL) async throws -> [DisplaySegment] {
        try validateAPIKey()
        try Task.checkCancellation()
        guard audioURL.scheme == "https", audioURL.host != nil else {
            throw OpenRecError.invalidConfiguration("AssemblyAI needs a valid HTTPS recording URL.")
        }
        return try await transcribeUploadedAudioURL(audioURL.absoluteString)
    }

    private func transcribeUploadedAudioURL(_ audioURL: String) async throws -> [DisplaySegment] {

        try Task.checkCancellation()
        let submitRequest = try requestBuilder.submitRequest(apiKey: apiKey, audioURL: audioURL)
        let (submitData, submitResponse) = try await session.data(for: submitRequest)
        try validate(response: submitResponse, data: submitData)
        let submitted = try decodeTranscript(submitData, context: "submission")

        do {
            let completed = try await poll(transcriptID: submitted.id)
            let mapped = try AssemblyAITranscriptMapper.displaySegments(from: completed)
            // Cleanup is deliberately best-effort: a provider-side deletion problem
            // must not discard a finished transcript or make OpenRec duplicate the call.
            if performsRemoteCleanup {
                await deleteTranscriptBestEffort(transcriptID: completed.id)
            }
            return mapped
        } catch {
            // Failed and timed-out jobs still own the uploaded recording, so ask
            // AssemblyAI to remove both artifacts before surfacing the error.
            if performsRemoteCleanup {
                await deleteTranscriptBestEffort(transcriptID: submitted.id)
            }
            throw error
        }
    }

    private func poll(transcriptID: String) async throws -> AssemblyAITranscriptResponse {
        let deadline = now().addingTimeInterval(max(1, pollTimeout))
        while true {
            try Task.checkCancellation()
            guard now() < deadline else {
                throw OpenRecError.timedOut("AssemblyAI transcription timed out. Your recording is safe and can be retried.")
            }

            let request = requestBuilder.pollRequest(apiKey: apiKey, transcriptID: transcriptID)
            let (data, response) = try await session.data(for: request)
            if isTransientPollResponse(response) {
                try await sleepBeforeNextPoll(deadline: deadline)
                continue
            }
            try validate(response: response, data: data)
            let transcript = try decodeTranscript(data, context: "status")
            switch transcript.status {
            case .completed:
                return transcript
            case .error:
                throw OpenRecError.invalidResponse(
                    transcript.error?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                        ? transcript.error!
                        : "AssemblyAI could not transcribe this recording."
                )
            case .queued, .processing:
                try await sleepBeforeNextPoll(deadline: deadline)
            }
        }
    }

    private func sleepBeforeNextPoll(deadline: Date) async throws {
        let remaining = deadline.timeIntervalSince(now())
        guard remaining > 0 else {
            throw OpenRecError.timedOut("AssemblyAI transcription timed out. Your recording is safe and can be retried.")
        }
        let delay = min(max(0, pollInterval), remaining)
        let nanoseconds = UInt64((delay * 1_000_000_000).rounded())
        if nanoseconds > 0 { try await sleeper(nanoseconds) }
    }

    private func isTransientPollResponse(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 429 || (500...599).contains(http.statusCode)
    }

    private func decodeTranscript(_ data: Data, context: String) throws -> AssemblyAITranscriptResponse {
        do {
            return try JSONDecoder().decode(AssemblyAITranscriptResponse.self, from: data)
        } catch {
            throw OpenRecError.invalidResponse("AssemblyAI returned an unreadable \(context) response.")
        }
    }

    private func deleteTranscriptBestEffort(transcriptID: String) async {
        let request = requestBuilder.deleteRequest(apiKey: apiKey, transcriptID: transcriptID)
        guard let (data, response) = try? await session.data(for: request) else { return }
        try? validate(response: response, data: data)
    }

    private func validateAPIKey() throws {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenRecError.invalidConfiguration("Enter an AssemblyAI API key first.")
        }
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OpenRecError.invalidResponse("AssemblyAI returned no HTTP status.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let nested = object?["error"] as? [String: Any]
            let message = (object?["error"] as? String)
                ?? (nested?["message"] as? String)
                ?? String(data: data, encoding: .utf8)
                ?? "Unknown AssemblyAI error"
            throw OpenRecError.requestFailed(status: http.statusCode, message: message)
        }
    }
}

struct AssemblyAIStreamingRequestBuilder {
    let endpoint: URL

    init(endpoint: URL = URL(string: "wss://streaming.assemblyai.com/v3/ws")!) {
        self.endpoint = endpoint
    }

    func request(apiKey: String, sampleRate: Int = AssemblyAIConfiguration.realtimeSampleRate) throws -> URLRequest {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "sample_rate", value: String(sampleRate)),
            URLQueryItem(name: "encoding", value: "pcm_s16le"),
            URLQueryItem(name: "speech_model", value: AssemblyAIConfiguration.realtimeModel),
            URLQueryItem(name: "speaker_labels", value: "true"),
        ]
        guard let url = components?.url else {
            throw OpenRecError.invalidConfiguration("Invalid AssemblyAI streaming endpoint.")
        }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        return request
    }
}

final class AssemblyAIRealtimeTranscriber: NSObject, URLSessionWebSocketDelegate {
    private let apiKey: String
    private let requestBuilder: AssemblyAIStreamingRequestBuilder
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var isOpen = false
    private var disconnectRequested = false
    private var pendingAudio: [Data] = []
    private var terminationFallback: DispatchWorkItem?
    weak var delegate: RealtimeTranscriptionDelegate?

    init(
        apiKey: String,
        endpoint: URL = URL(string: "wss://streaming.assemblyai.com/v3/ws")!
    ) {
        self.apiKey = apiKey
        self.requestBuilder = AssemblyAIStreamingRequestBuilder(endpoint: endpoint)
        super.init()
    }

    func connect() {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            delegate?.realtimeTranscriptionDidFail(
                OpenRecError.invalidConfiguration("Enter an AssemblyAI API key first.")
            )
            return
        }
        do {
            let request = try requestBuilder.request(apiKey: apiKey)
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            let task = session.webSocketTask(with: request)
            lock.lock()
            self.session = session
            self.task = task
            isOpen = false
            disconnectRequested = false
            pendingAudio.removeAll(keepingCapacity: true)
            lock.unlock()
            task.resume()
            receive()
        } catch {
            delegate?.realtimeTranscriptionDidFail(error)
        }
    }

    func sendAudioChunk(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        guard !disconnectRequested else {
            lock.unlock()
            return
        }
        if !isOpen {
            pendingAudio.append(data)
            if pendingAudio.count > 100 { pendingAudio.removeFirst(pendingAudio.count - 100) }
            lock.unlock()
            return
        }
        let task = self.task
        lock.unlock()
        send(.data(data), using: task)
    }

    func disconnect() {
        lock.lock()
        guard !disconnectRequested else {
            lock.unlock()
            return
        }
        disconnectRequested = true
        pendingAudio.removeAll()
        let open = isOpen
        let task = self.task
        lock.unlock()

        if open {
            send(.string(#"{"type":"Terminate"}"#), using: task, reportFailure: false)
        }
        scheduleTerminationFallback()
    }

    private func receive() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                let text: String?
                switch message {
                case .string(let value): text = value
                case .data(let data): text = String(data: data, encoding: .utf8)
                @unknown default: text = nil
                }
                let shouldContinue = text.map(self.handle) ?? true
                if shouldContinue { self.receive() }
            case .failure(let error):
                self.lock.lock()
                let expected = self.disconnectRequested
                self.lock.unlock()
                if !expected { self.delegate?.realtimeTranscriptionDidFail(error) }
                self.finish()
            }
        }
    }

    private func handle(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return true }

        switch type {
        case "Begin":
            let configuration = json["configuration"] as? [String: Any]
            if let model = configuration?["model"] as? String,
               model != AssemblyAIConfiguration.realtimeModel {
                delegate?.realtimeTranscriptionDidFail(
                    OpenRecError.invalidResponse(
                        "AssemblyAI opened \(model) instead of \(AssemblyAIConfiguration.realtimeModel)."
                    )
                )
                disconnect()
            }
        case "Turn":
            let transcript = (json["transcript"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else { return true }
            if json["end_of_turn"] as? Bool == true {
                delegate?.realtimeTranscriptionDidCommit(
                    transcript,
                    speakerLabel: json["speaker_label"] as? String
                )
            } else {
                delegate?.realtimeTranscriptionDidUpdate(transcript)
            }
        case "Error", "error":
            let message = (json["error"] as? String)
                ?? (json["message"] as? String)
                ?? "AssemblyAI realtime transcription failed."
            delegate?.realtimeTranscriptionDidFail(OpenRecError.invalidResponse(message))
            disconnect()
        case "Termination":
            finish()
            return false
        default:
            break
        }
        return true
    }

    private func send(
        _ message: URLSessionWebSocketTask.Message,
        using task: URLSessionWebSocketTask?,
        reportFailure: Bool = true
    ) {
        task?.send(message) { [weak self] error in
            guard reportFailure, let error else { return }
            self?.delegate?.realtimeTranscriptionDidFail(error)
        }
    }

    private func scheduleTerminationFallback() {
        terminationFallback?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finish() }
        terminationFallback = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func finish() {
        lock.lock()
        let task = self.task
        let session = self.session
        self.task = nil
        self.session = nil
        isOpen = false
        pendingAudio.removeAll()
        let fallback = terminationFallback
        terminationFallback = nil
        lock.unlock()

        fallback?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        lock.lock()
        isOpen = true
        let buffered = pendingAudio
        pendingAudio.removeAll(keepingCapacity: true)
        let shouldTerminate = disconnectRequested
        lock.unlock()

        if shouldTerminate {
            send(.string(#"{"type":"Terminate"}"#), using: webSocketTask, reportFailure: false)
        } else {
            buffered.forEach { send(.data($0), using: webSocketTask) }
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        lock.lock()
        let expected = disconnectRequested
        lock.unlock()
        if !expected && closeCode != .normalClosure {
            let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) }
            delegate?.realtimeTranscriptionDidFail(
                OpenRecError.invalidResponse(
                    reasonText?.isEmpty == false
                        ? reasonText!
                        : "AssemblyAI realtime transcription disconnected (\(closeCode.rawValue))."
                )
            )
        }
        finish()
    }
}
