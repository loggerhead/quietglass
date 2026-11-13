import AppKit
import CoreImage
import XCTest
@testable import QuietGlass

final class RegionalRenderingTests: XCTestCase {
    func testPerRegionPixelsMatchFullFrameReferenceAndPriorityOverlap() throws {
        let width = 400, height = 300
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(NSColor.black.cgColor); bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.setFillColor(NSColor.white.cgColor)
        for x in stride(from: 0, to: width, by: 60) { for y in stride(from: 0, to: height, by: 60) where (x / 60 + y / 60) % 2 == 0 {
            bitmap.fill(CGRect(x: x, y: y, width: 60, height: 60))
        } }
        let input = CIImage(cgImage: try XCTUnwrap(bitmap.makeImage()))
        let regions = [ScreenBlurRegion(rectangle: CGRect(x: 0, y: 0, width: 0.5, height: 2.0 / 3), radius: 10),
                       ScreenBlurRegion(rectangle: CGRect(x: 0.25, y: 1.0 / 3, width: 0.5, height: 2.0 / 3), radius: 50)]
        let composite = try XCTUnwrap(DisplayBlurRenderer().renderRegions(input, regions: regions))
        let low = try XCTUnwrap(DisplayBlurRenderer().render(input, radius: 10))
        let high = try XCTUnwrap(DisplayBlurRenderer().render(input, radius: 50))
        let context = CIContext()
        func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
            var result = [UInt8](repeating: 0, count: 4)
            context.render(CIImage(cgImage: image), toBitmap: &result, rowBytes: 4,
                           bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return result
        }
        for (x, y, reference) in [(50, 50, low), (150, 150, low), (250, 250, high)] {
            let actual = pixel(composite, x: x, y: y), expected = pixel(reference, x: x, y: y)
            for component in 0..<4 { XCTAssertLessThanOrEqual(abs(Int(actual[component]) - Int(expected[component])), 2) }
        }
        XCTAssertNotEqual(pixel(low, x: 150, y: 150), pixel(high, x: 150, y: 150), "The reference must distinguish the two blur strengths")
        let outside = pixel(composite, x: 350, y: 250)
        XCTAssertEqual(outside[3], 255); XCTAssertLessThan(outside[0], 30, "Unprotected pixels in the private composite stay opaque/dark")
    }

    func testRegionalFrameCostAgainstFullFrameBaseline() throws {
        guard ProcessInfo.processInfo.environment["QUIETGLASS_PROFILE"] == "1" else { throw XCTSkip("Run with QUIETGLASS_PROFILE=1 to measure regional rendering") }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Preview/BlurPreview.png")
        let preview = try XCTUnwrap(CIImage(contentsOf: url))
        let input = preview.transformed(by: CGAffineTransform(scaleX: 1512 / preview.extent.width, y: 982 / preview.extent.height))
        func median(_ work: () -> Void) -> Double {
            work(); var values: [Double] = []
            for _ in 0..<7 { let start = ProcessInfo.processInfo.systemUptime; autoreleasepool(invoking: work); values.append((ProcessInfo.processInfo.systemUptime - start) * 1000) }
            return values.sorted()[3]
        }
        let renderer = DisplayBlurRenderer(), reference = DisplayBlurRenderer()
        let one = [ScreenBlurRegion(rectangle: CGRect(x: 0, y: 0, width: 1, height: 1), radius: 28)]
        var four: [ScreenBlurRegion] = [], hundred: [ScreenBlurRegion] = []
        for index in 0..<4 {
            let x = CGFloat(index % 2) * 0.5, y = CGFloat(index / 2) * 0.5
            four.append(ScreenBlurRegion(rectangle: CGRect(x: x, y: y, width: 0.5, height: 0.5), radius: Double(10 + index * 15)))
        }
        for index in 0..<100 {
            let x = CGFloat(index % 10) * 0.1, y = CGFloat(index / 10) * 0.1
            hundred.append(ScreenBlurRegion(rectangle: CGRect(x: x, y: y, width: 0.07, height: 0.025), radius: Double(10 + index % 61)))
        }
        let baseline = median { _ = reference.render(input, radius: 28) }
        let same = median { _ = renderer.renderRegions(input, regions: one) }
        let variants = median { for region in four { _ = reference.render(input, radius: region.radius) } }
        let quadrants = median { _ = renderer.renderRegions(input, regions: four) }
        let small = median { _ = renderer.renderRegions(input, regions: hundred) }
        print("QUIETGLASS_REGIONAL_PROFILE baseline_ms=\(baseline) one_ms=\(same) four_full_frames_ms=\(variants) four_regions_ms=\(quadrants) hundred_regions_ms=\(small)")
        XCTAssertLessThan(same, max(12, baseline * 2), "The equivalent one-radius path must retain its frame budget")
        XCTAssertLessThan(quadrants, 1000.0 / 30, "Mixed large regions must fit the full-screen capture frame interval")
        XCTAssertLessThan(small, 1000.0 / 12, "100 local regions must fit the regional capture interval")
        XCTAssertLessThan(quadrants, variants * 1.2, "Crops should avoid the previous repeated full-display work")
    }
}
