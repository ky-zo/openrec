import AVFoundation
import CoreMedia
import XCTest
@testable import OpenRecApp

@available(macOS 13.0, *)
final class ScreenRecorderWriterTests: XCTestCase {
    func testMuxedScreenWriterUsesAppleHLSAndCreatesAdaptorBeforeWriting() throws {
        let delegate = SegmentCollector()
        let audioFormat = try ScreenRecorder.makeMixedPCMFormatDescription()
        let screen = try ScreenRecorder.startSegmentedWriter(
            kind: .muxedScreen(width: 640, height: 360),
            segmentDuration: CMTime(seconds: 2, preferredTimescale: 600),
            mixedPCMFormatDescription: audioFormat,
            delegate: delegate
        )
        defer { screen.writer.cancelWriting() }

        XCTAssertEqual(screen.writer.outputFileTypeProfile, .mpeg4AppleHLS)
        XCTAssertEqual(screen.writer.status, .writing)
        XCTAssertNotNil(screen.videoInput)
        XCTAssertEqual(screen.audioInput.mediaType, .audio)
        XCTAssertNotNil(screen.pixelBufferAdaptor)
        XCTAssertEqual(screen.pixelBufferAdaptorCreationStatus, .unknown)
    }

    func testAudioOnlyWriterRemainsStrictCMAF() throws {
        let delegate = SegmentCollector()
        let audioFormat = try ScreenRecorder.makeMixedPCMFormatDescription()
        let audio = try ScreenRecorder.startSegmentedWriter(
            kind: .audioOnly,
            segmentDuration: CMTime(seconds: 2, preferredTimescale: 600),
            mixedPCMFormatDescription: audioFormat,
            delegate: delegate
        )
        defer { audio.writer.cancelWriting() }

        XCTAssertEqual(audio.writer.outputFileTypeProfile, .mpeg4CMAFCompliant)
        XCTAssertEqual(audio.writer.status, .writing)
        XCTAssertNil(audio.videoInput)
        XCTAssertNil(audio.pixelBufferAdaptor)
        XCTAssertNil(audio.pixelBufferAdaptorCreationStatus)
        XCTAssertEqual(audio.audioInput.mediaType, .audio)
    }
}

@available(macOS 13.0, *)
private final class SegmentCollector: NSObject, AVAssetWriterDelegate {
    func assetWriter(
        _ writer: AVAssetWriter,
        didOutputSegmentData segmentData: Data,
        segmentType: AVAssetSegmentType
    ) {}
}
