import SwiftUI
import AppKit

struct FloatingPanelView: View {
    @ObservedObject var recorderManager: RecorderManager
    @ObservedObject var windowState: WindowState
    let onOpenSettings: () -> Void
    let onOpenLibrary: (_ focusLastSaved: Bool) -> Void

    private var showRightPanel: Bool {
        guard !windowState.isCollapsed else { return false }
        return recorderManager.transcriptionManager.showPanel
    }

    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
            Color.black.opacity(0.45)

            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    HeaderView(
                        recorderManager: recorderManager,
                        windowState: windowState,
                        onOpenSettings: onOpenSettings
                    )

                    if windowState.isCollapsed {
                        CompactControlsView(recorderManager: recorderManager, onOpenLibrary: onOpenLibrary)
                    } else if recorderManager.isRecording {
                        // Center the controls row in the space below the header so
                        // the panel's top and bottom breathing room stay balanced.
                        RecordingControlsView(recorderManager: recorderManager)
                            .frame(maxHeight: .infinity)
                            .layoutPriority(1)
                    } else {
                        PopoverContentView(recorderManager: recorderManager, onOpenLibrary: onOpenLibrary)
                    }

                    Spacer(minLength: 0)
                }
                .frame(width: 240)

                if showRightPanel {
                    Color.white.opacity(0.15)
                        .frame(width: 1)

                    MeetingMemoryView(recorderManager: recorderManager)
                        .frame(width: 280)
                }
            }
            .clipped()
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

struct ASCIISpinner: View {
    let size: CGFloat
    private let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.08)) { context in
            let frame = Int(context.date.timeIntervalSinceReferenceDate / 0.08)
            Text(frames[frame % frames.count])
                .font(.system(size: size, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))
        }
    }
}

private struct HeaderView: View {
    @ObservedObject var recorderManager: RecorderManager
    @ObservedObject var windowState: WindowState
    let onOpenSettings: () -> Void
    @State private var hoveringSettings = false
    @State private var hoveringCollapse = false
    @State private var hoveringQuit = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(recorderManager.isRecording ? Color.red : Color.white.opacity(0.35))
                .frame(width: 6, height: 6)

            Text("OpenRec")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))

            Spacer()

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 10.5, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundColor(.white.opacity(hoveringSettings ? 1 : 0.66))
            .disabled(recorderManager.isRecording || recorderManager.isProcessing)
            .opacity(recorderManager.isRecording || recorderManager.isProcessing ? 0.35 : 1)
            .help("Settings")
            .onHover { hoveringSettings = $0 }

            Button {
                windowState.isCollapsed.toggle()
            } label: {
                Image(systemName: windowState.isCollapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 10.5, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundColor(.white.opacity(hoveringCollapse ? 1 : 0.66))
            .onHover { hoveringCollapse = $0 }

            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
                    .font(.system(size: 10.5, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundColor(.white.opacity(hoveringQuit ? 1 : 0.66))
            .onHover { hoveringQuit = $0 }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct RecordingControlsView: View {
    @ObservedObject var recorderManager: RecorderManager
    @State private var hoveringStop = false
    @State private var hoveringDiscard = false

    var body: some View {
        HStack(spacing: 8) {
            Button { recorderManager.stopRecording() } label: {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.15))
                        .frame(width: 28, height: 28)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white)
                        .frame(width: 10, height: 10)
                }
                .scaleEffect(hoveringStop ? 1.08 : 1)
                .animation(.easeOut(duration: 0.15), value: hoveringStop)
            }
            .buttonStyle(.plain)
            .onHover { hoveringStop = $0 }

            // The timer is the only compressible view in this row; without
            // fixedSize the window's 240pt width squeezes it into wrapped lines.
            Text(formatDuration(recorderManager.duration))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)

            AudioWaveformView(
                micLevel: recorderManager.micLevel,
                systemLevel: recorderManager.systemLevel
            )
            .frame(width: 44, height: 14)

            Image(systemName: recorderManager.cloudUploadHasFailed ? "icloud.slash.fill" : "icloud.and.arrow.up.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(recorderManager.cloudUploadNeedsAttention ? .orange : .green.opacity(0.82))
                .help(recorderManager.cloudUploadStatusText)

            Spacer(minLength: 2)

            Button(action: confirmAndDiscardRecording) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(hoveringDiscard ? .red : .white.opacity(0.52))
            }
            .buttonStyle(.plain)
            .onHover { hoveringDiscard = $0 }
            .help("Discard this recording")

            Menu {
                Toggle("Keep screen recording", isOn: preferenceBinding(recorderManager, \.keepScreenRecording))
                Toggle("Keep audio recording", isOn: preferenceBinding(recorderManager, \.keepAudioRecording))
                Divider()
                Toggle("Store transcript in meeting library", isOn: preferenceBinding(recorderManager, \.storeTranscriptInCloud))
                    .disabled(recorderManager.cloudStorage.mode == .managed && !recorderManager.cloudStorage.canStoreTranscriptInCloud)
                Toggle("Send to webhook", isOn: preferenceBinding(recorderManager, \.sendToWebhook))
                    .disabled(!recorderManager.webhookSettings.isConfigured)
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.62))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("What to keep after this call")

            Button { recorderManager.transcriptionManager.showPanel.toggle() } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(recorderManager.transcriptionManager.showPanel ? 0.9 : 0.52))
            }
            .buttonStyle(.plain)
            .help("Meeting notes")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Discarding a live call is destructive and unrecoverable, so it asks
    /// twice: a warning first, then an explicit "can't be undone" critical
    /// alert. Recording continues until the second confirmation.
    private func confirmAndDiscardRecording() {
        NSApp.activate(ignoringOtherApps: true)

        let first = NSAlert()
        first.messageText = "Discard this recording?"
        first.informativeText = "The recording, its cloud upload, and the live notes for this call will be deleted."
        first.alertStyle = .warning
        first.addButton(withTitle: "Keep Recording")
        first.addButton(withTitle: "Discard…")
        guard first.runModal() == .alertSecondButtonReturn else { return }

        let second = NSAlert()
        second.messageText = "Really discard everything from this call?"
        second.informativeText = "This permanently deletes everything captured so far. It cannot be undone."
        second.alertStyle = .critical
        second.addButton(withTitle: "Keep Recording")
        second.addButton(withTitle: "Discard Recording")
        guard second.runModal() == .alertSecondButtonReturn else { return }

        recorderManager.cancelRecording()
    }
}

