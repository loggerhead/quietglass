//  Created by Clinton Imaro on 20/09/2026.

import Vision
import CoreVideo
import ShieldCore
import CryptoKit

final class LocalTextAnalyzer {
    private let queue = DispatchQueue(label: "local.clinton.QuietGlass.text", qos: .utility)
    private let lock = NSLock()
    private var busy = false
    private var lastScan: TimeInterval = 0
    private var cancelled = false
    private var lastFingerprint: SHA256.Digest?
    private struct Configuration { let id: UUID; let options: SensitiveTextOptions; let phrases: [String] }
    private let configurations: [Configuration]
    private let completion: @MainActor (Result<[UUID: [CGRect]], Error>) -> Void

    init(options: SensitiveTextOptions, phrases: [String] = [], completion: @escaping @MainActor (Result<[CGRect], Error>) -> Void) {
        let id = UUID()
        configurations = [Configuration(id: id, options: options, phrases: phrases)]
        self.completion = { result in completion(result.map { $0[id] ?? [] }) }
    }

    /// One Vision request per frame, with independent matching for every enabled text rule.
    init(rules: [ProtectionRule], completion: @escaping @MainActor (Result<[UUID: [CGRect]], Error>) -> Void) {
        configurations = Self.configurations(for: rules)
        self.completion = completion
    }

    private static func configurations(for rules: [ProtectionRule]) -> [Configuration] {
        rules.compactMap { rule in
            guard case .sensitiveText(let types, let phrases) = rule.trigger else { return nil }
            let options = types.reduce(SensitiveTextOptions()) { $0.union($1.option) }
            return Configuration(id: rule.id, options: options, phrases: phrases)
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func offer(_ buffer: CVPixelBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard !cancelled, !busy, now - lastScan >= 1 else { lock.unlock(); return }
        busy = true
        lastScan = now
        lock.unlock()
        queue.async { [self] in
            let fingerprint = FrameFingerprint.digest(buffer)
            if let fingerprint, fingerprint == lastFingerprint {
                lock.lock(); busy = false; lock.unlock()
                return
            }
            let result: Result<[UUID: [CGRect]], Error> = Result {
                try autoreleasepool {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = false
                    request.recognitionLanguages = ["en-US"]
                    try VNImageRequestHandler(cvPixelBuffer: buffer, options: [:]).perform([request])
                    return Self.regions(in: request.results ?? [], configurations: configurations)
                }
            }
            if case .success = result { lastFingerprint = fingerprint }
            lock.lock()
            busy = false
            let shouldDeliver = !cancelled
            lock.unlock()
            if shouldDeliver { Task { @MainActor [completion] in completion(result) } }
        }
    }

    static func regions(in observations: [VNRecognizedTextObservation], options: SensitiveTextOptions, phrases: [String] = []) -> [CGRect] {
        observations.flatMap { observation -> [CGRect] in
            guard let candidate = observation.topCandidates(1).first else { return [] }
            return SensitiveText.ranges(in: candidate.string, options: options, phrases: phrases).compactMap { match in
                guard let range = Range(match, in: candidate.string) else { return nil }
                let box = (try? candidate.boundingBox(for: range))?.boundingBox ?? observation.boundingBox
                return box.insetBy(dx: -0.003, dy: -0.004).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            }
        }
    }

    static func regions(in observations: [VNRecognizedTextObservation], rules: [ProtectionRule]) -> [UUID: [CGRect]] {
        regions(in: observations, configurations: configurations(for: rules))
    }

    private static func regions(in observations: [VNRecognizedTextObservation], configurations: [Configuration]) -> [UUID: [CGRect]] {
        Dictionary(uniqueKeysWithValues: configurations.map {
            ($0.id, regions(in: observations, options: $0.options, phrases: $0.phrases))
        })
    }
}
