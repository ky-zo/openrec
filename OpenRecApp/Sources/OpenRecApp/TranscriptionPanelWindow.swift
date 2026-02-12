import AppKit
import SwiftUI

final class TranscriptionPanelWindow {
    private var window: NSWindow?

    func show(transcriptionManager: TranscriptionManager) {
        if let window {
            window.orderFrontRegardless()
            return
        }

        guard let screen = NSScreen.main else { return }

        let panelWidth: CGFloat = 400
        let panelHeight = screen.visibleFrame.height
        let originX = screen.visibleFrame.maxX  // Start offscreen right
        let originY = screen.visibleFrame.minY

        let panel = NSWindow(
            contentRect: NSRect(x: originX, y: originY, width: panelWidth, height: panelHeight),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)

        let hostingView = NSHostingView(
            rootView: TranscriptionInlineView(
                transcriptionManager: transcriptionManager,
                onClose: { [weak self] in
                    self?.hide()
                }
            )
        )
        panel.contentView = hostingView

        panel.orderFrontRegardless()
        window = panel

        // Slide in from right
        let targetX = screen.visibleFrame.maxX - panelWidth
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(
                NSRect(x: targetX, y: originY, width: panelWidth, height: panelHeight),
                display: true
            )
        })
    }

    func hide() {
        guard let panel = window else { return }
        guard let screen = NSScreen.main else {
            panel.orderOut(nil)
            window = nil
            return
        }

        let targetX = screen.visibleFrame.maxX
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            var frame = panel.frame
            frame.origin.x = targetX
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            self?.window = nil
        })
    }

    var isVisible: Bool {
        window?.isVisible ?? false
    }
}
