import AppKit
import SwiftUI

/// The OpenRec mark is based on the asymmetric waveform used in onboarding.
/// Keeping the geometry here prevents the app, onboarding, and menu-bar marks
/// from drifting into different shapes over time.
enum OpenRecWaveformGeometry {
    static let designSize = CGSize(width: 45, height: 50)

    private static let bars: [(x: CGFloat, height: CGFloat)] = [
        (0, 13),
        (8, 33),
        (17, 50),
        (25, 26),
        (33, 39),
        (41, 17)
    ]

    static func path(in rect: CGRect) -> CGPath {
        let scale = min(
            rect.width / designSize.width,
            rect.height / designSize.height
        )
        let renderedSize = CGSize(
            width: designSize.width * scale,
            height: designSize.height * scale
        )
        let origin = CGPoint(
            x: rect.midX - renderedSize.width / 2,
            y: rect.midY - renderedSize.height / 2
        )
        let barWidth = 4 * scale
        let path = CGMutablePath()

        for bar in bars {
            let height = bar.height * scale
            let barRect = CGRect(
                x: origin.x + bar.x * scale,
                y: rect.midY - height / 2,
                width: barWidth,
                height: height
            )
            path.addRoundedRect(
                in: barRect,
                cornerWidth: barWidth / 2,
                cornerHeight: barWidth / 2
            )
        }

        return path
    }
}

struct OpenRecWaveformShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(OpenRecWaveformGeometry.path(in: rect))
    }
}

struct OpenRecWaveformBadge: View {
    let diameter: CGFloat
    var backgroundColor = Color.white.opacity(0.08)
    var waveformColor = Color.white.opacity(0.9)

    var body: some View {
        ZStack {
            Circle()
                .fill(backgroundColor)

            OpenRecWaveformShape()
                .fill(waveformColor)
                .frame(
                    width: diameter * (45 / 108),
                    height: diameter * (50 / 108)
                )
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

enum OpenRecBrandIcon {
    /// A monochrome template image lets macOS provide the correct idle color
    /// for every menu-bar appearance while AppDelegate supplies the red live
    /// recording tint.
    static func statusItemImage(
        accessibilityDescription: String,
        canvasSize: CGFloat = 18
    ) -> NSImage {
        let size = NSSize(width: canvasSize, height: canvasSize)
        let image = NSImage(size: size, flipped: true) { rect in
            let glyphHeight = min(rect.height - 1, 17)
            let glyphWidth = glyphHeight
                * OpenRecWaveformGeometry.designSize.width
                / OpenRecWaveformGeometry.designSize.height
            let glyphRect = CGRect(
                x: rect.midX - glyphWidth / 2,
                y: rect.midY - glyphHeight / 2,
                width: glyphWidth,
                height: glyphHeight
            )
            let path = OpenRecWaveformGeometry.path(in: glyphRect)
            guard let context = NSGraphicsContext.current?.cgContext else {
                return false
            }
            context.addPath(path)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }
}
