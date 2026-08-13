import Foundation
import Combine
import CryptoKit
import AuthenticationServices
import AppKit

struct WebhookMediaURLs {
    let screen: URL?
    let audio: URL?
}

/// Immutable per-operation storage identity. API endpoints and credentials are
/// captured before a call's first suspension point, so an open Settings window
/// cannot split one recording across backends or accounts.
struct CloudStorageContext: @unchecked Sendable {
    let mode: StorageMode
    fileprivate let managedBaseURL: URL?
    fileprivate let managedToken: String?
    fileprivate let r2Signer: R2RequestSigner?
}

enum ManagedSignOutPrivacy {
    static func scrubbedArtifactStub(
        from meeting: MeetingRecord,
        fileExists: (String) -> Bool
    ) -> MeetingRecord? {
        guard meeting.storageMode == .managed else { return meeting }
        let hasLocalArtifact = [meeting.localScreenPath, meeting.localAudioPath]
            .compactMap { $0 }
            .contains(where: fileExists)
        // A delivered-by-reference webhook can intentionally keep private
        // media alive until its signed URL expires. Preserve that tiny cleanup
        // record across sign-out; deleting it would orphan the R2 objects.
        let hasDeferredMediaCleanup = meeting.screenDeletionScheduledAt != nil
            || meeting.audioDeletionScheduledAt != nil
        let needsRecovery = meeting.saveStatus != .saved
            || meeting.webhookDeliveryStatus == .failed
            || hasDeferredMediaCleanup
        guard hasLocalArtifact || needsRecovery else { return nil }

        var stub = meeting
        stub.callApp = nil
        stub.callTitle = nil
        stub.transcript = nil
        stub.insights = MeetingInsights(title: needsRecovery ? "Recovery recording" : "Local recording")
        if !needsRecovery {
            stub.localScreenPath = meeting.localScreenPath.flatMap { fileExists($0) ? $0 : nil }
            stub.localAudioPath = meeting.localAudioPath.flatMap { fileExists($0) ? $0 : nil }
        }
        stub.errorMessage = meeting.saveStatus == .failed
            ? "A private local recovery recording is waiting. Sign in again to retry this save."
            : nil
        stub.webhookErrorMessage = meeting.webhookDeliveryStatus == .failed
            ? "Webhook delivery needs to be retried after signing in again."
            : nil
        stub.updatedAt = Date()
        return stub
    }
}

