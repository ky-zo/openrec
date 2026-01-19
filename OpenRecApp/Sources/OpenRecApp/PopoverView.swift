import SwiftUI

struct PopoverView: View {
    @ObservedObject var recorderManager: RecorderManager
    @State private var isHovering = false
    @State private var isHoveringFolder = false
    @State private var isHoveringLocation = false

    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)

            VStack(spacing: 0) {
                // Top section with button and status - fixed height
                VStack(spacing: 8) {
                    Spacer()
                        .frame(height: 12)

                    // Record/Stop Button or Processing indicator
                    if recorderManager.isProcessing {
                        // Processing state
                        VStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.8)
                                .frame(width: 48, height: 48)

                            Text("Saving...")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white.opacity(0.7))
                        }
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
                                    .frame(width: 48, height: 48)

                                if recorderManager.isRecording {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.white)
                                        .frame(width: 18, height: 18)
                                } else {
                                    Circle()
                                        .fill(Color.white.opacity(0.9))
                                        .frame(width: 18, height: 18)
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

                    // Status area - fixed height to prevent jumping
                    Group {
                        if recorderManager.isRecording {
                            VStack(spacing: 4) {
                                Text(formatDuration(recorderManager.duration))
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white)

                                AudioWaveformView(
                                    micLevel: recorderManager.micLevel,
                                    systemLevel: recorderManager.systemLevel
                                )
                                .frame(height: 20)
                                .padding(.horizontal, 30)
                            }
                        } else if recorderManager.isProcessing {
                            Text(" ")
                                .font(.system(size: 12, weight: .medium))
                        } else {
                            Text("Start Recording")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white.opacity(0.5))
                        }
                    }
                    .frame(height: 40)
                }
                .frame(height: 120)

                Spacer(minLength: 0)

                // Bottom buttons - fixed at bottom
                VStack(spacing: 5) {
                    Button(action: {
                        recorderManager.openRecordingsFolder()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                                .font(.system(size: 11))
                            Text("Open Recordings")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(.white.opacity(isHoveringFolder ? 1.0 : 0.7))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(isHoveringFolder ? 0.15 : 0.08))
                        .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isHoveringFolder = hovering
                    }

                    Button(action: {
                        recorderManager.chooseRecordingsFolder()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "folder.badge.gearshape")
                                .font(.system(size: 11))
                            Text("Change Location...")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(.white.opacity(isHoveringLocation ? 1.0 : 0.7))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(isHoveringLocation ? 0.15 : 0.08))
                        .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isHoveringLocation = hovering
                    }

                    // Path display
                    Text(recorderManager.recordingsPathDisplay)
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
        }
        .frame(width: 220, height: 200)
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

// MARK: - Audio Waveform Visualization

struct AudioWaveformView: View {
    let micLevel: Float
    let systemLevel: Float

    private let barCount = 9

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                WaveformBar(
                    micLevel: micLevel,
                    systemLevel: systemLevel,
                    index: index,
                    totalBars: barCount
                )
            }
        }
    }
}

struct WaveformBar: View {
    let micLevel: Float
    let systemLevel: Float
    let index: Int
    let totalBars: Int

    @State private var animatedHeight: CGFloat = 0.15

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(barColor)
            .frame(width: 4, height: max(3, animatedHeight * 20))
            .animation(.easeOut(duration: 0.08), value: animatedHeight)
            .onChange(of: micLevel) { _ in updateHeight() }
            .onChange(of: systemLevel) { _ in updateHeight() }
            .onAppear { updateHeight() }
    }

    private var barColor: Color {
        let combinedLevel = max(micLevel, systemLevel)
        if combinedLevel > 0.8 {
            return .red
        } else if combinedLevel > 0.5 {
            return .orange
        } else {
            return .green
        }
    }

    private func updateHeight() {
        let combinedLevel = max(micLevel, systemLevel)

        let center = CGFloat(totalBars) / 2.0
        let distanceFromCenter = abs(CGFloat(index) - center) / center
        let variation = 1.0 - (distanceFromCenter * 0.5)

        let randomFactor = CGFloat.random(in: 0.7...1.0)

        let targetHeight = CGFloat(combinedLevel) * variation * randomFactor
        animatedHeight = max(0.15, min(1.0, targetHeight))
    }
}
