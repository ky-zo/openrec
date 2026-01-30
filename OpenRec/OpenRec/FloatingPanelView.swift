import SwiftUI
import AppKit

struct FloatingPanelView: View {
    @ObservedObject var recorderManager: RecorderManager
    @ObservedObject var windowState: WindowState

    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)

            VStack(spacing: 0) {
                HeaderView(recorderManager: recorderManager, windowState: windowState)

                if windowState.isCollapsed {
                    CompactControlsView(recorderManager: recorderManager)
                } else {
                    PopoverContentView(recorderManager: recorderManager)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

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
                ProgressView()
                    .scaleEffect(0.75)
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