@MainActor
final class CloudStorageManager: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    struct CalendarCallContext {
        let title: String
        let participants: [String]
    }
    @Published var mode: StorageMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "StorageMode") }
    }
    @Published var managedEmail = UserDefaults.standard.string(forKey: "ManagedEmail")
    @Published var isSigningIn = false
    /// Google accounts serving calendar context — independent of the sign-in
    /// identity, and additive: connect as many as needed, all merge into one
    /// upcoming list.
    @Published var calendarEmails: [String] = UserDefaults.standard.stringArray(forKey: "CalendarEmails") ?? []
    @Published var isConnectingCalendar = false

    var calendarEmail: String? { calendarEmails.first }
    @Published var statusMessage: String?
    @Published private(set) var libraryMeetings: [MeetingRecord] = []
    @Published private(set) var isLoadingLibrary = false
    @Published var libraryError: String?

    var managedAPIBaseURL: String {
        get { UserDefaults.standard.string(forKey: "ManagedAPIBaseURL") ?? "https://openrec-cloud.qstar0.workers.dev" }
        set { UserDefaults.standard.set(newValue, forKey: "ManagedAPIBaseURL"); objectWillChange.send() }
    }
    var r2AccountID: String {
        get { UserDefaults.standard.string(forKey: "R2AccountID") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "R2AccountID"); objectWillChange.send() }
    }
    var r2Bucket: String {
        get { UserDefaults.standard.string(forKey: "R2Bucket") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "R2Bucket"); objectWillChange.send() }
    }
    var r2AccessKeyID: String {
        get { KeychainStore.string(for: "r2-access-key-id") }
        set { KeychainStore.set(newValue, for: "r2-access-key-id"); objectWillChange.send() }
    }
    var r2SecretAccessKey: String {
        get { KeychainStore.string(for: "r2-secret-access-key") }
        set { KeychainStore.set(newValue, for: "r2-secret-access-key"); objectWillChange.send() }
    }

    var isManagedSignedIn: Bool { !KeychainStore.string(for: "managed-session-token").isEmpty }
    var canStoreTranscriptInCloud: Bool { mode == .managed && isManagedSignedIn }
    var isReady: Bool {
        switch mode {
        case .managed: return isManagedSignedIn
        case .ownR2:
            return !r2AccountID.isEmpty && !r2Bucket.isEmpty && !r2AccessKeyID.isEmpty && !r2SecretAccessKey.isEmpty
        }
    }

    func captureStorageContext(for requestedMode: StorageMode? = nil) throws -> CloudStorageContext {
        let selectedMode = requestedMode ?? mode
        switch selectedMode {
        case .managed:
            let base = try validatedManagedBaseURL()
            let token = KeychainStore.string(for: "managed-session-token")
            guard !token.isEmpty else {
                throw OpenRecError.invalidConfiguration("Your OpenRec Cloud session expired. Sign in again.")
            }
            return CloudStorageContext(
                mode: .managed,
                managedBaseURL: base,
                managedToken: token,
                r2Signer: nil
            )
        case .ownR2:
            guard !r2AccountID.isEmpty,
                  !r2Bucket.isEmpty,
                  !r2AccessKeyID.isEmpty,
                  !r2SecretAccessKey.isEmpty else {
                throw OpenRecError.invalidConfiguration("Complete the R2 account, bucket, access key, and secret key fields.")
            }
            return CloudStorageContext(
                mode: .ownR2,
                managedBaseURL: nil,
                managedToken: nil,
                r2Signer: R2RequestSigner(
                    accountID: r2AccountID,
                    bucket: r2Bucket,
                    accessKeyID: r2AccessKeyID,
                    secretAccessKey: r2SecretAccessKey
                )
            )
        }
    }

    private var authSession: ASWebAuthenticationSession?

    override init() {
        let saved = UserDefaults.standard.string(forKey: "StorageMode")
        mode = StorageMode(rawValue: saved ?? "") ?? .managed
        super.init()
        removeLegacyRemoteMediaCacheIfNeeded()
        libraryMeetings = loadLocalMeetingRecords()
        Task { @MainActor [weak self] in
            await self?.abortStaleMediaUploadsFromPriorLaunch()
        }
    }

    /// Best-effort crash reconciliation for metadata-only multipart journal
    /// entries. Active uploads are aborted exactly; completed BYO objects are
    /// committed to a manifest before their markers are removed. Scopes that
    /// do not match the currently configured account are untouched.
    private func abortStaleMediaUploadsFromPriorLaunch() async {
        guard let entries = try? await MediaStreamingUploadJournal.shared.entriesFromPriorLaunch(),
              !entries.isEmpty else { return }

        let managedBase = try? validatedManagedBaseURL()
        let managedToken = KeychainStore.string(for: "managed-session-token")
        let r2Signer: R2RequestSigner? = {
            guard !r2AccountID.isEmpty,
                  !r2Bucket.isEmpty,
                  !r2AccessKeyID.isEmpty,
                  !r2SecretAccessKey.isEmpty else { return nil }
            return R2RequestSigner(
                accountID: r2AccountID,
                bucket: r2Bucket,
                accessKeyID: r2AccessKeyID,
                secretAccessKey: r2SecretAccessKey
            )
        }()

        if let managedBase, !managedToken.isEmpty {
            let scope = ManagedMediaStreamingTransport.storageScope(managedBase)
            let transport = ManagedMediaStreamingTransport(baseURL: managedBase, token: managedToken)
            for entry in entries where entry.backend == .managed && entry.storageScope == scope {
                guard let upload = entry.upload else { continue }
                do {
                    // Exact-token abort is a no-op for an already attached
                    // generation. Do not delete the meeting here: another
                    // stream may have completed immediately before the crash.
                    try await transport.abortUpload(upload)
                    try await MediaStreamingUploadJournal.shared.remove(upload)
                } catch {
                    // Keep exact metadata until owner-scoped cleanup succeeds.
                }
            }
        }

        if let r2Signer {
            let scope = OwnR2MediaStreamingTransport.storageScope(r2Signer)
            let transport = OwnR2MediaStreamingTransport(signer: r2Signer)
            let groups = Dictionary(grouping: entries.filter {
                $0.backend == .ownR2 && $0.storageScope == scope
            }, by: \.meetingID)
            for (_, group) in groups {
                var recoverable: [(ActiveMediaUploadJournalEntry, MediaStreamingMediaResult)] = []
                var fullyReconciled = true
                for entry in group {
                    guard let upload = entry.upload else {
                        fullyReconciled = false
                        continue
                    }
                    do {
                        if let completed = entry.completedResult {
                            if try await transport.objectExists(objectKey: completed.objectKey) {
                                recoverable.append((entry, completed))
                            } else {
                                try await MediaStreamingUploadJournal.shared.remove(upload)
                            }
                            continue
                        }

                        // If completion won a race with the crash (or journal
                        // update failed), abort is harmless: NoSuchUpload is
                        // terminal and never deletes the completed object.
                        let existedBeforeAbort = try await transport.objectExists(objectKey: upload.objectKey)
                        try await transport.abortUpload(upload)
                        let existsAfterAbort: Bool
                        if existedBeforeAbort {
                            existsAfterAbort = true
                        } else {
                            existsAfterAbort = try await transport.objectExists(objectKey: upload.objectKey)
                        }
                        guard existsAfterAbort else {
                            try await MediaStreamingUploadJournal.shared.remove(upload)
                            continue
                        }
                        let recovered = MediaStreamingMediaResult(
                            kind: upload.kind,
                            objectKey: upload.objectKey,
                            contentType: upload.contentType,
                            byteCount: 0,
                            partCount: 0
                        )
                        try await MediaStreamingUploadJournal.shared.markCompleted(
                            upload,
                            result: recovered
                        )
                        recoverable.append((entry, recovered))
                    } catch {
                        // Keep metadata until object existence and exact abort
                        // can both be resolved under the configured R2 scope.
                        fullyReconciled = false
                    }
                }

                guard fullyReconciled, let first = recoverable.first else { continue }
                let media = recoverable.map(\.1).sorted { $0.kind.rawValue < $1.kind.rawValue }
                do {
                    try await transport.commitManifest(
                        descriptor: first.0.meetingDescriptor,
                        media: media
                    )
                    try await MediaStreamingUploadJournal.shared.removeAll(
                        recoverable.compactMap { $0.0.upload }
                    )
                } catch {
                    // Completed objects remain journaled and are retried next
                    // launch; they are never deleted for a manifest failure.
                }
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow()
    }

    /// Connect (or switch) the Google account whose calendar names calls and
    /// fills the Coming up list. Deliberately separate from sign-in: the
    /// meeting library stays on the signed-in account no matter which account
    /// is picked here.
    func connectGoogleCalendar() async -> Bool {
        guard !isConnectingCalendar else { return false }
        guard mode == .managed, isManagedSignedIn else {
            statusMessage = "Sign in to OpenRec Cloud first, then connect a calendar."
            return false
        }
        isConnectingCalendar = true
        defer { isConnectingCalendar = false }
        do {
            let context = try captureStorageContext()
            guard let base = context.managedBaseURL,
                  let token = context.managedToken,
                  !token.isEmpty else {
                throw OpenRecError.invalidConfiguration("Sign in to OpenRec Cloud first, then connect a calendar.")
            }
            let scheme = authCallbackScheme
            var request = URLRequest(url: base.appendingPathComponent("v1/calendar/connect/session"))
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 20
            request.httpBody = try JSONSerialization.data(withJSONObject: ["redirect_uri": "\(scheme)://calendar"])
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response, data: data)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let urlString = root["url"] as? String,
                  let authURL = URL(string: urlString) else {
                throw OpenRecError.invalidResponse("The calendar server returned an unusable connect link.")
            }

            let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
                let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: scheme) { url, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let url { continuation.resume(returning: url) }
                    else { continuation.resume(throwing: OpenRecError.invalidResponse("Google returned no calendar callback.")) }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                authSession = session
                if !session.start() {
                    continuation.resume(throwing: OpenRecError.invalidResponse("Could not start the Google Calendar connection."))
                }
            }

            let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems
            guard items?.first(where: { $0.name == "status" })?.value == "connected" else {
                throw OpenRecError.invalidResponse("The Google Calendar connection was not completed.")
            }
            if let email = items?.first(where: { $0.name == "email" })?.value,
               !calendarEmails.contains(email) {
                calendarEmails.append(email)
                UserDefaults.standard.set(calendarEmails, forKey: "CalendarEmails")
            }
            await refreshCalendarConnectionStatus()
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    /// Ask the backend which Google accounts currently serve calendar context.
    func refreshCalendarConnectionStatus() async {
        guard mode == .managed,
              let context = try? captureStorageContext(),
              let base = context.managedBaseURL,
              let token = context.managedToken,
              !token.isEmpty else { return }
        var request = URLRequest(url: base.appendingPathComponent("v1/calendar/status"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (try? validate(response: response, data: data)) != nil,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        calendarEmails = root["emails"] as? [String] ?? []
        UserDefaults.standard.set(calendarEmails, forKey: "CalendarEmails")
    }

    /// Remove one connected calendar account.
    func disconnectCalendar(email: String) async {
        guard mode == .managed,
              let context = try? captureStorageContext(),
              let base = context.managedBaseURL,
              let token = context.managedToken,
              !token.isEmpty else { return }
        var components = URLComponents(
            url: base.appendingPathComponent("v1/calendar/connection"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "email", value: email)]
        guard let url = components?.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        _ = try? await URLSession.shared.data(for: request)
        await refreshCalendarConnectionStatus()
    }

    func signInWithGoogle() async {
        guard !isSigningIn else { return }
        isSigningIn = true
        statusMessage = nil
        defer { isSigningIn = false }

        do {
            let base = try validatedManagedBaseURL()
            let callbackScheme = authCallbackScheme
            var components = URLComponents(url: base.appendingPathComponent("v1/auth/google/start"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "redirect_uri", value: "\(callbackScheme)://auth")]
            guard let startURL = components.url else { throw OpenRecError.invalidConfiguration("Invalid sign-in URL.") }

            let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
                let session = ASWebAuthenticationSession(url: startURL, callbackURLScheme: callbackScheme) { url, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let url { continuation.resume(returning: url) }
                    else { continuation.resume(throwing: OpenRecError.invalidResponse("Google sign-in returned no callback.")) }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                authSession = session
                if !session.start() {
                    continuation.resume(throwing: OpenRecError.invalidResponse("Could not start Google sign-in."))
                }
            }

            guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value else {
                throw OpenRecError.invalidResponse("Google sign-in returned no authorization code.")
            }
            let result = try await exchange(code: code, baseURL: base)
            KeychainStore.set(result.token, for: "managed-session-token")
            managedEmail = result.email
            UserDefaults.standard.set(result.email, forKey: "ManagedEmail")
            mode = .managed
            statusMessage = "Signed in as \(result.email)"
            objectWillChange.send()
            // Rehydrate privacy-scrubbed recovery/deferred-cleanup records as
            // soon as the account is available again. RecorderManager observes
            // the refreshed library and rearms any scheduled media deletion.
            await refreshLibrary()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func signOut() {
        let token = KeychainStore.string(for: "managed-session-token")
        if !token.isEmpty {
            Task { await revokeManagedSession(token: token) }
        }
        let preservedRecoveryIndex = scrubManagedLocalIndexForSignOut()
        KeychainStore.set("", for: "managed-session-token")
        managedEmail = nil
        UserDefaults.standard.removeObject(forKey: "ManagedEmail")
        libraryMeetings = loadLocalMeetingRecords()
        let mediaCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("\(applicationSupportNamespace)/Media", isDirectory: true)
        try? FileManager.default.removeItem(at: mediaCache)
        statusMessage = preservedRecoveryIndex
            ? "Signed out"
            : "Signed out. Some local recovery links could not be preserved. Your recording files were not deleted."
        objectWillChange.send()
    }

    /// Signing out removes cloud-derived meeting memory from this Mac. Records
    /// with local media or unfinished work are replaced by privacy-scrubbed
    /// artifact stubs: no title, transcript, summary, participants, or decisions
    /// remain. The stubs stay hidden while signed out, but their paths stop those
    /// explicit recovery files from being re-imported as ordinary meetings and
    /// allow work to resume after the same user signs in again. Media files are
    /// never deleted here. If a stub cannot be written, fail closed by removing
    /// the private metadata JSON and leave the user's recording file untouched.
    private func scrubManagedLocalIndexForSignOut() -> Bool {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: meetingsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        var preservedEveryLink = true
        for url in urls where url.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: url) else { continue }
            if let meeting = try? Self.jsonDecoder.decode(MeetingRecord.self, from: data) {
                guard meeting.storageMode == .managed else { continue }
                do {
                    if let stub = ManagedSignOutPrivacy.scrubbedArtifactStub(
                        from: meeting,
                        fileExists: { FileManager.default.fileExists(atPath: $0) }
                    ) {
                        try Self.jsonEncoder.encode(stub).write(to: url, options: .atomic)
                    } else {
                        try FileManager.default.removeItem(at: url)
                    }
                } catch {
                    preservedEveryLink = false
                    try? FileManager.default.removeItem(at: url)
                }
            } else if (try? Self.jsonDecoder.decode(MeetingPayload.self, from: data)) != nil {
                // The legacy payload-only format has no local recovery paths.
                // In managed mode it is cloud-derived private data, so remove it.
                do { try FileManager.default.removeItem(at: url) }
                catch { preservedEveryLink = false }
            }
        }
        return preservedEveryLink
    }

    private func revokeManagedSession(token: String) async {
        do {
            let base = try validatedManagedBaseURL()
            var request = URLRequest(url: base.appendingPathComponent("v1/auth/session"))
            request.httpMethod = "DELETE"
            request.timeoutInterval = 15
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response, data: data)
        } catch {
            statusMessage = "Signed out on this Mac. The old cloud session will expire automatically."
        }
    }

    func currentCalendarCall(storageContext: CloudStorageContext? = nil) async throws -> CalendarCallContext? {
        let context = try storageContext ?? captureStorageContext()
        guard context.mode == .managed,
              let base = context.managedBaseURL,
              let token = context.managedToken,
              !token.isEmpty else { return nil }
        var request = URLRequest(url: base.appendingPathComponent("v1/calendar/current"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenRecError.invalidResponse("The calendar server returned unreadable data.")
        }
        guard let event = root["event"] as? [String: Any] else { return nil }
        let title = event["title"] as? String ?? "Calendar call"
        let participants = event["participants"] as? [String] ?? []
        return CalendarCallContext(title: title, participants: participants)
    }

    /// Ongoing and upcoming Google Calendar events for the "Coming up" list.
    /// Returns nil when the account cannot serve calendar context (own-R2
    /// mode, signed out, or a sign-in that predates calendar access).
    func upcomingCalendarEvents(withinDays days: Int = 7) async -> [UpcomingCalendarEvent]? {
        guard mode == .managed,
              let context = try? captureStorageContext(),
              let base = context.managedBaseURL,
              let token = context.managedToken,
              !token.isEmpty else { return nil }
        var components = URLComponents(
            url: base.appendingPathComponent("v1/calendar/upcoming"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "days", value: String(days))]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (try? validate(response: response, data: data)) != nil,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = root["events"] as? [[String: Any]] else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        return events.compactMap { event -> UpcomingCalendarEvent? in
            guard let title = event["title"] as? String, !title.isEmpty,
                  let startsAt = event["startsAt"] as? String,
                  let start = iso.date(from: startsAt) ?? isoPlain.date(from: startsAt) else { return nil }
            let end = (event["endsAt"] as? String).flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) } ?? start
            return UpcomingCalendarEvent(
                id: event["id"] as? String ?? "\(title)-\(start.timeIntervalSince1970)",
                title: title,
                start: start,
                end: end
            )
        }
    }

    func saveMeeting(
        _ payload: MeetingPayload,
        includeTranscript: Bool,
        hasScreenRecording: Bool = false,
        hasAudioRecording: Bool = false,
        isFinal: Bool = true,
        storageMode: StorageMode? = nil,
        storageContext: CloudStorageContext? = nil
    ) async throws {
        let context = try storageContext ?? captureStorageContext(for: storageMode)
        let selectedMode = context.mode
        if selectedMode == .ownR2 {
            // A BYO bucket is media + recoverable meeting metadata only. Keep
            // the raw transcript in this Mac's local library so it is never
            // written into object storage merely to make the manifest portable.
            let cloudPayload = MeetingPayload(
                id: payload.id,
                startedAt: payload.startedAt,
                endedAt: payload.endedAt,
                callApp: payload.callApp,
                callTitle: payload.callTitle,
                transcript: "",
                insights: payload.insights,
                durationSeconds: payload.durationSeconds
            )
            guard let signer = context.r2Signer else {
                throw OpenRecError.invalidConfiguration("The R2 recording context is unavailable.")
            }
            let previous = try? await fetchOwnR2Manifest(meetingID: payload.id, signer: signer)
            var media = previous?.media.filter { object in
                (object.kind == MeetingMediaKind.screen.rawValue && hasScreenRecording)
                    || (object.kind == MeetingMediaKind.audio.rawValue && hasAudioRecording)
            } ?? []
            if hasScreenRecording, !media.contains(where: { $0.kind == MeetingMediaKind.screen.rawValue }) {
                media.append(OwnR2MediaObject(
                    kind: MeetingMediaKind.screen.rawValue,
                    objectKey: OwnR2MediaStreamingTransport.objectKey(meetingID: payload.id, kind: .screen),
                    contentType: "video/mp4"
                ))
            }
            if hasAudioRecording, !media.contains(where: { $0.kind == MeetingMediaKind.audio.rawValue }) {
                media.append(OwnR2MediaObject(
                    kind: MeetingMediaKind.audio.rawValue,
                    objectKey: OwnR2MediaStreamingTransport.objectKey(meetingID: payload.id, kind: .audio),
                    contentType: "audio/mp4"
                ))
            }
            let manifest = OwnR2MeetingManifest(
                payload: cloudPayload,
                hasScreenRecording: hasScreenRecording,
                hasAudioRecording: hasAudioRecording,
                storesTranscript: false,
                isComplete: isFinal,
                updatedAt: Date(),
                media: media
            )
            try await uploadR2(
                data: try Self.jsonEncoder.encode(manifest),
                objectKey: "meetings/\(payload.id.uuidString.lowercased())/meeting.json",
                contentType: "application/json",
                signer: signer
            )
            return
        }

        guard let base = context.managedBaseURL,
              let token = context.managedToken,
              !token.isEmpty else {
            throw OpenRecError.invalidConfiguration("Sign in with Google before storing transcripts in the cloud.")
        }

        var request = URLRequest(url: base.appendingPathComponent("v1/meetings/\(payload.id.uuidString.lowercased())"))
        request.httpMethod = "PUT"
        request.timeoutInterval = 45
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let cloudPayload = MeetingPayload(
            id: payload.id,
            startedAt: payload.startedAt,
            endedAt: payload.endedAt,
            callApp: payload.callApp,
            callTitle: payload.callTitle,
            transcript: includeTranscript ? payload.transcript : "",
            insights: payload.insights,
            durationSeconds: payload.durationSeconds
        )
        request.httpBody = try Self.jsonEncoder.encode(cloudPayload)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
    }

    func uploadMedia(
        meetingID: UUID,
        screenURL: URL?,
        audioURL: URL?,
        storageContext: CloudStorageContext? = nil
    ) async throws {
        let context = try storageContext ?? captureStorageContext()
        switch context.mode {
        case .managed:
            guard let base = context.managedBaseURL, let token = context.managedToken else {
                throw OpenRecError.invalidConfiguration("The OpenRec Cloud recording context is unavailable.")
            }
            if let screenURL {
                try await uploadManaged(fileURL: screenURL, meetingID: meetingID, kind: "screen", baseURL: base, token: token)
            }
            if let audioURL {
                try await uploadManaged(fileURL: audioURL, meetingID: meetingID, kind: "audio", baseURL: base, token: token)
            }
        case .ownR2:
            guard let signer = context.r2Signer else {
                throw OpenRecError.invalidConfiguration("The R2 recording context is unavailable.")
            }
            let prefix = "meetings/\(meetingID.uuidString.lowercased())"
            if let screenURL {
                try await uploadR2(fileURL: screenURL, objectKey: "\(prefix)/recording.\(screenURL.pathExtension)", signer: signer)
            }
            if let audioURL {
                try await uploadR2(fileURL: audioURL, objectKey: "\(prefix)/audio.\(audioURL.pathExtension)", signer: signer)
            }
        }
    }

    /// Starts a bounded cloud-first media session. Managed storage receives a
    /// provisional meeting row before either multipart upload begins; the final
    /// `saveMeeting` call replaces that placeholder with analyzed metadata.
    func beginMediaStreaming(
        meetingID: UUID,
        kinds: [MeetingMediaKind],
        startedAt: Date = Date(),
        callApp: String? = nil,
        callTitle: String? = nil,
        storageContext: CloudStorageContext? = nil,
        progress: MediaStreamingProgressHandler? = nil
    ) async throws -> MediaStreamingSession {
        // Credentials may have been added after launch; retry any exact stale
        // aborts before opening fresh multipart generations.
        await abortStaleMediaUploadsFromPriorLaunch()
        let descriptor = MediaStreamingMeetingDescriptor(
            meetingID: meetingID,
            startedAt: startedAt,
            callApp: callApp,
            callTitle: callTitle
        )
        let context = try storageContext ?? captureStorageContext()
        let transport: any MediaStreamingTransport
        switch context.mode {
        case .managed:
            guard let base = context.managedBaseURL,
                  let token = context.managedToken,
                  !token.isEmpty else {
                throw OpenRecError.invalidConfiguration("The OpenRec Cloud recording context is unavailable.")
            }
            transport = ManagedMediaStreamingTransport(baseURL: base, token: token)
        case .ownR2:
            guard let signer = context.r2Signer else {
                throw OpenRecError.invalidConfiguration("The R2 recording context is unavailable.")
            }
            transport = OwnR2MediaStreamingTransport(signer: signer)
        }
        return try await MediaStreamingSession.begin(
            descriptor: descriptor,
            kinds: kinds,
            transport: transport,
            progressHandler: progress
        )
    }

    /// Resolves access after a streaming-session object has gone away (for
    /// example, library playback or a webhook retry after relaunch). The current
    /// storage mode and credentials are snapshotted when this method starts.
    func accessURL(
        meetingID: UUID,
        kind: MeetingMediaKind,
        ttl: TimeInterval = 15 * 60,
        storageContext: CloudStorageContext? = nil
    ) async throws -> RemoteMediaAccess {
        let selectedTransport: any MediaStreamingTransport
        if let storageContext {
            selectedTransport = try transport(for: storageContext)
        } else {
            selectedTransport = try mediaStreamingTransportSnapshot()
        }
        return try await selectedTransport.accessURL(meetingID: meetingID, kind: kind, ttl: ttl)
    }

    /// Deletes retained media when no live session is available. Managed cloud
    /// also clears the meeting's D1 media pointer; BYO R2 removes the fixed v2
    /// object key. Final metadata persistence updates the BYO manifest flags.
    func deleteMedia(
        meetingID: UUID,
        kind: MeetingMediaKind,
        storageMode: StorageMode? = nil,
        storageContext: CloudStorageContext? = nil
    ) async throws {
        let selectedTransport: any MediaStreamingTransport
        if let storageContext {
            selectedTransport = try transport(for: storageContext)
        } else {
            selectedTransport = try mediaStreamingTransportSnapshot(for: storageMode ?? mode)
        }
        try await selectedTransport.deleteMedia(meetingID: meetingID, kind: kind)
    }

    /// Removes an exact, unfinished meeting created before capture began. This
    /// is intentionally separate from normal meeting deletion: callers use it
    /// only after aborting that meeting's multipart session, so a failed start
    /// cannot leave an empty row in the user's library.
    func discardAbandonedMeeting(
        meetingID: UUID,
        storageMode: StorageMode,
        storageContext: CloudStorageContext? = nil
    ) async throws {
        let context = try storageContext ?? captureStorageContext(for: storageMode)
        if context.mode == .managed {
            guard let base = context.managedBaseURL,
                  let token = context.managedToken,
                  !token.isEmpty else {
                throw OpenRecError.invalidConfiguration("Your OpenRec Cloud session expired before the empty recording could be cleaned up.")
            }
            var request = URLRequest(
                url: base.appendingPathComponent("v1/meetings/\(meetingID.uuidString.lowercased())")
            )
            request.httpMethod = "DELETE"
            request.timeoutInterval = 30
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response, data: data)
        }

        let localURL = meetingsDirectory.appendingPathComponent("\(meetingID.uuidString.lowercased()).json")
        if FileManager.default.fileExists(atPath: localURL.path) {
            try FileManager.default.removeItem(at: localURL)
        }
        libraryMeetings.removeAll { $0.id == meetingID }
    }

    /// Permanently deletes a saved meeting everywhere it lives: cloud metadata
    /// and media for its storage mode, retained local artifact files, and the
    /// local library record. Callers confirm with the user first.
    func deleteMeeting(_ meeting: MeetingRecord) async throws {
        switch meeting.storageMode {
        case .managed:
            let context = try captureStorageContext(for: .managed)
            guard let base = context.managedBaseURL,
                  let token = context.managedToken,
                  !token.isEmpty else {
                throw OpenRecError.invalidConfiguration("Sign in to OpenRec Cloud before deleting this meeting.")
            }
            var request = URLRequest(
                url: base.appendingPathComponent("v1/meetings/\(meeting.id.uuidString.lowercased())")
            )
            request.httpMethod = "DELETE"
            request.timeoutInterval = 45
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response, data: data)
        case .ownR2:
            do {
                let context = try captureStorageContext(for: .ownR2)
                guard let signer = context.r2Signer else {
                    throw OpenRecError.invalidConfiguration("The R2 recording context is unavailable.")
                }
                let prefix = "meetings/\(meeting.id.uuidString.lowercased())"
                // R2 treats deleting a missing key as success, so removing the
                // full fixed key set (including sidecar backups) is safe.
                for objectKey in [
                    OwnR2MediaStreamingTransport.objectKey(meetingID: meeting.id, kind: .screen),
                    OwnR2MediaStreamingTransport.objectKey(meetingID: meeting.id, kind: .audio),
                    "\(prefix)/transcript.txt",
                    "\(prefix)/meeting.json",
                ] {
                    let request = try signer.signedDeleteRequest(objectKey: objectKey)
                    let (data, response) = try await URLSession.shared.data(for: request)
                    try validate(response: response, data: data)
                }
            } catch {
                // Without working R2 credentials the bucket cannot be touched.
                // A meeting that never marked cloud media can still be removed
                // locally; one with cloud media must not silently orphan it.
                if meeting.hasScreenRecording || meeting.hasAudioRecording { throw error }
            }
        }

        if let path = meeting.localScreenPath { try? FileManager.default.removeItem(atPath: path) }
        if let path = meeting.localAudioPath { try? FileManager.default.removeItem(atPath: path) }
        let localURL = meetingsDirectory.appendingPathComponent("\(meeting.id.uuidString.lowercased()).json")
        if FileManager.default.fileExists(atPath: localURL.path) {
            try FileManager.default.removeItem(at: localURL)
        }
        libraryMeetings.removeAll { $0.id == meeting.id }
    }

    private func mediaStreamingTransportSnapshot() throws -> any MediaStreamingTransport {
        try mediaStreamingTransportSnapshot(for: mode)
    }

    private func mediaStreamingTransportSnapshot(for storageMode: StorageMode) throws -> any MediaStreamingTransport {
        try transport(for: captureStorageContext(for: storageMode))
    }

    private func transport(for context: CloudStorageContext) throws -> any MediaStreamingTransport {
        switch context.mode {
        case .managed:
            guard let base = context.managedBaseURL,
                  let token = context.managedToken,
                  !token.isEmpty else {
                throw OpenRecError.invalidConfiguration("Your OpenRec Cloud session expired. Sign in again.")
            }
            return ManagedMediaStreamingTransport(baseURL: base, token: token)
        case .ownR2:
            guard let signer = context.r2Signer else {
                throw OpenRecError.invalidConfiguration("The R2 recording context is unavailable.")
            }
            return OwnR2MediaStreamingTransport(signer: signer)
        }
    }

    private func uploadManaged(fileURL: URL, meetingID: UUID, kind: String) async throws {
        let base = try validatedManagedBaseURL()
        let token = KeychainStore.string(for: "managed-session-token")
        guard !token.isEmpty else { throw OpenRecError.invalidConfiguration("Your OpenRec Cloud session expired. Sign in again.") }

        try await uploadManaged(fileURL: fileURL, meetingID: meetingID, kind: kind, baseURL: base, token: token)
    }

    private func uploadManaged(
        fileURL: URL,
        meetingID: UUID,
        kind: String,
        baseURL: URL,
        token: String
    ) async throws {

        let fileSize = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        if fileSize > Self.managedSingleUploadLimit {
            try await uploadManagedMultipart(
                fileURL: fileURL,
                fileSize: fileSize,
                meetingID: meetingID,
                kind: kind,
                base: baseURL,
                token: token
            )
            return
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/meetings/\(meetingID.uuidString.lowercased())/media/\(kind)"))
        request.httpMethod = "PUT"
        request.timeoutInterval = 600
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType(for: fileURL), forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
        try validate(response: response, data: data)
    }

    private func uploadManagedMultipart(
        fileURL: URL,
        fileSize: Int,
        meetingID: UUID,
        kind: String,
        base: URL,
        token: String
    ) async throws {
        let route = "v1/meetings/\(meetingID.uuidString.lowercased())/media/\(kind)/multipart"
        var createRequest = URLRequest(url: base.appendingPathComponent(route))
        createRequest.httpMethod = "POST"
        createRequest.timeoutInterval = 30
        createRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (createData, createResponse) = try await URLSession.shared.data(for: createRequest)
        try validate(response: createResponse, data: createData)
        let session = try Self.jsonDecoder.decode(ManagedMultipartSession.self, from: createData)

        do {
            var uploadedParts: [ManagedMultipartPart] = []
            var offset = 0
            var partNumber = 1
            while offset < fileSize {
                let byteCount = min(Self.managedMultipartPartSize, fileSize - offset)
                let partData = try await Task.detached(priority: .utility) {
                    try Self.readChunk(from: fileURL, offset: UInt64(offset), count: byteCount)
                }.value
                guard !partData.isEmpty else {
                    throw OpenRecError.invalidResponse("The recording ended unexpectedly while OpenRec was uploading it.")
                }

                let partURL = try managedMultipartURL(
                    base: base,
                    route: route,
                    uploadID: session.uploadId,
                    suffix: "parts/\(partNumber)"
                )
                var partRequest = URLRequest(url: partURL)
                partRequest.httpMethod = "PUT"
                partRequest.timeoutInterval = 600
                partRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                partRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                let (partResponseData, partResponse) = try await URLSession.shared.upload(for: partRequest, from: partData)
                try validate(response: partResponse, data: partResponseData)
                uploadedParts.append(try Self.jsonDecoder.decode(ManagedMultipartPart.self, from: partResponseData))
                offset += partData.count
                partNumber += 1
            }

            let completeURL = try managedMultipartURL(
                base: base,
                route: route,
                uploadID: session.uploadId,
                suffix: "complete"
            )
            var completeRequest = URLRequest(url: completeURL)
            completeRequest.httpMethod = "POST"
            completeRequest.timeoutInterval = 120
            completeRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            completeRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            completeRequest.httpBody = try Self.jsonEncoder.encode(ManagedMultipartCompletion(parts: uploadedParts))
            let (completeData, completeResponse) = try await URLSession.shared.data(for: completeRequest)
            try validate(response: completeResponse, data: completeData)
        } catch {
            if let abortURL = try? managedMultipartURL(base: base, route: route, uploadID: session.uploadId) {
                var abortRequest = URLRequest(url: abortURL)
                abortRequest.httpMethod = "DELETE"
                abortRequest.timeoutInterval = 30
                abortRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                _ = try? await URLSession.shared.data(for: abortRequest)
            }
            throw error
        }
    }

    private func managedMultipartURL(base: URL, route: String, uploadID: String, suffix: String? = nil) throws -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        guard let encodedUploadID = uploadID.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw OpenRecError.invalidResponse("The cloud returned an invalid upload session.")
        }
        let basePath = components?.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let prefix = basePath.isEmpty ? "" : "/\(basePath)"
        components?.percentEncodedPath = "\(prefix)/\(route)/\(encodedUploadID)" + (suffix.map { "/\($0)" } ?? "")
        guard let url = components?.url else {
            throw OpenRecError.invalidResponse("The cloud returned an invalid upload URL.")
        }
        return url
    }

    private nonisolated static func readChunk(from url: URL, offset: UInt64, count: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: count) ?? Data()
    }

    private func uploadR2(fileURL: URL, objectKey: String) async throws {
        guard !r2AccountID.isEmpty, !r2Bucket.isEmpty, !r2AccessKeyID.isEmpty, !r2SecretAccessKey.isEmpty else {
            throw OpenRecError.invalidConfiguration("Complete the R2 account, bucket, access key, and secret key fields.")
        }
        let signer = R2RequestSigner(
            accountID: r2AccountID,
            bucket: r2Bucket,
            accessKeyID: r2AccessKeyID,
            secretAccessKey: r2SecretAccessKey
        )
        try await uploadR2(fileURL: fileURL, objectKey: objectKey, signer: signer)
    }

    private func uploadR2(
        fileURL: URL,
        objectKey: String,
        signer: R2RequestSigner
    ) async throws {
        let mediaContentType = contentType(for: fileURL)
        var request = try await Task.detached(priority: .utility) {
            try signer.signedPutRequest(fileURL: fileURL, objectKey: objectKey, contentType: mediaContentType)
        }.value
        request.timeoutInterval = 600
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
        try validate(response: response, data: data)
    }

    private func uploadR2(data: Data, objectKey: String, contentType: String) async throws {
        guard !r2AccountID.isEmpty, !r2Bucket.isEmpty, !r2AccessKeyID.isEmpty, !r2SecretAccessKey.isEmpty else {
            throw OpenRecError.invalidConfiguration("Complete the R2 account, bucket, access key, and secret key fields.")
        }
        let signer = R2RequestSigner(
            accountID: r2AccountID,
            bucket: r2Bucket,
            accessKeyID: r2AccessKeyID,
            secretAccessKey: r2SecretAccessKey
        )
        try await uploadR2(data: data, objectKey: objectKey, contentType: contentType, signer: signer)
    }

    private func uploadR2(
        data: Data,
        objectKey: String,
        contentType: String,
        signer: R2RequestSigner
    ) async throws {
        var request = try signer.signedPutRequest(data: data, objectKey: objectKey, contentType: contentType)
        request.timeoutInterval = 60
        let (responseData, response) = try await URLSession.shared.upload(for: request, from: data)
        try validate(response: response, data: responseData)
    }

    func upsertLocalMeeting(_ meeting: MeetingRecord) throws {
        try FileManager.default.createDirectory(at: meetingsDirectory, withIntermediateDirectories: true)
        let url = meetingsDirectory.appendingPathComponent("\(meeting.id.uuidString.lowercased()).json")
        try Self.jsonEncoder.encode(meeting).write(to: url, options: .atomic)
        mergeIntoLibrary(meeting)
    }

    /// Turn jobs left behind by a crash into an actionable library state.
    /// A job that had already reached cleanup is complete apart from applying
    /// local retention, so it can be finalized without re-sending a webhook.
    func recoverInterruptedSaves() {
        let interrupted = libraryMeetings.filter { $0.saveStatus == .processing }
        for var meeting in interrupted {
            if meeting.saveStage == .cleaningUp,
               !meeting.hasScreenRecording,
               !meeting.hasAudioRecording {
                let transcriptURL = meeting.localScreenPath.map { path -> URL in
                    let screenURL = URL(fileURLWithPath: path)
                    let baseName = screenURL.deletingPathExtension().lastPathComponent
                    return screenURL.deletingLastPathComponent().appendingPathComponent("\(baseName)_transcript.txt")
                }
                if !meeting.preferences.keepScreenRecording, let path = meeting.localScreenPath {
                    try? FileManager.default.removeItem(atPath: path)
                    meeting.localScreenPath = nil
                }
                if !meeting.preferences.keepAudioRecording, let path = meeting.localAudioPath {
                    try? FileManager.default.removeItem(atPath: path)
                    meeting.localAudioPath = nil
                }
                if !meeting.preferences.storeTranscriptInCloud {
                    meeting.transcript = nil
                    if let transcriptURL { try? FileManager.default.removeItem(at: transcriptURL) }
                }
                meeting.saveStatus = .saved
                meeting.saveStage = .complete
                meeting.errorMessage = nil
            } else if meeting.saveStage == .deliveringWebhook {
                // Core metadata and media are already safe at this stage. The
                // external receiver may or may not have accepted the request,
                // so expose an idempotent webhook-only retry.
                meeting.saveStatus = .saved
                meeting.saveStage = .complete
                meeting.errorMessage = nil
                meeting.webhookDeliveryStatus = .failed
                meeting.webhookErrorMessage = "Delivery was interrupted. Retry to confirm the external webhook received this meeting."
            } else if meeting.hasScreenRecording || meeting.hasAudioRecording {
                meeting.saveStatus = .failed
                meeting.errorMessage = "The recording is safe in cloud storage. Retry to finish transcription, retention, and meeting details."
            } else if meeting.localScreenURL != nil {
                meeting.saveStatus = .failed
                meeting.errorMessage = "Saving was interrupted. Retry to finish this meeting from its local recovery files."
            } else {
                meeting.saveStatus = .failed
                meeting.errorMessage = "Cloud streaming stopped before a playable recording was finalized. No local recording was created."
            }
            meeting.updatedAt = Date()
            try? upsertLocalMeeting(meeting)
        }
    }

    func localMeeting(id: UUID) -> MeetingRecord? {
        libraryMeetings.first(where: { $0.id == id }) ?? loadLocalMeetingRecords().first(where: { $0.id == id })
    }

    func refreshLibrary() async {
        guard !isLoadingLibrary else { return }
        isLoadingLibrary = true
        libraryError = nil
        defer { isLoadingLibrary = false }

        let local = loadLocalMeetingRecords()
        do {
            let remote: [MeetingRecord]
            switch mode {
            case .managed:
                guard isManagedSignedIn else {
                    libraryMeetings = local.sorted { $0.startedAt > $1.startedAt }
                    return
                }
                remote = try await fetchManagedMeetings()
            case .ownR2:
                guard isReady else {
                    libraryMeetings = local.sorted { $0.startedAt > $1.startedAt }
                    return
                }
                remote = try await fetchOwnR2Meetings()
            }
            libraryMeetings = merge(remote: remote, local: local)
        } catch {
            libraryMeetings = local.sorted { $0.startedAt > $1.startedAt }
            libraryError = "Cloud meetings could not be refreshed. Showing this Mac’s meetings. \(error.localizedDescription)"
        }
    }

    func meetingDetail(for summary: MeetingRecord) async throws -> MeetingRecord {
        // Failed and in-progress managed records are authoritative local recovery
        // state; finalization may have failed before a cloud row existed.
        guard summary.storageMode == .managed,
              summary.saveStatus == .saved,
              isManagedSignedIn else { return summary }
        let base = try validatedManagedBaseURL()
        let token = KeychainStore.string(for: "managed-session-token")
        var request = URLRequest(url: base.appendingPathComponent("v1/meetings/\(summary.id.uuidString.lowercased())"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 404 {
            // Keep a locally saved/recovered summary usable if its corresponding
            // cloud row was never finalized or was removed independently.
            return summary
        }
        try validate(response: response, data: data)
        let envelope = try Self.jsonDecoder.decode(CloudMeetingDetailEnvelope.self, from: data)
        var detail = envelope.meeting.record(storageMode: .managed)
        if let local = localMeeting(id: detail.id) { detail = merge(remote: detail, local: local) }
        mergeIntoLibrary(detail)
        return detail
    }

    func mediaURL(
        for meeting: MeetingRecord,
        kind: MeetingMediaKind,
        storageContext: CloudStorageContext? = nil
    ) async throws -> URL {
        // Existing user-owned recovery files remain playable. New recordings
        // stream directly from short-lived cloud URLs and never download a full
        // duplicate into the app cache.
        if kind == .screen, let local = meeting.localScreenURL { return local }
        if kind == .audio, let local = meeting.localAudioURL { return local }

        let hasRemote = kind == .screen ? meeting.hasScreenRecording : meeting.hasAudioRecording
        guard hasRemote else { throw OpenRecError.invalidResponse("This meeting has no \(kind.label.lowercased()).") }

        let context = try storageContext ?? captureStorageContext(for: meeting.storageMode)
        return try await transport(for: context)
            .accessURL(meetingID: meeting.id, kind: kind, ttl: 60 * 60).url
    }

    /// Resolve the exact retained media that a webhook retry promises to send.
    /// Cloud objects win so a normal retry remains URL-only and never downloads
    /// or rebuilds the recording on this Mac. A local URL is returned only for
    /// a legacy artifact that has not reached cloud storage yet.
    func webhookMediaURLs(
        for meeting: MeetingRecord,
        storageContext: CloudStorageContext? = nil
    ) async throws -> WebhookMediaURLs {
        let screen: URL?
        if meeting.hasScreenRecording {
            screen = try await mediaURL(for: meeting, kind: .screen, storageContext: storageContext)
        } else if let local = meeting.localScreenURL {
            screen = local
        } else {
            screen = nil
        }

        let audio: URL?
        if meeting.hasAudioRecording {
            audio = try await mediaURL(for: meeting, kind: .audio, storageContext: storageContext)
        } else if let local = meeting.localAudioURL {
            audio = local
        } else {
            audio = nil
        }
        return WebhookMediaURLs(screen: screen, audio: audio)
    }

    func validateR2Connection() async throws {
        guard mode == .ownR2 else { return }
        guard !r2AccountID.isEmpty, !r2Bucket.isEmpty, !r2AccessKeyID.isEmpty, !r2SecretAccessKey.isEmpty else {
            throw OpenRecError.invalidConfiguration("Complete all four R2 fields before testing the connection.")
        }

        let signer = R2RequestSigner(
            accountID: r2AccountID,
            bucket: r2Bucket,
            accessKeyID: r2AccessKeyID,
            secretAccessKey: r2SecretAccessKey
        )
        let objectKey = "_openrec/connection-tests/\(UUID().uuidString.lowercased()).txt"
        let probe = Data("OpenRec multipart connection test".utf8)
        var uploadID: String?
        var completed = false
        do {
            let createRequest = try signer.signedCreateMultipartRequest(
                objectKey: objectKey,
                contentType: "text/plain"
            )
            let (createData, createResponse) = try await URLSession.shared.data(for: createRequest)
            try validate(response: createResponse, data: createData)
            let parser = R2MultipartUploadIDParser()
            try parser.parse(createData)
            guard let parsedUploadID = parser.uploadID, !parsedUploadID.isEmpty else {
                throw OpenRecError.invalidResponse("R2 did not return a multipart upload ID.")
            }
            uploadID = parsedUploadID

            let partRequest = try signer.signedUploadPartRequest(
                data: probe,
                objectKey: objectKey,
                uploadID: parsedUploadID,
                partNumber: 1
            )
            let (partData, partResponse) = try await URLSession.shared.upload(for: partRequest, from: probe)
            try validate(response: partResponse, data: partData)
            guard let http = partResponse as? HTTPURLResponse,
                  let etag = http.value(forHTTPHeaderField: "ETag"),
                  !etag.isEmpty else {
                throw OpenRecError.invalidResponse("R2 did not return an ETag for the multipart connection test.")
            }

            let completionBody = R2MultipartCompletionXML.encode(parts: [
                MediaUploadedPart(partNumber: 1, etag: etag)
            ])
            let completeRequest = try signer.signedCompleteMultipartRequest(
                data: completionBody,
                objectKey: objectKey,
                uploadID: parsedUploadID
            )
            let (completeData, completeResponse) = try await URLSession.shared.upload(
                for: completeRequest,
                from: completionBody
            )
            try validate(response: completeResponse, data: completeData)
            completed = true

            let getRequest = try signer.signedGetRequest(objectKey: objectKey)
            let (getData, getResponse) = try await URLSession.shared.data(for: getRequest)
            try validate(response: getResponse, data: getData)
            guard getData == probe else {
                throw OpenRecError.invalidResponse("R2 returned different bytes after completing the multipart test.")
            }
        } catch {
            if let uploadID, !completed,
               let abort = try? signer.signedAbortMultipartRequest(objectKey: objectKey, uploadID: uploadID) {
                _ = try? await URLSession.shared.data(for: abort)
            }
            if completed, let delete = try? signer.signedDeleteRequest(objectKey: objectKey) {
                _ = try? await URLSession.shared.data(for: delete)
            }
            throw error
        }
        let deleteRequest = try signer.signedDeleteRequest(objectKey: objectKey)
        let (data, response) = try await URLSession.shared.data(for: deleteRequest)
        try validate(response: response, data: data)
    }

    private var meetingsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("\(applicationSupportNamespace)/Meetings", isDirectory: true)
    }

    private var applicationSupportNamespace: String {
        Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true ? "OpenRec Dev" : "OpenRec"
    }

    private func removeLegacyRemoteMediaCacheIfNeeded() {
        let key = "RemovedLegacyRemoteMediaCacheV2"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("\(applicationSupportNamespace)/Media", isDirectory: true)
        try? FileManager.default.removeItem(at: cache)
        UserDefaults.standard.set(true, forKey: key)
    }

    private var authCallbackScheme: String {
        Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true ? "openrec-dev" : "openrec"
    }

    private func loadLocalMeetingRecords() -> [MeetingRecord] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: meetingsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        var records = urls.compactMap { url -> MeetingRecord? in
            guard url.pathExtension.lowercased() == "json", let data = try? Data(contentsOf: url) else { return nil }
            if let record = try? Self.jsonDecoder.decode(MeetingRecord.self, from: data) { return record }
            // Migrate the metadata-only format shipped before the library existed.
            guard let payload = try? Self.jsonDecoder.decode(MeetingPayload.self, from: data) else { return nil }
            return MeetingRecord(
                id: payload.id,
                startedAt: payload.startedAt,
                endedAt: payload.endedAt,
                durationSeconds: payload.durationSeconds,
                callApp: payload.callApp,
                callTitle: payload.callTitle,
                transcript: payload.transcript.isEmpty ? nil : payload.transcript,
                insights: payload.insights,
                hasScreenRecording: false,
                hasAudioRecording: false,
                screenFileExtension: nil,
                audioFileExtension: nil,
                localScreenPath: nil,
                localAudioPath: nil,
                storageMode: mode,
                preferences: CallPreferences(),
                saveStatus: .saved,
                saveStage: .complete,
                errorMessage: nil,
                createdAt: payload.endedAt,
                updatedAt: payload.endedAt
            )
        }

        let knownScreenPaths = Set(records.compactMap(\.localScreenPath))
        var imported: [MeetingRecord] = []
        for legacy in discoverLegacyRecordings() where legacy.localScreenPath.map({ !knownScreenPaths.contains($0) }) ?? true {
            if !records.contains(where: { $0.id == legacy.id }) {
                records.append(legacy)
                imported.append(legacy)
            }
        }
        if !imported.isEmpty {
            try? FileManager.default.createDirectory(at: meetingsDirectory, withIntermediateDirectories: true)
            for meeting in imported {
                let url = meetingsDirectory.appendingPathComponent("\(meeting.id.uuidString.lowercased()).json")
                try? Self.jsonEncoder.encode(meeting).write(to: url, options: .atomic)
            }
        }
        // Managed stubs deliberately remain on disk only to preserve recovery
        // links and suppress legacy re-import. They must never reappear in the
        // signed-out library or expose which meetings belonged to that account.
        if !isManagedSignedIn {
            records.removeAll { $0.storageMode == .managed }
        }
        return records.sorted { $0.startedAt > $1.startedAt }
    }

    private func discoverLegacyRecordings() -> [MeetingRecord] {
        let configured = UserDefaults.standard.string(forKey: "RecordingsDirectory").map(URL.init(fileURLWithPath:))
        let directory = configured ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OpenRec", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var meetings: [MeetingRecord] = []
        for case let screenURL as URL in enumerator
            where screenURL.pathExtension.lowercased() == "mp4"
                && screenURL.lastPathComponent.hasPrefix("recording_") {
            let base = screenURL.deletingPathExtension()
            let audioURL = base.appendingPathExtension("m4a")
            let transcriptURL = base.deletingLastPathComponent()
                .appendingPathComponent("\(base.lastPathComponent)_transcript.txt")
            let sessionFolder = screenURL.deletingLastPathComponent()
            let parent = sessionFolder.deletingLastPathComponent()
            let rawTitle = parent.standardizedFileURL == directory.standardizedFileURL ? "" : parent.lastPathComponent
            let callTitle = rawTitle.isEmpty ? nil : rawTitle.replacingOccurrences(of: "-", with: " ").capitalized
            let startedAt = Self.legacyTimestampFormatter.date(from: sessionFolder.lastPathComponent)
                ?? (try? screenURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? Date()
            let transcript = (try? String(contentsOf: transcriptURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = Self.stableMeetingID(for: screenURL.standardizedFileURL.path)
            meetings.append(MeetingRecord(
                id: id,
                startedAt: startedAt,
                endedAt: startedAt,
                durationSeconds: 0,
                callApp: nil,
                callTitle: callTitle,
                transcript: transcript?.isEmpty == false ? transcript : nil,
                insights: MeetingInsights(title: callTitle ?? "Local recording"),
                hasScreenRecording: false,
                hasAudioRecording: false,
                screenFileExtension: "mp4",
                audioFileExtension: FileManager.default.fileExists(atPath: audioURL.path) ? "m4a" : nil,
                localScreenPath: screenURL.path,
                localAudioPath: FileManager.default.fileExists(atPath: audioURL.path) ? audioURL.path : nil,
                storageMode: .ownR2,
                preferences: CallPreferences(
                    keepScreenRecording: true,
                    keepAudioRecording: FileManager.default.fileExists(atPath: audioURL.path),
                    storeTranscriptInCloud: transcript?.isEmpty == false,
                    sendToWebhook: false
                ),
                saveStatus: .saved,
                saveStage: .complete,
                errorMessage: nil,
                createdAt: startedAt,
                updatedAt: startedAt
            ))
        }
        return meetings
    }

    private static func stableMeetingID(for value: String) -> UUID {
        let digest = SHA256.hash(data: Data(value.utf8))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        let formatted = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        return UUID(uuidString: formatted) ?? UUID()
    }

    private static let legacyTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter
    }()

    func searchManagedMeetings(query: String) async throws -> [MeetingRecord] {
        guard mode == .managed, isManagedSignedIn else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try await fetchManagedMeetings(query: trimmed)
    }

    private func fetchManagedMeetings(query: String? = nil) async throws -> [MeetingRecord] {
        let base = try validatedManagedBaseURL()
        let token = KeychainStore.string(for: "managed-session-token")
        guard !token.isEmpty else { throw OpenRecError.invalidConfiguration("Sign in again to refresh cloud meetings.") }
        var records: [MeetingRecord] = []
        var offset: Int? = 0
        while let pageOffset = offset {
            var components = URLComponents(url: base.appendingPathComponent("v1/meetings"), resolvingAgainstBaseURL: false)!
            var items = [URLQueryItem(name: "offset", value: String(pageOffset))]
            if let query, !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
            components.queryItems = items
            guard let url = components.url else { throw OpenRecError.invalidConfiguration("The cloud meeting URL is invalid.") }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response, data: data)
            let envelope = try Self.jsonDecoder.decode(CloudMeetingsEnvelope.self, from: data)
            records.append(contentsOf: envelope.meetings.map { $0.record(storageMode: .managed) })
            offset = envelope.nextOffset
        }
        return records
    }

    private func fetchOwnR2Meetings() async throws -> [MeetingRecord] {
        let signer = R2RequestSigner(
            accountID: r2AccountID,
            bucket: r2Bucket,
            accessKeyID: r2AccessKeyID,
            secretAccessKey: r2SecretAccessKey
        )
        var manifestKeys: [String] = []
        var continuationToken: String?
        var seenContinuationTokens = Set<String>()
        repeat {
            let request = try signer.signedListRequest(prefix: "meetings/", continuationToken: continuationToken)
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response, data: data)
            let parser = R2ListObjectsParser()
            try parser.parse(data)
            manifestKeys.append(contentsOf: parser.keys.filter { $0.hasSuffix("/meeting.json") })
            continuationToken = parser.isTruncated ? parser.nextContinuationToken : nil
            if parser.isTruncated && continuationToken == nil {
                throw OpenRecError.invalidResponse("R2 truncated the meeting list without a continuation token.")
            }
            if let continuationToken, !seenContinuationTokens.insert(continuationToken).inserted {
                throw OpenRecError.invalidResponse("R2 repeated a continuation token while listing meetings.")
            }
        } while continuationToken != nil

        var records: [MeetingRecord] = []
        for key in manifestKeys {
            do {
                let request = try signer.signedGetRequest(objectKey: key)
                let (data, response) = try await URLSession.shared.data(for: request)
                try validate(response: response, data: data)
                records.append(try Self.jsonDecoder.decode(OwnR2MeetingManifest.self, from: data).record())
            } catch {
                // One damaged or concurrently replaced manifest must not hide
                // the rest of the user's meeting library.
                continue
            }
        }
        return records.sorted { $0.startedAt > $1.startedAt }
    }

    private func fetchOwnR2Manifest(meetingID: UUID) async throws -> OwnR2MeetingManifest {
        let signer = R2RequestSigner(
            accountID: r2AccountID,
            bucket: r2Bucket,
            accessKeyID: r2AccessKeyID,
            secretAccessKey: r2SecretAccessKey
        )
        return try await fetchOwnR2Manifest(meetingID: meetingID, signer: signer)
    }

    private func fetchOwnR2Manifest(
        meetingID: UUID,
        signer: R2RequestSigner
    ) async throws -> OwnR2MeetingManifest {
        let key = "meetings/\(meetingID.uuidString.lowercased())/meeting.json"
        let request = try signer.signedGetRequest(objectKey: key)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try Self.jsonDecoder.decode(OwnR2MeetingManifest.self, from: data)
    }

    private func merge(remote: [MeetingRecord], local: [MeetingRecord]) -> [MeetingRecord] {
        var records = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        for cloud in remote {
            records[cloud.id] = records[cloud.id].map { merge(remote: cloud, local: $0) } ?? cloud
        }
        return records.values.sorted { $0.startedAt > $1.startedAt }
    }

    private func merge(remote: MeetingRecord, local: MeetingRecord) -> MeetingRecord {
        var value = remote
        value.transcript = remote.transcript ?? local.transcript
        value.localScreenPath = local.localScreenPath
        value.localAudioPath = local.localAudioPath
        value.screenFileExtension = remote.screenFileExtension ?? local.screenFileExtension
        value.audioFileExtension = remote.audioFileExtension ?? local.audioFileExtension
        value.preferences = local.preferences
        value.saveStatus = local.saveStatus
        value.saveStage = local.saveStage
        value.errorMessage = local.errorMessage
        value.webhookDeliveryStatus = local.webhookDeliveryStatus
        value.webhookErrorMessage = local.webhookErrorMessage
        value.screenDeletionScheduledAt = local.screenDeletionScheduledAt
        value.audioDeletionScheduledAt = local.audioDeletionScheduledAt
        value.createdAt = min(remote.createdAt, local.createdAt)
        value.updatedAt = max(remote.updatedAt, local.updatedAt)
        return value
    }

    private func mergeIntoLibrary(_ meeting: MeetingRecord) {
        if let index = libraryMeetings.firstIndex(where: { $0.id == meeting.id }) {
            libraryMeetings[index] = meeting
        } else {
            libraryMeetings.append(meeting)
        }
        libraryMeetings.sort { $0.startedAt > $1.startedAt }
    }

    private func exchange(code: String, baseURL: URL) async throws -> (token: String, email: String) {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/auth/exchange"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String,
              let email = json["email"] as? String else {
            throw OpenRecError.invalidResponse("The sign-in server returned an unreadable session.")
        }
        return (token, email)
    }

    private func validatedManagedBaseURL() throws -> URL {
        let value = managedAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), url.scheme == "https", url.host != nil else {
            throw OpenRecError.invalidConfiguration("Enter a valid HTTPS OpenRec Cloud API URL.")
        }
        return url
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw OpenRecError.invalidResponse("No HTTP response was received.") }
        guard (200..<300).contains(http.statusCode) else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = json?["error"] as? String ?? Self.sanitizedErrorBody(data, status: http.statusCode)
            throw OpenRecError.requestFailed(status: http.statusCode, message: message)
        }
    }

    /// Non-JSON failure bodies are often entire HTML error pages (gateway
    /// errors, maintenance pages). Never surface those verbatim — they flood
    /// every error label in the UI.
    nonisolated static func sanitizedErrorBody(_ data: Data, status: Int) -> String {
        guard let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty else { return "Unknown error (HTTP \(status))" }
        if raw.hasPrefix("<") || raw.lowercased().contains("<html") {
            return "The server returned an unexpected web page (HTTP \(status)). Try again in a moment."
        }
        let flattened = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return flattened.count > 240 ? String(flattened.prefix(240)) + "…" : flattened
    }

    private func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp4", "m4a": return url.pathExtension.lowercased() == "mp4" ? "video/mp4" : "audio/mp4"
        case "mp3": return "audio/mpeg"
        default: return "application/octet-stream"
        }
    }

    private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // Keep single Worker requests comfortably below Cloudflare's request-body limit.
    private static let managedSingleUploadLimit = 64 * 1024 * 1024
    // R2 multipart parts must be at least 5 MiB, except for the final part.
    private static let managedMultipartPartSize = 5 * 1024 * 1024
}

