import AppKit
import ScreenCaptureKit

@MainActor
protocol ScreenFrameCapturing: AnyObject {
    var id: UUID { get }
    func start() async throws
    func stopAndWait() async
    func setRenderPlan(_ plan: ScreenBlurRenderPlan)
    func setFrameRate(_ value: Int32)
    func setRenderingEnabled(_ value: Bool)
}
extension DisplayCapture: ScreenFrameCapturing {}

struct ScreenBlurRegion: Equatable {
    /// Display-relative lower-left coordinates, independent of display origins.
    let rectangle: CGRect
    let radius: Double
}
struct ScreenBlurRenderPlan: Equatable {
    let radius: Double
    let regions: [ScreenBlurRegion]
    let fullScreen: Bool
}

struct ScreenCaptureDescriptor {
    let id: UInt32
    let width: Int
    let height: Int
    var filter: SCContentFilter? = nil
}
struct ScreenCaptureRequest {
    let id: UUID
    let display: ScreenCaptureDescriptor
    let configuration: SCStreamConfiguration
    let renderPlan: ScreenBlurRenderPlan
    let renderingEnabled: Bool
    let onFrame: @MainActor (CGImage) -> Void
    let onFailure: @MainActor (Error) -> Void
    let onSample: ((CVPixelBuffer) -> Void)?
    let onRegionFrame: @MainActor (CGImage) -> Void
}
enum ScreenCaptureAdapterError: Error { case missingFilter }

@MainActor
enum ScreenCaptureAdapter {
    static func displays() async throws -> [ScreenCaptureDescriptor] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        guard !own.isEmpty else { return [] }
        return content.displays.map { display in
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            if #available(macOS 14.2, *) { filter.includeMenuBar = true }
            return ScreenCaptureDescriptor(id: display.displayID, width: display.width, height: display.height, filter: filter)
        }
    }
    static func capture(_ request: ScreenCaptureRequest) throws -> any ScreenFrameCapturing {
        guard let filter = request.display.filter else { throw ScreenCaptureAdapterError.missingFilter }
        return DisplayCapture(id: request.id, filter: filter, configuration: request.configuration,
            renderPlan: request.renderPlan, renderingEnabled: request.renderingEnabled,
            onFrame: request.onFrame, onFailure: request.onFailure, onSample: request.onSample,
            onRegionFrame: request.onRegionFrame)
    }
}
