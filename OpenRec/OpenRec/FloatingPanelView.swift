import SwiftUI
import AppKit

struct FloatingPanelView: View {
    @ObservedObject var recorderManager: RecorderManager
    @ObservedObject var windowState: WindowState

    /// Right panel: during recording, user-controlled via showPanel toggle;
    /// when not recording, auto-show when mode != .off.
    private var showRightPanel: Bool {
        if windowState.isCollapsed { return false }
        let tm = recorderManager.transcriptionManager
        if tm.mode == .off { return false }
        if recorderManager.isRecording {
            return tm.showPanel // user toggles via expand button
        }
        return true
    }

    /// Transcript content vs settings in the right panel
    private var showTranscript: Bool {
        let tm = recorderManager.transcriptionManager
        if windowState.isCollapsed { return false }
        if recorderManager.isRecording && tm.mode == .live && tm.hasAPIKey { return true }
        if tm.showPanel && !tm.committedSegments.isEmpty { return true }
        if tm.isTranscribing { return true }
        return false
    }

    /// Tips show during live recording or when transcript results are available
    private var showTips: Bool {
        if windowState.isCollapsed { return false }
        let tm = recorderManager.transcriptionManager
        if !tm.hasOpenRouterKey { return false }
        if recorderManager.isRecording && tm.mode == .live && tm.hasAPIKey { return true }
        if tm.isTranscribing { return true }
        if tm.showPanel && !tm.committedSegments.isEmpty { return true }
        return false
    }

    var body: some View {
        ZStack {
            // Single shared background for the entire window
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
            Color.black.opacity(0.45)

            // Content layout — no SwiftUI animations here;
            // the NSWindow frame animation handles all sizing transitions.
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    // Main panel — pinned to top so it doesn't drift when window grows
                    VStack(spacing: 0) {
                        HeaderView(recorderManager: recorderManager, windowState: windowState)

                        if windowState.isCollapsed {
                            CompactControlsView(recorderManager: recorderManager)
                        } else if recorderManager.isRecording {
                            RecordingControlsView(recorderManager: recorderManager)
                        } else {
                            PopoverContentView(recorderManager: recorderManager)
                        }

                        Spacer(minLength: 0)
                    }
                    .frame(width: 240)

                    // Right panel: transcript or settings
                    if showRightPanel {
                        Color.white.opacity(0.15)
                            .frame(width: 1)

                        Group {
                            if showTranscript {
                                TranscriptionInlineView(
                                    transcriptionManager: recorderManager.transcriptionManager,
                                    onClose: {
                                        recorderManager.transcriptionManager.showPanel = false
                                    }
                                )
                            } else {
                                APIKeySettingsView(transcriptionManager: recorderManager.transcriptionManager)
                            }
                        }
                        .frame(width: 280)
                    }
                }
                .clipped()

                // Tips row — full width below both panels
                if showTips {
                    Color.white.opacity(0.15)
                        .frame(height: 1)

                    TipsInlineView(transcriptionManager: recorderManager.transcriptionManager)
                        .frame(height: recorderManager.isRecording ? 200 : 140)
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

// MARK: - Recording Controls (compact single row)

private struct RecordingControlsView: View {
    @ObservedObject var recorderManager: RecorderManager
    @State private var isHovering = false
    @State private var isHoveringExpand = false

    var body: some View {
        HStack(spacing: 10) {
            // Stop button
            Button(action: {
                recorderManager.stopRecording()
            }) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.15))
                        .frame(width: 28, height: 28)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white)
                        .frame(width: 10, height: 10)
                }
                .scaleEffect(isHovering ? 1.08 : 1.0)
                .animation(.easeInOut(duration: 0.15), value: isHovering)
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }

            // Timer
            Text(formatDuration(recorderManager.duration))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.white)

            // Waveform
            AudioWaveformView(
                micLevel: recorderManager.micLevel,
                systemLevel: recorderManager.systemLevel
            )
            .frame(width: 60, height: 14)

            Spacer()

            // Expand/collapse transcript button
            if recorderManager.transcriptionManager.mode != .off {
                Button(action: {
                    recorderManager.transcriptionManager.showPanel.toggle()
                }) {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(
                            recorderManager.transcriptionManager.showPanel
                                ? 0.9
                                : (isHoveringExpand ? 0.7 : 0.4)
                        ))
                }
                .buttonStyle(.plain)
                .onHover { isHoveringExpand = $0 }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)
        let hrs = totalSeconds / 3600
        let mins = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hrs > 0 {
            return String(format: "%d:%02d:%02d", hrs, mins, secs)
        } else {
            return String(format: "%02d:%02d", mins, secs)
        }
    }
}

// MARK: - ASCII Spinner

struct ASCIISpinner: View {
    let size: CGFloat
    @State private var frame = 0
    private let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    var body: some View {
        Text(frames[frame % frames.count])
            .font(.system(size: size, weight: .medium, design: .monospaced))
            .foregroundColor(.white.opacity(0.7))
            .onAppear {
                Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
                    frame += 1
                }
            }
    }
}

// MARK: - API Key Settings (Right Panel)

private struct APIKeySettingsView: View {
    @ObservedObject var transcriptionManager: TranscriptionManager