private struct ManagedMultipartSession: Decodable {
    let uploadId: String
}

private struct ManagedMultipartPart: Codable {
    let partNumber: Int
    let etag: String
}

private struct ManagedMultipartCompletion: Encodable {
    let parts: [ManagedMultipartPart]
}

struct OwnR2MediaObject: Codable, Equatable, Sendable {
    let kind: String
    let objectKey: String
    let contentType: String
    let byteCount: Int?
    let partCount: Int?

    init(
        kind: String,
        objectKey: String,
        contentType: String,
        byteCount: Int? = nil,
        partCount: Int? = nil
    ) {
        self.kind = kind
        self.objectKey = objectKey
        self.contentType = contentType
        self.byteCount = byteCount
        self.partCount = partCount
    }
}

struct OwnR2MeetingManifest: Codable {
    let schemaVersion: Int
    let payload: MeetingPayload
    let hasScreenRecording: Bool
    let hasAudioRecording: Bool
    let storesTranscript: Bool
    let isComplete: Bool
    let updatedAt: Date
    let media: [OwnR2MediaObject]

    init(
        payload: MeetingPayload,
        hasScreenRecording: Bool,
        hasAudioRecording: Bool,
        storesTranscript: Bool,
        isComplete: Bool,
        updatedAt: Date,
        media: [OwnR2MediaObject] = []
    ) {
        self.schemaVersion = 2
        self.payload = payload
        self.hasScreenRecording = hasScreenRecording
        self.hasAudioRecording = hasAudioRecording
        self.storesTranscript = storesTranscript
        self.isComplete = isComplete
        self.updatedAt = updatedAt
        self.media = media
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, payload, hasScreenRecording, hasAudioRecording
        case storesTranscript, isComplete, updatedAt, media
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        payload = try values.decode(MeetingPayload.self, forKey: .payload)
        hasScreenRecording = try values.decode(Bool.self, forKey: .hasScreenRecording)
        hasAudioRecording = try values.decode(Bool.self, forKey: .hasAudioRecording)
        storesTranscript = try values.decode(Bool.self, forKey: .storesTranscript)
        isComplete = try values.decode(Bool.self, forKey: .isComplete)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        media = try values.decodeIfPresent([OwnR2MediaObject].self, forKey: .media) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(payload, forKey: .payload)
        try values.encode(hasScreenRecording, forKey: .hasScreenRecording)
        try values.encode(hasAudioRecording, forKey: .hasAudioRecording)
        try values.encode(storesTranscript, forKey: .storesTranscript)
        try values.encode(isComplete, forKey: .isComplete)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encode(media, forKey: .media)
    }

