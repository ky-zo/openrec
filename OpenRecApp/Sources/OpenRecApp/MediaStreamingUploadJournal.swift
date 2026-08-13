import Foundation

enum MediaStreamingBackend: String, Codable, Sendable {
    case managed
    case ownR2
}

/// Metadata required to abort one exact multipart upload after a crash. This
/// deliberately cannot contain media bytes or credentials.
struct ActiveMediaUploadJournalEntry: Codable, Equatable, Sendable {
    let backend: MediaStreamingBackend
    let storageScope: String
    let meetingID: UUID
    let kind: String
    let uploadID: String
    let objectKey: String
    let contentType: String
    let launchID: UUID
    let createdAt: Date
    let meetingStartedAt: Date?
    let callApp: String?
    let callTitle: String?
    let completedObjectKey: String?
    let completedByteCount: Int?
    let completedPartCount: Int?
    let completedAt: Date?

    init(
        upload: MediaMultipartUpload,
        descriptor: MediaStreamingMeetingDescriptor,
        launchID: UUID,
        createdAt: Date = Date()
    ) {
        backend = upload.backend
        storageScope = upload.storageScope
        meetingID = upload.meetingID
        kind = upload.kind.rawValue
        uploadID = upload.uploadID
        objectKey = upload.objectKey
        contentType = upload.contentType
        self.launchID = launchID
        self.createdAt = createdAt
        meetingStartedAt = descriptor.startedAt
        callApp = descriptor.callApp
        callTitle = descriptor.callTitle
        completedObjectKey = nil
        completedByteCount = nil
        completedPartCount = nil
        completedAt = nil
    }

    private init(
        backend: MediaStreamingBackend,
        storageScope: String,
        meetingID: UUID,
        kind: String,
        uploadID: String,
        objectKey: String,
        contentType: String,
        launchID: UUID,
        createdAt: Date,
        meetingStartedAt: Date?,
        callApp: String?,
        callTitle: String?,
        completedObjectKey: String?,
        completedByteCount: Int?,
        completedPartCount: Int?,
        completedAt: Date?
    ) {
        self.backend = backend
        self.storageScope = storageScope
        self.meetingID = meetingID
        self.kind = kind
        self.uploadID = uploadID
        self.objectKey = objectKey
        self.contentType = contentType
        self.launchID = launchID
        self.createdAt = createdAt
        self.meetingStartedAt = meetingStartedAt
        self.callApp = callApp
        self.callTitle = callTitle
        self.completedObjectKey = completedObjectKey
        self.completedByteCount = completedByteCount
        self.completedPartCount = completedPartCount
        self.completedAt = completedAt
    }

    var upload: MediaMultipartUpload? {
        guard let mediaKind = MeetingMediaKind(rawValue: kind) else { return nil }
        return MediaMultipartUpload(
            meetingID: meetingID,
            kind: mediaKind,
            uploadID: uploadID,
            objectKey: objectKey,
            contentType: contentType,
            backend: backend,
            storageScope: storageScope
        )
    }

    func matches(_ upload: MediaMultipartUpload) -> Bool {
        backend == upload.backend
            && storageScope == upload.storageScope
            && meetingID == upload.meetingID
            && kind == upload.kind.rawValue
            && uploadID == upload.uploadID
    }

    var isAwaitingManifest: Bool { completedObjectKey != nil }

    var meetingDescriptor: MediaStreamingMeetingDescriptor {
        MediaStreamingMeetingDescriptor(
            meetingID: meetingID,
            startedAt: meetingStartedAt ?? createdAt,
            callApp: callApp,
            callTitle: callTitle
        )
    }

    var completedResult: MediaStreamingMediaResult? {
        guard let upload,
              let completedObjectKey else { return nil }
        return MediaStreamingMediaResult(
            kind: upload.kind,
            objectKey: completedObjectKey,
            contentType: contentType,
            byteCount: completedByteCount ?? 0,
            partCount: completedPartCount ?? 0
        )
    }

