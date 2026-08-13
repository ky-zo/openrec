import Foundation
import AppKit
import ScreenCaptureKit

struct DetectedCall: Equatable {
    let appName: String
    let title: String?
    let participants: [String]

    init(appName: String, title: String?, participants: [String] = []) {
        self.appName = appName
        self.title = title
        self.participants = participants
    }

    var displayTitle: String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Call detected" : trimmed
    }
}

@MainActor
final class CallDetectionManager {
    var onCallDetected: ((DetectedCall) -> Void)?
    var isRecording: (() -> Bool)?

    private var timer: Timer?
    private var lastDetected: DetectedCall?
    private var dismissedUntil = Date.distantPast

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.scan() }
        }
        Task { await scan() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func snooze() {
        dismissedUntil = Date().addingTimeInterval(15 * 60)
        // Let the same still-active call prompt again when snooze expires.
        lastDetected = nil
    }

    private func scan() async {
        guard isRecording?() != true, Date() >= dismissedUntil else { return }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }

        let candidates = content.windows.compactMap { window -> DetectedCall? in
            guard let app = window.owningApplication else { return nil }
            let appName = app.applicationName
            let bundle = app.bundleIdentifier.lowercased()
            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let haystack = "\(appName) \(title ?? "") \(bundle)".lowercased()

            let meetingTitleMatch = [
                "meet.google.com", "google meet", "zoom meeting", "zoom webinar",
                "microsoft teams meeting", "teams call", "slack huddle", "webex meeting",
                "around call", "whereby", "riverside studio",
            ].contains(where: haystack.contains)
            let dedicatedApp = [
                "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams",
                "com.apple.facetime", "com.cisco.webexmeetingsapp",
            ].contains(bundle)

            let cleaned = cleanedTitle(title, appName: appName)
            let genericDedicatedTitles = [
                "zoom", "zoom workplace", "zoom.us", "microsoft teams", "teams",
                "facetime", "webex", "webex meetings",
            ]
            let hasCallSpecificDedicatedWindow = dedicatedApp
                && window.isOnScreen
                && cleaned.map { !genericDedicatedTitles.contains($0.lowercased()) } == true

            guard meetingTitleMatch || hasCallSpecificDedicatedWindow else { return nil }
            return DetectedCall(appName: appName, title: cleaned)
        }

        guard let detected = candidates.first else {
            lastDetected = nil
            return
        }
        guard detected != lastDetected else { return }
        lastDetected = detected
        onCallDetected?(detected)
    }

    private func cleanedTitle(_ title: String?, appName: String) -> String? {
        guard var title, !title.isEmpty else { return nil }
        for suffix in [" - Google Chrome", " — Mozilla Firefox", " - Zoom", " | Microsoft Teams"] {
            if title.hasSuffix(suffix) { title.removeLast(suffix.count) }
        }
        if title.lowercased() == appName.lowercased() { return nil }
        return title
    }
}
