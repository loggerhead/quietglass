import AppKit
import XCTest
import ShieldCore
@testable import QuietGlass

@MainActor private final class CaptureCounts {
    var live = 0
    var maximumLive = 0
}
@MainActor private final class TestScreenCapture: ScreenFrameCapturing {
    let request: ScreenCaptureRequest
    let counts: CaptureCounts
    var id: UUID { request.id }
    var holdStart = false, holdStop = false
    var startGate: CheckedContinuation<Void, Never>?, stopGate: CheckedContinuation<Void, Never>?
    var started = false, stopped = false
    var renderPlan: ScreenBlurRenderPlan
    var regionalRadii: Set<Double> { Set(renderPlan.regions.map(\.radius)) }
    var radius: Double { renderPlan.radius }
    var frameRate: Int32
    var rendering: Bool
    init(_ request: ScreenCaptureRequest, counts: CaptureCounts) {
        self.request = request; self.counts = counts; renderPlan = request.renderPlan
        frameRate = request.configuration.minimumFrameInterval.timescale; rendering = request.renderingEnabled
    }
    func start() async throws {
        if holdStart { await withCheckedContinuation { startGate = $0 } }
        started = true; counts.live += 1; counts.maximumLive = max(counts.maximumLive, counts.live)
    }
    func stopAndWait() async {
        guard !stopped else { return }
        if holdStop { await withCheckedContinuation { stopGate = $0 } }
        stopped = true
        if started { counts.live -= 1 }
    }
    func setRenderPlan(_ value: ScreenBlurRenderPlan) { renderPlan = value }
    func setFrameRate(_ value: Int32) { frameRate = value }
    func setRenderingEnabled(_ value: Bool) { rendering = value }
    func releaseStart() { holdStart = false; startGate?.resume(); startGate = nil }
    func releaseStop() { holdStop = false; stopGate?.resume(); stopGate = nil }
}
@MainActor private final class TestCaptureFactory {
    let counts = CaptureCounts()
    let display: ScreenCaptureDescriptor
    var loads = 0
    var captures: [TestScreenCapture] = []
    var holdNextStart = false
    init(id: UInt32) { display = ScreenCaptureDescriptor(id: id, width: 4, height: 4) }
    func load() async throws -> [ScreenCaptureDescriptor] { loads += 1; return [display] }
    func make(_ request: ScreenCaptureRequest) -> any ScreenFrameCapturing {
        let capture = TestScreenCapture(request, counts: counts)
        capture.holdStart = holdNextStart; holdNextStart = false
        captures.append(capture); return capture
    }
    func releaseAll() { for capture in captures { capture.releaseStart(); capture.releaseStop() } }
}
@MainActor private final class CapturePipelineHarness {
    let frame = CGRect(x: 0, y: 0, width: 4, height: 4)
    let factory: TestCaptureFactory
    let executor: ScreenBlurExecutor
    let manual: ProtectionRule
    let scan = ProtectionPreset.sensitiveText.rule()
    var engine: ProtectionEngine
    init() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let id = try XCTUnwrap((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value)
        let factory = TestCaptureFactory(id: id); self.factory = factory
        executor = ScreenBlurExecutor(loadDisplays: factory.load, makeCapture: factory.make, surfaceFrame: { _ in CGRect(x: 0, y: 0, width: 4, height: 4) })
        manual = ProtectionRule(name: "Manual", trigger: .manual(shortcut: nil), scope: .allDisplays)
        engine = try ProtectionEngine(rules: [manual, scan])
        engine.send(.displays([ProtectionDisplay(id: id, frame: frame)]), at: 0)
        engine.send(.permission(.screen, granted: true), at: 0)
        engine.send(.escapeAvailability(true), at: 0)
        executor.configureTextRules([scan])
    }
    func apply(_ event: ProtectionEvent) { executor.apply(engine.send(event, at: 0)) }
    func settle() async { for _ in 0..<25 { await Task.yield() } }
    func finish() { factory.releaseAll(); executor.shutdown() }
    func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.blue.cgColor); context.fill(frame)
        return try XCTUnwrap(context.makeImage())
    }
}