    func markingCompleted(
        result: MediaStreamingMediaResult,
        at date: Date
    ) -> ActiveMediaUploadJournalEntry {
        ActiveMediaUploadJournalEntry(
            backend: backend,
            storageScope: storageScope,
            meetingID: meetingID,
            kind: kind,
            uploadID: uploadID,
            objectKey: objectKey,
            contentType: contentType,
            launchID: launchID,
            createdAt: createdAt,
            meetingStartedAt: meetingStartedAt,
            callApp: callApp,
            callTitle: callTitle,
            completedObjectKey: result.objectKey,
            completedByteCount: result.byteCount,
            completedPartCount: result.partCount,
            completedAt: date
        )
    }
}

actor MediaStreamingUploadJournal {
    static let currentLaunchID = UUID()
    static let shared = MediaStreamingUploadJournal(fileURL: defaultURL())

    private struct Envelope: Codable {
        let version: Int
        var uploads: [ActiveMediaUploadJournalEntry]
    }

    private let fileURL: URL
    private let launchID: UUID
    private let failureInjector: (@Sendable (Mutation) -> Error?)?

    enum Mutation: Equatable, Sendable {
        case record
        case markCompleted
        case remove
    }

    init(
        fileURL: URL,
        launchID: UUID = currentLaunchID,
        failureInjector: (@Sendable (Mutation) -> Error?)? = nil
    ) {
        self.fileURL = fileURL
        self.launchID = launchID
        self.failureInjector = failureInjector
    }

    func record(
        _ upload: MediaMultipartUpload,
        descriptor: MediaStreamingMeetingDescriptor,
        now: Date = Date()
    ) throws {
        var entries = try loadEntries()
        if !entries.contains(where: { $0.matches(upload) }) {
            entries.append(ActiveMediaUploadJournalEntry(
                upload: upload,
                descriptor: descriptor,
                launchID: launchID,
                createdAt: now
            ))
        }
        try persist(entries, mutation: .record)
    }

    func markCompleted(
        _ upload: MediaMultipartUpload,
        result: MediaStreamingMediaResult,
        now: Date = Date()
    ) throws {
        var entries = try loadEntries()
        guard let index = entries.firstIndex(where: { $0.matches(upload) }) else {
            throw OpenRecError.invalidResponse("The completed R2 object has no active recovery journal entry.")
        }
        entries[index] = entries[index].markingCompleted(result: result, at: now)
        try persist(entries, mutation: .markCompleted)
    }

    func remove(_ upload: MediaMultipartUpload) throws {
        try removeAll([upload])
    }

    /// Removes a meeting's recovered markers with one atomic file mutation.
    /// This prevents a crash between per-kind removals from leaving a partial
    /// recovery set that could later overwrite the manifest with one stream.
    func removeAll(_ uploads: [MediaMultipartUpload]) throws {
        guard !uploads.isEmpty else { return }
        var entries = try loadEntries()
        entries.removeAll { entry in uploads.contains(where: entry.matches) }
        try persist(entries, mutation: .remove)
    }

    func entriesFromPriorLaunch() throws -> [ActiveMediaUploadJournalEntry] {
        try loadEntries().filter { $0.launchID != launchID }
    }

    func allEntries() throws -> [ActiveMediaUploadJournalEntry] {
        try loadEntries()
    }

    private func loadEntries() throws -> [ActiveMediaUploadJournalEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let envelope = try Self.decoder.decode(Envelope.self, from: Data(contentsOf: fileURL))
            guard envelope.version == 1 else {
                throw OpenRecError.invalidResponse("The active upload journal uses an unsupported version.")
            }
            return envelope.uploads
        } catch let error as OpenRecError {
            throw error
        } catch {
            throw OpenRecError.invalidResponse("The active upload journal is unreadable. It was left untouched for recovery.")
        }
    }

    private func persist(
        _ entries: [ActiveMediaUploadJournalEntry],
        mutation: Mutation
    ) throws {
        if let error = failureInjector?(mutation) { throw error }
        if entries.isEmpty {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            return
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.encoder.encode(Envelope(version: 1, uploads: entries))
            .write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: fileURL.path
        )
    }

    private static func defaultURL() -> URL {
        let namespace = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true ? "OpenRec Dev" : "OpenRec"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent("active-media-uploads.json")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
