//  Created by Clinton Imaro on 20/09/2026.

import Vision
import CoreVideo
import CoreImage
import ShieldCore
import CryptoKit

final class LocalTextAnalyzer {
    private let queue = DispatchQueue(label: "local.clinton.QuietGlass.text", qos: .utility)
    private let lock = NSLock()
    private var busy = false
    private var lastScan: TimeInterval = 0
    private var cancelled = false
    private var lastFingerprint: SHA256.Digest?
    private let context = CIContext(options: [.cacheIntermediates: false])
    /// Text recognition stays accurate well below native 5K resolution. Capping
    /// the longest side keeps OCR and fingerprint work bounded on large displays.
    private static let maxAnalysisDimension = 2048
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
            // OCR and the cache fingerprint share one downsampled image, so a
            // cached scan is only reused when OCR would see identical pixels.
            let analysis = downsampled(buffer) ?? buffer
            let fingerprint = FrameFingerprint.digest(analysis)
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
                    try VNImageRequestHandler(cvPixelBuffer: analysis, options: [:]).perform([request])
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

    func downsampled(_ buffer: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let longest = max(width, height)
        guard width > 0, height > 0 else { return nil }
        guard longest > Self.maxAnalysisDimension else { return buffer }
        let scale = Double(Self.maxAnalysisDimension) / Double(longest)
        let targetWidth = max(1, Int((Double(width) * scale).rounded()))
        let targetHeight = max(1, Int((Double(height) * scale).rounded()))
        var output: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, targetWidth, targetHeight, kCVPixelFormatType_32BGRA, attributes, &output) == kCVReturnSuccess,
              let output else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
            .transformed(by: CGAffineTransform(scaleX: CGFloat(targetWidth) / CGFloat(width),
                                               y: CGFloat(targetHeight) / CGFloat(height)))
        context.render(image, to: output)
        return output
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
