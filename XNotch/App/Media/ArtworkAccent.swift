import AppKit
import CoreImage

/// The soft glow behind the open artwork, rendered once per artwork: the
/// image on a transparent canvas, blurred so it fades out past its edges.
enum ArtworkGlow {
    /// The glow image's size relative to the artwork it sits behind.
    static let canvasScale: CGFloat = 1.9
    /// Blur radius as a fraction of the artwork's side.
    private static let radiusFraction: CGFloat = 0.22
    private static let side = 64
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func image(of image: NSImage) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let canvas = Int((CGFloat(side) * canvasScale).rounded())
        let inset = CGFloat(canvas - side) / 2
        guard let bitmap = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        bitmap.interpolationQuality = .medium
        bitmap.draw(cgImage, in: CGRect(x: inset, y: inset, width: CGFloat(side), height: CGFloat(side)))
        guard let padded = bitmap.makeImage() else { return nil }

        let input = CIImage(cgImage: padded)
        let blurred = input.applyingGaussianBlur(sigma: Double(CGFloat(side) * radiusFraction))
            .cropped(to: input.extent)
        guard let output = context.createCGImage(blurred, from: input.extent) else { return nil }
        return NSImage(cgImage: output, size: NSSize(width: canvas, height: canvas))
    }
}

enum ArtworkAccent {
    /// A light, saturated tint representative of the artwork: colourful pixels
    /// outweigh greys and darks, and the result is lifted so it reads on black.
    static func color(of image: NSImage) -> NSColor {
        let side = 24
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return .white }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        var red = 0.0, green = 0.0, blue = 0.0, total = 0.0
        for index in 0..<(side * side) {
            let r = Double(pixels[index * 4]) / 255
            let g = Double(pixels[index * 4 + 1]) / 255
            let b = Double(pixels[index * 4 + 2]) / 255
            let maxValue = max(r, g, b), minValue = min(r, g, b)
            let saturation = maxValue > 0 ? (maxValue - minValue) / maxValue : 0
            let weight = saturation * saturation * maxValue + 0.002
            red += r * weight
            green += g * weight
            blue += b * weight
            total += weight
        }
        let average = NSColor(srgbRed: red / total, green: green / total, blue: blue / total, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        guard saturation > 0.08 else { return NSColor(white: 0.88, alpha: 1) }
        return NSColor(hue: hue, saturation: min(saturation, 0.7), brightness: max(brightness, 0.85), alpha: 1)
    }
}
