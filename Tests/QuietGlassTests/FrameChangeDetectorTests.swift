import XCTest
import CoreVideo
@testable import QuietGlass

final class FrameChangeDetectorTests: XCTestCase {
    private let width = FrameThumbnail.width
    private let height = FrameThumbnail.height

    private func frame(_ value: UInt8 = 0) -> [UInt8] {
        [UInt8](repeating: value, count: width * height)
    }

    func testIdenticalFramesDoNotTrigger() {
        let value = frame(120)
        XCTAssertFalse(FrameChangeDecision.changed(previous: value, current: value))
    }

    func testPixelNoiseBelowTheGateIsIgnored() {
        XCTAssertFalse(FrameChangeDecision.changed(previous: frame(100), current: frame(105)))
    }

    func testGlobalChangeAboveTwoPercentTriggers() {
        var previous = frame(0)
        var current = frame(0)
        // One pixel every 50 is exactly 2% of the frame and stays below the
        // block ratio, so only the global rule can fire.
        for index in stride(from: 0, to: previous.count, by: 50) {
            previous[index] = 0
            current[index] = 60
        }
        XCTAssertTrue(FrameChangeDecision.changed(previous: previous, current: current))
    }

    func testScatteredChangeBelowTwoPercentDoesNotTrigger() {
        var current = frame(0)
        for index in stride(from: 0, to: current.count, by: 100) { current[index] = 60 }
        XCTAssertFalse(FrameChangeDecision.changed(previous: frame(0), current: current))
    }

    func testLocalizedBlockChangeTriggersBelowGlobalRatio() {
        var current = frame(0)
        // A full 16x16 block is only 1.33% of the frame but 100% of one block.
        for y in 32..<48 {
            for x in 32..<48 { current[y * width + x] = 80 }
        }
        XCTAssertTrue(FrameChangeDecision.changed(previous: frame(0), current: current))
    }

    func testMismatchedInputsAlwaysScan() {
        XCTAssertTrue(FrameChangeDecision.changed(previous: [], current: []))
        XCTAssertTrue(FrameChangeDecision.changed(previous: [1, 2], current: [1]))
        XCTAssertTrue(FrameChangeDecision.changed(previous: [1], current: [2, 3]))
    }

    func testFingerprintDownscalesAndReadsLuma() throws {
        let dark = try XCTUnwrap(FrameThumbnail(buffer: makeBuffer { _, _ in (0, 0, 0) }))
        let bright = try XCTUnwrap(FrameThumbnail(buffer: makeBuffer { _, _ in (255, 255, 255) }))
        XCTAssertEqual(dark.pixels.count, width * height)
        XCTAssertLessThan(dark.pixels.max()!, 5)
        XCTAssertGreaterThan(bright.pixels.min()!, 245)
        XCTAssertFalse(FrameChangeDecision.changed(previous: dark.pixels, current: dark.pixels))
        XCTAssertTrue(FrameChangeDecision.changed(previous: dark.pixels, current: bright.pixels))
    }

    func testFingerprintRejectsUnexpectedPixelFormats() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32ARGB, nil, &buffer), kCVReturnSuccess)
        XCTAssertNil(FrameThumbnail(buffer: try XCTUnwrap(buffer)))
    }

    private func makeBuffer(_ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 640, 480, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let value = buffer!
        CVPixelBufferLockBaseAddress(value, [])
        defer { CVPixelBufferUnlockBaseAddress(value, []) }
        let base = CVPixelBufferGetBaseAddress(value)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(value)
        for y in 0..<480 {
            for x in 0..<640 {
                let (blue, green, red) = pixel(x, y)
                let offset = y * rowBytes + x * 4
                base[offset] = blue; base[offset + 1] = green; base[offset + 2] = red; base[offset + 3] = 255
            }
        }
        return value
    }
}
