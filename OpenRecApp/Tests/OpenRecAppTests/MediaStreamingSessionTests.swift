import Foundation
import XCTest
@testable import OpenRecApp

final class MediaStreamingSessionTests: XCTestCase {
    func testAccumulatorEmitsExactNonfinalPartsAndPreservesByteOrder() {
        var accumulator = MultipartByteAccumulator(partSize: 4)

        XCTAssertEqual(accumulator.append(Data("abc".utf8)), [])
        XCTAssertEqual(accumulator.append(Data("defgh".utf8)), [Data("abcd".utf8), Data("efgh".utf8)])
        XCTAssertEqual(accumulator.bufferedByteCount, 0)
        XCTAssertEqual(accumulator.append(Data("ij".utf8)), [])
        XCTAssertEqual(accumulator.finish(), Data("ij".utf8))
        XCTAssertNil(accumulator.finish())
    }

    func testProductionMultipartAndBackpressureLimits() {
        XCTAssertEqual(MediaStreamingSession.multipartPartSize, 5 * 1024 * 1024)
        XCTAssertEqual(MediaStreamingSession.defaultMaximumPendingBytes, 96 * 1024 * 1024)
        XCTAssertEqual(MediaStreamingRetryPolicy.partUpload.maximumAttempts, 30)
        XCTAssertEqual(MediaStreamingRetryPolicy.partUpload.outageDeadline, 120)
    }

    func testSessionReordersCallbacksBeforeBuildingMultipartParts() async throws {
        let transport = RecordingMediaStreamingTransport()
        let meetingID = UUID()
        let journal = makeJournal()
        let session = try await MediaStreamingSession.begin(
            descriptor: descriptor(id: meetingID),
            kinds: [.screen],
            transport: transport,
            maximumPendingBytes: 24,
            reorderWindow: 4,
            partSize: 4,
            journal: journal
        )

        try await session.append(Data("efgh".utf8), kind: .screen, sequence: 1)
        try await session.append(Data("abcd".utf8), kind: .screen, sequence: 0)
        try await session.append(Data("ij".utf8), kind: .screen, sequence: 2)
        let result = try await session.finish()

        let uploaded = await transport.uploadedParts(for: .screen)
        XCTAssertEqual(uploaded.map(\.partNumber), [1, 2, 3])
        XCTAssertEqual(uploaded.map(\.data), [Data("abcd".utf8), Data("efgh".utf8), Data("ij".utf8)])
        XCTAssertEqual(result.media.first?.byteCount, 10)
        XCTAssertEqual(result.media.first?.partCount, 3)
        let progress = await session.progressSnapshot()
        XCTAssertEqual(progress.state, .completed)
        let remainingJournalEntries = try await journal.allEntries()
        XCTAssertTrue(remainingJournalEntries.isEmpty)
    }

    func testFinishRejectsASequenceGapWithoutCompletingObject() async throws {
        let transport = RecordingMediaStreamingTransport()
        let session = try await MediaStreamingSession.begin(
            descriptor: descriptor(id: UUID()),
            kinds: [.audio],
            transport: transport,
            maximumPendingBytes: 16,
            reorderWindow: 4,
            partSize: 4,
            journal: makeJournal()
        )
        try await session.append(Data("late".utf8), kind: .audio, sequence: 1)

        do {
            _ = try await session.finish()
            XCTFail("Expected a missing-sequence failure")
        } catch let error as MediaStreamingError {
            XCTAssertEqual(error, .sequenceGap(kind: .audio, expected: 0, nextReceived: 1))
        }
        let completionCount = await transport.completionCount()
        XCTAssertEqual(completionCount, 0)
        await session.abort()
    }