    func record() -> MeetingRecord {
        MeetingRecord(
            id: payload.id,
            startedAt: payload.startedAt,
            endedAt: payload.endedAt,
            durationSeconds: payload.durationSeconds,
            callApp: payload.callApp,
            callTitle: payload.callTitle,
            transcript: storesTranscript && !payload.transcript.isEmpty ? payload.transcript : nil,
            insights: payload.insights,
            hasScreenRecording: hasScreenRecording,
            hasAudioRecording: hasAudioRecording,
            screenFileExtension: hasScreenRecording ? mediaExtension(kind: .screen, fallback: "mp4") : nil,
            audioFileExtension: hasAudioRecording ? mediaExtension(kind: .audio, fallback: "m4a") : nil,
            localScreenPath: nil,
            localAudioPath: nil,
            storageMode: .ownR2,
            preferences: CallPreferences(
                keepScreenRecording: hasScreenRecording,
                keepAudioRecording: hasAudioRecording,
                storeTranscriptInCloud: storesTranscript,
                sendToWebhook: false
            ),
            saveStatus: isComplete ? .saved : .failed,
            saveStage: isComplete ? .complete : .transcribing,
            errorMessage: isComplete ? nil : "The raw recordings are safe in R2, but meeting analysis was interrupted on another Mac.",
            createdAt: payload.startedAt,
            updatedAt: updatedAt
        )
    }

