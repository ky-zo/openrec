import AppKit
import XCTest
@testable import OpenRecApp

final class OpenRecBrandIconTests: XCTestCase {
    func testWaveformGeometryHasSixAsymmetricBarsOnTheSharedDesignGrid() {
        let rect = CGRect(origin: .zero, size: OpenRecWaveformGeometry.designSize)
        let path = OpenRecWaveformGeometry.path(in: rect)
        var subpathCount = 0

        path.applyWithBlock { element in
            if element.pointee.type == .moveToPoint {
                subpathCount += 1
            }
        }

        XCTAssertEqual(subpathCount, 6)
        XCTAssertEqual(path.boundingBoxOfPath.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(path.boundingBoxOfPath.origin.y, 0, accuracy: 0.001)
        XCTAssertEqual(path.boundingBoxOfPath.width, 45, accuracy: 0.001)
        XCTAssertEqual(path.boundingBoxOfPath.height, 50, accuracy: 0.001)
    }

    func testMenuBarImageIsAnAccessibleTemplateAtTheExpectedSize() {
        let image = OpenRecBrandIcon.statusItemImage(
            accessibilityDescription: "OpenRec is recording"
        )

        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.accessibilityDescription, "OpenRec is recording")
        XCTAssertNotNil(image.tiffRepresentation)
    }
}
