import AppKit
import CoreGraphics

final class RecordingOverlayWindow {
    private var window: NSWindow?
    private let borderWidth: CGFloat = 2
    private let cornerRadius: CGFloat = 18

    func show(displayID: CGDirectDisplayID?) {
        guard let screen = screen(for: displayID) ?? NSScreen.main else { return }

        if let window = window {
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            return
        }

        let overlay = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        overlay.level = .statusBar
        overlay.backgroundColor = .clear
        overlay.isOpaque = false
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = RecordingOverlayView(
            frame: overlay.contentView?.bounds ?? screen.frame,
            borderWidth: borderWidth,
            cornerRadius: cornerRadius
        )
        view.autoresizingMask = [.width, .height]
        overlay.contentView = view

        overlay.orderFrontRegardless()
        window = overlay
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }

    private func screen(for displayID: CGDirectDisplayID?) -> NSScreen? {
        guard let displayID = displayID else { return nil }
        return NSScreen.screens.first { screen in
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                return number == displayID
            }
            return false
        }
    }
}

final class RecordingOverlayView: NSView {
    private let borderWidth: CGFloat
    private let cornerRadius: CGFloat
    private let borderLayer = CAShapeLayer()

    init(frame frameRect: NSRect, borderWidth: CGFloat, cornerRadius: CGFloat) {
        self.borderWidth = borderWidth
        self.cornerRadius = cornerRadius
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        borderLayer.strokeColor = NSColor.systemRed.cgColor
        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.lineWidth = borderWidth
        borderLayer.lineJoin = .round
        layer?.addSublayer(borderLayer)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layout() {
        super.layout()
        let inset = borderWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        borderLayer.frame = bounds
        borderLayer.path = topRoundedPath(in: rect, radius: cornerRadius)
    }

    private func topRoundedPath(in rect: CGRect, radius: CGFloat) -> CGPath {
        let radius = min(radius, rect.width / 2, rect.height / 2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        path.addArc(
            center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius),
            radius: radius,
            startAngle: .pi,
            endAngle: .pi / 2,
            clockwise: true
        )
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius),
            radius: radius,
            startAngle: .pi / 2,
            endAngle: 0,
            clockwise: true
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
