import Foundation

// MARK: - AssemblyAI Realtime WebSocket STT (v3 API)

class AssemblyAIRealtimeSTT: NSObject, URLSessionWebSocketDelegate {
    private let apiKey: String
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    weak var delegate: ElevenLabsSTTDelegate?

    init(apiKey: String) {
        self.apiKey = apiKey
        super.init()
    }

    func connect() {
        var components = URLComponents(string: "wss://streaming.assemblyai.com/v3/ws")!
        components.queryItems = [
            URLQueryItem(name: "token", value: apiKey),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "encoding", value: "pcm_s16le"),
        ]

        guard let url = components.url else { return }

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        urlSession = session
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        receiveMessage()
    }

    func sendAudioChunk(_ data: Data) {
        webSocketTask?.send(.data(data)) { _ in }
    }

    func disconnect() {
        let terminate = #"{"type":"Terminate"}"#
        webSocketTask?.send(.string(terminate)) { [weak self] _ in
            self?.webSocketTask?.cancel(with: .normalClosure, reason: nil)
            self?.webSocketTask = nil
            self?.urlSession?.invalidateAndCancel()
            self?.urlSession = nil
        }
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
              let type = json["type"] as? String else { return }

        switch type {
        case "Turn":
            handleTurn(json)
        case "Termination":
            delegate?.sttDidDisconnect(error: nil)
        default:
            break
        }
    }

    private func handleTurn(_ json: [String: Any]) {
        let transcript = json["transcript"] as? String ?? ""
        let endOfTurn = json["end_of_turn"] as? Bool ?? false

        guard !transcript.isEmpty else { return }

        if endOfTurn {
            // Build words array from the response
            var words: [TranscriptWord] = []
            if let wordsArray = json["words"] as? [[String: Any]] {
                for wordDict in wordsArray {
                    let text = wordDict["text"] as? String ?? ""
                    let start = (wordDict["start"] as? Double ?? 0) / 1000.0 // ms to seconds
                    let end = (wordDict["end"] as? Double ?? 0) / 1000.0
                    words.append(TranscriptWord(text: text, start: start, end: end, speakerID: nil))
                }
            }

            let segment = TranscriptSegment(
                text: transcript,
                words: words,
                speakerID: nil,
                isPartial: false
            )
            delegate?.sttDidReceiveCommittedTranscript(segment)
        } else {
            delegate?.sttDidReceivePartialTranscript(transcript)
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
