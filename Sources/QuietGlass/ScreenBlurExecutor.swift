import AppKit
import QuartzCore
import ScreenCaptureKit
import ShieldCore

@MainActor
private final class ProtectionFrameTarget: NSObject {
    weak var executor: ScreenBlurExecutor?
    @objc func draw(_ link: CADisplayLink) { executor?.animate(link) }
}

/// The only capture owner in the rule path. Each display has one stream, shared
/// by full-screen blur, region rendering, and all OCR rules. Surfaces are adapters.
@MainActor
final class ScreenBlurExecutor: ProtectionPlanExecuting {
    var onText: ((UUID, [UInt32: [CGRect]]) -> Void)?
    var onTextFailure: ((Error) -> Void)?
    var onFailure: ((Error) -> Void)?
    var onReady: (() -> Void)?
    var includeInCaptures = false {
        didSet {
            for surface in fullSurfaces.values { surface.panel.sharingType = includeInCaptures ? .readOnly : .none }
            for surface in regionSurfaces.values { surface.panel.sharingType = includeInCaptures ? .readOnly : .none }
        }
    }
    private(set) var captures: [UInt32: any ScreenFrameCapturing] = [:]
    private let loadDisplays: @MainActor () async throws -> [ScreenCaptureDescriptor]
    private let makeCapture: @MainActor (ScreenCaptureRequest) throws -> any ScreenFrameCapturing
    private let surfaceFrame: @MainActor (NSScreen) -> CGRect
    private var failedDisplays = Set<UInt32>()
    private(set) var fullSurfaces: [UInt32: ShieldSurface] = [:]
    private(set) var regionSurfaces: [UInt32: PrivacySurface] = [:]
    private var analyzers: [UInt32: LocalTextAnalyzer] = [:]
    private var textRules: [ProtectionRule] = []
    private var configuredTextIDs: [UUID] = []
    private var textRegions: [UUID: [UInt32: [CGRect]]] = [:]
    private var plan: ProtectionPlan?
    private var captureTask: Task<Void, Never>?
    private var stoppingTask: Task<Void, Never>?
    private var generation = 0
    private var transitions: [UInt32: GlassTransition] = [:]
    private var animatedCoverage: [UInt32: Double] = [:]
    private var animationLink: CADisplayLink?
    private var lastFrame: TimeInterval?
    private let frameTarget = ProtectionFrameTarget()
    private var stopped = false
    private var freshFrameIDs = Set<UInt32>()
    private var announcedReady = false
    var isCapturing: Bool { captureTask != nil || !captures.isEmpty }

    init(loadDisplays: (@MainActor () async throws -> [ScreenCaptureDescriptor])? = nil,
         makeCapture: (@MainActor (ScreenCaptureRequest) throws -> any ScreenFrameCapturing)? = nil,
         surfaceFrame: (@MainActor (NSScreen) -> CGRect)? = nil) {
        self.loadDisplays = loadDisplays ?? ScreenCaptureAdapter.displays
        self.makeCapture = makeCapture ?? ScreenCaptureAdapter.capture
        self.surfaceFrame = surfaceFrame ?? { $0.frame }
    }

    func configureTextRules(_ rules: [ProtectionRule]) {
        let enabled = rules.filter { rule in
            guard rule.isEnabled else { return false }
            if case .sensitiveText = rule.trigger { return true }; return false
        }
        guard enabled != textRules else { return }
        textRules = enabled; textRegions = [:]
        stopStreams()
        if let plan { apply(plan) }
    }

    func apply(_ plan: ProtectionPlan) {
        guard !stopped else { return }
        self.plan = plan
        reconcileScreens()
        if configuredTextIDs != plan.textAnalysisRuleIDs {
            configuredTextIDs = plan.textAnalysisRuleIDs
            stopStreams()
        }
        if plan.state == .suspended || { if case .paused = plan.state { return true }; return false }() || plan.state == .cleared {
            clearImmediately(); stopStreams(); return
        }
        for display in plan.displays {
            let id = display.displayID
            if !display.animatesCoverage {
                var transition = transitions[id] ?? GlassTransition()
                transition.reset(to: display.fullScreenCoverage)
                transitions[id] = transition; animatedCoverage[id] = display.fullScreenCoverage
                fullSurfaces[id]?.update(coverage: display.fullScreenCoverage, direction: display.direction, excludedRegions: display.excludedRegions)
            }
            captures[id]?.setRenderPlan(renderPlan(display))
            captures[id]?.setFrameRate(display.fullScreenCoverage > 0 || plan.captureDisplayIDs.contains(id) ? 30 : display.hasProtection ? 12 : 3)
            captures[id]?.setRenderingEnabled(display.hasProtection || plan.captureDisplayIDs.contains(id) || (animatedCoverage[id] ?? 0) > 0)
            renderRegions(display)
        }
        startAnimation()
        startCaptureIfNeeded()
    }

