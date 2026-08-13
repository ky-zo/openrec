import Foundation

extension MeetingMediaKind: @unchecked Sendable {}

enum MediaStreamingState: Equatable, Sendable {
    case preparing
    case streaming
    case finishing
    case completed
    case aborted
    case failed(String)
}

struct MediaStreamingProgress: Equatable, Sendable {
    let pendingBytes: Int
    let uploadedBytes: Int
    let acceptedBytes: Int
    let maximumPendingBytes: Int
    let uploadedParts: Int
    let state: MediaStreamingState

    var errorMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    var pendingFraction: Double {
        guard maximumPendingBytes > 0 else { return 0 }
        return min(1, Double(pendingBytes) / Double(maximumPendingBytes))
    }
}

typealias MediaStreamingProgressHandler = @MainActor @Sendable (MediaStreamingProgress) -> Void

struct RemoteMediaAccess: Equatable, Sendable {
    let url: URL
    let expiresAt: Date
}

struct MediaStreamingMediaResult: Equatable, Sendable {
    let kind: MeetingMediaKind
    let objectKey: String
    let contentType: String
    let byteCount: Int
    let partCount: Int
}

struct MediaStreamingResult: Equatable, Sendable {
    let meetingID: UUID
    let media: [MediaStreamingMediaResult]
}

enum MediaStreamingError: LocalizedError, Equatable, Sendable {
    case noMediaSelected
    case mediaWasNotSelected(MeetingMediaKind)
    case duplicateSequence(kind: MeetingMediaKind, sequence: Int)
    case sequenceTooFarAhead(kind: MeetingMediaKind, expected: Int, received: Int, window: Int)
    case sequenceGap(kind: MeetingMediaKind, expected: Int, nextReceived: Int)
    case backpressure(limit: Int, pending: Int, attempted: Int)
    case invalidState(String)
    case emptyStream(MeetingMediaKind)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .noMediaSelected:
            return "Choose at least one recording stream before starting cloud upload."
        case .mediaWasNotSelected(let kind):
            return "The \(kind.label.lowercased()) stream was not enabled for this recording."
        case .duplicateSequence(let kind, let sequence):
            return "The \(kind.label.lowercased()) stream sent duplicate chunk \(sequence)."
        case .sequenceTooFarAhead(let kind, let expected, let received, let window):
            return "The \(kind.label.lowercased()) stream skipped too far ahead (expected \(expected), received \(received); reorder window \(window))."
        case .sequenceGap(let kind, let expected, let nextReceived):
            return "The \(kind.label.lowercased()) stream is missing chunk \(expected) before chunk \(nextReceived)."
        case .backpressure(let limit, let pending, let attempted):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return "Cloud upload could not keep up. \(formatter.string(fromByteCount: Int64(pending))) is pending and the next \(formatter.string(fromByteCount: Int64(attempted))) chunk would exceed the \(formatter.string(fromByteCount: Int64(limit))) safety limit."
        case .invalidState(let message), .transport(let message):
            return message
        case .emptyStream(let kind):
            return "The \(kind.label.lowercased()) stream ended before it produced any media."
        }
    }
}

struct MediaStreamingMeetingDescriptor: Sendable {
    let meetingID: UUID
    let startedAt: Date
    let callApp: String?
    let callTitle: String?

    var provisionalPayload: MeetingPayload {
        MeetingPayload(
            id: meetingID,
            startedAt: startedAt,
            endedAt: startedAt,
            callApp: callApp,
            callTitle: callTitle,
            transcript: "",
            insights: MeetingInsights(),
            durationSeconds: 0
        )
    }
}

struct MediaMultipartUpload: Sendable {
    let meetingID: UUID
    let kind: MeetingMediaKind
    let uploadID: String
    let objectKey: String
    let contentType: String
    let backend: MediaStreamingBackend
    let storageScope: String
}

struct MediaUploadedPart: Codable, Equatable, Sendable {
    let partNumber: Int
    let etag: String
}

struct MediaCompletedUpload: Equatable, Sendable {
    let objectKey: String
}