private struct CompactControlsView: View {
    @ObservedObject var recorderManager: RecorderManager
    let onOpenLibrary: (_ focusLastSaved: Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            if recorderManager.isProcessing || recorderManager.isStarting {
                ASCIISpinner(size: 18)
                    .frame(width: 32, height: 32)
            } else {
                Button {
                    if case .failed = recorderManager.savePhase {
                        if recorderManager.canRetryLastSave { recorderManager.retryLastSave() }
                        else { onOpenLibrary(true) }
                    } else if recorderManager.isRecording {
                        recorderManager.stopRecording()
                    } else {
                        Task { await recorderManager.startRecording() }
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(recorderManager.isRecording ? Color.white.opacity(0.15) : Color.red)
                            .frame(width: 32, height: 32)
                        if recorderManager.isRecording {
                            RoundedRectangle(cornerRadius: 2).fill(Color.white).frame(width: 12, height: 12)
                        } else if case .failed = recorderManager.savePhase {
                            Image(systemName: recorderManager.canRetryLastSave ? "arrow.clockwise" : "exclamationmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                        } else {
                            Circle().fill(Color.white.opacity(0.9)).frame(width: 12, height: 12)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(statusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                Text(statusDetail)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.65))
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 18)
    }

    private var statusText: String {
        if recorderManager.isProcessing { return recorderManager.savePhase.label }
        if recorderManager.isStarting { return "Starting…" }
        if case .failed = recorderManager.savePhase { return "Save failed" }
        return recorderManager.isRecording ? "Recording" : "Ready"
    }

    private var statusDetail: String {
        if case .failed = recorderManager.savePhase {
            return recorderManager.canRetryLastSave ? "Click to retry" : "Open Meetings for recovery"
        }
        return formatDuration(recorderManager.duration)
    }
}

private struct MeetingMemoryView: View {
    @ObservedObject var recorderManager: RecorderManager
    @State private var copied = false

    private var hasInsightMemory: Bool {
        let insights = recorderManager.transcriptionManager.insights
        return !insights.summary.isEmpty
            || !insights.aiNotes.isEmpty
            || !insights.participants.isEmpty
            || !insights.actionItems.isEmpty
            || !insights.decisions.isEmpty
    }

    private var hasTranscriptMemory: Bool {
        !recorderManager.transcriptionManager.committedSegments.isEmpty
    }

    private var hasVisibleMemory: Bool {
        hasInsightMemory
            || hasTranscriptMemory
            || !recorderManager.transcriptionManager.partialText.isEmpty
    }

    private var isSaveFailure: Bool {
        if case .failed = recorderManager.savePhase { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "text.quote")
                Text(recorderManager.isRecording ? "Live notes" : "Meeting notes")
                    .font(.system(size: 12, weight: .semibold))
                if recorderManager.transcriptionManager.isTranscribing || recorderManager.transcriptionManager.isAnalyzing {
                    ASCIISpinner(size: 11)
                }
                Spacer()
                Button(action: copyMeetingMemory) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain)
                .disabled(!hasInsightMemory && !hasTranscriptMemory)
                .help("Copy meeting memory")
                Button { recorderManager.transcriptionManager.showPanel = false } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.white.opacity(0.72))
            .padding(12)

            Color.white.opacity(0.1).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        let insights = recorderManager.transcriptionManager.insights
                        if !insights.summary.isEmpty || !insights.aiNotes.isEmpty {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(insights.title)
                                    .font(.system(size: 13, weight: .semibold))
                                if !insights.aiNotes.isEmpty {
                                    MarkdownNotesView(
                                        markdown: insights.aiNotes,
                                        textColor: .white,
                                        secondaryColor: .white.opacity(0.5)
                                    )
                                } else {
                                    Text(insights.summary)
                                        .font(.system(size: 11))
                                        .foregroundColor(.white.opacity(0.72))
                                }
                            }
                        }

                        if !insights.participants.isEmpty {
                            Label(insights.participants.joined(separator: ", "), systemImage: "person.2")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.white.opacity(0.5))
                        }

