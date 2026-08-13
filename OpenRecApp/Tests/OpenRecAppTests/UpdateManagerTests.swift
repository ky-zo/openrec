import XCTest
@testable import OpenRecApp

final class UpdateManagerTests: XCTestCase {
    func testLatestEnclosureParsesNewestSparkleItemRegardlessOfAttributeOrder() {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        <item><enclosure url="https://cdn.example.com/OpenRec-0.3.0.dmg" sparkle:version="17" sparkle:shortVersionString="0.3.0" length="1" type="application/octet-stream"/></item>
        <item><enclosure sparkle:shortVersionString="0.3.1" sparkle:version="18" url="https://cdn.example.com/OpenRec-0.3.1.dmg" length="2" type="application/octet-stream"/></item>
        </channel></rss>
        """

        let info = UpdateManager.latestEnclosure(inAppcast: xml)

        XCTAssertEqual(info?.tag, "v0.3.1")
        XCTAssertEqual(info?.downloadURL.lastPathComponent, "OpenRec-0.3.1.dmg")
    }

    func testLatestEnclosureReturnsNilWithoutEnclosures() {
        XCTAssertNil(UpdateManager.latestEnclosure(inAppcast: "<rss><channel></channel></rss>"))
    }

    func testAppcastVersionBeatsOlderCurrentVersionOnly() throws {
        let newer = try XCTUnwrap(UpdateManager.Version("0.3.1"))
        let current = try XCTUnwrap(UpdateManager.Version("0.3.0"))
        let same = try XCTUnwrap(UpdateManager.Version("0.3.1"))
        XCTAssertTrue(current < newer)
        XCTAssertFalse(newer < same)
    }
}
