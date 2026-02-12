import SwiftUI
import AppKit

struct TranscriptionInlineView: View {
    @ObservedObject var transcriptionManager: TranscriptionManager
    var onClose: () -> Void

    @State private var copiedFeedback = false

    private let primaryText = Color.white.opacity(0.9)
    private let secondaryText = Color.white.opacity(0.6)
    private let hintText = Color.white.opacity(0.45)

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider().background(Color.white.opacity(0.1))
            transcriptBody
            if let error = transcriptionManager.error {
                errorView(error)
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.quote")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(primaryText)

            Text("Transcript")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(primaryText)

            if transcriptionManager.isTranscribing {
                ASCIISpinner(size: 11)
                    .frame(width: 14, height: 14)
            }

            Spacer()

            Button(action: copyTranscript) {
                Image(systemName: copiedFeedback ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(copiedFeedback ? .green : secondaryText)
            }
            .buttonStyle(.plain)
            .disabled(transcriptionManager.committedSegments.isEmpty)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(secondaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Transcript Body

    private var transcriptBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(transcriptionManager.committedSegments) { segment in
                        TranscriptSegmentRow(segment: segment)
                            .id(segment.id)
                    }

                    if !transcriptionManager.partialText.isEmpty {
                        Text(transcriptionManager.partialText)
                            .font(.system(size: 11))
                            .italic()
                            .foregroundColor(hintText)
                            .padding(.horizontal, 12)
                            .id("partial")
                    }

                    if transcriptionManager.isTranscribing && transcriptionManager.committedSegments.isEmpty && transcriptionManager.partialText.isEmpty {
                        HStack {
                            Spacer()
                            VStack(spacing: 6) {
                                ASCIISpinner(size: 14)
                                Text("Listening...")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(hintText)
                            }
                            Spacer()
                        }
                        .padding(.top, 30)
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: transcriptionManager.committedSegments.count) { _ in
                if let last = transcriptionManager.committedSegments.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: transcriptionManager.partialText) { _ in
                if !transcriptionManager.partialText.isEmpty {
                    withAnimation {
                        proxy.scrollTo("partial", anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Error

    private func errorView(_ message: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 9))
            Text(message)
                .font(.system(size: 9))
                .lineLimit(2)
        }
        .foregroundColor(.red.opacity(0.9))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Actions

    private func copyTranscript() {
        let text = transcriptionManager.fullTranscriptText()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copiedFeedback = false
        }
    }
}

// MARK: - Segment Row

private struct TranscriptSegmentRow: View {
    let segment: DisplaySegment

    private var speakerColor: Color {
        segment.speakerLabel == "Me" ? .blue : .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle()
                    .fill(speakerColor)
                    .frame(width: 6, height: 6)

                Text(segment.speakerLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(speakerColor)

                if let timestamp = segment.timestamp {
                    Text(formatTimestamp(timestamp))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.3))
                }

                Spacer()
            }

            Text(segment.text)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.85))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
