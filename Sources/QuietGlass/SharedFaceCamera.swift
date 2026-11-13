import Foundation
import AVFoundation

/// Serializes production camera ownership. Frames/embeddings are never persisted.
final class SharedFaceCamera: NearbyCameraSession {
    private let id = UUID()
    private let hub: FaceCameraHub
    private let completion: (Result<NearbyFaceSample, NearbyCameraFailure>) -> Void
    private var recognition = false
    private var deviceID = ""
    private let previewOnly: Bool
    var previewSession: AVCaptureSession? { hub.previewSession }
    init(hub: FaceCameraHub = .shared, previewOnly: Bool = false, completion: @escaping (Result<NearbyFaceSample, NearbyCameraFailure>) -> Void) {
        self.hub = hub; self.previewOnly = previewOnly; self.completion = completion
    }
    func configureRecognition(_ enabled: Bool) { recognition = enabled }
    func configureDevice(_ id: String?) { deviceID = id ?? "" }
    func start() { hub.add(id, device: deviceID, recognition: recognition, previewOnly: previewOnly, completion: completion) }
    func stop() { hub.remove(id) }
    deinit { hub.remove(id) }
}

final class FaceCameraHub {
    static let shared = FaceCameraHub()
    private struct Client {
        let recognition: Bool
        let previewOnly: Bool
        let completion: (Result<NearbyFaceSample, NearbyCameraFailure>) -> Void
    }
    private let queue = DispatchQueue(label: "local.clinton.QuietGlass.camera-sharing")
    private let queueKey = DispatchSpecificKey<Bool>()
    private var clients: [UUID: Client] = [:]
    private var camera: NearbyCameraSession?
    private var device = ""
    private var generation = 0
    private let makeCamera: (@escaping (Result<NearbyFaceSample, NearbyCameraFailure>) -> Void) -> NearbyCameraSession
    init(makeCamera: @escaping (@escaping (Result<NearbyFaceSample, NearbyCameraFailure>) -> Void) -> NearbyCameraSession = { FaceCamera(completion: $0) }) {
        self.makeCamera = makeCamera
        queue.setSpecific(key: queueKey, value: true)
    }
    var previewSession: AVCaptureSession? {
        if DispatchQueue.getSpecific(key: queueKey) == true { return camera?.previewSession }
        return queue.sync { camera?.previewSession }
    }
    func add(_ id: UUID, device: String, recognition: Bool, previewOnly: Bool = false, completion: @escaping (Result<NearbyFaceSample, NearbyCameraFailure>) -> Void) {
        queue.async { [self] in
            if !clients.isEmpty && self.device != device {
                // A viewer follows a new protection camera instead of preventing it from starting.
                guard !previewOnly && clients.values.allSatisfy(\.previewOnly) else { completion(.failure(.configuration)); return }
                generation += 1; camera?.stop(); camera = nil
            }
            clients[id] = Client(recognition: recognition, previewOnly: previewOnly, completion: completion)
            if camera == nil {
                self.device = device; generation += 1
                let token = generation
                let camera = makeCamera { [weak self] result in
                    guard let self else { return }
                    self.queue.async {
                        guard token == self.generation else { return }
                        for client in self.clients.values { client.completion(result) }
                    }
                }
                self.camera = camera
                camera.configureDevice(device)
                camera.configureRecognition(clients.values.contains(where: \.recognition))
                camera.start()
            } else { camera?.configureRecognition(clients.values.contains(where: \.recognition)) }
        }
    }
    func remove(_ id: UUID) {
        queue.async { [self] in
            guard clients.removeValue(forKey: id) != nil else { return }
            if clients.isEmpty { generation += 1; camera?.stop(); camera = nil }
            else { camera?.configureRecognition(clients.values.contains(where: \.recognition)) }
        }
    }
    func flush() async { await withCheckedContinuation { continuation in queue.async { continuation.resume() } } }
}
