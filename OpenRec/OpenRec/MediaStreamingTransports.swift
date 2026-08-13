import Foundation

struct ManagedMediaStreamingTransport: MediaStreamingTransport {
    let baseURL: URL
    let token: String

    func prepareMeeting(_ descriptor: MediaStreamingMeetingDescriptor) async throws {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("v1/meetings/\(descriptor.meetingID.uuidString.lowercased())")
        )
        request.httpMethod = "PUT"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.jsonEncoder.encode(descriptor.provisionalPayload)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response, data: data)
    }

    func beginUpload(
        meetingID: UUID,
        kind: MeetingMediaKind,
        contentType: String
    ) async throws -> MediaMultipartUpload {
        let route = Self.multipartRoute(meetingID: meetingID, kind: kind)
        var request = URLRequest(url: baseURL.appendingPathComponent(route))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response, data: data)
        let envelope = try Self.jsonDecoder.decode(ManagedMultipartBeginEnvelope.self, from: data)
        guard !envelope.uploadId.isEmpty else {
            throw OpenRecError.invalidResponse("OpenRec Cloud returned an empty upload session.")
        }
        return MediaMultipartUpload(
            meetingID: meetingID,
            kind: kind,
            uploadID: envelope.uploadId,
            // Immutable generation keys are server-owned and returned only by
            // completion. Never derive or cache a managed object key here.
            objectKey: "",
            contentType: contentType,
            backend: .managed,
            storageScope: Self.storageScope(baseURL)
        )
    }

    func uploadPart(
        _ data: Data,
        partNumber: Int,
        upload: MediaMultipartUpload
    ) async throws -> MediaUploadedPart {
        try await MediaStreamingRetry.run {
            let url = try multipartURL(upload: upload, suffix: "parts/\(partNumber)")
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.timeoutInterval = 60
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let (responseData, response) = try await URLSession.shared.upload(for: request, from: data)
            try Self.validate(response, data: responseData)
            let part = try Self.jsonDecoder.decode(MediaUploadedPart.self, from: responseData)
            guard part.partNumber == partNumber, !part.etag.isEmpty else {
                throw OpenRecError.invalidResponse("OpenRec Cloud returned an invalid multipart acknowledgement.")
            }
            return part
        }
    }

    func completeUpload(
        _ upload: MediaMultipartUpload,
        parts: [MediaUploadedPart]
    ) async throws -> MediaCompletedUpload {
        let body = try Self.jsonEncoder.encode(ManagedMultipartCompletionBody(parts: parts))
        return try await MediaStreamingRetry.run(policy: .completion) {
            let url = try multipartURL(upload: upload, suffix: "complete")
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.validate(response, data: data)
            let envelope = try Self.jsonDecoder.decode(ManagedMultipartCompleteEnvelope.self, from: data)
            guard envelope.ok, !envelope.objectKey.isEmpty else {
                throw OpenRecError.invalidResponse("OpenRec Cloud did not confirm the completed recording.")
            }
            return MediaCompletedUpload(objectKey: envelope.objectKey)
        }
    }

    func abortUpload(_ upload: MediaMultipartUpload) async throws {
        do {
            try await MediaStreamingRetry.run(policy: .completion) {
                let url = try multipartURL(upload: upload, suffix: nil)
                var request = URLRequest(url: url)
                request.httpMethod = "DELETE"
                request.timeoutInterval = 20
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let (data, response) = try await URLSession.shared.data(for: request)
                try Self.validate(response, data: data)
            }
        } catch OpenRecError.requestFailed(let status, _) where status == 404 {
            // No owner-scoped token exists. This is terminal for the local
            // journal and cannot identify or delete an attached generation.
            return
        }
    }

    func deleteProvisionalMeeting(meetingID: UUID) async throws {
        try await MediaStreamingRetry.run(policy: .completion) {
            var request = URLRequest(
                url: baseURL.appendingPathComponent("v1/meetings/\(meetingID.uuidString.lowercased())")
            )
            request.httpMethod = "DELETE"
            request.timeoutInterval = 20
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.validate(response, data: data)
        }
    }

    func deleteMedia(meetingID: UUID, kind: MeetingMediaKind) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent(Self.mediaRoute(meetingID: meetingID, kind: kind)))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response, data: data)
    }

    func accessURL(
        meetingID: UUID,
        kind: MeetingMediaKind,
        ttl: TimeInterval
    ) async throws -> RemoteMediaAccess {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("\(Self.mediaRoute(meetingID: meetingID, kind: kind))/access"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "ttl", value: String(Self.safeTTL(ttl)))
        ]
        guard let url = components?.url else {
            throw OpenRecError.invalidConfiguration("The OpenRec Cloud playback URL is invalid.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response, data: data)
        let envelope = try Self.jsonDecoder.decode(ManagedMediaAccessEnvelope.self, from: data)
        return RemoteMediaAccess(url: envelope.url, expiresAt: envelope.expiresAt)
    }

    func commitManifest(
        descriptor: MediaStreamingMeetingDescriptor,
        media: [MediaStreamingMediaResult]
    ) async throws {
        // Completing a managed multipart upload atomically attaches its object
        // key to the provisional D1 meeting row. Final meeting analysis later
        // replaces the provisional metadata through the normal PUT route.
    }

    private func multipartURL(upload: MediaMultipartUpload, suffix: String?) throws -> URL {
        let route = Self.multipartRoute(meetingID: upload.meetingID, kind: upload.kind)
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        guard let encodedUploadID = upload.uploadID.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw OpenRecError.invalidResponse("OpenRec Cloud returned an invalid upload session.")
        }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let existing = components?.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let prefix = existing.isEmpty ? "" : "/\(existing)"
        components?.percentEncodedPath = "\(prefix)/\(route)/\(encodedUploadID)" + (suffix.map { "/\($0)" } ?? "")
        guard let url = components?.url else {
            throw OpenRecError.invalidResponse("OpenRec Cloud returned an invalid upload URL.")
        }
        return url
    }

    private static func mediaRoute(meetingID: UUID, kind: MeetingMediaKind) -> String {
        "v1/meetings/\(meetingID.uuidString.lowercased())/media/\(kind.rawValue)"
    }

    private static func multipartRoute(meetingID: UUID, kind: MeetingMediaKind) -> String {
        "\(mediaRoute(meetingID: meetingID, kind: kind))/multipart"
    }

    private static func safeTTL(_ value: TimeInterval) -> Int {
        min(24 * 60 * 60, max(60, Int(value.rounded(.down))))
    }

    static func storageScope(_ baseURL: URL) -> String {
        baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OpenRecError.invalidResponse("OpenRec Cloud returned no HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = root?["error"] as? String
                ?? String(data: data, encoding: .utf8)
                ?? "OpenRec Cloud rejected the upload."
            throw OpenRecError.requestFailed(status: http.statusCode, message: message)
        }
    }

    private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

