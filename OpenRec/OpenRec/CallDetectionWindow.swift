import AppKit
import SwiftUI

@MainActor
final class CallDetectionWindow {
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    func show(call: DetectedCall, onStart: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        hideWorkItem?.cancel()
        panel?.orderOut(nil)

        let size = NSSize(width: 324, height: call.participants.isEmpty ? 116 : 136)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.sharingType = .readOnly
        panel.contentView = NSHostingView(rootView: CallDetectedView(
            call: call,
            onStart: { [weak self] in self?.hide(); onStart() },
            onDismiss: { [weak self] in self?.hide(); onDismiss() }
        ))

        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let target = NSRect(
            x: visible.maxX - size.width - 18,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        panel.setFrame(NSRect(x: visible.maxX + 8, y: target.minY, width: size.width, height: size.height), display: false)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            panel.animator().setFrame(target, display: true)
        }
        self.panel = panel

        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 14, execute: work)
    }

    func hide() {
        hideWorkItem?.cancel()
        guard let panel else { return }
        let frame = panel.frame
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
            panel.animator().setFrameOrigin(NSPoint(x: frame.maxX + 20, y: frame.minY))
            panel.animator().alphaValue = 0
        } completionHandler: { panel.orderOut(nil) }
        self.panel = nil
    }
}

private struct CallDetectedView: View {
    let call: DetectedCall
    let onStart: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.red.opacity(0.16)).frame(width: 36, height: 36)
                Image(systemName: "waveform.badge.mic").font(.system(size: 15, weight: .semibold)).foregroundColor(.red)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(call.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(1)
                Text("Call detected in \(call.appName)")
                    .font(.system(size: 10.5))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
                if !call.participants.isEmpty {
                    Label(call.participants.prefix(3).joined(separator: ", "), systemImage: "person.2.fill")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.48))
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    Button("Record call", action: onStart)
                        .buttonStyle(CallDetectionButtonStyle(prominent: true))
                    Button("Snooze 15 min", action: onDismiss)
                        .buttonStyle(CallDetectionButtonStyle(prominent: false))
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 324, height: call.participants.isEmpty ? 116 : 136)
        .background(Color(red: 0.12, green: 0.125, blue: 0.13).opacity(0.98))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }
}

private struct CallDetectionButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(prominent ? .white : Color.white.opacity(0.62))
            .padding(.horizontal, 10)
            .frame(height: 27)
            .background(prominent ? Color.red.opacity(0.9) : Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
