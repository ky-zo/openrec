import Foundation

struct OpenAIService {
    let apiKey: String

    static func isCredentialOrModelAccessFailure(_ error: Error) -> Bool {
        guard case .requestFailed(let status, _) = error as? OpenRecError else {
            return false
        }
        return status == 401 || status == 403 || status == 404
    }

    func validateAccess() async throws {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenRecError.invalidConfiguration("Enter an OpenAI API key first.")
        }
        guard let url = URL(string: "https://api.openai.com/v1/models/gpt-5-mini") else {
            throw OpenRecError.invalidConfiguration("Invalid OpenAI endpoint.")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
    }

    func generateInsights(transcript: String, callTitle: String?) async throws -> MeetingInsights {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw OpenRecError.invalidConfiguration("Invalid OpenAI endpoint.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let prompt = """
        Turn this meeting transcript into concise, factual meeting memory. Infer participant names only when the transcript explicitly supports them. Never invent names, owners, dates, or decisions. Return JSON matching the provided schema. Suggested title from the call window: \(callTitle ?? "none").

        Transcript:
        \(transcript)
        """
        let body: [String: Any] = [
            "model": "gpt-5-mini",
            "messages": [
                ["role": "system", "content": "You extract meeting summaries, participants, decisions, and concrete next steps."],
                ["role": "user", "content": prompt],
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "meeting_insights",
                    "strict": true,
                    "schema": [
                        "type": "object",
                        "properties": [
                            "title": ["type": "string"],
                            "summary": ["type": "string"],
                            "participants": ["type": "array", "items": ["type": "string"]],
                            "actionItems": [
                                "type": "array",
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "owner": ["type": "string"],
                                        "task": ["type": "string"],
                                        "dueDate": ["type": ["string", "null"]],
                                    ],
                                    "required": ["owner", "task", "dueDate"],
                                    "additionalProperties": false,
                                ],
                            ],
                            "decisions": ["type": "array", "items": ["type": "string"]],
                        ],
                        "required": ["title", "summary", "participants", "actionItems", "decisions"],
                        "additionalProperties": false,
                    ],
                ],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              let contentData = content.data(using: .utf8) else {
            throw OpenRecError.invalidResponse("OpenAI returned an unreadable insights response.")
        }
        return try JSONDecoder().decode(MeetingInsights.self, from: contentData)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OpenRecError.invalidResponse("The server returned no HTTP status.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let error = json?["error"] as? [String: Any]
            let message = error?["message"] as? String ?? String(data: data, encoding: .utf8) ?? "Unknown error"
            throw OpenRecError.requestFailed(status: http.statusCode, message: message)
        }
    }

}