struct OwnR2MediaStreamingTransport: MediaStreamingTransport {
    let signer: R2RequestSigner

    func prepareMeeting(_ descriptor: MediaStreamingMeetingDescriptor) async throws {}

    func beginUpload(
        meetingID: UUID,
        kind: MeetingMediaKind,
        contentType: String
    ) async throws -> MediaMultipartUpload {
        let objectKey = Self.objectKey(meetingID: meetingID, kind: kind)
        var request = try signer.signedCreateMultipartRequest(
            objectKey: objectKey,
            contentType: contentType
        )
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response, data: data)
        let parser = R2MultipartUploadIDParser()
        try parser.parse(data)
        guard let uploadID = parser.uploadID, !uploadID.isEmpty else {
            throw OpenRecError.invalidResponse("R2 did not return a multipart upload ID.")
        }
        return MediaMultipartUpload(
            meetingID: meetingID,
            kind: kind,
            uploadID: uploadID,
            objectKey: objectKey,
            contentType: contentType,
            backend: .ownR2,
            storageScope: Self.storageScope(signer)
        )
    }

    func uploadPart(
        _ data: Data,
        partNumber: Int,
        upload: MediaMultipartUpload
    ) async throws -> MediaUploadedPart {
        try await MediaStreamingRetry.run {
            var request = try signer.signedUploadPartRequest(
                data: data,
                objectKey: upload.objectKey,
                uploadID: upload.uploadID,
                partNumber: partNumber
            )
            request.timeoutInterval = 60
            let (responseData, response) = try await URLSession.shared.upload(for: request, from: data)
            try Self.validate(response, data: responseData)
            guard let http = response as? HTTPURLResponse,
                  let etag = http.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !etag.isEmpty else {
                throw OpenRecError.invalidResponse("R2 uploaded a part but returned no ETag.")
            }
            return MediaUploadedPart(partNumber: partNumber, etag: etag)
        }
    }

    func completeUpload(
        _ upload: MediaMultipartUpload,
        parts: [MediaUploadedPart]
    ) async throws -> MediaCompletedUpload {
        let body = R2MultipartCompletionXML.encode(parts: parts)
        do {
            try await MediaStreamingRetry.run(policy: .completion) {
                var request = try signer.signedCompleteMultipartRequest(
                    data: body,
                    objectKey: upload.objectKey,
                    uploadID: upload.uploadID
                )
                request.timeoutInterval = 30
                let (responseData, response) = try await URLSession.shared.upload(for: request, from: body)
                try Self.validate(response, data: responseData)
            }
            return MediaCompletedUpload(objectKey: upload.objectKey)
        } catch {
            // A completion response can be lost after R2 has atomically made
            // the object visible and invalidated the upload ID. Never abort or
            // delete solely because that acknowledgement was lost.
            if try await objectExists(objectKey: upload.objectKey) {
                return MediaCompletedUpload(objectKey: upload.objectKey)
            }
            throw error
        }
    }

    func abortUpload(_ upload: MediaMultipartUpload) async throws {
        do {
            try await MediaStreamingRetry.run(policy: .completion) {
                var request = try signer.signedAbortMultipartRequest(
                    objectKey: upload.objectKey,
                    uploadID: upload.uploadID
                )
                request.timeoutInterval = 20
                let (data, response) = try await URLSession.shared.data(for: request)
                try Self.validate(response, data: data)
            }
        } catch let error as R2ServiceError where error.isNoSuchUpload || error.status == 404 {
            // Already completed or previously aborted is terminal for this
            // upload ID. The object, if completed, is deliberately untouched.
            return
        }
    }

    func deleteProvisionalMeeting(meetingID: UUID) async throws {
        // BYO R2 has no database row before the v2 manifest is committed.
    }

    func deleteMedia(meetingID: UUID, kind: MeetingMediaKind) async throws {
        let request = try signer.signedDeleteRequest(objectKey: Self.objectKey(meetingID: meetingID, kind: kind))
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response, data: data)
    }

    func accessURL(
        meetingID: UUID,
        kind: MeetingMediaKind,
        ttl: TimeInterval
    ) async throws -> RemoteMediaAccess {
        let safeTTL = min(7 * 24 * 60 * 60, max(60, Int(ttl.rounded(.down))))
        let now = Date()
        let url = try signer.presignedGetURL(
            objectKey: Self.objectKey(meetingID: meetingID, kind: kind),
            expiresIn: safeTTL,
            now: now
        )
        return RemoteMediaAccess(url: url, expiresAt: now.addingTimeInterval(TimeInterval(safeTTL)))
    }

    func commitManifest(
        descriptor: MediaStreamingMeetingDescriptor,
        media: [MediaStreamingMediaResult]
    ) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let objectKey = "meetings/\(descriptor.meetingID.uuidString.lowercased())/meeting.json"
        let existing = try await existingManifest(objectKey: objectKey)
        let manifest = Self.mergedManifest(
            descriptor: descriptor,
            recoveredMedia: media,
            preserving: existing
        )
        let body = try encoder.encode(manifest)
        var request = try signer.signedPutRequest(
            data: body,
            objectKey: objectKey,
            contentType: "application/json"
        )
        request.timeoutInterval = 60
        let (responseData, response) = try await URLSession.shared.upload(for: request, from: body)
        try Self.validate(response, data: responseData)
    }

    /// Recovery is deliberately monotonic: a stale completed-object marker can
    /// add or refresh media references, but it never replaces richer meeting
    /// metadata or removes a stream already present in a newer manifest.
    static func mergedManifest(
        descriptor: MediaStreamingMeetingDescriptor,
        recoveredMedia: [MediaStreamingMediaResult],
        preserving existing: OwnR2MeetingManifest?,
        now: Date = Date()
    ) -> OwnR2MeetingManifest {
        var mediaByKind: [String: OwnR2MediaObject] = [:]
        for item in existing?.media ?? [] { mediaByKind[item.kind] = item }
        for item in recoveredMedia {
            mediaByKind[item.kind.rawValue] = OwnR2MediaObject(
                kind: item.kind.rawValue,
                objectKey: item.objectKey,
                contentType: item.contentType,
                byteCount: item.byteCount,
                partCount: item.partCount
            )
        }
        let mergedMedia = mediaByKind.values.sorted { $0.kind < $1.kind }
        return OwnR2MeetingManifest(
            payload: existing?.payload ?? descriptor.provisionalPayload,
            hasScreenRecording: existing?.hasScreenRecording == true
                || mergedMedia.contains(where: { $0.kind == MeetingMediaKind.screen.rawValue }),
            hasAudioRecording: existing?.hasAudioRecording == true
                || mergedMedia.contains(where: { $0.kind == MeetingMediaKind.audio.rawValue }),
            storesTranscript: existing?.storesTranscript ?? false,
            isComplete: existing?.isComplete ?? false,
            updatedAt: now,
            media: mergedMedia
        )
    }

    static func objectKey(meetingID: UUID, kind: MeetingMediaKind) -> String {
        let prefix = "meetings/\(meetingID.uuidString.lowercased())"
        return kind == .screen ? "\(prefix)/recording.mp4" : "\(prefix)/audio.m4a"
    }

    static func storageScope(_ signer: R2RequestSigner) -> String {
        "r2://\(signer.accountID)/\(signer.bucket)"
    }

    func objectExists(objectKey: String) async throws -> Bool {
        try await MediaStreamingRetry.run(policy: .completion) {
            var request = try signer.signedHeadRequest(objectKey: objectKey)
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw OpenRecError.invalidResponse("R2 returned no HTTP response while checking a completed recording.")
            }
            if (200..<300).contains(http.statusCode) { return true }
            if http.statusCode == 404 { return false }
            try Self.validate(response, data: data)
            return false
        }
    }

    private func existingManifest(objectKey: String) async throws -> OwnR2MeetingManifest? {
        var request = try signer.signedGetRequest(objectKey: objectKey)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenRecError.invalidResponse("R2 returned no HTTP response while reading meeting recovery metadata.")
        }
        if http.statusCode == 404 { return nil }
        try Self.validate(response, data: data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(OwnR2MeetingManifest.self, from: data)
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OpenRecError.invalidResponse("R2 returned no HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let parser = R2ErrorResponseParser()
            try? parser.parse(data)
            let message = parser.message
                ?? String(data: data, encoding: .utf8)
                ?? "R2 rejected the upload."
            throw R2ServiceError(status: http.statusCode, code: parser.code, message: message)
        }
    }
}

