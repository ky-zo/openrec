import Foundation

enum AssemblyAITestFixtures {
    static let transcriptID = "4f55d870-6f06-4d91-bd5d-e5ab203b85ea"
    static let uploadURL = "https://cdn.assemblyai.com/upload/openrec-fixture"

    static let upload = data(
        """
        {
          "upload_url": "\(uploadURL)"
        }
        """
    )

    static let submitted = data(
        """
        {
          "id": "\(transcriptID)",
          "status": "queued"
        }
        """
    )

    static let queued = submitted

    static let processing = data(
        """
        {
          "id": "\(transcriptID)",
          "status": "processing"
        }
        """
    )

    static let completedDiarized = data(
        """
        {
          "id": "\(transcriptID)",
          "status": "completed",
          "speech_model_used": "universal-3-5-pro",
          "speaker_labels": true,
          "text": "Morning. Let's ship it. Agreed.",
          "error": null,
          "utterances": [
            {
              "speaker": "A",
              "text": "  Morning.  ",
              "start": 250,
              "end": 980,
              "confidence": 0.99,
              "words": []
            },
            {
              "speaker": "B",
              "text": "Let's ship it.",
              "start": 1250,
              "end": 2840,
              "confidence": 0.97,
              "words": []
            },
            {
              "speaker": "UNKNOWN",
              "text": "Agreed.",
              "start": -20,
              "end": 3220,
              "confidence": 0.71,
              "words": []
            },
            {
              "speaker": "C",
              "text": "   ",
              "start": 4000,
              "end": 4100,
              "confidence": 0.20,
              "words": []
            }
          ]
        }
        """
    )

    static let completedTextOnly = data(
        """
        {
          "id": "\(transcriptID)",
          "status": "completed",
          "speech_model_used": "universal-3-5-pro",
          "text": "  A transcript without utterances.  ",
          "utterances": []
        }
        """
    )

    static let completedEmpty = data(
        """
        {
          "id": "\(transcriptID)",
          "status": "completed",
          "speech_model_used": "universal-3-5-pro",
          "text": "   ",
          "utterances": []
        }
        """
    )

    static let completedWrongModel = data(
        """
        {
          "id": "\(transcriptID)",
          "status": "completed",
          "speech_model_used": "universal-2",
          "text": "Fallback transcript",
          "utterances": []
        }
        """
    )

    static let processingError = data(
        """
        {
          "id": "\(transcriptID)",
          "status": "error",
          "error": "Audio duration is too short"
        }
        """
    )

    static let authenticationError = data(
        """
        {
          "error": "Authentication error, API token missing/invalid"
        }
        """
    )

    private static func data(_ json: String) -> Data {
        Data(json.utf8)
    }
}

final class AssemblyAIMockURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    private static var _handler: Handler?

    static var handler: Handler? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _handler
        }
        set {
            lock.lock()
            _handler = newValue
            lock.unlock()
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
