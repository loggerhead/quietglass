//  Created by Clinton Imaro on 20/09/2026.

import CoreImage

final class DisplayBlurRenderer {
    /// A blur is low-frequency detail, so rendering it at half resolution and
    /// letting the overlay stretch the result looks the same while cutting the
    /// pixel work to a quarter. Radius scales with the image, so the perceived
    /// softness is unchanged.
    static let renderScale: CGFloat = 0.5

    // Every rendered frame is a new CIImage, so cached intermediates are never
    // reused across frames; keeping the cache off bounds memory in steady state.
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var previous: CGImage?

    /// `opaque` skips compositing over the previous frame. Screen capture frames
    /// are opaque BGRA, so the fallback only matters for synthetic/transparent
    /// inputs (and keeps the first frame opaque when there is no history).
    func render(_ input: CIImage, radius: Double, opaque: Bool = false) -> CGImage? {
        guard !input.extent.isEmpty, !input.extent.isInfinite, !input.extent.isNull else { return previous }
        let scaled = input.transformed(by: CGAffineTransform(scaleX: Self.renderScale, y: Self.renderScale))
        // Integral extents keep the `previous` size check exact for odd widths.
        let extent = scaled.extent.integral
        let radius = radius * Self.renderScale
        let blurred = radius > 0 ? scaled.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: extent) : scaled.cropped(to: extent)
        let output: CIImage
        if opaque {
            output = blurred
        } else {
            let background: CIImage
            if let previous, previous.width == Int(extent.width), previous.height == Int(extent.height) {
                background = CIImage(cgImage: previous)
            } else {
                background = CIImage(color: CIColor(red: 0.08, green: 0.08, blue: 0.08)).cropped(to: extent)
            }
            output = blurred.composited(over: background).cropped(to: extent)
        }
        guard let image = context.createCGImage(output, from: extent) else { return previous }
        previous = image
        return image
    }
    /// Keep Gaussian blur on the original input, then let Core Image evaluate
    /// only each protected crop. Ordered crops share one output surface/context.
    /// Later compositing of earlier rules preserves overlap priority. The
    /// scaled input, radii, and regions all use one half-resolution space.
    func renderRegions(_ input: CIImage, regions: [ScreenBlurRegion]) -> CGImage? {
        guard !input.extent.isEmpty, !input.extent.isInfinite, !input.extent.isNull else { return previous }
        let scaled = input.transformed(by: CGAffineTransform(scaleX: Self.renderScale, y: Self.renderScale))
        let extent = scaled.extent.integral
        var blurred: [Double: CIImage] = [:]
        var output = CIImage(color: CIColor(red: 0.08, green: 0.08, blue: 0.08)).cropped(to: extent)
        for region in regions.reversed() {
            let normalized = region.rectangle
            let rectangle = CGRect(x: extent.minX + normalized.minX * extent.width,
                                   y: extent.minY + normalized.minY * extent.height,
                                   width: normalized.width * extent.width, height: normalized.height * extent.height).intersection(extent)
            guard !rectangle.isNull, !rectangle.isEmpty else { continue }
            let radius = region.radius * Self.renderScale
            let source = blurred[radius] ?? scaled.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            blurred[radius] = source
            output = source.cropped(to: rectangle).composited(over: output)
        }
        guard let image = context.createCGImage(output, from: extent) else { return previous }
        previous = image
        return image
    }

}
