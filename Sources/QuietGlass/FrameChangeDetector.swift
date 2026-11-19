import Accelerate
import CoreVideo

/// Tunable gates for the frame-diff prefilter. The defaults target a 160x120
/// grayscale view of a 640x480 camera: sensor noise stays below the per-pixel
/// gate, a person entering changes well over 2% of the frame, and a partially
/// visible face at the edge still fills enough of one 16x16 block.
struct FrameChangeThresholds {
    var pixelDelta: UInt8 = 10
    var changedRatio: Double = 0.02
    var blockSize: Int = 16
    var blockRatio: Double = 0.25
}

/// A downscaled grayscale snapshot used only for change detection. Vision
/// still receives the full-resolution buffer; this never feeds recognition.
struct FrameThumbnail {
    static let width = 160
    static let height = 120
    let pixels: [UInt8]

    init?(buffer: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        var source = vImage_Buffer(data: base,
                                   height: vImagePixelCount(CVPixelBufferGetHeight(buffer)),
                                   width: vImagePixelCount(CVPixelBufferGetWidth(buffer)),
                                   rowBytes: CVPixelBufferGetBytesPerRow(buffer))
        // Scale first so the luma pass only touches the small image.
        var scaled = [UInt8](repeating: 0, count: Self.width * Self.height * 4)
        let scaleError = scaled.withUnsafeMutableBytes { raw -> vImage_Error in
            var destination = vImage_Buffer(data: raw.baseAddress,
                                            height: vImagePixelCount(Self.height),
                                            width: vImagePixelCount(Self.width),
                                            rowBytes: Self.width * 4)
            return vImageScale_ARGB8888(&source, &destination, nil, vImage_Flags(kvImageNoFlags))
        }
        guard scaleError == kvImageNoError else { return nil }
        var gray = [UInt8](repeating: 0, count: Self.width * Self.height)
        // BT.601 luma in BGRA memory order, divisor 256.
        var coefficients: [Int16] = [29, 150, 76, 0]
        let lumaError = scaled.withUnsafeMutableBytes { sourceRaw in
            gray.withUnsafeMutableBytes { destinationRaw -> vImage_Error in
                var source = vImage_Buffer(data: sourceRaw.baseAddress,
                                           height: vImagePixelCount(Self.height),
                                           width: vImagePixelCount(Self.width),
                                           rowBytes: Self.width * 4)
                var destination = vImage_Buffer(data: destinationRaw.baseAddress,
                                                height: vImagePixelCount(Self.height),
                                                width: vImagePixelCount(Self.width),
                                                rowBytes: Self.width)
                return vImageMatrixMultiply_ARGB8888ToPlanar8(&source, &destination, &coefficients, 256, nil, 0,
                                                              vImage_Flags(kvImageNoFlags))
            }
        }
        guard lumaError == kvImageNoError else { return nil }
        pixels = gray
    }
}

/// Pure comparison rules for the prefilter, split from pixel conversion so the
/// thresholds can be verified without a camera.
enum FrameChangeDecision {
    /// Even a static scene is fully rechecked at this interval so a very slow
    /// change can never hide from the prefilter.
    static let forcedScanInterval: TimeInterval = 0.5

    static func changed(previous: [UInt8], current: [UInt8],
                        thresholds: FrameChangeThresholds = FrameChangeThresholds()) -> Bool {
        guard previous.count == current.count, current.count == FrameThumbnail.width * FrameThumbnail.height else { return true }
        let width = FrameThumbnail.width, height = FrameThumbnail.height
        let block = thresholds.blockSize
        guard block > 0 else { return true }
        let blocksPerRow = (width + block - 1) / block
        let blockRows = (height + block - 1) / block
        var blockCounts = [Int](repeating: 0, count: blocksPerRow * blockRows)
        var changedCount = 0
        let delta = Int(thresholds.pixelDelta)
        for y in 0..<height {
            let row = y * width
            let blockRow = y / block
            for x in 0..<width {
                let index = row + x
                guard abs(Int(current[index]) - Int(previous[index])) > delta else { continue }
                changedCount += 1
                blockCounts[blockRow * blocksPerRow + x / block] += 1
            }
        }
        if Double(changedCount) / Double(current.count) >= thresholds.changedRatio { return true }
        // A small but high-contrast change (a face at the edge) may stay below
        // the global ratio; any mostly changed block still triggers a scan.
        for blockRow in 0..<blockRows {
            let rows = min(block, height - blockRow * block)
            for blockColumn in 0..<blocksPerRow {
                let columns = min(block, width - blockColumn * block)
                let area = rows * columns
                if Double(blockCounts[blockRow * blocksPerRow + blockColumn]) / Double(area) >= thresholds.blockRatio { return true }
            }
        }
        return false
    }
}