                        if !insights.actionItems.isEmpty {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("Next steps")
                                    .font(.system(size: 11, weight: .semibold))
                                ForEach(insights.actionItems) { item in
                                    HStack(alignment: .top, spacing: 7) {
                                        Image(systemName: "arrow.turn.down.right")
                                            .font(.system(size: 8, weight: .semibold))
                                            .padding(.top, 3)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.owner.isEmpty ? item.task : "\(item.owner): \(item.task)")
                                                .font(.system(size: 11))
                                                .foregroundColor(.white.opacity(0.76))
                                            if let due = item.dueDate, !due.isEmpty {
                                                Text(due)
                                                    .font(.system(size: 9, weight: .medium))
                                                    .foregroundColor(.white.opacity(0.42))
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        if !insights.decisions.isEmpty {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("Decisions")
                                    .font(.system(size: 11, weight: .semibold))
                                ForEach(insights.decisions, id: \.self) { decision in
                                    Label(decision, systemImage: "checkmark.circle.fill")
                                        .font(.system(size: 11))
                                        .foregroundColor(.white.opacity(0.76))
                                }
                            }
                        }

                        if hasInsightMemory && (hasTranscriptMemory || !recorderManager.transcriptionManager.partialText.isEmpty) {
                            Color.white.opacity(0.1).frame(height: 1)
                        }

                        ForEach(recorderManager.transcriptionManager.committedSegments) { segment in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(segment.speakerLabel)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(segment.speakerLabel == "Me" ? .blue : .green)
                                Text(segment.text)
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.82))
                                    .textSelection(.enabled)
                            }
                            .id(segment.id)
                        }

                        if !recorderManager.transcriptionManager.partialText.isEmpty {
                            Text(recorderManager.transcriptionManager.partialText)
                                .font(.system(size: 11))
                                .italic()
                                .foregroundColor(.white.opacity(0.45))
                                .id("partial")
                        }

                        if !hasVisibleMemory || isSaveFailure {
                            EmptyMeetingState(recorderManager: recorderManager)
                        }
                    }
                    .padding(14)
                }
                .onChange(of: recorderManager.transcriptionManager.committedSegments.count) { _ in
                    if let last = recorderManager.transcriptionManager.committedSegments.last {
                        withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
    }

    private func copyMeetingMemory() {
        let insights = recorderManager.transcriptionManager.insights
        var sections: [String] = []
        if !insights.aiNotes.isEmpty { sections.append("\(insights.title)\n\n\(insights.aiNotes)") }
        else if !insights.summary.isEmpty { sections.append("\(insights.title)\n\n\(insights.summary)") }
        if !insights.participants.isEmpty { sections.append("Participants\n\(insights.participants.joined(separator: ", "))") }
        if !insights.actionItems.isEmpty {
            sections.append("Next steps\n" + insights.actionItems.map { "• " + ($0.owner.isEmpty ? $0.task : "\($0.owner): \($0.task)") }.joined(separator: "\n"))
        }
        if !insights.decisions.isEmpty { sections.append("Decisions\n" + insights.decisions.map { "• \($0)" }.joined(separator: "\n")) }
        let transcript = recorderManager.transcriptionManager.fullTranscriptText()
        if !transcript.isEmpty { sections.append("Transcript\n\(transcript)") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sections.joined(separator: "\n\n"), forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

private struct EmptyMeetingState: View {
    @ObservedObject var recorderManager: RecorderManager

    private var statusText: String {
        if recorderManager.isProcessing { return recorderManager.savePhase.label }
        if recorderManager.isStarting { return "Starting recording…" }
        if recorderManager.isRecording { return "Listening for the conversation…" }
        switch recorderManager.savePhase {
        case .complete, .completeWithWarning:
            return "No speech was detected in this call."
        case .failed:
            return "Meeting notes could not be completed."
        default:
            return "Meeting notes will appear here."
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            if recorderManager.isProcessing || recorderManager.isStarting {
                ASCIISpinner(size: 18)
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.white.opacity(0.34))
            }
            Text(statusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.45))
                .multilineTextAlignment(.center)
            if case .failed(let message) = recorderManager.savePhase {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundColor(.orange.opacity(0.9))
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    if recorderManager.canRetryLastSave {
                        Button("Retry") { recorderManager.retryLastSave() }
                    }
                }
                .font(.system(size: 10, weight: .medium))
                .buttonStyle(.plain)
                .foregroundColor(.white.opacity(0.75))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 38)
    }
}

@MainActor
private func preferenceBinding(_ manager: RecorderManager, _ path: WritableKeyPath<CallPreferences, Bool>) -> Binding<Bool> {
    Binding(
        get: { manager.currentCallPreferences[keyPath: path] },
        set: { manager.setActiveCallPreference(path, to: $0) }
    )
}

private func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds)
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let remainder = total % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
        : String(format: "%02d:%02d", minutes, remainder)
}