    private func mediaExtension(kind: MeetingMediaKind, fallback: String) -> String {
        guard let object = media.first(where: { $0.kind == kind.rawValue }) else { return fallback }
        let value = URL(fileURLWithPath: object.objectKey).pathExtension
        return value.isEmpty ? fallback : value
    }
}

private struct CloudMeetingsEnvelope: Decodable {
    let meetings: [CloudMeeting]
    let nextOffset: Int?
}

final class R2ListObjectsParser: NSObject, XMLParserDelegate {
    private(set) var keys: [String] = []
    private(set) var isTruncated = false
    private(set) var nextContinuationToken: String?
    private var currentElement = ""
    private var currentText = ""
    private var insideContents = false

    func parse(_ data: Data) throws {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            throw parser.parserError ?? OpenRecError.invalidResponse("R2 returned an unreadable object list.")
        }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""
        if elementName == "Contents" { insideContents = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if elementName == "Key", insideContents, !value.isEmpty { keys.append(value) }
        if elementName == "IsTruncated" { isTruncated = value.lowercased() == "true" }
        if elementName == "NextContinuationToken", !value.isEmpty { nextContinuationToken = value }
        if elementName == "Contents" { insideContents = false }
        currentElement = ""
        currentText = ""
    }
}

private struct CloudMeetingDetailEnvelope: Decodable {
    let meeting: CloudMeeting
}

