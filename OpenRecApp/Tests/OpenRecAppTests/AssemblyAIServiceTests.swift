import Foundation
import XCTest
@testable import OpenRecApp

final class AssemblyAIServiceTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var session: URLSession!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssemblyAIServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AssemblyAIMockURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDownWithError() throws {
        AssemblyAIMockURLProtocol.handler = nil
        session.invalidateAndCancel()
        session = nil
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    func testBatchRequestContractUsesUniversal35ProAndDiarization() throws {
        let builder = AssemblyAIRequestBuilder()
        let request = try builder.submitRequest(
            apiKey: "assembly-secret",
            audioURL: AssemblyAITestFixtures.uploadURL
        )
        let body = try XCTUnwrap(request.httpBody)
        let decoded = try JSONDecoder().decode(AssemblyAITranscriptRequestBody.self, from: body)

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.assemblyai.com/v2/transcript")
        XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "assembly-secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(decoded.audioURL, AssemblyAITestFixtures.uploadURL)
        XCTAssertEqual(decoded.speechModels, ["universal-3-5-pro", "universal-2"])
        XCTAssertTrue(decoded.speakerLabels)
        XCTAssertTrue(decoded.languageDetection)
    }

    func testValidationUploadAndPollRequestContracts() throws {
        let builder = AssemblyAIRequestBuilder()
        let validation = try builder.validationRequest(apiKey: "assembly-secret")
        let upload = builder.uploadRequest(apiKey: "assembly-secret")
        let poll = builder.pollRequest(
            apiKey: "assembly-secret",
            transcriptID: AssemblyAITestFixtures.transcriptID
        )

        XCTAssertEqual(validation.httpMethod, "GET")
        XCTAssertEqual(validation.url?.path, "/v2/transcript")
        XCTAssertEqual(
            URLComponents(url: try XCTUnwrap(validation.url), resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "limit" })?.value,
            "1"
        )
        XCTAssertEqual(validation.value(forHTTPHeaderField: "authorization"), "assembly-secret")

        XCTAssertEqual(upload.httpMethod, "POST")
        XCTAssertEqual(upload.url?.path, "/v2/upload")
        XCTAssertEqual(upload.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        XCTAssertEqual(upload.value(forHTTPHeaderField: "authorization"), "assembly-secret")

        XCTAssertEqual(poll.httpMethod, "GET")
        XCTAssertEqual(
            poll.url?.path,
            "/v2/transcript/\(AssemblyAITestFixtures.transcriptID)"
        )
        XCTAssertEqual(poll.value(forHTTPHeaderField: "authorization"), "assembly-secret")
        XCTAssertFalse(poll.url?.absoluteString.contains("assembly-secret") == true)
    }