private struct ManagedMultipartBeginEnvelope: Decodable {
    let uploadId: String
}

private struct ManagedMultipartCompletionBody: Encodable {
    let parts: [MediaUploadedPart]
}

private struct ManagedMultipartCompleteEnvelope: Decodable {
    let ok: Bool
    let objectKey: String
    let etag: String?
}

private struct ManagedMediaAccessEnvelope: Decodable {
    let url: URL
    let expiresAt: Date
}

final class R2MultipartUploadIDParser: NSObject, XMLParserDelegate {
    private(set) var uploadID: String?
    private var currentText = ""

    func parse(_ data: Data) throws {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            throw parser.parserError ?? OpenRecError.invalidResponse("R2 returned unreadable multipart XML.")
        }
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "UploadId" {
            let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { uploadID = value }
        }
        currentText = ""
    }
}

final class R2ErrorResponseParser: NSObject, XMLParserDelegate {
    private(set) var code: String?
    private(set) var message: String?
    private var currentText = ""

    func parse(_ data: Data) throws {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else { throw parser.parserError ?? OpenRecError.invalidResponse("R2 returned unreadable error XML.") }
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { currentText += string }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "Code" {
            let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { code = value }
        } else if elementName == "Message" {
            let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { message = value }
        }
        currentText = ""
    }
}