    func testStrictCapCountsQueuedAndInFlightBytes() async throws {
        let transport = BlockingMediaStreamingTransport()
        let session = try await MediaStreamingSession.begin(
            descriptor: descriptor(id: UUID()),
            kinds: [.screen],
            transport: transport,
            maximumPendingBytes: 8,
            reorderWindow: 4,
            partSize: 4,
            journal: makeJournal()
        )
        try await session.append(Data("abcd".utf8), kind: .screen, sequence: 0)
        try await session.append(Data("efgh".utf8), kind: .screen, sequence: 1)

        do {
            try await session.append(Data("i".utf8), kind: .screen, sequence: 2)
            XCTFail("Expected the strict pending-byte cap to reject the chunk")
        } catch let error as MediaStreamingError {
            XCTAssertEqual(error, .backpressure(limit: 8, pending: 8, attempted: 1))
        }

        let failed = await session.progressSnapshot()
        XCTAssertEqual(failed.state, .failed(MediaStreamingError.backpressure(
            limit: 8,
            pending: 8,
            attempted: 1
        ).localizedDescription))
        await transport.releaseUploads()
        await session.abort()
    }

    func testR2MultipartUploadIDParserHandlesNamespacedResponse() throws {
        let xml = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <InitiateMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Bucket>recordings</Bucket><Key>meetings/a/recording.mp4</Key><UploadId>upload/+==</UploadId>
        </InitiateMultipartUploadResult>
        """.utf8)
        let parser = R2MultipartUploadIDParser()

        try parser.parse(xml)

        XCTAssertEqual(parser.uploadID, "upload/+==")
    }

    func testR2ErrorParserCapturesNoSuchUploadCode() throws {
        let parser = R2ErrorResponseParser()
        try parser.parse(Data("""
        <Error><Code>NoSuchUpload</Code><Message>The specified upload does not exist.</Message></Error>
        """.utf8))

        XCTAssertEqual(parser.code, "NoSuchUpload")
        XCTAssertEqual(parser.message, "The specified upload does not exist.")
    }

    func testR2CompletionXMLSortsPartsAndEscapesETags() {
        let data = R2MultipartCompletionXML.encode(parts: [
            MediaUploadedPart(partNumber: 2, etag: "\"b&2\""),
            MediaUploadedPart(partNumber: 1, etag: "\"a<1\"")
        ])
        let xml = String(decoding: data, as: UTF8.self)

        XCTAssertLessThan(xml.range(of: "<PartNumber>1</PartNumber>")!.lowerBound,
                          xml.range(of: "<PartNumber>2</PartNumber>")!.lowerBound)
        XCTAssertTrue(xml.contains("&quot;a&lt;1&quot;"))
        XCTAssertTrue(xml.contains("&quot;b&amp;2&quot;"))
    }

    func testR2MultipartAndPresignedGetRequestsUseSigV4QueryParameters() throws {
        let signer = R2RequestSigner(
            accountID: "account",
            bucket: "my bucket",
            accessKeyID: "ACCESS",
            secretAccessKey: "SECRET"
        )
        let now = Date(timeIntervalSince1970: 1_704_164_645) // 2024-01-02T03:04:05Z
        let create = try signer.signedCreateMultipartRequest(
            objectKey: "meetings/a b/recording.mp4",
            contentType: "video/mp4",
            now: now
        )
        let part = try signer.signedUploadPartRequest(
            data: Data("part".utf8),
            objectKey: "meetings/a b/recording.mp4",
            uploadID: "id/+==",
            partNumber: 7,
            now: now
        )
        let playback = try signer.presignedGetURL(
            objectKey: "meetings/a b/recording.mp4",
            expiresIn: 900,
            now: now
        )
        let head = try signer.signedHeadRequest(
            objectKey: "meetings/a b/recording.mp4",
            now: now
        )

        XCTAssertEqual(create.httpMethod, "POST")
        XCTAssertEqual(
            create.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath },
            "/my%20bucket/meetings/a%20b/recording.mp4"
        )
        XCTAssertEqual(create.url?.query, "uploads=")
        XCTAssertTrue(create.value(forHTTPHeaderField: "Authorization")?.contains("SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date") == true)

        XCTAssertEqual(part.httpMethod, "PUT")
        XCTAssertEqual(part.url?.query, "partNumber=7&uploadId=id%2F%2B%3D%3D")
        XCTAssertFalse(part.value(forHTTPHeaderField: "Authorization")?.isEmpty ?? true)

        let query = URLComponents(url: playback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(values["X-Amz-Algorithm"], "AWS4-HMAC-SHA256")
        XCTAssertEqual(values["X-Amz-Expires"], "900")
        XCTAssertEqual(values["X-Amz-SignedHeaders"], "host")
        XCTAssertEqual(values["X-Amz-Credential"], "ACCESS/20240102/auto/s3/aws4_request")
        XCTAssertEqual(values["X-Amz-Signature"]?.count, 64)
        XCTAssertEqual(head.httpMethod, "HEAD")
        XCTAssertFalse(head.value(forHTTPHeaderField: "Authorization")?.isEmpty ?? true)
    }

    func testOwnR2ManifestStillDecodesV1AndNewManifestsUseV2() throws {
        let payload = descriptor(id: UUID()).provisionalPayload
        let legacy = LegacyManifest(
            payload: payload,
            hasScreenRecording: true,
            hasAudioRecording: false,
            storesTranscript: false,
            isComplete: true,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(OwnR2MeetingManifest.self, from: encoder.encode(legacy))

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertTrue(decoded.media.isEmpty)
        let created = OwnR2MeetingManifest(
            payload: payload,
            hasScreenRecording: true,
            hasAudioRecording: false,
            storesTranscript: false,
            isComplete: true,
            updatedAt: Date(),
            media: [OwnR2MediaObject(
                kind: "screen",
                objectKey: "meetings/id/recording.mp4",
                contentType: "video/mp4",
                byteCount: 42,
                partCount: 1
            )]
        )
        let v2Root = try JSONSerialization.jsonObject(with: encoder.encode(created)) as? [String: Any]
        XCTAssertEqual(v2Root?["schemaVersion"] as? Int, 2)
        XCTAssertEqual((v2Root?["media"] as? [[String: Any]])?.first?["byteCount"] as? Int, 42)
    }

    func testBYORecoveryManifestMergePreservesFinalMetadataAndExistingMedia() {
        let meetingID = UUID()
        let meeting = descriptor(id: meetingID)
        let finalPayload = MeetingPayload(
            id: meetingID,
            startedAt: meeting.startedAt,
            endedAt: meeting.startedAt.addingTimeInterval(90),
            callApp: "Zoom",
            callTitle: "Final title",
            transcript: "",
            insights: MeetingInsights(title: "Final insight"),
            durationSeconds: 90
        )
        let existing = OwnR2MeetingManifest(
            payload: finalPayload,
            hasScreenRecording: false,
            hasAudioRecording: true,
            storesTranscript: false,
            isComplete: true,
            updatedAt: Date(timeIntervalSince1970: 20),
            media: [OwnR2MediaObject(
                kind: MeetingMediaKind.audio.rawValue,
                objectKey: "meetings/id/audio.m4a",
                contentType: "audio/mp4",
                byteCount: 11,
                partCount: 1
            )]
        )
        let merged = OwnR2MediaStreamingTransport.mergedManifest(
            descriptor: meeting,
            recoveredMedia: [MediaStreamingMediaResult(
                kind: .screen,
                objectKey: "meetings/id/recording.mp4",
                contentType: "video/mp4",
                byteCount: 22,
                partCount: 2
            )],
            preserving: existing,
            now: Date(timeIntervalSince1970: 30)
        )

        XCTAssertTrue(merged.isComplete)
        XCTAssertEqual(merged.payload.callTitle, "Final title")
        XCTAssertEqual(merged.payload.insights.title, "Final insight")
        XCTAssertTrue(merged.hasAudioRecording)
        XCTAssertTrue(merged.hasScreenRecording)
        XCTAssertEqual(Set(merged.media.map(\.kind)), Set(["audio", "screen"]))
        XCTAssertEqual(merged.media.first(where: { $0.kind == "audio" })?.byteCount, 11)
        XCTAssertEqual(merged.media.first(where: { $0.kind == "screen" })?.byteCount, 22)
    }

    func testRetryClassificationDoesNotRetryAuthenticationOrOtherClientErrors() {
        XCTAssertTrue(MediaStreamingRetry.isRetryable(OpenRecError.requestFailed(status: 408, message: "slow")))
        XCTAssertTrue(MediaStreamingRetry.isRetryable(OpenRecError.requestFailed(status: 429, message: "busy")))
        XCTAssertTrue(MediaStreamingRetry.isRetryable(OpenRecError.requestFailed(status: 503, message: "down")))
        XCTAssertTrue(MediaStreamingRetry.isRetryable(URLError(.networkConnectionLost)))
        XCTAssertFalse(MediaStreamingRetry.isRetryable(OpenRecError.requestFailed(status: 401, message: "expired")))
        XCTAssertFalse(MediaStreamingRetry.isRetryable(OpenRecError.requestFailed(status: 403, message: "denied")))
        XCTAssertFalse(MediaStreamingRetry.isRetryable(OpenRecError.requestFailed(status: 422, message: "bad")))
        XCTAssertTrue(MediaStreamingRetry.isRetryable(URLError(.dnsLookupFailed)))
        XCTAssertFalse(MediaStreamingRetry.isRetryable(URLError(.cancelled)))
        XCTAssertTrue(MediaStreamingRetry.isRetryable(R2ServiceError(status: 500, code: "InternalError", message: "retry")))
        XCTAssertFalse(MediaStreamingRetry.isRetryable(R2ServiceError(status: 404, code: "NoSuchUpload", message: "gone")))
    }

    func testRetryPolicyUsesExponentialBackoffWithBoundedJitter() {
        let policy = MediaStreamingRetryPolicy.partUpload

        XCTAssertEqual(policy.delay(afterFailure: 1, randomUnit: 0.5), 0.5, accuracy: 0.0001)
        XCTAssertEqual(policy.delay(afterFailure: 2, randomUnit: 0.5), 1, accuracy: 0.0001)
        XCTAssertEqual(policy.delay(afterFailure: 8, randomUnit: 0.5), 8, accuracy: 0.0001)
        XCTAssertEqual(policy.delay(afterFailure: 1, randomUnit: 0), 0.375, accuracy: 0.0001)
        XCTAssertEqual(policy.delay(afterFailure: 1, randomUnit: 1), 0.625, accuracy: 0.0001)
    }

    func testRetryRunnerRecoversAcrossTransientHandoffWithoutSleeping() async throws {
        let attempts = LockedAttemptCounter()
        let value: String = try await MediaStreamingRetry.run(
            policy: MediaStreamingRetryPolicy(
                maximumAttempts: 5,
                outageDeadline: 10,
                initialDelay: 0.1,
                maximumDelay: 1,
                jitterFraction: 0
            ),
            clock: { 0 },
            sleeper: { _ in },
            randomUnit: { 0.5 }
        ) {
            let attempt = attempts.increment()
            if attempt < 3 { throw URLError(.networkConnectionLost) }
            return "uploaded"
        }

        XCTAssertEqual(value, "uploaded")
        XCTAssertEqual(attempts.value, 3)
    }

    func testRetryRunnerStopsAtOutageDeadline() async {
        let attempts = LockedAttemptCounter()
        let clock = LockedTestClock()
        do {
            let _: String = try await MediaStreamingRetry.run(
                policy: MediaStreamingRetryPolicy(
                    maximumAttempts: 30,
                    outageDeadline: 1,
                    initialDelay: 0.75,
                    maximumDelay: 1,
                    jitterFraction: 0
                ),
                clock: { clock.now },
                sleeper: { seconds in clock.advance(by: seconds) },
                randomUnit: { 0.5 }
            ) {
                _ = attempts.increment()
                throw URLError(.notConnectedToInternet)
            }
            XCTFail("Expected the outage deadline to stop retries")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
        XCTAssertEqual(clock.now, 1, accuracy: 0.0001)
        XCTAssertEqual(attempts.value, 3)
    }

    func testUploadJournalContainsOnlyMetadataAndSurvivesLaunchBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openrec-upload-journal-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("active.json")
        let firstLaunch = MediaStreamingUploadJournal(fileURL: url, launchID: UUID())
        let upload = MediaMultipartUpload(
            meetingID: UUID(),
            kind: .screen,
            uploadID: "opaque-upload-token",
            objectKey: "managed://logical-only",
            contentType: "video/mp4",
            backend: .managed,
            storageScope: "https://api.example.test"
        )
        try await firstLaunch.record(
            upload,
            descriptor: descriptor(id: upload.meetingID),
            now: Date(timeIntervalSince1970: 10)
        )

        let raw = try Data(contentsOf: url)
        let text = String(decoding: raw, as: UTF8.self)
        XCTAssertLessThan(raw.count, 4_096)
        XCTAssertFalse(text.contains("mdat"))
        XCTAssertFalse(text.contains("credential"))

        let nextLaunch = MediaStreamingUploadJournal(fileURL: url, launchID: UUID())
        let stale = try await nextLaunch.entriesFromPriorLaunch()
        XCTAssertEqual(stale.count, 1)
        XCTAssertEqual(stale.first?.uploadID, upload.uploadID)
        XCTAssertEqual(stale.first?.upload?.storageScope, upload.storageScope)

        try await nextLaunch.remove(upload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try? FileManager.default.removeItem(at: directory)
    }

    func testBYOCompletedObjectStaysJournaledUntilManifestCanBeRecovered() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openrec-byo-recovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("active.json")
        let firstLaunchID = UUID()
        let journal = MediaStreamingUploadJournal(fileURL: url, launchID: firstLaunchID)
        let transport = RecordingMediaStreamingTransport(backend: .ownR2)
        let meetingID = UUID()
        let meeting = descriptor(id: meetingID)
        let session = try await MediaStreamingSession.begin(
            descriptor: meeting,
            kinds: [.screen],
            transport: transport,
            maximumPendingBytes: 16,
            reorderWindow: 4,
            partSize: 4,
            journal: journal
        )
        try await session.append(Data("abcdefgh".utf8), kind: .screen, sequence: 0)

        let completed = try await session.finish(kind: .screen)

        XCTAssertEqual(completed.byteCount, 8)
        XCTAssertEqual(completed.partCount, 2)
        let manifestCommitCount = await transport.manifestCommitCount()
        XCTAssertEqual(manifestCommitCount, 0)
        let currentEntries = try await journal.allEntries()
        XCTAssertEqual(currentEntries.count, 1)
        XCTAssertTrue(currentEntries[0].isAwaitingManifest)
        XCTAssertEqual(currentEntries[0].completedResult, completed)
        XCTAssertEqual(currentEntries[0].meetingDescriptor.meetingID, meetingID)
        XCTAssertEqual(currentEntries[0].meetingDescriptor.startedAt, meeting.startedAt)
        XCTAssertEqual(currentEntries[0].meetingDescriptor.callApp, meeting.callApp)
        XCTAssertEqual(currentEntries[0].meetingDescriptor.callTitle, meeting.callTitle)

        // A new process can rebuild the manifest from metadata alone. No
        // completed object is treated as an active upload to be discarded.
        let nextLaunch = MediaStreamingUploadJournal(fileURL: url, launchID: UUID())
        let recoverable = try await nextLaunch.entriesFromPriorLaunch()
        XCTAssertEqual(recoverable.count, 1)
        XCTAssertTrue(recoverable[0].isAwaitingManifest)
        XCTAssertEqual(recoverable[0].completedResult, completed)
    }

    func testBYOManifestSuccessWithJournalRemovalFailureKeepsCompleteRecoverySet() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openrec-byo-remove-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("active.json")
        let journal = MediaStreamingUploadJournal(
            fileURL: url,
            launchID: UUID(),
            failureInjector: { mutation in
                mutation == .remove ? TestJournalError.injectedRemovalFailure : nil
            }
        )
        let transport = RecordingMediaStreamingTransport(backend: .ownR2)
        let meetingID = UUID()
        let session = try await MediaStreamingSession.begin(
            descriptor: descriptor(id: meetingID),
            kinds: [.screen, .audio],
            transport: transport,
            maximumPendingBytes: 24,
            reorderWindow: 4,
            partSize: 4,
            journal: journal
        )
        try await session.append(Data("screen".utf8), kind: .screen, sequence: 0)
        try await session.append(Data("audio".utf8), kind: .audio, sequence: 0)

        do {
            _ = try await session.finish()
            XCTFail("Expected the injected journal removal failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("injected journal removal"))
        }

        let manifestCommitCount = await transport.manifestCommitCount()
        let manifestMedia = await transport.lastManifestMedia()
        XCTAssertEqual(manifestCommitCount, 1)
        XCTAssertEqual(Set(manifestMedia.map(\.kind)), Set([.screen, .audio]))

        // The failed atomic removal leaves both completed markers. Retrying
        // recovery therefore rewrites the same complete v2 manifest instead
        // of accidentally hiding one stream.
        let nextLaunch = MediaStreamingUploadJournal(fileURL: url, launchID: UUID())
        let recoverable = try await nextLaunch.entriesFromPriorLaunch()
        XCTAssertEqual(recoverable.count, 2)
        XCTAssertTrue(recoverable.allSatisfy(\.isAwaitingManifest))
        XCTAssertEqual(Set(recoverable.compactMap { $0.completedResult?.kind }), Set([.screen, .audio]))
    }

    func testR2NoSuchUploadIsRecognizedAsTerminalWithoutTreatingOther404AsCompletion() {
        XCTAssertTrue(R2ServiceError(
            status: 404,
            code: "NoSuchUpload",
            message: "The specified upload does not exist"
        ).isNoSuchUpload)
        XCTAssertFalse(R2ServiceError(
            status: 404,
            code: "NoSuchKey",
            message: "The object does not exist"
        ).isNoSuchUpload)
    }

    private func descriptor(id: UUID) -> MediaStreamingMeetingDescriptor {
        MediaStreamingMeetingDescriptor(
            meetingID: id,
            startedAt: Date(timeIntervalSince1970: 10),
            callApp: "Tests",
            callTitle: "Streaming"
        )
    }

    private func makeJournal() -> MediaStreamingUploadJournal {
        MediaStreamingUploadJournal(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("openrec-test-journal-\(UUID().uuidString).json"),
            launchID: UUID()
        )
    }
}

private final class LockedAttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class LockedTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    var now: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        value += seconds
        lock.unlock()
    }
}

private struct LegacyManifest: Codable {
    let payload: MeetingPayload
    let hasScreenRecording: Bool
    let hasAudioRecording: Bool
    let storesTranscript: Bool
    let isComplete: Bool
    let updatedAt: Date
}

private struct RecordedPart: Sendable {
    let partNumber: Int
    let data: Data
}

private enum TestJournalError: LocalizedError {
    case injectedRemovalFailure

    var errorDescription: String? { "injected journal removal failure" }
}

private actor RecordingMediaStreamingTransport: MediaStreamingTransport {
    private var parts: [MeetingMediaKind: [RecordedPart]] = [:]
    private var completions = 0
    private var manifestCommits: [[MediaStreamingMediaResult]] = []
    private let backend: MediaStreamingBackend
    private let scope: String

    init(backend: MediaStreamingBackend = .managed) {
        self.backend = backend
        scope = backend == .ownR2 ? "r2://test/bucket" : "https://example.test"
    }

    func prepareMeeting(_ descriptor: MediaStreamingMeetingDescriptor) async throws {}

    func beginUpload(meetingID: UUID, kind: MeetingMediaKind, contentType: String) async throws -> MediaMultipartUpload {
        MediaMultipartUpload(
            meetingID: meetingID,
            kind: kind,
            uploadID: "upload-\(kind.rawValue)",
            objectKey: "meetings/\(meetingID)/\(kind.rawValue).mp4",
            contentType: contentType,
            backend: backend,
            storageScope: scope
        )
    }

    func uploadPart(_ data: Data, partNumber: Int, upload: MediaMultipartUpload) async throws -> MediaUploadedPart {
        parts[upload.kind, default: []].append(RecordedPart(partNumber: partNumber, data: data))
        return MediaUploadedPart(partNumber: partNumber, etag: "etag-\(partNumber)")
    }

    func completeUpload(_ upload: MediaMultipartUpload, parts: [MediaUploadedPart]) async throws -> MediaCompletedUpload {
        completions += 1
        return MediaCompletedUpload(objectKey: upload.objectKey)
    }

    func abortUpload(_ upload: MediaMultipartUpload) async throws {}
    func deleteProvisionalMeeting(meetingID: UUID) async throws {}
    func deleteMedia(meetingID: UUID, kind: MeetingMediaKind) async throws {}

    func accessURL(meetingID: UUID, kind: MeetingMediaKind, ttl: TimeInterval) async throws -> RemoteMediaAccess {
        RemoteMediaAccess(url: URL(string: "https://example.test/media")!, expiresAt: Date().addingTimeInterval(ttl))
    }

    func commitManifest(descriptor: MediaStreamingMeetingDescriptor, media: [MediaStreamingMediaResult]) async throws {
        manifestCommits.append(media)
    }

    func uploadedParts(for kind: MeetingMediaKind) -> [RecordedPart] { parts[kind] ?? [] }
    func completionCount() -> Int { completions }
    func manifestCommitCount() -> Int { manifestCommits.count }
    func lastManifestMedia() -> [MediaStreamingMediaResult] { manifestCommits.last ?? [] }
}

private actor BlockingMediaStreamingTransport: MediaStreamingTransport {
    private var shouldBlock = true
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func prepareMeeting(_ descriptor: MediaStreamingMeetingDescriptor) async throws {}

    func beginUpload(meetingID: UUID, kind: MeetingMediaKind, contentType: String) async throws -> MediaMultipartUpload {
        MediaMultipartUpload(
            meetingID: meetingID,
            kind: kind,
            uploadID: "blocked",
            objectKey: "blocked.mp4",
            contentType: contentType,
            backend: .managed,
            storageScope: "https://example.test"
        )
    }

    func uploadPart(_ data: Data, partNumber: Int, upload: MediaMultipartUpload) async throws -> MediaUploadedPart {
        if shouldBlock {
            await withCheckedContinuation { continuations.append($0) }
        }
        return MediaUploadedPart(partNumber: partNumber, etag: "etag-\(partNumber)")
    }

    func completeUpload(_ upload: MediaMultipartUpload, parts: [MediaUploadedPart]) async throws -> MediaCompletedUpload {
        MediaCompletedUpload(objectKey: upload.objectKey)
    }

    func abortUpload(_ upload: MediaMultipartUpload) async throws {}
    func deleteProvisionalMeeting(meetingID: UUID) async throws {}
    func deleteMedia(meetingID: UUID, kind: MeetingMediaKind) async throws {}

    func accessURL(meetingID: UUID, kind: MeetingMediaKind, ttl: TimeInterval) async throws -> RemoteMediaAccess {
        RemoteMediaAccess(url: URL(string: "https://example.test/media")!, expiresAt: Date().addingTimeInterval(ttl))
    }

    func commitManifest(descriptor: MediaStreamingMeetingDescriptor, media: [MediaStreamingMediaResult]) async throws {}

    func releaseUploads() {
        shouldBlock = false
        let waiting = continuations
        continuations.removeAll()
        waiting.forEach { $0.resume() }
    }
}