protocol MediaStreamingTransport: Sendable {
    func prepareMeeting(_ descriptor: MediaStreamingMeetingDescriptor) async throws
    func beginUpload(
        meetingID: UUID,
        kind: MeetingMediaKind,
        contentType: String
    ) async throws -> MediaMultipartUpload
    func uploadPart(
        _ data: Data,
        partNumber: Int,
        upload: MediaMultipartUpload
    ) async throws -> MediaUploadedPart
    func completeUpload(
        _ upload: MediaMultipartUpload,
        parts: [MediaUploadedPart]
    ) async throws -> MediaCompletedUpload
    func abortUpload(_ upload: MediaMultipartUpload) async throws
    func deleteProvisionalMeeting(meetingID: UUID) async throws
    func deleteMedia(meetingID: UUID, kind: MeetingMediaKind) async throws
    func accessURL(
        meetingID: UUID,
        kind: MeetingMediaKind,
        ttl: TimeInterval
    ) async throws -> RemoteMediaAccess
    func commitManifest(
        descriptor: MediaStreamingMeetingDescriptor,
        media: [MediaStreamingMediaResult]
    ) async throws
}

/// Converts arbitrary ordered byte chunks into multipart upload parts. Every
/// emitted non-final part is exactly `partSize` bytes; only `finish()` may emit
/// a shorter part. CMAF init and media fragments therefore keep their original
/// byte order even when their boundaries do not align with multipart parts.
struct MultipartByteAccumulator {
    let partSize: Int
    private(set) var buffered = Data()

    init(partSize: Int = MediaStreamingSession.multipartPartSize) {
        precondition(partSize > 0)
        self.partSize = partSize
    }

    var bufferedByteCount: Int { buffered.count }

    mutating func append(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        buffered.append(data)
        var parts: [Data] = []
        while buffered.count >= partSize {
            parts.append(Data(buffered.prefix(partSize)))
            buffered.removeFirst(partSize)
        }
        return parts
    }

    mutating func finish() -> Data? {
        guard !buffered.isEmpty else { return nil }
        let final = buffered
        buffered.removeAll(keepingCapacity: false)
        return final
    }
}

