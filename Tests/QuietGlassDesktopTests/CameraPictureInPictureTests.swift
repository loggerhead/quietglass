import AppKit
import AVFoundation
import XCTest
@testable import QuietGlass

private final class PictureCamera: NearbyCameraSession {
    let session = AVCaptureSession()
    var previewSession: AVCaptureSession? { session }
    let completion: (Result<NearbyFaceSample, NearbyCameraFailure>) -> Void
    var starts = 0, stops = 0
    var recognition = false
    var deviceID: String?
    init(_ completion: @escaping (Result<NearbyFaceSample, NearbyCameraFailure>) -> Void) { self.completion = completion }
    func start() { starts += 1 }
    func stop() { stops += 1 }
    func configureRecognition(_ enabled: Bool) { recognition = enabled }
    func configureDevice(_ id: String?) { deviceID = id }
}

final class CameraPictureInPictureTests: OptInDesktopTestCase {
    @MainActor private func settle() async { for _ in 0..<20 { await Task.yield() } }

    @MainActor func testOpeningTwiceReusesViewerAndNativeCloseStopsItsCamera() async throws {
        _ = NSApplication.shared
        var cameras: [PictureCamera] = []
        let viewer = CameraPictureInPicture(access: { true }, makeCamera: { let value = PictureCamera($0); cameras.append(value); return value })
        defer { viewer.close() }
        viewer.show(cameraID: "camera-A"); await settle()
        viewer.show(cameraID: "camera-A"); await settle()
        XCTAssertEqual(cameras.count, 1); XCTAssertEqual(cameras[0].starts, 1)
        XCTAssertTrue(viewer.session === cameras[0].session)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == QG("Camera picture in picture") && $0.isVisible })
        XCTAssertEqual(window.level, .floating)
        XCTAssertFalse(window.hidesOnDeactivate)
        XCTAssertTrue(window.isMovableByWindowBackground)
        window.close()
        XCTAssertFalse(viewer.running); XCTAssertNil(viewer.session); XCTAssertEqual(cameras[0].stops, 1)
    }

    @MainActor func testPermissionDenialAndClosingDuringPermissionRequestNeverStartCamera() async {
        _ = NSApplication.shared
        var starts = 0
        let denied = CameraPictureInPicture(access: { false }, makeCamera: { starts += 1; return PictureCamera($0) })
        denied.show(cameraID: ""); await settle()
        XCTAssertFalse(denied.running); XCTAssertNil(denied.session); XCTAssertEqual(starts, 0)
        denied.close()
        var permission: CheckedContinuation<Bool, Never>?
        let pending = CameraPictureInPicture(access: { await withCheckedContinuation { permission = $0 } }, makeCamera: { starts += 1; return PictureCamera($0) })
        pending.show(cameraID: ""); await settle(); pending.close()
        permission?.resume(returning: true); await settle()
        XCTAssertFalse(pending.running); XCTAssertNil(pending.session); XCTAssertEqual(starts, 0)
    }

    @MainActor func testClosingCheckReturnsProtectionLifecycleButLeavesPictureInPictureRunning() async {
        _ = NSApplication.shared
        var checkCamera: PictureCamera!, viewerCamera: PictureCamera!
        let viewer = CameraPictureInPicture(access: { true }, makeCamera: { viewerCamera = PictureCamera($0); return viewerCamera })
        let check = ProtectionCheck(access: { true }, makeCamera: { checkCamera = PictureCamera($0); return checkCamera }, pictureInPicture: viewer)
        defer { check.close(); viewer.close() }
        var began = 0, ended = 0, covered = false
        check.onBegin = { began += 1 }; check.onEnd = { ended += 1 }; check.onDemoCoverage = { covered = $0 }
        check.startCamera(id: "camera-A"); await settle()
        check.openPictureInPicture(cameraID: "camera-A"); await settle()
        check.close()
        XCTAssertEqual(began, 1); XCTAssertEqual(ended, 1); XCTAssertEqual(checkCamera.stops, 1)
        XCTAssertFalse(check.running); XCTAssertFalse(covered)
        XCTAssertTrue(viewer.running); XCTAssertTrue(viewer.session === viewerCamera.session)
    }

    @MainActor func testSleepAndInactiveSessionPauseUntilAllReasonsClear() async {
        _ = NSApplication.shared
        var cameras: [PictureCamera] = []
        let viewer = CameraPictureInPicture(access: { true }, makeCamera: { let value = PictureCamera($0); cameras.append(value); return value })
        defer { viewer.close() }
        viewer.show(cameraID: "A"); await settle()
        viewer.pause(for: "sleep"); viewer.pause(for: "session")
        XCTAssertFalse(viewer.running); XCTAssertEqual(cameras[0].stops, 1)
        viewer.resume(after: "sleep"); await settle(); XCTAssertEqual(cameras.count, 1)
        viewer.resume(after: "session"); await settle(); XCTAssertEqual(cameras.count, 2); XCTAssertTrue(viewer.running)
        viewer.close(); viewer.resume(after: "sleep"); await settle(); XCTAssertFalse(viewer.running)
    }

    func testViewerSharesProtectionCameraAndCannotStopOrReplaceIt() async {
        var cameras: [PictureCamera] = []
        let hub = FaceCameraHub(makeCamera: { let value = PictureCamera($0); cameras.append(value); return value })
        let protection = SharedFaceCamera(hub: hub, completion: { _ in })
        let viewer = SharedFaceCamera(hub: hub, previewOnly: true, completion: { _ in })
        protection.configureDevice("A"); protection.configureRecognition(true); protection.start()
        viewer.configureDevice("A"); viewer.start(); await hub.flush()
        XCTAssertEqual(cameras.count, 1); XCTAssertTrue(cameras[0].recognition)
        XCTAssertTrue(viewer.previewSession === cameras[0].session)
        viewer.stop(); await hub.flush(); XCTAssertEqual(cameras[0].stops, 0)
        var rejected = false
        let other = SharedFaceCamera(hub: hub, previewOnly: true, completion: { if case .failure(.configuration) = $0 { rejected = true } })
        other.configureDevice("B"); other.start(); await hub.flush()
        XCTAssertTrue(rejected); XCTAssertEqual(cameras.count, 1); XCTAssertEqual(cameras[0].stops, 0)
        other.stop(); protection.stop(); await hub.flush(); XCTAssertEqual(cameras[0].stops, 1)
    }

    func testViewerFollowsNewProtectionCameraAfterOldProtectionClientStops() async {
        var cameras: [PictureCamera] = []
        let hub = FaceCameraHub(makeCamera: { let value = PictureCamera($0); cameras.append(value); return value })
        let viewer = SharedFaceCamera(hub: hub, previewOnly: true, completion: { _ in })
        viewer.configureDevice("A"); viewer.start(); await hub.flush()
        let protection = SharedFaceCamera(hub: hub, completion: { _ in })
        protection.configureDevice("B"); protection.start(); await hub.flush()
        XCTAssertEqual(cameras.count, 2); XCTAssertEqual(cameras[0].stops, 1)
        XCTAssertEqual(cameras[1].deviceID, "B"); XCTAssertTrue(viewer.previewSession === cameras[1].session)
        protection.stop(); await hub.flush(); XCTAssertEqual(cameras[1].stops, 0)
        viewer.stop(); await hub.flush(); XCTAssertEqual(cameras[1].stops, 1)
    }
}