    private func reconcileScreens() {
        let screens = NSScreen.screens
        var existing = Set<UInt32>()
        for screen in screens {
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { continue }
            existing.insert(id)
            if fullSurfaces[id] == nil { fullSurfaces[id] = ShieldSurface(screen: screen, includeInCaptures: includeInCaptures) }
            if regionSurfaces[id] == nil { regionSurfaces[id] = PrivacySurface(screen: screen, includeInCaptures: includeInCaptures) }
            fullSurfaces[id]?.resize(to: surfaceFrame(screen)); regionSurfaces[id]?.resize(to: surfaceFrame(screen))
        }
        for id in Set(fullSurfaces.keys).subtracting(existing) {
            if let capture = captures.removeValue(forKey: id) { enqueueStop(capture) }
            analyzers.removeValue(forKey: id)?.cancel()
            fullSurfaces.removeValue(forKey: id)?.panel.close(); regionSurfaces.removeValue(forKey: id)?.panel.close()
            transitions.removeValue(forKey: id); animatedCoverage.removeValue(forKey: id)
            for rule in textRegions.keys { textRegions[rule]?.removeValue(forKey: id) }
        }
    }

    private func renderPlan(_ display: DisplayProtectionPlan) -> ScreenBlurRenderPlan {
        let frame = fullSurfaces[display.displayID]?.panel.frame ?? .zero
        let covered = (animatedCoverage[display.displayID] ?? 0) >= 0.999
        let regions = !covered && frame.width > 0 && frame.height > 0 ? display.orderedRegions.map { region in
            ScreenBlurRegion(rectangle: CGRect(x: (region.rectangle.minX - frame.minX) / frame.width,
                y: (region.rectangle.minY - frame.minY) / frame.height,
                width: region.rectangle.width / frame.width, height: region.rectangle.height / frame.height), radius: region.blur.radius)
        } : []
        return ScreenBlurRenderPlan(radius: display.blur.radius, regions: regions,
            fullScreen: display.fullScreenCoverage > 0 || plan?.captureDisplayIDs.contains(display.displayID) == true || (animatedCoverage[display.displayID] ?? 0) > 0)
    }

    private func renderRegions(_ display: DisplayProtectionPlan) {
        // Full-screen plans already contain all protected pixels. Focus is a carve-out
        // of that layer; the region layer must not accidentally fill its hole.
        let covered = (animatedCoverage[display.displayID] ?? 0) >= 0.999
        regionSurfaces[display.displayID]?.update(regions: covered ? [] : display.orderedRegions)
    }