struct R2ServiceError: LocalizedError, Equatable, Sendable {
    let status: Int
    let code: String?
    let message: String

    var isNoSuchUpload: Bool {
        code == "NoSuchUpload"
            || (code == nil && status == 404 && message.localizedCaseInsensitiveContains("upload"))
    }

    var errorDescription: String? {
        let serviceCode = code.map { " [\($0)]" } ?? ""
        return "R2 request failed (\(status))\(serviceCode): \(message)"
    }
}

enum R2MultipartCompletionXML {
    static func encode(parts: [MediaUploadedPart]) -> Data {
        let body = parts.sorted { $0.partNumber < $1.partNumber }.map { part in
            "<Part><PartNumber>\(part.partNumber)</PartNumber><ETag>\(escape(part.etag))</ETag></Part>"
        }.joined()
        return Data("<CompleteMultipartUpload>\(body)</CompleteMultipartUpload>".utf8)
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

struct MediaStreamingRetryPolicy: Equatable, Sendable {
    let maximumAttempts: Int
    let outageDeadline: TimeInterval
    let initialDelay: TimeInterval
    let maximumDelay: TimeInterval
    let jitterFraction: Double

    static let partUpload = MediaStreamingRetryPolicy(
        // The deadline, rather than attempt count, governs a sustained outage.
        maximumAttempts: 30,
        outageDeadline: 120,
        initialDelay: 0.5,
        maximumDelay: 8,
        jitterFraction: 0.25
    )

    static let completion = MediaStreamingRetryPolicy(
        maximumAttempts: 6,
        outageDeadline: 45,
        initialDelay: 0.5,
        maximumDelay: 5,
        jitterFraction: 0.2
    )

    func delay(afterFailure failure: Int, randomUnit: Double) -> TimeInterval {
        let exponent = max(0, min(30, failure - 1))
        let base = min(maximumDelay, initialDelay * pow(2, Double(exponent)))
        let unit = min(1, max(0, randomUnit))
        let factor = (1 - jitterFraction) + (2 * jitterFraction * unit)
        return max(0, base * factor)
    }
}

enum MediaStreamingRetry {
    typealias MonotonicClock = @Sendable () -> TimeInterval
    typealias Sleeper = @Sendable (TimeInterval) async throws -> Void
    typealias RandomUnit = @Sendable () -> Double

    static func run<T>(
        policy: MediaStreamingRetryPolicy = .partUpload,
        clock: @escaping MonotonicClock = { ProcessInfo.processInfo.systemUptime },
        sleeper: @escaping Sleeper = { seconds in
            guard seconds > 0 else { return }
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        randomUnit: @escaping RandomUnit = { Double.random(in: 0...1) },
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        precondition(policy.maximumAttempts > 0)
        precondition(policy.outageDeadline >= 0)
        let startedAt = clock()
        var attempt = 1
        while true {
            try Task.checkCancellation()
            do {
                return try await operation()
            } catch {
                guard attempt < policy.maximumAttempts, isRetryable(error) else { throw error }
                let elapsed = max(0, clock() - startedAt)
                let remaining = policy.outageDeadline - elapsed
                guard remaining > 0 else { throw error }
                let delay = min(remaining, policy.delay(
                    afterFailure: attempt,
                    randomUnit: randomUnit()
                ))
                try await sleeper(delay)
                attempt += 1
            }
        }
    }

    static func isRetryable(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if case OpenRecError.requestFailed(let status, _) = error {
            return status == 408 || status == 429 || (500...599).contains(status)
        }
        if let r2 = error as? R2ServiceError {
            return r2.status == 408 || r2.status == 429 || (500...599).contains(r2.status)
        }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .networkConnectionLost,
             .timedOut,
             .notConnectedToInternet,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .resourceUnavailable:
            return true
        default:
            return false
        }
    }
}
