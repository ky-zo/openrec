import Foundation

/// Debounces API-key checks and prevents an older network response from
/// verifying a key that has since been replaced.
@MainActor
final class APIKeyAutoVerifier: ObservableObject {
    typealias Sleeper = (UInt64) async throws -> Void

    enum Trigger {
        case automatic
        case immediate
    }

    static let defaultDebounceNanoseconds: UInt64 = 450_000_000
    static let automaticMinimumLength = 20

    private let debounceNanoseconds: UInt64
    private let sleeper: Sleeper
    private var task: Task<Void, Never>?
    private var revision = 0

    init(
        debounceNanoseconds: UInt64 = 450_000_000,
        sleeper: @escaping Sleeper = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.debounceNanoseconds = debounceNanoseconds
        self.sleeper = sleeper
    }

    deinit {
        task?.cancel()
    }

    static func normalized(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isPlausibleForAutomaticVerification(_ key: String) -> Bool {
        let key = normalized(key)
        return key.count >= automaticMinimumLength
            && !key.contains(where: { $0.isWhitespace })
    }

    func submit(
        key rawKey: String,
        trigger: Trigger,
        currentKey: @escaping () -> String,
        onRunning: @escaping () -> Void,
        validate: @escaping (String) async throws -> Void,
        onCompletion: @escaping (String, Result<Void, Error>) -> Void
    ) {
        let delayNanoseconds: UInt64
        switch trigger {
        case .automatic:
            guard Self.isPlausibleForAutomaticVerification(rawKey) else {
                cancel()
                return
            }
            delayNanoseconds = debounceNanoseconds
        case .immediate:
            guard !Self.normalized(rawKey).isEmpty else {
                cancel()
                return
            }
            delayNanoseconds = 0
        }

        start(
            key: rawKey,
            delayNanoseconds: delayNanoseconds,
            currentKey: currentKey,
            onRunning: onRunning,
            validate: validate,
            onCompletion: onCompletion
        )
    }

    func cancel() {
        revision += 1
        task?.cancel()
        task = nil
    }

    private func start(
        key rawKey: String,
        delayNanoseconds: UInt64,
        currentKey: @escaping () -> String,
        onRunning: @escaping () -> Void,
        validate: @escaping (String) async throws -> Void,
        onCompletion: @escaping (String, Result<Void, Error>) -> Void
    ) {
        revision += 1
        let requestRevision = revision
        let key = Self.normalized(rawKey)
        let sleeper = self.sleeper
        task?.cancel()

        task = Task { [weak self] in
            if delayNanoseconds > 0 {
                do {
                    try await sleeper(delayNanoseconds)
                } catch {
                    return
                }
            }

            guard self?.isCurrent(
                revision: requestRevision,
                key: key,
                currentKey: currentKey
            ) == true else { return }

            onRunning()
            let result: Result<Void, Error>
            do {
                try await validate(key)
                result = .success(())
            } catch {
                result = .failure(error)
            }

            guard self?.isCurrent(
                revision: requestRevision,
                key: key,
                currentKey: currentKey
            ) == true else { return }

            self?.task = nil
            onCompletion(key, result)
        }
    }

    private func isCurrent(
        revision requestRevision: Int,
        key: String,
        currentKey: () -> String
    ) -> Bool {
        !Task.isCancelled
            && revision == requestRevision
            && Self.normalized(currentKey()) == key
    }
}
