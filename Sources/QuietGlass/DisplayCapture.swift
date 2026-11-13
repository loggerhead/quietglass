// Clinton Imaro was here 20/09/2026.

import CoreImage
import ScreenCaptureKit

final class DisplayCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    static let background = CGColor(gray: 0.08, alpha: 1)
    let id: UUID
    private var stream: SCStream!
    private let configuration: SCStreamConfiguration
    private var configuredFrameRate: Int32
    private let frameQueue = DispatchQueue(label: "local.clinton.QuietGlass.frames", qos: .userInteractive)
    private let renderQueue = DispatchQueue(label: "local.clinton.QuietGlass.blur", qos: .userInteractive)
    private let renderer = DisplayBlurRenderer()
    private let onFrame: @MainActor (CGImage) -> Void
    private let onFailure: @MainActor (Error) -> Void
    private let onSample: ((CVPixelBuffer) -> Void)?
    private var renderPlan: ScreenBlurRenderPlan
    private let regionalRenderer = DisplayBlurRenderer()
    private let onRegionFrame: @MainActor (CGImage) -> Void
    private var pendingBuffer: CVPixelBuffer?
    private var lastBuffer: CVPixelBuffer?
    private var rendering = false
    private var stopped = false
    private var renderingEnabled: Bool

    init(id: UUID, filter: SCContentFilter, configuration: SCStreamConfiguration, renderPlan: ScreenBlurRenderPlan, renderingEnabled: Bool = true,
         onFrame: @escaping @MainActor (CGImage) -> Void,
         onFailure: @escaping @MainActor (Error) -> Void,
         onSample: ((CVPixelBuffer) -> Void)? = nil,
         onRegionFrame: @escaping @MainActor (CGImage) -> Void) {
        self.id = id
        self.configuration = configuration
        self.configuredFrameRate = configuration.minimumFrameInterval.timescale
        self.renderPlan = renderPlan; self.onRegionFrame = onRegionFrame
        self.renderingEnabled = renderingEnabled
        self.onFrame = onFrame
        self.onFailure = onFailure
        self.onSample = onSample
        super.init()
        stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    }

    func start() async throws {
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
        try await stream.startCapture()
    }

    func stop() {
        Task { await stopAndWait() }
    }

    func stopAndWait() async {
        await withCheckedContinuation { continuation in
            frameQueue.async { [self] in
                stopped = true; pendingBuffer = nil; lastBuffer = nil
                continuation.resume()
            }
        }
        try? await stream.stopCapture()
    }

    func setRenderPlan(_ value: ScreenBlurRenderPlan) {
        frameQueue.async { [self] in
            guard !stopped, renderPlan != value else { return }
            renderPlan = value; pendingBuffer = lastBuffer; renderNextFrame()
        }
    }

    @MainActor func setFrameRate(_ value: Int32) {
        guard value > 0, value != configuredFrameRate else { return }
        configuredFrameRate = value
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: value)
        Task { [stream, configuration, onFailure] in
            do { try await stream?.updateConfiguration(configuration) }
            catch { onFailure(error) }
        }
    }

    func setRenderingEnabled(_ value: Bool) {
        frameQueue.async { [self] in
            guard !stopped, renderingEnabled != value else { return }
            renderingEnabled = value
            pendingBuffer = value ? lastBuffer : nil
            if value { renderNextFrame() }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        frameQueue.async { [self] in
            guard !stopped else { return }
            stopped = true
            pendingBuffer = nil
            lastBuffer = nil
            Task { @MainActor [onFailure] in onFailure(error) }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !stopped, type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let buffer = sampleBuffer.imageBuffer else { return }
        lastBuffer = buffer
        onSample?(buffer)
        pendingBuffer = renderingEnabled ? buffer : nil
        renderNextFrame()
    }

    private func renderNextFrame() {
        guard !stopped, renderingEnabled, !rendering, let buffer = pendingBuffer else { return }
        pendingBuffer = nil
        rendering = true
        let plan = renderPlan
        renderQueue.async { [self] in
            let result: (CGImage?, CGImage?) = autoreleasepool {
                let input = CIImage(cvPixelBuffer: buffer)
                let regions = plan.regions.isEmpty ? nil : regionalRenderer.renderRegions(input, regions: plan.regions)
                // A region-only frame reuses its composite for readiness; it does
                // not also render an invisible full-screen image.
                let full = plan.fullScreen ? renderer.render(input, radius: plan.radius) : regions
                return (full, regions)
            }
            frameQueue.async { [self] in
                rendering = false
                guard !stopped else { return }
                Task { @MainActor [onFrame, onRegionFrame] in
                    if let image = result.0 { onFrame(image) }
                    if let image = result.1 { onRegionFrame(image) }
                }
                renderNextFrame()
            }
        }
    }
}
