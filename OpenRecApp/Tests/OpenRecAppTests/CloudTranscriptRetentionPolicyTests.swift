import XCTest
@testable import OpenRecApp

final class CloudTranscriptRetentionPolicyTests: XCTestCase {
    func testRequestedTranscriptFailureIsRecoverableAndActionable() {
        XCTAssertThrowsError(
            try CloudTranscriptRetentionPolicy.validatedTranscript(
                "partial text that must not mask a failed transcription",
                required: true,
                failureDescription: "The transcription request timed out"
            )
        ) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("timed out"))
            XCTAssertTrue(message.contains("kept the recording needed for retry"))
            XCTAssertTrue(message.contains("AssemblyAI API key"))
            XCTAssertTrue(message.contains("retry this meeting"))
        }
    }

    func testRequestedWhitespaceOnlyTranscriptFailsBeforeRetention() {
        XCTAssertThrowsError(
            try CloudTranscriptRetentionPolicy.validatedTranscript(
                "  \n\t  ",
                required: true
            )
        ) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("empty transcript"))
            XCTAssertTrue(message.contains("kept the recording needed for retry"))
        }
    }

    func testOptionalTranscriptFailureDoesNotBlockSaving() throws {
        let transcript = try CloudTranscriptRetentionPolicy.validatedTranscript(
            "",
            required: false,
            failureDescription: "AssemblyAI unavailable"
        )

        XCTAssertEqual(transcript, "")
    }

    func testRecoveryRetranscribesMissingRequiredTranscriptEvenWhenInsightsExist() {
        XCTAssertTrue(
            CloudTranscriptRetentionPolicy.shouldAttemptTranscription(
                storedTranscript: nil,
                hasStoredInsights: true,
                hasRetryMedia: true,
                storeTranscriptInCloud: true
            )
        )
        XCTAssertFalse(
            CloudTranscriptRetentionPolicy.shouldAttemptTranscription(
                storedTranscript: "Recovered transcript",
                hasStoredInsights: true,
                hasRetryMedia: true,
                storeTranscriptInCloud: true
            )
        )
    }

    func testRecoveryCannotAttemptTranscriptionWithoutRetryMedia() {
        XCTAssertFalse(
            CloudTranscriptRetentionPolicy.shouldAttemptTranscription(
                storedTranscript: nil,
                hasStoredInsights: false,
                hasRetryMedia: false,
                storeTranscriptInCloud: true
            )
        )
    }

    func testSuccessfulRetryReappliesOriginalMediaRetentionChoices() {
        XCTAssertFalse(
            CloudTranscriptRetentionPolicy.shouldKeepMediaAfterSuccessfulProcessing(
                retentionRequested: false,
                preserveWebhookRecovery: false,
                deletionScheduled: false
            )
        )
        XCTAssertTrue(
            CloudTranscriptRetentionPolicy.shouldKeepMediaAfterSuccessfulProcessing(
                retentionRequested: true,
                preserveWebhookRecovery: false,
                deletionScheduled: false
            )
        )
        XCTAssertTrue(
            CloudTranscriptRetentionPolicy.shouldKeepMediaAfterSuccessfulProcessing(
                retentionRequested: false,
                preserveWebhookRecovery: true,
                deletionScheduled: false
            )
        )
    }
}
