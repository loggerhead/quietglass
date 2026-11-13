import AppKit
import AVFoundation
import SwiftUI

private final class CameraPictureInPicturePanel: NSPanel {
    override var canBecomeMain: Bool { false }
}

/// A viewer-only camera lease. It never submits detection or protection commands.
@MainActor final class CameraPictureInPicture: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var session: AVCaptureSession?
    @Published private(set) var running = false
    @Published private(set) var message = "Starting camera…"
    private var panel: NSPanel?
    private var camera: NearbyCameraSession?
    private var cameraID = ""
    private var generation = 0
    private var terminationObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var pausedReasons: Set<String> = []
    private var wantsCamera = false
    private let access: () async -> Bool
    private let makeCamera: (@escaping (Result<NearbyFaceSample, NearbyCameraFailure>) -> Void) -> NearbyCameraSession

    init(access: @escaping () async -> Bool = NearbyPeople.requestCameraAccess,
         makeCamera: @escaping (@escaping (Result<NearbyFaceSample, NearbyCameraFailure>) -> Void) -> NearbyCameraSession = {
             SharedFaceCamera(previewOnly: true, completion: $0)
         }) {
        self.access = access; self.makeCamera = makeCamera
        super.init()
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        let center = NSWorkspace.shared.notificationCenter
        for (pauseName, resumeName, reason) in [
            (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, "sleep"),
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, "displays"),
            (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, "session")
        ] {
            workspaceObservers.append(center.addObserver(forName: pauseName, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.pause(for: reason) }
            })
            workspaceObservers.append(center.addObserver(forName: resumeName, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.resume(after: reason) }
            })
        }
    }

    func show(cameraID: String) {
        if panel == nil {
            let value = CameraPictureInPicturePanel(contentRect: CGRect(x: 0, y: 0, width: 360, height: 203),
                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
            value.title = QG("Camera picture in picture")
            value.isReleasedWhenClosed = false; value.isFloatingPanel = true; value.hidesOnDeactivate = false
            value.isMovableByWindowBackground = true; value.level = .floating
            value.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
            value.contentAspectRatio = CGSize(width: 16, height: 9)
            value.minSize = CGSize(width: 240, height: 157)
            value.backgroundColor = .black; value.delegate = self
            value.contentView = NSHostingView(rootView: CameraPictureInPictureView(viewer: self))
            if let screen = NSScreen.main {
                value.setFrameOrigin(CGPoint(x: screen.visibleFrame.maxX - value.frame.width - 24,
                                             y: screen.visibleFrame.maxY - value.frame.height - 24))
            }
            panel = value
        }
        panel?.orderFrontRegardless()
        guard !running || self.cameraID != cameraID else { return }
        start(cameraID: cameraID)
    }

    private func start(cameraID: String) {
        stop(); self.cameraID = cameraID
        wantsCamera = true
        guard pausedReasons.isEmpty else { message = "Camera paused while your Mac is inactive."; return }
        running = true; message = "Starting camera…"
        let token = generation
        Task { [weak self] in
            guard let self else { return }
            let allowed = await access()
            guard running && generation == token else { return }
            guard allowed else { fail(.permission); return }
            let value = makeCamera { [weak self] result in
                Task { @MainActor in
                    guard let self, self.running, self.generation == token else { return }
                    switch result {
                    case .success:
                        self.session = self.camera?.previewSession
                        self.message = "Live camera view"
                    case .failure(let failure): self.fail(failure)
                    }
                }
            }
            camera = value; value.configureDevice(cameraID); value.start()
            session = value.previewSession
        }
    }

    func retry() { start(cameraID: cameraID) }
    private func fail(_ failure: NearbyCameraFailure) {
        stop(); wantsCamera = false
        message = failure == .configuration
            ? "Use the camera selected for protection, then reopen picture in picture."
            : QG("%@. Check the camera and try again.", QG(failure.title))
    }
    private func stop() {
        generation += 1; camera?.stop(); camera = nil; session = nil; running = false
    }
    func pause(for reason: String) {
        pausedReasons.insert(reason)
        if wantsCamera { stop(); message = "Camera paused while your Mac is inactive." }
    }
    func resume(after reason: String) {
        pausedReasons.remove(reason)
        if pausedReasons.isEmpty && wantsCamera && !running { start(cameraID: cameraID) }
    }
    func close() {
        let value = panel; panel = nil
        value?.delegate = nil; value?.contentView = nil; value?.orderOut(nil); value?.close()
        stop(); wantsCamera = false
    }
    func windowWillClose(_ notification: Notification) {
        (notification.object as? NSWindow)?.contentView = nil
        panel = nil; stop(); wantsCamera = false
    }
    deinit {
        camera?.stop()
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}

private struct CameraPictureInPictureView: View {
    @ObservedObject var viewer: CameraPictureInPicture
    var body: some View {
        Group {
            if let session = viewer.session {
                CameraPictureInPicturePreview(session: session)
                    .accessibilityLabel(QG("Live camera view"))
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "video").font(.system(size: 24))
                    Text(QG(viewer.message)).font(.system(size: 12)).multilineTextAlignment(.center)
                    if viewer.running { ProgressView().controlSize(.small) }
                    else { Button(QG("Retry camera")) { viewer.retry() } }
                }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(.black).foregroundStyle(.white).preferredColorScheme(.dark)
    }
}

private struct CameraPictureInPicturePreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> CameraPictureInPictureSurface { CameraPictureInPictureSurface() }
    func updateNSView(_ view: CameraPictureInPictureSurface, context: Context) {
        view.preview.session = session; view.needsLayout = true
    }
    static func dismantleNSView(_ view: CameraPictureInPictureSurface, coordinator: ()) { view.preview.session = nil }
}

private final class CameraPictureInPictureSurface: NSView {
    let preview = AVCaptureVideoPreviewLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); wantsLayer = true
        preview.videoGravity = .resizeAspect; layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(preview)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout(); CATransaction.begin(); CATransaction.setDisableActions(true)
        preview.frame = bounds
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false
        }
        CATransaction.commit()
    }
}
