import Foundation

// MARK: - Data Models

struct TranscriptWord {
    let text: String
    let start: Double
    let end: Double
    let speakerID: String?
}

struct TranscriptSegment: Identifiable {
    let id = UUID()
    let text: String
    let words: [TranscriptWord]
    let speakerID: String?
    let isPartial: Bool
}

// MARK: - Delegate Protocol

protocol ElevenLabsSTTDelegate: AnyObject {
    func sttDidReceivePartialTranscript(_ text: String)
    func sttDidReceiveCommittedTranscript(_ segment: TranscriptSegment)
    func sttDidDisconnect(error: Error?)
}

// MARK: - Realtime WebSocket STT

class ElevenLabsRealtimeSTT: NSObject, URLSessionWebSocketDelegate {
    private let apiKey: String
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    weak var delegate: ElevenLabsSTTDelegate?

    init(apiKey: String) {
        self.apiKey = apiKey
        super.init()
    }

    func connect() {
        var components = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
        components.queryItems = [
            URLQueryItem(name: "model_id", value: "scribe_v2_realtime"),
            URLQueryItem(name: "audio_format", value: "pcm_16000"),
            URLQueryItem(name: "commit_strategy", value: "vad"),
            URLQueryItem(name: "include_timestamps", value: "true"),
            URLQueryItem(name: "language_code", value: "en"),
        ]

        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        urlSession = session
        webSocketTask = session.webSocketTask(with: request)
        webSocketTask?.resume()
        receiveMessage()
    }

    func sendAudioChunk(_ data: Data) {
        let base64 = data.base64EncodedString()
        let json: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": base64,
            "commit": false,
            "sample_rate": 16000,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: json),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }

        webSocketTask?.send(.string(jsonString)) { _ in }
    }

    func disconnect() {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                self.receiveMessage()
            case .failure(let error):
                self.delegate?.sttDidDisconnect(error: error)
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageType = json["message_type"] as? String else { return }

        switch messageType {
        case "partial_transcript":
            if let transcript = json["text"] as? String, !transcript.isEmpty {
                delegate?.sttDidReceivePartialTranscript(transcript)
            }
        case "committed_transcript_with_timestamps":
            parseCommittedTranscript(json)
        default:
            break
        }
    }

    private func parseCommittedTranscript(_ json: [String: Any]) {
        let fullText = json["text"] as? String ?? ""
        guard !fullText.isEmpty else { return }

        var words: [TranscriptWord] = []
        if let wordsArray = json["words"] as? [[String: Any]] {
            for wordDict in wordsArray {
                let text = wordDict["text"] as? String ?? ""
                let start = wordDict["start"] as? Double ?? 0
                let end = wordDict["end"] as? Double ?? 0
                let speakerID = wordDict["speaker_id"] as? String
                words.append(TranscriptWord(text: text, start: start, end: end, speakerID: speakerID))
            }
        }

        // Group words by speaker_id into segments
        var segments: [(speakerID: String?, words: [TranscriptWord])] = []
        for word in words {
            if let last = segments.last, last.speakerID == word.speakerID {
                segments[segments.count - 1].words.append(word)
            } else {
                segments.append((speakerID: word.speakerID, words: [word]))
            }
        }

        if segments.isEmpty {
            let segment = TranscriptSegment(text: fullText, words: words, speakerID: nil, isPartial: false)
            delegate?.sttDidReceiveCommittedTranscript(segment)
        } else {
            for group in segments {
                let text = group.words.map { $0.text }.joined(separator: " ")
                let segment = TranscriptSegment(text: text, words: group.words, speakerID: group.speakerID, isPartial: false)
                delegate?.sttDidReceiveCommittedTranscript(segment)
            }
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        // Connected
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        delegate?.sttDidDisconnect(error: nil)
    }
}

// MARK: - Batch HTTP STT

class ElevenLabsBatchSTT {
    private let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func transcribe(fileURL: URL, completion: @escaping (Result<[TranscriptSegment], Error>) -> Void) {
        let url = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        guard let fileData = try? Data(contentsOf: fileURL) else {
            completion(.failure(STTError.fileReadFailed))
            return
        }

        var body = Data()
        let filename = fileURL.lastPathComponent
        let mimeType = filename.hasSuffix(".mp3") ? "audio/mpeg" : "audio/mp4"

        // file field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        body.append("\r\n")

        // model_id field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"model_id\"\r\n\r\n")
        body.append("scribe_v2\r\n")

        // timestamps_granularity field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"timestamps_granularity\"\r\n\r\n")
        body.append("word\r\n")

        // diarize field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"diarize\"\r\n\r\n")
        body.append("true\r\n")

        // language_code field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"language_code\"\r\n\r\n")
        body.append("en\r\n")

        body.append("--\(boundary)--\r\n")

        request.httpBody = body

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }

            guard let data else {
                completion(.failure(STTError.noData))
                return
            }

            do {
                let segments = try Self.parseResponse(data)
                completion(.success(segments))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private static func parseResponse(_ data: Data) throws -> [TranscriptSegment] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw STTError.invalidResponse
        }

        guard let wordsArray = json["words"] as? [[String: Any]] else {
            // Might just have text
            if let text = json["text"] as? String, !text.isEmpty {
                return [TranscriptSegment(text: text, words: [], speakerID: nil, isPartial: false)]
            }
            throw STTError.invalidResponse
        }

        var allWords: [TranscriptWord] = []
        for wordDict in wordsArray {
            let text = wordDict["text"] as? String ?? ""
            let start = wordDict["start"] as? Double ?? 0
            let end = wordDict["end"] as? Double ?? 0
            let speakerID = wordDict["speaker_id"] as? String
            allWords.append(TranscriptWord(text: text, start: start, end: end, speakerID: speakerID))
        }

        // Group consecutive words by speaker
        var segments: [TranscriptSegment] = []
        var currentWords: [TranscriptWord] = []
        var currentSpeaker: String? = nil

        for word in allWords {
            if word.speakerID != currentSpeaker && !currentWords.isEmpty {
                let text = currentWords.map { $0.text }.joined(separator: " ")
                segments.append(TranscriptSegment(text: text, words: currentWords, speakerID: currentSpeaker, isPartial: false))
                currentWords = []
            }
            currentSpeaker = word.speakerID
            currentWords.append(word)
        }

        if !currentWords.isEmpty {
            let text = currentWords.map { $0.text }.joined(separator: " ")
            segments.append(TranscriptSegment(text: text, words: currentWords, speakerID: currentSpeaker, isPartial: false))
        }

        return segments
    }
}

// MARK: - Helpers

enum STTError: Error, CustomStringConvertible {
    case fileReadFailed
    case noData
    case invalidResponse

    var description: String {
        switch self {
        case .fileReadFailed: return "Failed to read audio file"
        case .noData: return "No data in response"
        case .invalidResponse: return "Invalid API response"
        }
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
