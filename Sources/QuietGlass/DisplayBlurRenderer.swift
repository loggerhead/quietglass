//  Created by Clinton Imaro on 20/09/2026.

import CoreImage

final class DisplayBlurRenderer {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var previous: CGImage?

    func render(_ input: CIImage, radius: Double) -> CGImage? {
        guard !input.extent.isEmpty, !input.extent.isInfinite, !input.extent.isNull else { return previous }
        let blurred = radius > 0 ? input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: input.extent) : input
        let background: CIImage
        if let previous, previous.width == Int(input.extent.width), previous.height == Int(input.extent.height) {
            background = CIImage(cgImage: previous)
        } else {
            background = CIImage(color: CIColor(red: 0.08, green: 0.08, blue: 0.08)).cropped(to: input.extent)
        }
        let output = blurred.composited(over: background).cropped(to: input.extent)
        guard let image = context.createCGImage(output, from: input.extent) else { return previous }
        previous = image
        return image
    }
    /// Keep Gaussian blur on the original input, then let Core Image evaluate
    /// only each protected crop. Ordered crops share one output surface/context.
    /// Later compositing of earlier rules preserves overlap priority.
    func renderRegions(_ input: CIImage, regions: [ScreenBlurRegion]) -> CGImage? {
        let extent = input.extent
        guard !extent.isEmpty, !extent.isInfinite, !extent.isNull else { return previous }
        var blurred: [Double: CIImage] = [:]
        var output = CIImage(color: CIColor(red: 0.08, green: 0.08, blue: 0.08)).cropped(to: extent)
        for region in regions.reversed() {
            let normalized = region.rectangle
            let rectangle = CGRect(x: extent.minX + normalized.minX * extent.width,
                                   y: extent.minY + normalized.minY * extent.height,
                                   width: normalized.width * extent.width, height: normalized.height * extent.height).intersection(extent)
            guard !rectangle.isNull, !rectangle.isEmpty else { continue }
            let source = blurred[region.radius] ?? input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: region.radius])
            blurred[region.radius] = source
            output = source.cropped(to: rectangle).composited(over: output)
        }
        guard let image = context.createCGImage(output, from: extent) else { return previous }
        previous = image
        return image
    }

}
