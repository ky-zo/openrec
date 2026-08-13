import Foundation
import Combine

@MainActor
final class WebhookSettings: ObservableObject {
    var url: String {
        get { UserDefaults.standard.string(forKey: "RecordingWebhookURL") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "RecordingWebhookURL"); objectWillChange.send() }
    }
    var secret: String {
        get { KeychainStore.string(for: "recording-webhook-secret") }
        set { KeychainStore.set(newValue, for: "recording-webhook-secret"); objectWillChange.send() }
    }
    var isConfigured: Bool {
        guard let value = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return value.scheme == "https" && value.host != nil
    }
}

struct WebhookDeliveryService {
    let url: URL
    let secret: String

    func testConnection() async throws {
        guard url.scheme == "https" else {
            throw OpenRecError.invalidConfiguration("Recording webhooks must use HTTPS.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("connection.test", forHTTPHeaderField: "X-OpenRec-Event")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-OpenRec-Delivery")
        if !secret.isEmpty { request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "event": "connection.test",
            "source": "OpenRec",
            "sentAt": ISO8601DateFormatter().string(from: Date()),
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenRecError.invalidResponse("The webhook returned no HTTP response.") }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown webhook error"
            throw OpenRecError.requestFailed(status: http.statusCode, message: message)
        }
    }

    func deliver(payload: MeetingPayload, screenURL: URL?, audioURL: URL?) async throws {
        guard url.scheme == "https" else {
            throw OpenRecError.invalidConfiguration("Recording webhooks must use HTTPS.")
        }
        let boundary = "OpenRecWebhook-\(UUID().uuidString)"
        let bodyURL = try await Task.detached(priority: .utility) {
            try Self.buildDeliveryBody(
                payload: payload,
                screenURL: screenURL,
                audioURL: audioURL,
                boundary: boundary
            )
        }.value
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("meeting.completed", forHTTPHeaderField: "X-OpenRec-Event")
        request.setValue(payload.id.uuidString.lowercased(), forHTTPHeaderField: "X-OpenRec-Delivery")
        if !secret.isEmpty { request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: bodyURL)
        guard let http = response as? HTTPURLResponse else { throw OpenRecError.invalidResponse("The webhook returned no HTTP response.") }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown webhook error"
            throw OpenRecError.requestFailed(status: http.statusCode, message: message)
        }
    }

    /// Deliver cloud media by reference. The signed URLs are intentionally
    /// short-lived bearer URLs, so webhook receivers can pull the recording
    /// without OpenRec rebuilding another full copy on the user's disk.
    func deliverCloud(payload: MeetingPayload, screenURL: URL?, audioURL: URL?) async throws {
        guard url.scheme == "https" else {
            throw OpenRecError.invalidConfiguration("Recording webhooks must use HTTPS.")
        }
        let envelope = CloudWebhookEnvelope(
            event: "meeting.completed",
            source: "OpenRec",
            sentAt: Date(),
            meeting: payload,
            media: CloudWebhookMedia(
                screenURL: screenURL?.absoluteString,
                audioURL: audioURL?.absoluteString
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("meeting.completed", forHTTPHeaderField: "X-OpenRec-Event")
        request.setValue(payload.id.uuidString.lowercased(), forHTTPHeaderField: "X-OpenRec-Delivery")
        if !secret.isEmpty { request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try encoder.encode(envelope)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenRecError.invalidResponse("The webhook returned no HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown webhook error"
            throw OpenRecError.requestFailed(status: http.statusCode, message: message)
        }
    }

    private static func buildDeliveryBody(
        payload: MeetingPayload,
        screenURL: URL?,
        audioURL: URL?,
        boundary: String
    ) throws -> URL {
        let bodyURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).webhook")
        do {
            FileManager.default.createFile(atPath: bodyURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: bodyURL)
            defer { try? handle.close() }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let metadata = try encoder.encode(payload)
            try writeField(name: "metadata", filename: "meeting.json", contentType: "application/json", data: metadata, boundary: boundary, to: handle)
            if let screenURL { try writeFile(name: "screen_recording", url: screenURL, boundary: boundary, to: handle) }
            if let audioURL { try writeFile(name: "audio_recording", url: audioURL, boundary: boundary, to: handle) }
            try handle.write(contentsOf: Data("--\(boundary)--\r\n".utf8))
            try handle.synchronize()
            return bodyURL
        } catch {
            try? FileManager.default.removeItem(at: bodyURL)
            throw error
        }
    }

    private static func writeFile(name: String, url: URL, boundary: String, to output: FileHandle) throws {
        let type: String
        switch url.pathExtension.lowercased() {
        case "mp4": type = "video/mp4"
        case "m4a": type = "audio/mp4"
        case "mp3": type = "audio/mpeg"
        default: type = "application/octet-stream"
        }
        try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(url.lastPathComponent)\"\r\nContent-Type: \(type)\r\n\r\n".utf8))
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty { try output.write(contentsOf: chunk) }
        try output.write(contentsOf: Data("\r\n".utf8))
    }

    private static func writeField(name: String, filename: String, contentType: String, data: Data, boundary: String, to output: FileHandle) throws {
        try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(contentType)\r\n\r\n".utf8))
        try output.write(contentsOf: data)
        try output.write(contentsOf: Data("\r\n".utf8))
    }
}

private struct CloudWebhookEnvelope: Encodable {
    let event: String
    let source: String
    let sentAt: Date
    let meeting: MeetingPayload
    let media: CloudWebhookMedia
}

private struct CloudWebhookMedia: Encodable {
    let screenURL: String?
    let audioURL: String?

    private enum CodingKeys: String, CodingKey {
        case screenURL = "screen_url"
        case audioURL = "audio_url"
    }
}
