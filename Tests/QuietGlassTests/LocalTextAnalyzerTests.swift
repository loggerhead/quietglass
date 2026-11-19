//  Created by Clinton Imaro on 20/09/2026.

import XCTest
import AppKit
import CoreVideo
import Vision
import ShieldCore
@testable import QuietGlass

final class LocalTextAnalyzerTests: XCTestCase {
    func testLargeFramesAreDownsampledToTheAnalysisCap() throws {
        var value: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 3000, 1000, kCVPixelFormatType_32BGRA, nil, &value), kCVReturnSuccess)
        let buffer = try XCTUnwrap(value)
        let analyzer = LocalTextAnalyzer(options: .emailAddresses) { _ in }
        let output = try XCTUnwrap(analyzer.downsampled(buffer))
        XCTAssertEqual(CVPixelBufferGetWidth(output), 2048)
        XCTAssertEqual(CVPixelBufferGetHeight(output), 683)
        XCTAssertTrue(analyzer.downsampled(output) === output, "Frames within the cap must pass through unchanged")
    }

    @MainActor func testVisionFindsSensitiveTextInAnActualRenderedImage() throws {
        let image = NSImage(size: NSSize(width: 1000, height: 300))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1000, height: 300).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 34), .foregroundColor: NSColor.black]
        ("Contact sample@example.test" as NSString).draw(at: NSPoint(x: 40, y: 200), withAttributes: attributes)
        ("Ordinary text stays visible" as NSString).draw(at: NSPoint(x: 40, y: 100), withAttributes: attributes)
        image.unlockFocus()
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
        let observations = try XCTUnwrap(request.results)
        let regions = LocalTextAnalyzer.regions(in: observations, options: .emailAddresses)
        XCTAssertEqual(regions.count, 1)
        let region = try XCTUnwrap(regions.first)
        XCTAssertGreaterThan(region.minY, 0.6)
        XCTAssertLessThan(region.width, 0.7)
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).contains(region))
        XCTAssertTrue(LocalTextAnalyzer.regions(in: observations, options: .credentials).isEmpty)
        let email = ProtectionRule(name: "Email", trigger: .sensitiveText(types: [.emailAddresses], phrases: []), scope: .detectedText)
        let phrase = ProtectionRule(name: "Phrase", trigger: .sensitiveText(types: [], phrases: ["Ordinary text"]), scope: .detectedText)
        let credentials = ProtectionRule(name: "Credentials", trigger: .sensitiveText(types: [.credentials], phrases: []), scope: .detectedText)
        let byRule = LocalTextAnalyzer.regions(in: observations, rules: [email, phrase, credentials])
        XCTAssertEqual(byRule[email.id]?.count, 1)
        XCTAssertEqual(byRule[phrase.id]?.count, 1)
        XCTAssertEqual(byRule[credentials.id]?.count, 0)
        XCTAssertGreaterThan(byRule[email.id]![0].minY, byRule[phrase.id]![0].minY)
    }
}
