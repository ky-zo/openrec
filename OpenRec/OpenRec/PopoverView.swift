import SwiftUI
import AppKit

struct PopoverContentView: View {
    @ObservedObject var recorderManager: RecorderManager
    @State private var isHovering = false
    @State private var isHoveringFolder = false
    @State private var isHoveringLocation = false
    @FocusState private var isClientNameFocused: Bool
    private let primaryText = Color.white.opacity(0.9)
    private let secondaryText = Color.white.opacity(0.6)
    private let hintText = Color.white.opacity(0.45)
    private let placeholderText = Color.white.opacity(0.5)
    private let labelFont = Font.system(size: 11, weight: .medium)

    private var selectedMicrophoneName: String {
        if let selectedID = recorderManager.selectedMicrophoneID,
           let device = recorderManager.microphoneDevices.first(where: { $0.uniqueID == selectedID }) {
            return device.localizedName
        }
        if let first = recorderManager.microphoneDevices.first {
            return first.localizedName
        }
        return "No microphones"
    }

    private var hasMicrophones: Bool {
        !recorderManager.microphoneDevices.isEmpty
    }

    var body: some View {
            VStack(spacing: 0) {
            // Top section with button and status - fixed height
            VStack(spacing: 10) {
                Spacer()
                    .frame(height: 0)

                // Record/Stop Button or Processing indicator
                if recorderManager.isProcessing || recorderManager.isStarting {
                    VStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                            .frame(width: 48, height: 48)

                        Text(recorderManager.isProcessing ? "Saving..." : "Starting...")
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
                    } else if recorderManager.isProcessing || recorderManager.isStarting {
                        Text(" ")
                            .font(.system(size: 12, weight: .medium))
                    } else if let error = recorderManager.lastErrorMessage {
                        Text(error)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.red.opacity(0.9))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    } else {
                        Text("Start Recording")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                .frame(height: 26)
            }
            .frame(height: 112)

            Spacer(minLength: 0)

            // Bottom buttons - fixed at bottom
            VStack(spacing: 6) {
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(secondaryText)
                            .frame(width: 14, alignment: .center)

                        TextField(
                            "",
                            text: $recorderManager.clientNameInput,
                            prompt: Text("client name").foregroundColor(placeholderText)
                        )
                            .textFieldStyle(.plain)
                            .font(labelFont)
                            .foregroundColor(primaryText)
                            .focused($isClientNameFocused)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(6)
                }

                VStack(spacing: 4) {
                    Menu {
                        if recorderManager.microphoneDevices.isEmpty {
                            Button("No microphones found") {}
                                .disabled(true)
                        } else {
                            ForEach(recorderManager.microphoneDevices, id: \.uniqueID) { device in
                                Button(action: {
                                    recorderManager.setSelectedMicrophoneID(device.uniqueID)
                                }) {
                                    if device.uniqueID == recorderManager.selectedMicrophoneID {
                                        Label(device.localizedName, systemImage: "checkmark")
                                    } else {
                                        Text(device.localizedName)
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "mic")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(secondaryText)
                                .frame(width: 14, alignment: .center)

                            Text(selectedMicrophoneName)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundColor(secondaryText)
                        }
                        .font(labelFont)
                        .foregroundColor(primaryText.opacity(0.8))
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .tint(.white)
                    .frame(maxWidth: .infinity)
                    .disabled(!hasMicrophones)
                }

                Toggle(isOn: Binding(
                    get: { recorderManager.showRecordingBorder },
                    set: { recorderManager.setShowRecordingBorder($0) }
                )) {
                    Text("Show red border")
                        .font(labelFont)
                        .foregroundColor(primaryText.opacity(0.75))
                }
                .toggleStyle(.switch)
                .tint(.red)

                Button(action: {
                    recorderManager.openRecordingsFolder()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                        Text("Open Recordings")
                            .font(labelFont)
                    }
                    .foregroundColor(primaryText.opacity(isHoveringFolder ? 1.0 : 0.8))
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
                            .font(labelFont)
                    }
                    .foregroundColor(primaryText.opacity(isHoveringLocation ? 1.0 : 0.8))
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
                    .foregroundColor(hintText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            .onAppear {
                DispatchQueue.main.async {
                    isClientNameFocused = false
                }
            }
        }
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