private struct CloudMeeting: Decodable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let durationSeconds: Int
    let callApp: String?
    let callTitle: String?
    let transcript: String?
    let insights: MeetingInsights
    let hasScreenRecording: Bool
    let hasAudioRecording: Bool
    let createdAt: Date
    let updatedAt: Date

    func record(storageMode: StorageMode) -> MeetingRecord {
        MeetingRecord(
            id: id,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: durationSeconds,
            callApp: callApp,
            callTitle: callTitle,
            transcript: transcript?.isEmpty == true ? nil : transcript,
            insights: insights,
            hasScreenRecording: hasScreenRecording,
            hasAudioRecording: hasAudioRecording,
            screenFileExtension: hasScreenRecording ? "mp4" : nil,
            audioFileExtension: hasAudioRecording ? "m4a" : nil,
            localScreenPath: nil,
            localAudioPath: nil,
            storageMode: storageMode,
            preferences: CallPreferences(
                keepScreenRecording: hasScreenRecording,
                keepAudioRecording: hasAudioRecording,
                storeTranscriptInCloud: transcript?.isEmpty == false,
                sendToWebhook: false
            ),
            saveStatus: .saved,
            saveStage: .complete,
            errorMessage: nil,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

struct R2RequestSigner {
    let accountID: String
    let bucket: String
    let accessKeyID: String
    let secretAccessKey: String

    func signedPutRequest(fileURL: URL, objectKey: String, contentType: String, now: Date = Date()) throws -> URLRequest {
        try signedPutRequest(
            payloadHash: sha256(fileURL: fileURL),
            objectKey: objectKey,
            contentType: contentType,
            now: now
        )
    }

    func signedPutRequest(data: Data, objectKey: String, contentType: String, now: Date = Date()) throws -> URLRequest {
        try signedPutRequest(
            payloadHash: sha256(data),
            objectKey: objectKey,
            contentType: contentType,
            now: now
        )
    }

    private func signedPutRequest(
        payloadHash: String,
        objectKey: String,
        contentType: String,
        now: Date
    ) throws -> URLRequest {
        let encodedBucket = encodePathComponent(bucket)
        let encodedKey = objectKey.split(separator: "/").map { encodePathComponent(String($0)) }.joined(separator: "/")
        let host = "\(accountID).r2.cloudflarestorage.com"
        guard let url = URL(string: "https://\(host)/\(encodedBucket)/\(encodedKey)") else {
            throw OpenRecError.invalidConfiguration("The R2 account or bucket produced an invalid upload URL.")
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = formatter.string(from: now)
        formatter.dateFormat = "yyyyMMdd"
        let dateStamp = formatter.string(from: now)

        let canonicalURI = "/\(encodedBucket)/\(encodedKey)"
        let canonicalHeaders = "content-type:\(contentType)\nhost:\(host)\nx-amz-content-sha256:\(payloadHash)\nx-amz-date:\(amzDate)\n"
        let signedHeaders = "content-type;host;x-amz-content-sha256;x-amz-date"
        let canonicalRequest = "PUT\n\(canonicalURI)\n\n\(canonicalHeaders)\n\(signedHeaders)\n\(payloadHash)"
        let scope = "\(dateStamp)/auto/s3/aws4_request"
        let stringToSign = "AWS4-HMAC-SHA256\n\(amzDate)\n\(scope)\n\(sha256(Data(canonicalRequest.utf8)))"

        let dateKey = hmac(key: Data("AWS4\(secretAccessKey)".utf8), data: Data(dateStamp.utf8))
        let regionKey = hmac(key: dateKey, data: Data("auto".utf8))
        let serviceKey = hmac(key: regionKey, data: Data("s3".utf8))
        let signingKey = hmac(key: serviceKey, data: Data("aws4_request".utf8))
        let signature = hmac(key: signingKey, data: Data(stringToSign.utf8)).hexString

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue("AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)", forHTTPHeaderField: "Authorization")
        return request
    }

    func signedGetRequest(objectKey: String, now: Date = Date()) throws -> URLRequest {
        try signedEmptyPayloadRequest(method: "GET", objectKey: objectKey, now: now)
    }

    func signedHeadRequest(objectKey: String, now: Date = Date()) throws -> URLRequest {
        try signedEmptyPayloadRequest(method: "HEAD", objectKey: objectKey, now: now)
    }

    func signedDeleteRequest(objectKey: String, now: Date = Date()) throws -> URLRequest {
        try signedEmptyPayloadRequest(method: "DELETE", objectKey: objectKey, now: now)
    }

    func signedCreateMultipartRequest(
        objectKey: String,
        contentType: String,
        now: Date = Date()
    ) throws -> URLRequest {
        try signedObjectQueryRequest(
            method: "POST",
            objectKey: objectKey,
            query: [("uploads", "")],
            payloadHash: sha256(Data()),
            contentType: contentType,
            now: now
        )
    }

    func signedUploadPartRequest(
        data: Data,
        objectKey: String,
        uploadID: String,
        partNumber: Int,
        now: Date = Date()
    ) throws -> URLRequest {
        guard (1...10_000).contains(partNumber) else {
            throw OpenRecError.invalidConfiguration("R2 multipart part numbers must be between 1 and 10,000.")
        }
        return try signedObjectQueryRequest(
            method: "PUT",
            objectKey: objectKey,
            query: [("partNumber", String(partNumber)), ("uploadId", uploadID)],
            payloadHash: sha256(data),
            contentType: "application/octet-stream",
            now: now
        )
    }

    func signedCompleteMultipartRequest(
        data: Data,
        objectKey: String,
        uploadID: String,
        now: Date = Date()
    ) throws -> URLRequest {
        try signedObjectQueryRequest(
            method: "POST",
            objectKey: objectKey,
            query: [("uploadId", uploadID)],
            payloadHash: sha256(data),
            contentType: "application/xml",
            now: now
        )
    }

    func signedAbortMultipartRequest(
        objectKey: String,
        uploadID: String,
        now: Date = Date()
    ) throws -> URLRequest {
        try signedObjectQueryRequest(
            method: "DELETE",
            objectKey: objectKey,
            query: [("uploadId", uploadID)],
            payloadHash: sha256(Data()),
            contentType: nil,
            now: now
        )
    }

    func presignedGetURL(
        objectKey: String,
        expiresIn: Int,
        now: Date = Date()
    ) throws -> URL {
        guard (1...604_800).contains(expiresIn) else {
            throw OpenRecError.invalidConfiguration("R2 playback links must expire within seven days.")
        }
        let encodedBucket = encodePathComponent(bucket)
        let encodedKey = objectKey.split(separator: "/").map { encodePathComponent(String($0)) }.joined(separator: "/")
        let host = "\(accountID).r2.cloudflarestorage.com"
        let canonicalURI = "/\(encodedBucket)/\(encodedKey)"
        let dates = signingDates(now)
        let scope = "\(dates.dateStamp)/auto/s3/aws4_request"
        var query = [
            ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
            ("X-Amz-Credential", "\(accessKeyID)/\(scope)"),
            ("X-Amz-Date", dates.amzDate),
            ("X-Amz-Expires", String(expiresIn)),
            ("X-Amz-SignedHeaders", "host")
        ]
        let canonicalQuery = canonicalQueryString(query)
        let canonicalHeaders = "host:\(host)\n"
        let canonicalRequest = "GET\n\(canonicalURI)\n\(canonicalQuery)\n\(canonicalHeaders)\nhost\nUNSIGNED-PAYLOAD"
        let stringToSign = "AWS4-HMAC-SHA256\n\(dates.amzDate)\n\(scope)\n\(sha256(Data(canonicalRequest.utf8)))"
        let signature = signature(stringToSign: stringToSign, dateStamp: dates.dateStamp)
        query.append(("X-Amz-Signature", signature))
        let finalQuery = canonicalQueryString(query)
        guard let url = URL(string: "https://\(host)\(canonicalURI)?\(finalQuery)") else {
            throw OpenRecError.invalidConfiguration("The R2 account or bucket produced an invalid playback URL.")
        }
        return url
    }

    private func signedObjectQueryRequest(
        method: String,
        objectKey: String,
        query: [(String, String)],
        payloadHash: String,
        contentType: String?,
        now: Date
    ) throws -> URLRequest {
        let encodedBucket = encodePathComponent(bucket)
        let encodedKey = objectKey.split(separator: "/").map { encodePathComponent(String($0)) }.joined(separator: "/")
        let host = "\(accountID).r2.cloudflarestorage.com"
        let canonicalURI = "/\(encodedBucket)/\(encodedKey)"
        let canonicalQuery = canonicalQueryString(query)
        guard let url = URL(string: "https://\(host)\(canonicalURI)?\(canonicalQuery)") else {
            throw OpenRecError.invalidConfiguration("The R2 account or bucket produced an invalid multipart URL.")
        }
        let dates = signingDates(now)
        let scope = "\(dates.dateStamp)/auto/s3/aws4_request"
        let canonicalHeaders: String
        let signedHeaders: String
        if let contentType {
            canonicalHeaders = "content-type:\(contentType)\nhost:\(host)\nx-amz-content-sha256:\(payloadHash)\nx-amz-date:\(dates.amzDate)\n"
            signedHeaders = "content-type;host;x-amz-content-sha256;x-amz-date"
        } else {
            canonicalHeaders = "host:\(host)\nx-amz-content-sha256:\(payloadHash)\nx-amz-date:\(dates.amzDate)\n"
            signedHeaders = "host;x-amz-content-sha256;x-amz-date"
        }
        let canonicalRequest = "\(method)\n\(canonicalURI)\n\(canonicalQuery)\n\(canonicalHeaders)\n\(signedHeaders)\n\(payloadHash)"
        let stringToSign = "AWS4-HMAC-SHA256\n\(dates.amzDate)\n\(scope)\n\(sha256(Data(canonicalRequest.utf8)))"
        let requestSignature = signature(stringToSign: stringToSign, dateStamp: dates.dateStamp)

        var request = URLRequest(url: url)
        request.httpMethod = method
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        request.setValue(dates.amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(requestSignature)",
            forHTTPHeaderField: "Authorization"
        )
        return request
    }

    private func canonicalQueryString(_ values: [(String, String)]) -> String {
        var encoded: [(String, String)] = values.map { value in
            (encodePathComponent(value.0), encodePathComponent(value.1))
        }
        encoded.sort { lhs, rhs in
            if lhs.0 == rhs.0 { return lhs.1 < rhs.1 }
            return lhs.0 < rhs.0
        }
        return encoded.map { value in "\(value.0)=\(value.1)" }.joined(separator: "&")
    }

    private func signingDates(_ now: Date) -> (amzDate: String, dateStamp: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = formatter.string(from: now)
        formatter.dateFormat = "yyyyMMdd"
        return (amzDate, formatter.string(from: now))
    }

    private func signature(stringToSign: String, dateStamp: String) -> String {
        let dateKey = hmac(key: Data("AWS4\(secretAccessKey)".utf8), data: Data(dateStamp.utf8))
        let regionKey = hmac(key: dateKey, data: Data("auto".utf8))
        let serviceKey = hmac(key: regionKey, data: Data("s3".utf8))
        let signingKey = hmac(key: serviceKey, data: Data("aws4_request".utf8))
        return hmac(key: signingKey, data: Data(stringToSign.utf8)).hexString
    }

    func signedListRequest(prefix: String, continuationToken: String? = nil, now: Date = Date()) throws -> URLRequest {
        let encodedBucket = encodePathComponent(bucket)
        let host = "\(accountID).r2.cloudflarestorage.com"
        var query: [(String, String)] = [("list-type", "2"), ("prefix", prefix)]
        if let continuationToken, !continuationToken.isEmpty {
            query.append(("continuation-token", continuationToken))
        }
        let encodedQuery: [(String, String)] = query.map { pair in
            (encodePathComponent(pair.0), encodePathComponent(pair.1))
        }
        let sortedQuery = encodedQuery.sorted { lhs, rhs in
            if lhs.0 == rhs.0 { return lhs.1 < rhs.1 }
            return lhs.0 < rhs.0
        }
        let canonicalQuery = sortedQuery.map { pair in
            "\(pair.0)=\(pair.1)"
        }.joined(separator: "&")
        guard let url = URL(string: "https://\(host)/\(encodedBucket)/?\(canonicalQuery)") else {
            throw OpenRecError.invalidConfiguration("The R2 account or bucket produced an invalid list URL.")
        }

        let payloadHash = sha256(Data())
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = formatter.string(from: now)
        formatter.dateFormat = "yyyyMMdd"
        let dateStamp = formatter.string(from: now)
        let canonicalURI = "/\(encodedBucket)/"
        let canonicalHeaders = "host:\(host)\nx-amz-content-sha256:\(payloadHash)\nx-amz-date:\(amzDate)\n"
        let signedHeaders = "host;x-amz-content-sha256;x-amz-date"
        let canonicalRequest = "GET\n\(canonicalURI)\n\(canonicalQuery)\n\(canonicalHeaders)\n\(signedHeaders)\n\(payloadHash)"
        let scope = "\(dateStamp)/auto/s3/aws4_request"
        let stringToSign = "AWS4-HMAC-SHA256\n\(amzDate)\n\(scope)\n\(sha256(Data(canonicalRequest.utf8)))"
        let dateKey = hmac(key: Data("AWS4\(secretAccessKey)".utf8), data: Data(dateStamp.utf8))
        let regionKey = hmac(key: dateKey, data: Data("auto".utf8))
        let serviceKey = hmac(key: regionKey, data: Data("s3".utf8))
        let signingKey = hmac(key: serviceKey, data: Data("aws4_request".utf8))
        let signature = hmac(key: signingKey, data: Data(stringToSign.utf8)).hexString

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue("AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func signedEmptyPayloadRequest(method: String, objectKey: String, now: Date) throws -> URLRequest {
        let encodedBucket = encodePathComponent(bucket)
        let encodedKey = objectKey.split(separator: "/").map { encodePathComponent(String($0)) }.joined(separator: "/")
        let host = "\(accountID).r2.cloudflarestorage.com"
        guard let url = URL(string: "https://\(host)/\(encodedBucket)/\(encodedKey)") else {
            throw OpenRecError.invalidConfiguration("The R2 account or bucket produced an invalid download URL.")
        }

        let payloadHash = sha256(Data())
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = formatter.string(from: now)
        formatter.dateFormat = "yyyyMMdd"
        let dateStamp = formatter.string(from: now)
        let canonicalURI = "/\(encodedBucket)/\(encodedKey)"
        let canonicalHeaders = "host:\(host)\nx-amz-content-sha256:\(payloadHash)\nx-amz-date:\(amzDate)\n"
        let signedHeaders = "host;x-amz-content-sha256;x-amz-date"
        let canonicalRequest = "\(method)\n\(canonicalURI)\n\n\(canonicalHeaders)\n\(signedHeaders)\n\(payloadHash)"
        let scope = "\(dateStamp)/auto/s3/aws4_request"
        let stringToSign = "AWS4-HMAC-SHA256\n\(amzDate)\n\(scope)\n\(sha256(Data(canonicalRequest.utf8)))"
        let dateKey = hmac(key: Data("AWS4\(secretAccessKey)".utf8), data: Data(dateStamp.utf8))
        let regionKey = hmac(key: dateKey, data: Data("auto".utf8))
        let serviceKey = hmac(key: regionKey, data: Data("s3".utf8))
        let signingKey = hmac(key: serviceKey, data: Data("aws4_request".utf8))
        let signature = hmac(key: signingKey, data: Data(stringToSign.utf8)).hexString

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 600
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue("AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func sha256(fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { digest.update(data: chunk) }
        return Data(digest.finalize()).hexString
    }

    private func sha256(_ data: Data) -> String { Data(SHA256.hash(data: data)).hexString }
    private func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }
    private func encodePathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? value
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