final class ScreenCapturePipelineTests: OptInDesktopTestCase {
    @MainActor func testManualAndOCRPlanChangesReuseOneStreamAndContentLookup() async throws {
        let h = try CapturePipelineHarness(); defer { h.finish() }
        h.apply(.manual(h.manual.id, active: true)); await h.settle()
        XCTAssertEqual(h.factory.loads, 1); XCTAssertEqual(h.factory.captures.count, 1)
        XCTAssertNotNil(h.factory.captures[0].request.onSample, "OCR must receive the same captured sample")
        let capture = h.factory.captures[0]
        var ready = 0; h.executor.onReady = { ready += 1 }
        for _ in 0..<100 { h.apply(.tick); capture.request.onFrame(try h.image()) }
        await h.settle()
        XCTAssertEqual(h.factory.loads, 1, "Ordinary plan frames must not query SCShareableContent again")
        XCTAssertEqual(h.factory.captures.count, 1)
        XCTAssertEqual(h.factory.counts.maximumLive, 1)
        XCTAssertEqual(ready, 1, "Capture readiness must not erase notices on every frame")
    }
    @MainActor func testIndependentRegionRadiiShareTheCapturedFrameAndUpdateWithoutRestart() async throws {
        let h = try CapturePipelineHarness(); defer { h.finish() }
        let ref = ProtectedWindowRef(bundleID: "test.app", windowID: 1)
        let first = ProtectionRule(name: "First", trigger: .manual(shortcut: nil),
            scope: .region(ref, normalizedRect: CGRect(x: 0, y: 0, width: 0.5, height: 1), persistence: .session),
            action: .blur(BlurParameters(radius: 10), peek: nil))
        var second = ProtectionRule(name: "Second", trigger: .manual(shortcut: nil),
            scope: .region(ref, normalizedRect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1), persistence: .session),
            action: .blur(BlurParameters(radius: 50), peek: nil))
        try h.engine.replaceRules([first, second])
        h.apply(.windows([ProtectionWindow(reference: ref, frame: h.frame)], activeWindow: h.frame, activeBundleID: "test.app"))
        h.apply(.manual(first.id, active: true)); h.apply(.manual(second.id, active: true)); await h.settle()
        let capture = try XCTUnwrap(h.factory.captures.first)
        XCTAssertEqual(capture.regionalRadii, [10, 50])
        XCTAssertFalse(capture.renderPlan.fullScreen)
        capture.request.onRegionFrame(try h.image())
        second.action = .blur(BlurParameters(radius: 35), peek: nil)
        try h.engine.replaceRules([first, second]); h.apply(.tick); await h.settle()
        XCTAssertEqual(capture.regionalRadii, [10, 35])
        XCTAssertEqual(h.factory.captures.count, 1)
        XCTAssertEqual(h.factory.loads, 1)
    }
    @MainActor func testResumeWaitsForPreviousStreamStopBeforeCreatingAnother() async throws {
        let h = try CapturePipelineHarness(); defer { h.finish() }
        h.apply(.manual(h.manual.id, active: true)); await h.settle()
        let first = h.factory.captures[0]; first.holdStop = true
        h.apply(.pause(until: nil)); await h.settle()
        h.apply(.resume); await h.settle()
        XCTAssertEqual(h.factory.captures.count, 1)
        first.releaseStop(); await h.settle()
        XCTAssertEqual(h.factory.captures.count, 2)
        XCTAssertTrue(first.stopped)
        XCTAssertEqual(h.factory.counts.maximumLive, 1)
    }
    @MainActor func testCancelledStartMustFinishAndStopBeforeItsReplacementStarts() async throws {
        let h = try CapturePipelineHarness(); defer { h.finish() }
        h.factory.holdNextStart = true
        h.apply(.manual(h.manual.id, active: true)); await h.settle()
        let first = h.factory.captures[0]
        XCTAssertFalse(first.started)
        h.apply(.pause(until: nil)); h.apply(.resume); await h.settle()
        XCTAssertEqual(h.factory.captures.count, 1)
        first.releaseStart(); await h.settle()
        XCTAssertEqual(h.factory.captures.count, 2)
        XCTAssertEqual(h.factory.counts.maximumLive, 1)
        XCTAssertTrue(first.stopped)
    }
    @MainActor func testCaptureFailureRequiresExplicitRetryAndRejectsStaleFailureCallbacks() async throws {
        let h = try CapturePipelineHarness(); defer { h.finish() }
        h.apply(.manual(h.manual.id, active: true)); await h.settle()
        let first = h.factory.captures[0]
        var failures = 0; h.executor.onFailure = { _ in failures += 1 }
        let error = NSError(domain: "Capture test", code: 1)
        first.request.onFailure(error); await h.settle()
        for _ in 0..<100 { h.apply(.tick) }
        await h.settle()
        XCTAssertEqual(h.factory.loads, 1, "Failure must not become a per-frame restart loop")
        h.executor.retryCapture(); await h.settle()
        XCTAssertEqual(h.factory.captures.count, 2)
        first.request.onFailure(error)
        XCTAssertEqual(failures, 1, "A stopped generation cannot fail the replacement stream")
        XCTAssertEqual(h.factory.counts.maximumLive, 1)
    }
}
