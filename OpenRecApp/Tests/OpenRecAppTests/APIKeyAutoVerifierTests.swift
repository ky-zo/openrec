import XCTest
@testable import OpenRecApp

private actor AutoVerifyGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func openAll() {
        let waiting = continuations
        continuations.removeAll()
        waiting.forEach { $0.resume() }
    }
}

final class APIKeyAutoVerifierTests: XCTestCase {
    func testOpenAICredentialFailureClassificationPreservesVerifiedKeysOffline() {
        XCTAssertTrue(OpenAIService.isCredentialOrModelAccessFailure(
            OpenRecError.requestFailed(status: 401, message: "Unauthorized")
        ))
        XCTAssertTrue(OpenAIService.isCredentialOrModelAccessFailure(
            OpenRecError.requestFailed(status: 403, message: "Forbidden")
        ))
        XCTAssertTrue(OpenAIService.isCredentialOrModelAccessFailure(
            OpenRecError.requestFailed(status: 404, message: "Model unavailable")
        ))
        XCTAssertFalse(OpenAIService.isCredentialOrModelAccessFailure(
            OpenRecError.requestFailed(status: 429, message: "Rate limited")
        ))
        XCTAssertFalse(OpenAIService.isCredentialOrModelAccessFailure(
            OpenRecError.invalidResponse("Offline")
        ))
    }

    @MainActor
    func testAutomaticVerificationDebouncesAndUsesTheTrimmedSnapshot() async {
        let sleepStarted = expectation(description: "debounce started")
        let validationStarted = expectation(description: "validation started")
        let completed = expectation(description: "validation completed")
        let gate = AutoVerifyGate()
        let rawKey = "  " + String(repeating: "a", count: 32) + "\n"
        var currentKey = rawKey
        var validatedKey: String?
        let verifier = APIKeyAutoVerifier(
            debounceNanoseconds: 123,
            sleeper: { nanoseconds in
                XCTAssertEqual(nanoseconds, 123)
                sleepStarted.fulfill()
                await gate.wait()
            }
        )

        verifier.submit(
            key: rawKey,
            trigger: .automatic,
            currentKey: { currentKey },
            onRunning: { validationStarted.fulfill() },
            validate: {
                validatedKey = $0
            },
            onCompletion: { _, result in
                if case .failure(let error) = result {
                    XCTFail("Unexpected failure: \(error)")
                }
                completed.fulfill()
            }
        )

        await fulfillment(of: [sleepStarted], timeout: 1)
        XCTAssertNil(validatedKey)
        await gate.openAll()
        await fulfillment(of: [validationStarted, completed], timeout: 1)
        XCTAssertEqual(validatedKey, String(repeating: "a", count: 32))
        currentKey = ""
    }

    @MainActor
    func testLateResultForReplacedKeyCannotComplete() async {
        let firstStarted = expectation(description: "first validation started")
        let secondCompleted = expectation(description: "second validation completed")
        let staleCompletion = expectation(description: "stale completion")
        staleCompletion.isInverted = true
        let firstGate = AutoVerifyGate()
        let firstKey = String(repeating: "a", count: 32)
        let secondKey = String(repeating: "b", count: 32)
        var currentKey = firstKey
        let verifier = APIKeyAutoVerifier(debounceNanoseconds: 0)

        verifier.submit(
            key: firstKey,
            trigger: .immediate,
            currentKey: { currentKey },
            onRunning: {},
            validate: { _ in
                firstStarted.fulfill()
                await firstGate.wait()
            },
            onCompletion: { _, _ in staleCompletion.fulfill() }
        )

        await fulfillment(of: [firstStarted], timeout: 1)
        currentKey = secondKey
        verifier.submit(
            key: secondKey,
            trigger: .immediate,
            currentKey: { currentKey },
            onRunning: {},
            validate: { _ in },
            onCompletion: { key, result in
                XCTAssertEqual(key, secondKey)
                if case .failure(let error) = result {
                    XCTFail("Unexpected failure: \(error)")
                }
                secondCompleted.fulfill()
            }
        )

        await fulfillment(of: [secondCompleted], timeout: 1)
        await firstGate.openAll()
        await fulfillment(of: [staleCompletion], timeout: 0.15)
    }

    @MainActor
    func testShortAutomaticCandidateMakesNoRequest() async {
        var sleepCount = 0
        var validationCount = 0
        let verifier = APIKeyAutoVerifier(
            debounceNanoseconds: 0,
            sleeper: { _ in sleepCount += 1 }
        )

        verifier.submit(
            key: "sk-short",
            trigger: .automatic,
            currentKey: { "sk-short" },
            onRunning: {},
            validate: { _ in validationCount += 1 },
            onCompletion: { _, _ in XCTFail("Short keys should not auto-verify") }
        )
        await Task.yield()

        XCTAssertEqual(sleepCount, 0)
        XCTAssertEqual(validationCount, 0)
    }

    @MainActor
    func testManualVerificationReplacesPendingDebounceWithoutDuplicatingRequest() async {
        let sleepStarted = expectation(description: "automatic debounce started")
        let manualCompleted = expectation(description: "manual validation completed")
        let staleCompletion = expectation(description: "automatic completion")
        staleCompletion.isInverted = true
        let gate = AutoVerifyGate()
        let key = String(repeating: "c", count: 32)
        var validationCount = 0
        let verifier = APIKeyAutoVerifier(
            debounceNanoseconds: 1,
            sleeper: { _ in
                sleepStarted.fulfill()
                await gate.wait()
            }
        )

        verifier.submit(
            key: key,
            trigger: .automatic,
            currentKey: { key },
            onRunning: {},
            validate: { _ in validationCount += 1 },
            onCompletion: { _, _ in staleCompletion.fulfill() }
        )
        await fulfillment(of: [sleepStarted], timeout: 1)

        verifier.submit(
            key: key,
            trigger: .immediate,
            currentKey: { key },
            onRunning: {},
            validate: { _ in validationCount += 1 },
            onCompletion: { _, _ in manualCompleted.fulfill() }
        )
        await fulfillment(of: [manualCompleted], timeout: 1)
        await gate.openAll()
        await fulfillment(of: [staleCompletion], timeout: 0.15)

        XCTAssertEqual(validationCount, 1)
    }
}