    private let primaryText = Color.white.opacity(0.9)
    private let secondaryText = Color.white.opacity(0.6)
    private let hintText = Color.white.opacity(0.45)
    private let placeholderText = Color.white.opacity(0.5)
    private let labelFont = Font.system(size: 11, weight: .medium)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "key")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(primaryText)

                Text("API Keys")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(primaryText)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Color.white.opacity(0.1)
                .frame(height: 1)

            ScrollView {
                VStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ElevenLabs")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(secondaryText)

                        SecureField(
                            "",
                            text: Binding(
                                get: { transcriptionManager.apiKey },
                                set: { transcriptionManager.apiKey = $0 }
                            ),
                            prompt: Text("API key").foregroundColor(placeholderText)
                        )
                        .textFieldStyle(.plain)
                        .font(labelFont)
                        .foregroundColor(primaryText)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(6)

                        if transcriptionManager.hasAPIKey {
                            Label("Transcription ready", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.green.opacity(0.8))
                        } else {
                            Label("Required for Live & After", systemImage: "exclamationmark.circle")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.orange.opacity(0.8))
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("OpenRouter")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(secondaryText)

                        SecureField(
                            "",
                            text: Binding(
                                get: { transcriptionManager.openRouterKey },
                                set: { transcriptionManager.openRouterKey = $0 }
                            ),
                            prompt: Text("API key (for tips)").foregroundColor(placeholderText)
                        )
                        .textFieldStyle(.plain)
                        .font(labelFont)
                        .foregroundColor(primaryText)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(6)

                        if transcriptionManager.hasOpenRouterKey {
                            Label("Tips ready", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.green.opacity(0.8))
                        } else {
                            Label("Optional — enables call tips", systemImage: "info.circle")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(hintText)
                        }
                    }
                }
                .padding(12)
            }
        }
    }
}

// MARK: - Tips Inline View

private struct TipsInlineView: View {
    @ObservedObject var transcriptionManager: TranscriptionManager

    private let primaryText = Color.white.opacity(0.9)
    private let secondaryText = Color.white.opacity(0.6)
    private let hintText = Color.white.opacity(0.45)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.yellow.opacity(0.9))

                Text("Tips")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(primaryText)

                if transcriptionManager.callTipsManager.isLoading {
                    ASCIISpinner(size: 11)
                        .frame(width: 14, height: 14)
                }

                Spacer()

                Button(action: {
                    transcriptionManager.callTipsManager.requestOnce(transcriptionManager: transcriptionManager)
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(transcriptionManager.callTipsManager.isLoading ? 0.2 : 0.5))
                }
                .buttonStyle(.plain)
                .disabled(transcriptionManager.callTipsManager.isLoading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            Color.white.opacity(0.06)
                .frame(height: 1)

            ScrollView {
                if transcriptionManager.callTipsManager.tips.isEmpty && !transcriptionManager.callTipsManager.isLoading {
                    Text("Tips will appear during the call...")
                        .font(.system(size: 13))
                        .foregroundColor(hintText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                } else {
                    Text(transcriptionManager.callTipsManager.tips)
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.9))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
            }
        }
    }
}

// MARK: - Header

private struct HeaderView: View {
    @ObservedObject var recorderManager: RecorderManager
    @ObservedObject var windowState: WindowState
    @State private var isHoveringToggle = false
    @State private var isHoveringQuit = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(recorderManager.isRecording ? Color.red : Color.white.opacity(0.35))
                .frame(width: 6, height: 6)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("OpenRec")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))

                Text("by Fluar.com")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
            }

            Spacer()

            Button(action: {
                windowState.isCollapsed.toggle()
            }) {
                Image(systemName: windowState.isCollapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundColor(.white.opacity(isHoveringToggle ? 1.0 : 0.7))
            .onHover { hovering in
                isHoveringToggle = hovering
            }

            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundColor(.white.opacity(isHoveringQuit ? 1.0 : 0.7))
            .onHover { hovering in
                isHoveringQuit = hovering
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct CompactControlsView: View {
    @ObservedObject var recorderManager: RecorderManager
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 16) {
            if recorderManager.isProcessing || recorderManager.isStarting {
                ASCIISpinner(size: 18)
                    .frame(width: 32, height: 32)
            } else {
                Button(action: {
                    if recorderManager.isRecording {
                        recorderManager.stopRecording()
                    } else {
                        Task {
                            await recorderManager.startRecording()
                        }
                    }
                }) {
                    ZStack {
                        Circle()
                            .fill(recorderManager.isRecording ? Color.white.opacity(0.15) : Color.red)
                            .frame(width: 32, height: 32)

                        if recorderManager.isRecording {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white)
                                .frame(width: 12, height: 12)
                        } else {
                            Circle()
                                .fill(Color.white.opacity(0.9))
                                .frame(width: 12, height: 12)
                        }
                    }
                    .scaleEffect(isHovering ? 1.08 : 1.0)
                    .animation(.easeInOut(duration: 0.15), value: isHovering)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isHovering = hovering
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(statusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))

                Text(formatDuration(recorderManager.duration))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 18)
    }

    private var statusText: String {
        if recorderManager.isProcessing {
            return "Saving..."
        }
        if recorderManager.isStarting {
            return "Starting..."
        }
        return recorderManager.isRecording ? "Recording" : "Ready"
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)
        let hrs = totalSeconds / 3600
        let mins = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hrs > 0 {
            return String(format: "%d:%02d:%02d", hrs, mins, secs)
        } else {
            return String(format: "%02d:%02d", mins, secs)
        }
    }
}