actor MediaStreamingSession {
    /// R2's minimum multipart part size. Smaller parts release memory sooner
    /// during slow uploads while the independent 96 MiB cap remains strict.
    static let multipartPartSize = 5 * 1024 * 1024
    static let defaultMaximumPendingBytes = 96 * 1024 * 1024
    static let defaultReorderWindow = 32

    private struct Track {
        let upload: MediaMultipartUpload
        var accumulator: MultipartByteAccumulator
        var nextSequence = 0
        var reordered: [Int: Data] = [:]
        var nextPartNumber = 1
        var uploadedParts: [MediaUploadedPart] = []
        var acceptedBytes = 0
        var uploadedBytes = 0
        var completedObjectKey: String?
        var isAccepting = true
        var isComplete = false
    }

    private struct PendingPart {
        let kind: MeetingMediaKind
        let upload: MediaMultipartUpload
        let partNumber: Int
        let data: Data
    }

    private let descriptor: MediaStreamingMeetingDescriptor
    private let transport: any MediaStreamingTransport
    private let maximumPendingBytes: Int
    private let reorderWindow: Int
    private let progressHandler: MediaStreamingProgressHandler?
    private let journal: MediaStreamingUploadJournal
    private var tracks: [MeetingMediaKind: Track]
    private var queue: [PendingPart] = []
    private var inFlight: PendingPart?
    private var worker: Task<Void, Never>?
    private var state: MediaStreamingState = .preparing
    private var terminalError: MediaStreamingError?
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var finalizationInProgress = false

    private init(
        descriptor: MediaStreamingMeetingDescriptor,
        transport: any MediaStreamingTransport,
        uploads: [MediaMultipartUpload],
        maximumPendingBytes: Int,
        reorderWindow: Int,
        partSize: Int,
        progressHandler: MediaStreamingProgressHandler?,
        journal: MediaStreamingUploadJournal
    ) {
        self.descriptor = descriptor
        self.transport = transport
        self.maximumPendingBytes = maximumPendingBytes
        self.reorderWindow = reorderWindow
        self.progressHandler = progressHandler
        self.journal = journal
        self.tracks = Dictionary(uniqueKeysWithValues: uploads.map {
            ($0.kind, Track(upload: $0, accumulator: MultipartByteAccumulator(partSize: partSize)))
        })
        self.state = .streaming
    }

    static func begin(
        descriptor: MediaStreamingMeetingDescriptor,
        kinds: [MeetingMediaKind],
        transport: any MediaStreamingTransport,
        maximumPendingBytes: Int = defaultMaximumPendingBytes,
        reorderWindow: Int = defaultReorderWindow,
        progressHandler: MediaStreamingProgressHandler? = nil,
        journal: MediaStreamingUploadJournal = .shared
    ) async throws -> MediaStreamingSession {
        try await begin(
            descriptor: descriptor,
            kinds: kinds,
            transport: transport,
            maximumPendingBytes: maximumPendingBytes,
            reorderWindow: reorderWindow,
            partSize: multipartPartSize,
            progressHandler: progressHandler,
            journal: journal
        )
    }

    /// Internal part-size override keeps boundary and backpressure tests small;
    /// production callers always use the fixed 5 MiB overload above.
    static func begin(
        descriptor: MediaStreamingMeetingDescriptor,
        kinds: [MeetingMediaKind],
        transport: any MediaStreamingTransport,
        maximumPendingBytes: Int,
        reorderWindow: Int,
        partSize: Int,
        progressHandler: MediaStreamingProgressHandler? = nil,
        journal: MediaStreamingUploadJournal = .shared
    ) async throws -> MediaStreamingSession {
        let uniqueKinds = kinds.reduce(into: [MeetingMediaKind]()) { result, kind in
            if !result.contains(kind) { result.append(kind) }
        }
        guard !uniqueKinds.isEmpty else { throw MediaStreamingError.noMediaSelected }
        guard maximumPendingBytes >= partSize else {
            throw MediaStreamingError.invalidState("The upload safety limit must hold at least one multipart part.")
        }
        guard reorderWindow > 0 else {
            throw MediaStreamingError.invalidState("The upload reorder window must be greater than zero.")
        }

        do {
            try await transport.prepareMeeting(descriptor)
        } catch {
            // A PUT acknowledgement can be lost after the provisional managed
            // row was created. Best-effort DELETE keeps a failed start tidy.
            try? await transport.deleteProvisionalMeeting(meetingID: descriptor.meetingID)
            throw Self.transportError(error)
        }
        var uploads: [MediaMultipartUpload] = []
        do {
            for kind in uniqueKinds {
                let upload = try await transport.beginUpload(
                    meetingID: descriptor.meetingID,
                    kind: kind,
                    contentType: Self.contentType(for: kind)
                )
                do {
                    try await journal.record(upload, descriptor: descriptor)
                } catch {
                    try? await transport.abortUpload(upload)
                    throw error
                }
                uploads.append(upload)
            }
        } catch {
            for upload in uploads {
                do {
                    try await transport.abortUpload(upload)
                    try await journal.remove(upload)
                } catch {
                    // Keep the metadata entry when exact remote cleanup could
                    // not be confirmed; the next launch will retry it.
                }
            }
            try? await transport.deleteProvisionalMeeting(meetingID: descriptor.meetingID)
            throw Self.transportError(error)
        }

        let session = MediaStreamingSession(
            descriptor: descriptor,
            transport: transport,
            uploads: uploads,
            maximumPendingBytes: maximumPendingBytes,
            reorderWindow: reorderWindow,
            partSize: partSize,
            progressHandler: progressHandler,
            journal: journal
        )
        await session.publishProgress()
        return session
    }

    @discardableResult
    func append(
        _ data: Data,
        kind: MeetingMediaKind,
        sequence: Int
    ) async throws -> MediaStreamingProgress {
        try throwIfTerminal()
        guard state == .streaming else {
            throw MediaStreamingError.invalidState("This cloud upload is no longer accepting recording data.")
        }
        guard var track = tracks[kind] else {
            throw MediaStreamingError.mediaWasNotSelected(kind)
        }
        guard track.isAccepting else {
            throw MediaStreamingError.invalidState("The \(kind.label.lowercased()) stream has already finished.")
        }
        guard sequence >= track.nextSequence, track.reordered[sequence] == nil else {
            throw MediaStreamingError.duplicateSequence(kind: kind, sequence: sequence)
        }
        guard sequence - track.nextSequence < reorderWindow else {
            throw MediaStreamingError.sequenceTooFarAhead(
                kind: kind,
                expected: track.nextSequence,
                received: sequence,
                window: reorderWindow
            )
        }
        let pending = pendingByteCount
        guard data.count <= maximumPendingBytes - pending else {
            let error = MediaStreamingError.backpressure(
                limit: maximumPendingBytes,
                pending: pending,
                attempted: data.count
            )
            fail(error)
            throw error
        }

        track.reordered[sequence] = data
        track.acceptedBytes += data.count
        while let contiguous = track.reordered.removeValue(forKey: track.nextSequence) {
            let fullParts = track.accumulator.append(contiguous)
            for bytes in fullParts {
                queue.append(PendingPart(
                    kind: kind,
                    upload: track.upload,
                    partNumber: track.nextPartNumber,
                    data: bytes
                ))
                track.nextPartNumber += 1
            }
            track.nextSequence += 1
        }
        tracks[kind] = track
        startWorkerIfNeeded()
        publishProgress()
        return makeProgress()
    }

    func progressSnapshot() -> MediaStreamingProgress {
        makeProgress()
    }

    func finish(kind: MeetingMediaKind) async throws -> MediaStreamingMediaResult {
        try throwIfTerminal()
        guard var track = tracks[kind] else {
            throw MediaStreamingError.mediaWasNotSelected(kind)
        }
        if track.isComplete { return result(for: track) }
        guard !finalizationInProgress else {
            throw MediaStreamingError.invalidState("Another cloud recording stream is already being finalized.")
        }
        finalizationInProgress = true
        defer { finalizationInProgress = false }
        guard track.isAccepting else {
            throw MediaStreamingError.invalidState("The \(kind.label.lowercased()) stream is already being finalized.")
        }
        if let next = track.reordered.keys.min() {
            throw MediaStreamingError.sequenceGap(kind: kind, expected: track.nextSequence, nextReceived: next)
        }
        guard track.acceptedBytes > 0 else { throw MediaStreamingError.emptyStream(kind) }

        track.isAccepting = false
        if let finalBytes = track.accumulator.finish() {
            queue.append(PendingPart(
                kind: kind,
                upload: track.upload,
                partNumber: track.nextPartNumber,
                data: finalBytes
            ))
            track.nextPartNumber += 1
        }
        tracks[kind] = track
        if tracks.values.allSatisfy({ !$0.isAccepting }) { state = .finishing }
        startWorkerIfNeeded()
        publishProgress()

        try await waitUntilDrained(kind: kind)
        try throwIfTerminal()
        guard var drained = tracks[kind] else {
            throw MediaStreamingError.mediaWasNotSelected(kind)
        }
        do {
            let completion = try await transport.completeUpload(drained.upload, parts: drained.uploadedParts)
            guard state != .aborted else {
                throw MediaStreamingError.invalidState("This cloud upload was cancelled while it was being finalized.")
            }
            drained.completedObjectKey = completion.objectKey
            tracks[kind] = drained
            let completedResult = result(for: drained)
            if drained.upload.backend == .ownR2 {
                try await journal.markCompleted(drained.upload, result: completedResult)
            } else {
                try await journal.remove(drained.upload)
            }
        } catch {
            if state == .aborted { throw Self.transportError(error) }
            let terminal = Self.transportError(error)
            fail(terminal)
            throw terminal
        }
        drained.isComplete = true
        tracks[kind] = drained
        publishProgress()
        return result(for: drained)
    }

    func finish() async throws -> MediaStreamingResult {
        try throwIfTerminal()
        guard !finalizationInProgress else {
            throw MediaStreamingError.invalidState("This cloud recording is already being finalized.")
        }
        finalizationInProgress = true
        defer { finalizationInProgress = false }
        let kinds = tracks.keys.sorted { $0.rawValue < $1.rawValue }

        // Stop every stream before awaiting network work. This makes the state
        // and progress snapshot truthful while individual tracks complete.
        for kind in kinds {
            guard var track = tracks[kind] else { continue }
            if track.isComplete || !track.isAccepting { continue }
            if let next = track.reordered.keys.min() {
                throw MediaStreamingError.sequenceGap(kind: kind, expected: track.nextSequence, nextReceived: next)
            }
            guard track.acceptedBytes > 0 else { throw MediaStreamingError.emptyStream(kind) }
            track.isAccepting = false
            if let finalBytes = track.accumulator.finish() {
                queue.append(PendingPart(
                    kind: kind,
                    upload: track.upload,
                    partNumber: track.nextPartNumber,
                    data: finalBytes
                ))
                track.nextPartNumber += 1
            }
            tracks[kind] = track
        }
        state = .finishing
        startWorkerIfNeeded()
        publishProgress()
        try await waitUntilDrained(kind: nil)
        try throwIfTerminal()

        var completed: [MediaStreamingMediaResult] = []
        for kind in kinds {
            guard var track = tracks[kind] else { continue }
            if !track.isComplete {
                do {
                    let completion = try await transport.completeUpload(track.upload, parts: track.uploadedParts)
                    guard state != .aborted else {
                        throw MediaStreamingError.invalidState("This cloud upload was cancelled while it was being finalized.")
                    }
                    track.completedObjectKey = completion.objectKey
                    tracks[kind] = track
                    let completedResult = result(for: track)
                    if track.upload.backend == .ownR2 {
                        try await journal.markCompleted(track.upload, result: completedResult)
                    } else {
                        try await journal.remove(track.upload)
                    }
                } catch {
                    if state == .aborted { throw Self.transportError(error) }
                    let terminal = Self.transportError(error)
                    fail(terminal)
                    throw terminal
                }
                track.isComplete = true
                tracks[kind] = track
            }
            completed.append(result(for: track))
        }

        do {
            try await transport.commitManifest(descriptor: descriptor, media: completed)
            guard state != .aborted else {
                throw MediaStreamingError.invalidState("This cloud upload was cancelled while it was committing metadata.")
            }
            // BYO objects remain journaled until their manifest is durable.
            // A crash before this point can therefore rebuild discoverability.
            let recoverableUploads = tracks.values
                .filter { $0.upload.backend == .ownR2 }
                .map(\.upload)
            try await journal.removeAll(recoverableUploads)
        } catch {
            if state == .aborted { throw Self.transportError(error) }
            let terminal = Self.transportError(error)
            fail(terminal)
            throw terminal
        }
        state = .completed
        publishProgress()
        return MediaStreamingResult(meetingID: descriptor.meetingID, media: completed)
    }

    func abort(deleteCompleted: Bool = true) async {
        guard state != .aborted else { return }
        worker?.cancel()
        worker = nil
        let snapshot = Array(tracks.values)
        queue.removeAll(keepingCapacity: false)
        inFlight = nil
        if deleteCompleted, snapshot.first?.upload.backend == .managed {
            do {
                try await transport.deleteProvisionalMeeting(meetingID: descriptor.meetingID)
                for track in snapshot { try? await journal.remove(track.upload) }
                state = .aborted
                terminalError = nil
                resumeDrainWaiters()
                publishProgress()
                return
            } catch {
                // Fall back to exact per-upload aborts. Their journal entries
                // remain if the backend still cannot confirm cleanup.
            }
        }
        for track in snapshot where !track.isComplete && track.completedObjectKey == nil {
            do {
                try await transport.abortUpload(track.upload)
                try await journal.remove(track.upload)
            } catch {
                // The journal remains so a later launch can abort this exact
                // upload once the backend is reachable again.
            }
        }
        if deleteCompleted {
            for track in snapshot where track.isComplete || track.completedObjectKey != nil {
                do {
                    try await transport.deleteMedia(meetingID: descriptor.meetingID, kind: track.upload.kind)
                    try await journal.remove(track.upload)
                } catch {
                    // Leave the completed-object marker. Recovery will make the
                    // object discoverable rather than silently orphaning it.
                }
            }
        }
        state = .aborted
        terminalError = nil
        resumeDrainWaiters()
        publishProgress()
    }

    func accessURL(
        for kind: MeetingMediaKind,
        ttl: TimeInterval = 15 * 60
    ) async throws -> RemoteMediaAccess {
        guard tracks[kind]?.isComplete == true else {
            throw MediaStreamingError.invalidState("Finish the \(kind.label.lowercased()) upload before requesting playback access.")
        }
        do {
            return try await transport.accessURL(
                meetingID: descriptor.meetingID,
                kind: kind,
                ttl: ttl
            )
        } catch {
            throw Self.transportError(error)
        }
    }

    func deleteMedia(_ kind: MeetingMediaKind) async throws {
        do {
            try await transport.deleteMedia(meetingID: descriptor.meetingID, kind: kind)
        } catch {
            throw Self.transportError(error)
        }
    }

    /// A local snapshot used after a partial finalization failure. It does not
    /// make a network request, so the app can preserve already committed media
    /// even when the access-link endpoint is temporarily unreachable.
    func completedMediaKinds() -> [MeetingMediaKind] {
        tracks.compactMap { kind, track in
            track.isComplete || track.completedObjectKey != nil ? kind : nil
        }
    }

    private var pendingByteCount: Int {
        let accumulatorAndReorder = tracks.values.reduce(0) { total, track in
            total + track.accumulator.bufferedByteCount + track.reordered.values.reduce(0) { $0 + $1.count }
        }
        let queued = queue.reduce(0) { $0 + $1.data.count }
        return accumulatorAndReorder + queued + (inFlight?.data.count ?? 0)
    }

    private func makeProgress() -> MediaStreamingProgress {
        MediaStreamingProgress(
            pendingBytes: pendingByteCount,
            uploadedBytes: tracks.values.reduce(0) { $0 + $1.uploadedBytes },
            acceptedBytes: tracks.values.reduce(0) { $0 + $1.acceptedBytes },
            maximumPendingBytes: maximumPendingBytes,
            uploadedParts: tracks.values.reduce(0) { $0 + $1.uploadedParts.count },
            state: state
        )
    }

    private func publishProgress() {
        guard let progressHandler else { return }
        let value = makeProgress()
        Task { @MainActor in progressHandler(value) }
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, !queue.isEmpty, terminalError == nil else { return }
        worker = Task { await self.drainQueue() }
    }

    private func drainQueue() async {
        while !Task.isCancelled, terminalError == nil, !queue.isEmpty {
            let pending = queue.removeFirst()
            inFlight = pending
            publishProgress()
            do {
                let uploaded = try await transport.uploadPart(
                    pending.data,
                    partNumber: pending.partNumber,
                    upload: pending.upload
                )
                guard state != .aborted else {
                    inFlight = nil
                    worker = nil
                    resumeDrainWaiters()
                    publishProgress()
                    return
                }
                guard uploaded.partNumber == pending.partNumber else {
                    throw MediaStreamingError.transport("Cloud storage acknowledged the wrong multipart part number.")
                }
                guard var track = tracks[pending.kind] else {
                    throw MediaStreamingError.mediaWasNotSelected(pending.kind)
                }
                track.uploadedParts.append(uploaded)
                track.uploadedBytes += pending.data.count
                tracks[pending.kind] = track
                inFlight = nil
                resumeDrainWaiters()
                publishProgress()
            } catch {
                inFlight = nil
                if state == .aborted {
                    worker = nil
                    resumeDrainWaiters()
                    publishProgress()
                    return
                }
                fail(Self.transportError(error))
                return
            }
        }
        worker = nil
        resumeDrainWaiters()
        publishProgress()
    }

    private func waitUntilDrained(kind: MeetingMediaKind?) async throws {
        while hasPendingWork(for: kind) {
            try throwIfTerminal()
            await withCheckedContinuation { continuation in
                drainWaiters.append(continuation)
            }
        }
        try throwIfTerminal()
    }

    private func hasPendingWork(for kind: MeetingMediaKind?) -> Bool {
        if let kind {
            return queue.contains(where: { $0.kind == kind }) || inFlight?.kind == kind
        }
        return !queue.isEmpty || inFlight != nil
    }

    private func resumeDrainWaiters() {
        let waiters = drainWaiters
        drainWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }

    private func fail(_ error: MediaStreamingError) {
        terminalError = error
        state = .failed(error.localizedDescription)
        worker = nil
        resumeDrainWaiters()
        publishProgress()
    }

    private func throwIfTerminal() throws {
        if let terminalError { throw terminalError }
        if state == .aborted {
            throw MediaStreamingError.invalidState("This cloud upload was cancelled.")
        }
    }

    private func result(for track: Track) -> MediaStreamingMediaResult {
        MediaStreamingMediaResult(
            kind: track.upload.kind,
            objectKey: track.completedObjectKey ?? track.upload.objectKey,
            contentType: track.upload.contentType,
            byteCount: track.uploadedBytes,
            partCount: track.uploadedParts.count
        )
    }

    private static func contentType(for kind: MeetingMediaKind) -> String {
        kind == .screen ? "video/mp4" : "audio/mp4"
    }

    private static func transportError(_ error: Error) -> MediaStreamingError {
        if let streaming = error as? MediaStreamingError { return streaming }
        return .transport(error.localizedDescription)
    }
}
