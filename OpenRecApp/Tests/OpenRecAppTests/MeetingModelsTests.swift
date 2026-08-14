import Foundation
import XCTest
@testable import OpenRecApp

final class MeetingModelsTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenRecAppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    func testAppVersionPresentationIncludesMarketingVersionAndBuild() {
        XCTAssertEqual(
            AppVersionPresentation.label(infoDictionary: [
                "CFBundleShortVersionString": "0.3.2",
                "CFBundleVersion": "19",
            ]),
            "v0.3.2 (19)"
        )
        XCTAssertEqual(
            AppVersionPresentation.label(infoDictionary: ["CFBundleShortVersionString": "0.3.2"]),
            "v0.3.2"
        )
        XCTAssertEqual(AppVersionPresentation.label(infoDictionary: [:]), "dev build")
    }

    func testMeetingRecordJSONRoundTripPreservesLibraryState() throws {
        var record = makeRecord(
            transcript: "[Me] We should ship this.\n[Others] Agreed.",
            hasScreenRecording: true,
            hasAudioRecording: true,
            localScreenPath: "/tmp/openrec/screen.mp4",
            localAudioPath: "/tmp/openrec/audio.m4a",
            preferences: CallPreferences(
                keepScreenRecording: true,
                keepAudioRecording: false,
                storeTranscriptInCloud: true,
                sendToWebhook: true
            ),
            saveStatus: .failed,
            saveStage: .deliveringWebhook,
            errorMessage: "Webhook unavailable"
        )
        let cleanupAt = Date(timeIntervalSince1970: 2_000_000_000)
        record.screenDeletionScheduledAt = cleanupAt
        record.audioDeletionScheduledAt = cleanupAt

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(MeetingRecord.self, from: encoder.encode(record))

        XCTAssertEqual(decoded.id, record.id)
        XCTAssertEqual(decoded.startedAt, record.startedAt)
        XCTAssertEqual(decoded.endedAt, record.endedAt)
        XCTAssertEqual(decoded.durationSeconds, record.durationSeconds)
        XCTAssertEqual(decoded.callApp, record.callApp)
        XCTAssertEqual(decoded.callTitle, record.callTitle)
        XCTAssertEqual(decoded.transcript, record.transcript)
        XCTAssertEqual(decoded.insights.title, record.insights.title)
        XCTAssertEqual(decoded.insights.summary, record.insights.summary)
        XCTAssertEqual(decoded.insights.participants, record.insights.participants)
        XCTAssertEqual(decoded.insights.actionItems.map(\.owner), record.insights.actionItems.map(\.owner))
        XCTAssertEqual(decoded.insights.actionItems.map(\.task), record.insights.actionItems.map(\.task))
        XCTAssertEqual(decoded.insights.actionItems.map(\.dueDate), record.insights.actionItems.map(\.dueDate))
        XCTAssertEqual(decoded.insights.decisions, record.insights.decisions)
        XCTAssertEqual(decoded.hasScreenRecording, record.hasScreenRecording)
        XCTAssertEqual(decoded.hasAudioRecording, record.hasAudioRecording)
        XCTAssertEqual(decoded.screenFileExtension, record.screenFileExtension)
        XCTAssertEqual(decoded.audioFileExtension, record.audioFileExtension)
        XCTAssertEqual(decoded.localScreenPath, record.localScreenPath)
        XCTAssertEqual(decoded.localAudioPath, record.localAudioPath)
        XCTAssertEqual(decoded.storageMode, record.storageMode)
        XCTAssertEqual(decoded.preferences, record.preferences)
        XCTAssertEqual(decoded.saveStatus, record.saveStatus)
        XCTAssertEqual(decoded.saveStage, record.saveStage)
        XCTAssertEqual(decoded.errorMessage, record.errorMessage)
        XCTAssertEqual(decoded.webhookDeliveryStatus, record.webhookDeliveryStatus)
        XCTAssertEqual(decoded.webhookErrorMessage, record.webhookErrorMessage)
        XCTAssertEqual(decoded.screenDeletionScheduledAt, cleanupAt)
        XCTAssertEqual(decoded.audioDeletionScheduledAt, cleanupAt)
        XCTAssertEqual(decoded.createdAt, record.createdAt)
        XCTAssertEqual(decoded.updatedAt, record.updatedAt)
    }

    func testMeetingRecordPayloadRetainsTranscriptWhenPresent() {
        let record = makeRecord(transcript: "A retained transcript")

        let payload = record.payload

        XCTAssertEqual(payload.id, record.id)
        XCTAssertEqual(payload.startedAt, record.startedAt)
        XCTAssertEqual(payload.endedAt, record.endedAt)
        XCTAssertEqual(payload.callApp, record.callApp)
        XCTAssertEqual(payload.callTitle, record.callTitle)
        XCTAssertEqual(payload.transcript, "A retained transcript")
        XCTAssertEqual(payload.insights, record.insights)
        XCTAssertEqual(payload.durationSeconds, record.durationSeconds)
    }

    func testMeetingRecordPayloadOmitsTranscriptAsEmptyStringWhenNotRetained() {
        let record = makeRecord(transcript: nil)

        XCTAssertEqual(record.payload.transcript, "")
    }

    func testCallPreferencesDefaultsAndCodableRoundTrip() throws {
        let defaults = CallPreferences()

        XCTAssertTrue(defaults.keepScreenRecording)
        XCTAssertTrue(defaults.keepAudioRecording)
        XCTAssertTrue(defaults.storeTranscriptInCloud)
        XCTAssertFalse(defaults.sendToWebhook)

        let customized = CallPreferences(
            keepScreenRecording: false,
            keepAudioRecording: true,
            storeTranscriptInCloud: false,
            sendToWebhook: true
        )
        let decoded = try JSONDecoder().decode(
            CallPreferences.self,
            from: JSONEncoder().encode(customized)
        )

        XCTAssertEqual(decoded, customized)
    }

    func testPlayableLocalMediaRequiresAnExistingFileWhenRemoteMediaIsAbsent() throws {
        let screenURL = temporaryDirectory.appendingPathComponent("recording.mp4")
        let audioURL = temporaryDirectory.appendingPathComponent("audio.m4a")
        let record = makeRecord(
            hasScreenRecording: false,
            hasAudioRecording: false,
            localScreenPath: screenURL.path,
            localAudioPath: audioURL.path
        )

        XCTAssertNil(record.localScreenURL)
        XCTAssertNil(record.localAudioURL)
        XCTAssertFalse(record.hasPlayableScreen)
        XCTAssertFalse(record.hasPlayableAudio)

        try Data("screen".utf8).write(to: screenURL)
        try Data("audio".utf8).write(to: audioURL)

        XCTAssertEqual(record.localScreenURL, screenURL)
        XCTAssertEqual(record.localAudioURL, audioURL)
        XCTAssertTrue(record.hasPlayableScreen)
        XCTAssertTrue(record.hasPlayableAudio)

        try FileManager.default.removeItem(at: screenURL)
        try FileManager.default.removeItem(at: audioURL)

        XCTAssertNil(record.localScreenURL)
        XCTAssertNil(record.localAudioURL)
        XCTAssertFalse(record.hasPlayableScreen)
        XCTAssertFalse(record.hasPlayableAudio)
    }

    func testRemoteMediaRemainsPlayableWithoutLocalFiles() {
        let record = makeRecord(
            hasScreenRecording: true,
            hasAudioRecording: true,
            localScreenPath: temporaryDirectory.appendingPathComponent("missing.mp4").path,
            localAudioPath: temporaryDirectory.appendingPathComponent("missing.m4a").path
        )

        XCTAssertNil(record.localScreenURL)
        XCTAssertNil(record.localAudioURL)
        XCTAssertTrue(record.hasPlayableScreen)
        XCTAssertTrue(record.hasPlayableAudio)
    }

    func testSavedWebhookRecoveryFilesStayHiddenWhenRetentionIsOff() throws {
        let screenURL = temporaryDirectory.appendingPathComponent("webhook-recovery.mp4")
        try Data("screen".utf8).write(to: screenURL)
        let preferences = CallPreferences(
            keepScreenRecording: false,
            keepAudioRecording: false,
            storeTranscriptInCloud: true,
            sendToWebhook: true
        )
        var saved = makeRecord(
            localScreenPath: screenURL.path,
            preferences: preferences,
            saveStatus: .saved
        )
        saved.webhookDeliveryStatus = .failed

        XCTAssertNotNil(saved.localScreenURL)
        XCTAssertFalse(saved.hasPlayableScreen)

        saved.saveStatus = .failed
        XCTAssertTrue(saved.hasPlayableScreen)
    }

    func testFailedSaveRetryAcceptsCloudMediaOrAnExistingLegacyRecoveryFile() {
        let path = temporaryDirectory.appendingPathComponent("recovery.mp4").path
        let failed = makeRecord(localScreenPath: path, saveStatus: .failed)

        let available = MeetingSaveRecovery.evaluate(for: failed) { $0 == path }
        XCTAssertTrue(available.canRetry)
        XCTAssertEqual(available.screenURL, URL(fileURLWithPath: path))
        XCTAssertNil(available.unavailableReason)

        let missing = MeetingSaveRecovery.evaluate(for: failed) { _ in false }
        XCTAssertFalse(missing.canRetry)
        XCTAssertNil(missing.screenURL)
        XCTAssertTrue(missing.unavailableReason?.contains("missing") == true)

        var cloud = makeRecord(saveStatus: .failed)
        cloud.hasAudioRecording = true
        let cloudRecovery = MeetingSaveRecovery.evaluate(for: cloud) { _ in false }
        XCTAssertTrue(cloudRecovery.canRetry)
        XCTAssertTrue(cloudRecovery.cloudMediaAvailable)
        XCTAssertNil(cloudRecovery.screenURL)
        XCTAssertNil(cloudRecovery.unavailableReason)

        let saved = makeRecord(localScreenPath: path, saveStatus: .saved)
        let notFailed = MeetingSaveRecovery.evaluate(for: saved) { _ in true }
        XCTAssertFalse(notFailed.canRetry)
        XCTAssertNil(notFailed.unavailableReason)
    }

    func testEmptyTranscriptMessageReflectsTheCallPreference() {
        let disabled = makeRecord(
            transcript: nil,
            preferences: CallPreferences(
                keepScreenRecording: true,
                keepAudioRecording: true,
                storeTranscriptInCloud: false,
                sendToWebhook: false
            )
        )
        let enabled = makeRecord(transcript: nil)

        XCTAssertEqual(
            MeetingLibraryPresentation.emptyTranscriptMessage(for: disabled),
            "No transcript was stored for this call."
        )
        XCTAssertEqual(
            MeetingLibraryPresentation.emptyTranscriptMessage(for: enabled),
            "Transcript storage was enabled, but no transcript is available for this meeting."
        )
    }

    func testMeetingClipboardTextProvidesEachVisibleSectionAndCopyAll() {
        var meeting = makeRecord(transcript: "[Kamil] Ship it.\n[Alex] Agreed.")
        meeting.insights.aiNotes = "## Highlights\n- Release is ready."

        XCTAssertEqual(MeetingClipboardText.participants(for: meeting), "Kamil, Alex")
        XCTAssertEqual(MeetingClipboardText.summary(for: meeting), "The team agreed on the next release.")
        XCTAssertEqual(MeetingClipboardText.aiNotes(for: meeting), "## Highlights\n- Release is ready.")
        XCTAssertEqual(
            MeetingClipboardText.nextSteps(for: meeting),
            "• Kamil: Ship the release — 2026-08-12"
        )
        XCTAssertEqual(MeetingClipboardText.decisions(for: meeting), "• Release on Wednesday")
        XCTAssertEqual(MeetingClipboardText.transcript(for: meeting), "[Kamil] Ship it.\n[Alex] Agreed.")
        XCTAssertEqual(
            MeetingClipboardText.meeting(meeting),
            """
            Product review

            Participants
            Kamil, Alex

            Summary
            The team agreed on the next release.

            AI Notes
            ## Highlights
            - Release is ready.

            Next steps
            • Kamil: Ship the release — 2026-08-12

            Decisions
            • Release on Wednesday

            Transcript
            [Kamil] Ship it.
            [Alex] Agreed.
            """
        )
    }

    func testMeetingClipboardTextOmitsEmptySections() {
        var meeting = makeRecord(transcript: "  \n")
        meeting.insights.summary = ""
        meeting.insights.aiNotes = ""
        meeting.insights.participants = []
        meeting.insights.actionItems = []
        meeting.insights.decisions = []

        XCTAssertNil(MeetingClipboardText.transcript(for: meeting))
        XCTAssertEqual(MeetingClipboardText.meeting(meeting), "Product review")
    }

    func testManagedSignOutStubScrubsPrivateMeetingMemoryButKeepsRecoveryLink() {
        let path = temporaryDirectory.appendingPathComponent("managed-recovery.mp4").path
        let managed = makeRecord(localScreenPath: path, saveStatus: .failed)

        let stub = ManagedSignOutPrivacy.scrubbedArtifactStub(from: managed) { $0 == path }

        XCTAssertNotNil(stub)
        XCTAssertNil(stub?.callApp)
        XCTAssertNil(stub?.callTitle)
        XCTAssertNil(stub?.transcript)
        XCTAssertTrue(stub?.insights.participants.isEmpty == true)
        XCTAssertTrue(stub?.insights.summary.isEmpty == true)
        XCTAssertEqual(stub?.localScreenPath, path)
        XCTAssertEqual(stub?.saveStatus, .failed)
        XCTAssertTrue(stub?.errorMessage?.contains("Sign in again") == true)
    }

    func testManagedSignOutDropsSyncedRecordWithoutLocalArtifacts() {
        let managed = makeRecord(localScreenPath: nil, localAudioPath: nil, saveStatus: .saved)

        let stub = ManagedSignOutPrivacy.scrubbedArtifactStub(from: managed) { _ in false }

        XCTAssertNil(stub)
    }

    func testManagedSignOutPreservesDeferredCloudMediaCleanupWithoutLocalFiles() {
        let cleanupAt = Date(timeIntervalSince1970: 2_000_000_000)
        var meeting = makeRecord(
            hasScreenRecording: true,
            hasAudioRecording: true,
            saveStatus: .saved
        )
        meeting.webhookDeliveryStatus = .delivered
        meeting.screenDeletionScheduledAt = cleanupAt
        meeting.audioDeletionScheduledAt = cleanupAt

        let stub = ManagedSignOutPrivacy.scrubbedArtifactStub(from: meeting) { _ in false }

        XCTAssertNotNil(stub)
        XCTAssertNil(stub?.callTitle)
        XCTAssertNil(stub?.transcript)
        XCTAssertEqual(stub?.screenDeletionScheduledAt, cleanupAt)
        XCTAssertEqual(stub?.audioDeletionScheduledAt, cleanupAt)
    }

    func testMeetingRecordDecodesBeforeWebhookStatusFieldsExisted() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(makeRecord())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "webhookDeliveryStatus")
        object.removeValue(forKey: "webhookErrorMessage")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(MeetingRecord.self, from: legacyData)

        XCTAssertNil(decoded.webhookDeliveryStatus)
        XCTAssertNil(decoded.webhookErrorMessage)
    }

    func testR2ListSignaturePreservesPrefixAndContinuationToken() throws {
        let signer = R2RequestSigner(
            accountID: "account-id",
            bucket: "meeting bucket",
            accessKeyID: "access-key",
            secretAccessKey: "secret-key"
        )
        let request = try signer.signedListRequest(
            prefix: "meetings/",
            continuationToken: "next+/=token",
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let components = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.host, "account-id.r2.cloudflarestorage.com")
        XCTAssertEqual(request.url?.path, "/meeting bucket")
        XCTAssertTrue(request.url?.absoluteString.contains("/meeting%20bucket/?") == true)
        XCTAssertEqual(values["list-type"], "2")
        XCTAssertEqual(values["prefix"], "meetings/")
        XCTAssertEqual(values["continuation-token"], "next+/=token")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("AWS4-HMAC-SHA256 Credential=access-key/") == true)
    }

    func testR2ListParserFindsOnlyObjectKeysAndPagination() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult>
          <IsTruncated>true</IsTruncated>
          <Contents><Key>meetings/a/meeting.json</Key></Contents>
          <Contents><Key>meetings/a/screen.mp4</Key></Contents>
          <NextContinuationToken>next-token</NextContinuationToken>
        </ListBucketResult>
        """
        let parser = R2ListObjectsParser()

        try parser.parse(Data(xml.utf8))

        XCTAssertEqual(parser.keys, ["meetings/a/meeting.json", "meetings/a/screen.mp4"])
        XCTAssertTrue(parser.isTruncated)
        XCTAssertEqual(parser.nextContinuationToken, "next-token")
    }

    private func makeRecord(
        transcript: String? = "Transcript",
        hasScreenRecording: Bool = false,
        hasAudioRecording: Bool = false,
        localScreenPath: String? = nil,
        localAudioPath: String? = nil,
        preferences: CallPreferences = CallPreferences(),
        saveStatus: MeetingSaveStatus = .saved,
        saveStage: MeetingSaveStage = .complete,
        errorMessage: String? = nil
    ) -> MeetingRecord {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let endedAt = startedAt.addingTimeInterval(1_845)
        return MeetingRecord(
            id: UUID(uuidString: "B8E17C31-12A5-4C0A-9BC7-573E180DB52E")!,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: 1_845,
            callApp: "Google Chrome",
            callTitle: "Weekly product review",
            transcript: transcript,
            insights: MeetingInsights(
                title: "Product review",
                summary: "The team agreed on the next release.",
                participants: ["Kamil", "Alex"],
                actionItems: [
                    MeetingActionItem(owner: "Kamil", task: "Ship the release", dueDate: "2026-08-12")
                ],
                decisions: ["Release on Wednesday"]
            ),
            hasScreenRecording: hasScreenRecording,
            hasAudioRecording: hasAudioRecording,
            screenFileExtension: hasScreenRecording || localScreenPath != nil ? "mp4" : nil,
            audioFileExtension: hasAudioRecording || localAudioPath != nil ? "m4a" : nil,
            localScreenPath: localScreenPath,
            localAudioPath: localAudioPath,
            storageMode: .managed,
            preferences: preferences,
            saveStatus: saveStatus,
            saveStage: saveStage,
            errorMessage: errorMessage,
            createdAt: endedAt,
            updatedAt: endedAt.addingTimeInterval(30)
        )
    }
}