    private func startAnimation() {
        guard let plan, animationLink == nil else { return }
        let unsettled = plan.displays.contains { (animatedCoverage[$0.displayID] ?? 0) != $0.fullScreenCoverage }
        guard unsettled, let screen = NSScreen.screens.max(by: { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond }) else { return }
        frameTarget.executor = self
        let link = screen.displayLink(target: frameTarget, selector: #selector(ProtectionFrameTarget.draw(_:)))
        animationLink = link; lastFrame = nil
        link.add(to: .main, forMode: .common)
    }

    fileprivate func animate(_ link: CADisplayLink) {
        guard link === animationLink, let plan else { return }
        let now = link.targetTimestamp
        let elapsed = now - (lastFrame ?? link.timestamp); lastFrame = now
        var settled = true
        for display in plan.displays {
            let id = display.displayID
            var transition = transitions[id] ?? GlassTransition()
            let value = transition.advance(to: display.fullScreenCoverage, elapsed: elapsed)
            transitions[id] = transition; animatedCoverage[id] = value
            fullSurfaces[id]?.update(coverage: value, direction: display.direction, excludedRegions: display.excludedRegions)
            renderRegions(display)
            if value != display.fullScreenCoverage { settled = false }
        }
        if settled { animationLink?.invalidate(); animationLink = nil; stopIdleStreams() }
    }

    private func startCaptureIfNeeded() {
        guard let plan, captureTask == nil else { return }
        let needsCapture = plan.hasProtection || !plan.captureDisplayIDs.isEmpty || !plan.textAnalysisRuleIDs.isEmpty || animatedCoverage.values.contains { $0 > 0 }
        guard needsCapture else { stopIdleStreams(); return }
        let wanted = Set(plan.displays.filter { $0.hasProtection || plan.captureDisplayIDs.contains($0.displayID) || !plan.textAnalysisRuleIDs.isEmpty || (animatedCoverage[$0.displayID] ?? 0) > 0 }.map(\.displayID))
        guard !wanted.intersection(fullSurfaces.keys).subtracting(captures.keys).subtracting(failedDisplays).isEmpty else { return }
        announcedReady = false
        let token = generation
        let previousStops = stoppingTask
        captureTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.captureTask = nil } }
            await previousStops?.value
            guard !Task.isCancelled, self.generation == token else { return }
            do {
                let content = try await self.loadDisplays()
                guard !Task.isCancelled, self.generation == token else { return }
                for display in content {
                    let id = display.id
                    guard wanted.contains(id), !self.failedDisplays.contains(id), self.fullSurfaces[id] != nil, self.captures[id] == nil,
                          let current = self.plan?.displays.first(where: { $0.displayID == id }) else { continue }
                    let session = UUID()
                    let config = SCStreamConfiguration()
                    config.width = max(1, display.width); config.height = max(1, display.height)
                    config.minimumFrameInterval = CMTime(value: 1, timescale: current.fullScreenCoverage > 0 || self.plan?.captureDisplayIDs.contains(id) == true ? 30 : current.hasProtection ? 12 : 3)
                    config.queueDepth = 3; config.backgroundColor = DisplayCapture.background
                    config.shouldBeOpaque = true; config.showsCursor = false; config.capturesAudio = false
                    config.scalesToFit = true; config.preservesAspectRatio = true; config.pixelFormat = kCVPixelFormatType_32BGRA
                    let permittedTextRules = self.textRules.filter { self.configuredTextIDs.contains($0.id) }
                    let analyzer = permittedTextRules.isEmpty ? nil : LocalTextAnalyzer(rules: permittedTextRules) { [weak self] result in
                        guard let self, self.generation == token, self.captures[id]?.id == session else { return }
                        switch result {
                        case .success(let values):
                            guard let frame = self.fullSurfaces[id]?.panel.frame else { return }
                            for (rule, regions) in values {
                                self.textRegions[rule, default: [:]][id] = regions.map { ScreenRegions.fromVision($0, in: frame) }
                                self.onText?(rule, self.textRegions[rule] ?? [:])
                            }
                        case .failure(let error): self.onTextFailure?(error)
                        }
                    }
                    self.analyzers[id] = analyzer
                    let request = ScreenCaptureRequest(id: session, display: display, configuration: config, renderPlan: self.renderPlan(current), renderingEnabled: current.hasProtection || self.plan?.captureDisplayIDs.contains(id) == true,
                        onFrame: { [weak self] image in
                            guard let self, self.generation == token, self.captures[id]?.id == session else { return }
                            self.fullSurfaces[id]?.setImage(image)
                            self.freshFrameIDs.insert(id)
                            if let current = self.plan?.displays.first(where: { $0.displayID == id }) {
                                self.fullSurfaces[id]?.update(coverage: self.animatedCoverage[id] ?? current.fullScreenCoverage, direction: current.direction, excludedRegions: current.excludedRegions)
                                self.renderRegions(current)
                            }
                            if !self.announcedReady, wanted.isSubset(of: self.freshFrameIDs) { self.announcedReady = true; self.onReady?() }
                        }, onFailure: { [weak self] error in
                            guard let self, self.generation == token, self.captures[id]?.id == session else { return }
                            self.failedDisplays.insert(id)
                            self.freshFrameIDs.remove(id); self.announcedReady = false
                            if let capture = self.captures.removeValue(forKey: id) { self.enqueueStop(capture) }
                            self.onFailure?(error)
                        }, onSample: analyzer.map { worker in { worker.offer($0) } },
                        onRegionFrame: { [weak self] image in
                            guard let self, self.generation == token, self.captures[id]?.id == session else { return }
                            self.regionSurfaces[id]?.setImage(image)
                        })
                    let capture = try self.makeCapture(request)
                    self.captures[id] = capture
                    do { try await capture.start() } catch {
                        if self.captures[id]?.id == session { self.captures.removeValue(forKey: id) }
                        await capture.stopAndWait(); throw error
                    }
                    guard !Task.isCancelled, self.generation == token, self.captures[id]?.id == session else { await capture.stopAndWait(); return }
                }
            } catch {
                if self.generation == token {
                    self.failedDisplays.formUnion(wanted.subtracting(self.captures.keys))
                    self.freshFrameIDs.subtract(self.failedDisplays); self.announcedReady = false
                    self.onFailure?(error)
                }
            }
        }
    }

    private func stopIdleStreams() {
        guard configuredTextIDs.isEmpty, plan?.captureDisplayIDs.isEmpty != false, plan?.hasProtection != true, !animatedCoverage.values.contains(where: { $0 > 0 }) else { return }
        stopStreams()
    }
    private func stopStreams() {
        guard captureTask != nil || !captures.isEmpty else { return }
        generation += 1
        freshFrameIDs = []; announcedReady = false
        let previousStart = captureTask, previousStop = stoppingTask, previousCaptures = Array(captures.values)
        previousStart?.cancel(); captureTask = nil; captures = [:]
        stoppingTask = Task {
            await previousStop?.value
            await previousStart?.value
            for capture in previousCaptures { await capture.stopAndWait() }
        }
        for analyzer in analyzers.values { analyzer.cancel() }; analyzers = [:]
    }
    private func enqueueStop(_ capture: any ScreenFrameCapturing) {
        let previous = stoppingTask
        stoppingTask = Task { await previous?.value; await capture.stopAndWait() }
    }
    func retryCapture() { failedDisplays = []; if let plan { apply(plan) } }
    private func clearImmediately() {
        animationLink?.invalidate(); animationLink = nil; transitions = [:]; animatedCoverage = [:]
        for surface in fullSurfaces.values { surface.clear() }
        for surface in regionSurfaces.values { surface.clear() }
    }
    func shutdown() {
        stopped = true; stopStreams(); clearImmediately()
        for surface in fullSurfaces.values { surface.panel.close() }
        for surface in regionSurfaces.values { surface.panel.close() }
        fullSurfaces = [:]; regionSurfaces = [:]
    }
}
