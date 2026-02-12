import Foundation
import Combine

@MainActor
class CallTipsManager: ObservableObject {
    @Published var tips: String = ""
    @Published var isLoading = false

    private var timer: Timer?
    private var lastTranscriptLength = 0

    func start(transcriptionManager: TranscriptionManager) {
        stop()
        lastTranscriptLength = 0
        tips = ""

        timer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self, weak transcriptionManager] _ in
            Task { @MainActor in
                guard let self, let tm = transcriptionManager else { return }
                await self.tick(transcriptionManager: tm)
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func requestOnce(transcriptionManager: TranscriptionManager) {
        Task {
            await fetchTips(transcriptionManager: transcriptionManager)
        }
    }

    private func tick(transcriptionManager: TranscriptionManager) async {
        let currentLength = transcriptionManager.committedSegments.count
        guard currentLength > 0, currentLength != lastTranscriptLength else { return }
        await fetchTips(transcriptionManager: transcriptionManager)
    }

    private func fetchTips(transcriptionManager: TranscriptionManager) async {
        guard !isLoading else { return }

        let transcript = transcriptionManager.fullTranscriptText()
        guard !transcript.isEmpty else { return }

        let apiKey = transcriptionManager.openRouterKey
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        isLoading = true
        lastTranscriptLength = transcriptionManager.committedSegments.count

        defer { isLoading = false }

        guard let url = URL(string: "https://openrouter.ai/api/v1/chat/completions") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let systemPrompt = """
Real-time sales coach. Transcript: "Me" = seller, "Others" = prospect.

Stages: RAPPORT → DISCOVERY → PAIN → GAP → COST OF INACTION → FUTURE PACE → SUPPORT → PITCH → TEMP CHECK → OBJECTIONS

Rules:
- RAPPORT: Small talk, set agenda
- DISCOVERY: Open questions, let them talk 80%
- PAIN: Dig deeper — "What happens when that breaks?"
- GAP: Where are you now vs where you need to be?
- COST OF INACTION: "What if nothing changes in 6 months?"
- FUTURE PACE: "Imagine this is solved — what does that look like?"
- SUPPORT: "Who else needs to be involved?"
- PITCH: Only after pain/gap. Tie features to their words
- TEMP CHECK: "How does this land?" "What's missing?"
- OBJECTIONS: "Any smallest doubt?" Address honestly

Output format — THIS IS CRITICAL, follow exactly:
[STAGE NAME]
• Say: "exact phrase to use"
• Say: "another phrase"
• Do: brief action instruction

Max 3 bullets. Each bullet under 15 words. No filler. No summary. No praise. Just the stage tag and bullets.
If pitching before pain/gap established, warn: ⚠️ Slow down — dig into pain first.
"""

        let body: [String: Any] = [
            "model": "google/gemini-3-flash-preview",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": transcript]
            ]
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return }
        request.httpBody = httpBody

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let first = choices.first,
               let message = first["message"] as? [String: Any],
               let content = message["content"] as? String {
                tips = content
            }
        } catch {
            print("CallTipsManager error: \(error.localizedDescription)")
        }
    }
}