    func testRealtimeRequestContractUsesUniversal35ProWithDiarization() throws {
        let request = try AssemblyAIStreamingRequestBuilder().request(apiKey: "assembly-secret")
        let components = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
        )
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )

        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.host, "streaming.assemblyai.com")
        XCTAssertEqual(components.path, "/v3/ws")
        XCTAssertEqual(query["speech_model"], "universal-3-5-pro")
        XCTAssertEqual(query["speaker_labels"], "true")
        XCTAssertEqual(query["sample_rate"], "16000")
        XCTAssertEqual(query["encoding"], "pcm_s16le")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "assembly-secret")
        XCTAssertNil(query["token"])
    }

    func testDiarizedFixtureMapsSpeakerTurnsAndMilliseconds() throws {
        let response = try JSONDecoder().decode(
            AssemblyAITranscriptResponse.self,
            from: AssemblyAITestFixtures.completedDiarized
        )

        let segments = try AssemblyAITranscriptMapper.displaySegments(from: response)

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0].speakerLabel, "Speaker A")
        XCTAssertEqual(segments[0].text, "Morning.")
        XCTAssertEqual(try XCTUnwrap(segments[0].timestamp), 0.25, accuracy: 0.000_001)
        XCTAssertEqual(segments[1].speakerLabel, "Speaker B")
        XCTAssertEqual(segments[1].text, "Let's ship it.")
        XCTAssertEqual(try XCTUnwrap(segments[1].timestamp), 1.25, accuracy: 0.000_001)
        XCTAssertEqual(segments[2].speakerLabel, "Speaker")
        XCTAssertEqual(segments[2].text, "Agreed.")
        XCTAssertEqual(try XCTUnwrap(segments[2].timestamp), 0, accuracy: 0.000_001)
    }

    func testCompletedFixtureFallsBackToPlainTextWhenUtterancesAreAbsent() throws {
        let response = try JSONDecoder().decode(
            AssemblyAITranscriptResponse.self,
            from: AssemblyAITestFixtures.completedTextOnly
        )

        let segments = try AssemblyAITranscriptMapper.displaySegments(from: response)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].speakerLabel, "Conversation")
        XCTAssertEqual(segments[0].text, "A transcript without utterances.")
        XCTAssertEqual(segments[0].timestamp, 0)
    }

    func testMapperAcceptsUniversal2FallbackTranscript() throws {
        let fallback = try JSONDecoder().decode(
            AssemblyAITranscriptResponse.self,
            from: AssemblyAITestFixtures.completedFallbackModel
        )

        let segments = try AssemblyAITranscriptMapper.displaySegments(from: fallback)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].speakerLabel, "Conversation")
        XCTAssertEqual(segments[0].text, "Fallback transcript")
    }

    func testMapperRejectsWrongModelAndEmptyTranscript() throws {
        let wrongModel = try JSONDecoder().decode(
            AssemblyAITranscriptResponse.self,
            from: AssemblyAITestFixtures.completedWrongModel
        )
        let empty = try JSONDecoder().decode(
            AssemblyAITranscriptResponse.self,
            from: AssemblyAITestFixtures.completedEmpty
        )

        XCTAssertThrowsError(try AssemblyAITranscriptMapper.displaySegments(from: wrongModel)) { error in
            XCTAssertTrue(error.localizedDescription.contains("nano instead of universal-3-5-pro"))
        }
        XCTAssertThrowsError(try AssemblyAITranscriptMapper.displaySegments(from: empty)) { error in
            guard case OpenRecError.noSpeechDetected(let message) = error else {
                return XCTFail("Expected noSpeechDetected, got \(error)")
            }
            XCTAssertTrue(message.contains("did not detect any spoken words"))
        }
    }

    func testTranscribeRunsUploadSubmitPollingAndMapsCompletedFixture() async throws {
        let audioURL = temporaryDirectory.appendingPathComponent("call.m4a")
        try Data("non-empty audio fixture".utf8).write(to: audioURL)
        let state = LockedRequestState()
        AssemblyAIMockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            state.append(request)

            if url.path == "/v2/upload" {
                return (Self.response(url: url), AssemblyAITestFixtures.upload)
            }
            if url.path == "/v2/transcript", request.httpMethod == "POST" {
                return (Self.response(url: url), AssemblyAITestFixtures.submitted)
            }
            if url.path == "/v2/transcript/\(AssemblyAITestFixtures.transcriptID)",
               request.httpMethod == "DELETE" {
                return (Self.response(url: url), AssemblyAITestFixtures.completedDiarized)
            }
            if url.path == "/v2/transcript/\(AssemblyAITestFixtures.transcriptID)",
               request.httpMethod == "GET" {
                switch state.incrementPollCount() {
                case 1:
                    return (Self.response(url: url), AssemblyAITestFixtures.queued)
                case 2:
                    return (Self.response(url: url), AssemblyAITestFixtures.processing)
                default:
                    return (Self.response(url: url), AssemblyAITestFixtures.completedDiarized)
                }
            }
            throw URLError(.unsupportedURL)
        }

        let service = AssemblyAIService(
            apiKey: "assembly-secret",
            session: session,
            pollInterval: 0.001,
            pollTimeout: 60,
            sleeper: { nanoseconds in state.appendSleep(nanoseconds) },
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let segments = try await service.transcribe(fileURL: audioURL)

        XCTAssertEqual(segments.map(\.speakerLabel), ["Speaker A", "Speaker B", "Speaker"])
        XCTAssertEqual(state.pollCount, 3)
        XCTAssertEqual(state.sleepDurations, [1_000_000, 1_000_000])
        XCTAssertEqual(
            state.requests.map { "\($0.httpMethod ?? "GET") \($0.url?.path ?? "")" },
            [
                "POST /v2/upload",
                "POST /v2/transcript",
                "GET /v2/transcript/\(AssemblyAITestFixtures.transcriptID)",
                "GET /v2/transcript/\(AssemblyAITestFixtures.transcriptID)",
                "GET /v2/transcript/\(AssemblyAITestFixtures.transcriptID)",
                "DELETE /v2/transcript/\(AssemblyAITestFixtures.transcriptID)",
            ]
        )
    }

    func testTransientPollResponsesRetryThenComplete() async throws {
        let audioURL = temporaryDirectory.appendingPathComponent("transient-poll.m4a")
        try Data("non-empty audio fixture".utf8).write(to: audioURL)
        let state = LockedRequestState()
        AssemblyAIMockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            state.append(request)

            if url.path == "/v2/upload" {
                return (Self.response(url: url), AssemblyAITestFixtures.upload)
            }
            if url.path == "/v2/transcript", request.httpMethod == "POST" {
                return (Self.response(url: url), AssemblyAITestFixtures.submitted)
            }
            if url.path == "/v2/transcript/\(AssemblyAITestFixtures.transcriptID)",
               request.httpMethod == "DELETE" {
                return (Self.response(url: url), AssemblyAITestFixtures.completedDiarized)
            }
            if url.path == "/v2/transcript/\(AssemblyAITestFixtures.transcriptID)",
               request.httpMethod == "GET" {
                switch state.incrementPollCount() {
                case 1:
                    return (
                        Self.response(url: url, statusCode: 429),
                        Data(#"{"error":"rate limited"}"#.utf8)
                    )
                case 2:
                    return (
                        Self.response(url: url, statusCode: 503),
                        Data(#"{"error":"temporarily unavailable"}"#.utf8)
                    )
                default:
                    return (Self.response(url: url), AssemblyAITestFixtures.completedDiarized)
                }
            }
            throw URLError(.unsupportedURL)
        }
        let service = AssemblyAIService(
            apiKey: "assembly-secret",
            session: session,
            pollInterval: 0.001,
            pollTimeout: 60,
            sleeper: { nanoseconds in state.appendSleep(nanoseconds) },
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let segments = try await service.transcribe(fileURL: audioURL)

        XCTAssertEqual(segments.map(\.speakerLabel), ["Speaker A", "Speaker B", "Speaker"])
        XCTAssertEqual(state.pollCount, 3)
        XCTAssertEqual(state.sleepDurations, [1_000_000, 1_000_000])
        XCTAssertEqual(
            state.requests.filter { $0.httpMethod == "DELETE" }.count,
            1
        )
    }

    func testRemoteCloudAudioSkipsAssemblyUploadAndSubmitsSignedURL() async throws {
        let state = LockedRequestState()
        let signedAudioURL = URL(string: "https://api.openrec.app/v1/media/signed-audio-token")!
        AssemblyAIMockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            state.append(request)
            if url.path == "/v2/transcript", request.httpMethod == "POST" {
                return (Self.response(url: url), AssemblyAITestFixtures.submitted)
            }
            if url.path == "/v2/transcript/\(AssemblyAITestFixtures.transcriptID)",
               request.httpMethod == "DELETE" {
                return (Self.response(url: url), Data())
            }
            if url.path == "/v2/transcript/\(AssemblyAITestFixtures.transcriptID)" {
                return (Self.response(url: url), AssemblyAITestFixtures.completedDiarized)
            }
            throw URLError(.unsupportedURL)
        }

        let service = AssemblyAIService(
            apiKey: "assembly-secret",
            session: session,
            pollInterval: 0,
            pollTimeout: 60
        )
        let segments = try await service.transcribe(audioURL: signedAudioURL)

        XCTAssertEqual(segments.map(\.speakerLabel), ["Speaker A", "Speaker B", "Speaker"])
        XCTAssertFalse(state.requests.contains { $0.url?.path == "/v2/upload" })
        XCTAssertEqual(
            state.requests.map { "\($0.httpMethod ?? "GET") \($0.url?.path ?? "")" },
            [
                "POST /v2/transcript",
                "GET /v2/transcript/\(AssemblyAITestFixtures.transcriptID)",
                "DELETE /v2/transcript/\(AssemblyAITestFixtures.transcriptID)",
            ]
        )
    }

    func testHTTP200ProcessingErrorSurfacesAssemblyMessage() async throws {
        let audioURL = temporaryDirectory.appendingPathComponent("short.m4a")
        try Data("short".utf8).write(to: audioURL)
        let state = LockedRequestState()
        AssemblyAIMockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            state.append(request)
            if url.path == "/v2/upload" {
                return (Self.response(url: url), AssemblyAITestFixtures.upload)
            }
            if url.path == "/v2/transcript", request.httpMethod == "POST" {
                return (Self.response(url: url), AssemblyAITestFixtures.submitted)
            }
            if url.path == "/v2/transcript/\(AssemblyAITestFixtures.transcriptID)",
               request.httpMethod == "DELETE" {
                return (Self.response(url: url), Data())
            }
            return (Self.response(url: url), AssemblyAITestFixtures.processingError)
        }
        let service = AssemblyAIService(
            apiKey: "assembly-secret",
            session: session,
            pollInterval: 0,
            pollTimeout: 60
        )

        do {
            _ = try await service.transcribe(fileURL: audioURL)
            XCTFail("Expected AssemblyAI processing to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Audio duration is too short"))
        }
        XCTAssertEqual(
            state.requests.filter {
                $0.httpMethod == "DELETE"
                    && $0.url?.path == "/v2/transcript/\(AssemblyAITestFixtures.transcriptID)"
            }.count,
            1
        )
    }

    func testValidationExtractsTopLevelAuthenticationError() async throws {
        AssemblyAIMockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            return (
                Self.response(url: url, statusCode: 401),
                AssemblyAITestFixtures.authenticationError
            )
        }
        let service = AssemblyAIService(apiKey: "bad-key", session: session)

        do {
            try await service.validateAccess()
            XCTFail("Expected key validation to fail")
        } catch OpenRecError.requestFailed(let status, let message) {
            XCTAssertEqual(status, 401)
            XCTAssertEqual(message, "Authentication error, API token missing/invalid")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAuthenticationFailureClassificationOnlyMatchesUnauthorizedAndForbidden() {
        XCTAssertTrue(
            AssemblyAIService.isAuthenticationFailure(
                OpenRecError.requestFailed(status: 401, message: "invalid token")
            )
        )
        XCTAssertTrue(
            AssemblyAIService.isAuthenticationFailure(
                OpenRecError.requestFailed(status: 403, message: "forbidden")
            )
        )
        XCTAssertFalse(
            AssemblyAIService.isAuthenticationFailure(
                OpenRecError.requestFailed(status: 429, message: "rate limited")
            )
        )
        XCTAssertFalse(
            AssemblyAIService.isAuthenticationFailure(
                OpenRecError.requestFailed(status: 503, message: "temporarily unavailable")
            )
        )
        XCTAssertFalse(
            AssemblyAIService.isAuthenticationFailure(
                OpenRecError.invalidResponse("malformed payload")
            )
        )
        XCTAssertFalse(AssemblyAIService.isAuthenticationFailure(URLError(.timedOut)))
    }

    func testPollingStopsAtDeadlineWithoutRealSleeping() async throws {
        let audioURL = temporaryDirectory.appendingPathComponent("queued.m4a")
        try Data("queued audio".utf8).write(to: audioURL)
        let state = LockedRequestState()
        let clock = LockedTestClock(date: Date(timeIntervalSince1970: 1_700_000_000))
        AssemblyAIMockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            if url.path == "/v2/upload" {
                return (Self.response(url: url), AssemblyAITestFixtures.upload)
            }
            if url.path == "/v2/transcript", request.httpMethod == "POST" {
                return (Self.response(url: url), AssemblyAITestFixtures.submitted)
            }
            state.incrementPollCount()
            return (Self.response(url: url), AssemblyAITestFixtures.queued)
        }
        let service = AssemblyAIService(
            apiKey: "assembly-secret",
            session: session,
            pollInterval: 3,
            pollTimeout: 5,
            performsRemoteCleanup: false,
            sleeper: { nanoseconds in
                state.appendSleep(nanoseconds)
                clock.advance(by: TimeInterval(nanoseconds) / 1_000_000_000)
            },
            now: { clock.date }
        )

        do {
            _ = try await service.transcribe(fileURL: audioURL)
            XCTFail("Expected polling to time out")
        } catch OpenRecError.timedOut(let message) {
            XCTAssertTrue(message.contains("recording is safe"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(state.pollCount, 2)
        XCTAssertEqual(state.sleepDurations, [3_000_000_000, 2_000_000_000])
    }

    func testBlankAPIKeyFailsBeforeMakingARequest() async {
        let state = LockedRequestState()
        AssemblyAIMockURLProtocol.handler = { request in
            state.append(request)
            throw URLError(.cannotConnectToHost)
        }
        let service = AssemblyAIService(apiKey: "  \n ", session: session)

        do {
            try await service.validateAccess()
            XCTFail("Expected an empty key to fail")
        } catch OpenRecError.invalidConfiguration(let message) {
            XCTAssertTrue(message.contains("AssemblyAI API key"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(state.requests.isEmpty)
    }

    private static func response(url: URL, statusCode: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }
}

private final class LockedRequestState {
    private let lock = NSLock()
    private var storedRequests: [URLRequest] = []
    private var storedPollCount = 0
    private var storedSleepDurations: [UInt64] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    var pollCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedPollCount
    }

    var sleepDurations: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return storedSleepDurations
    }

    func append(_ request: URLRequest) {
        lock.lock()
        storedRequests.append(request)
        lock.unlock()
    }

    @discardableResult
    func incrementPollCount() -> Int {
        lock.lock()
        storedPollCount += 1
        let value = storedPollCount
        lock.unlock()
        return value
    }

    func appendSleep(_ nanoseconds: UInt64) {
        lock.lock()
        storedSleepDurations.append(nanoseconds)
        lock.unlock()
    }
}

private final class LockedTestClock {
    private let lock = NSLock()
    private var storedDate: Date

    init(date: Date) {
        storedDate = date
    }

    var date: Date {
        lock.lock()
        defer { lock.unlock() }
        return storedDate
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        storedDate = storedDate.addingTimeInterval(interval)
        lock.unlock()
    }
}
