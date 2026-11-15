// Render AppIcon.drawn into an .iconset; build_app.sh turns it into AppIcon.icns.
// usage: swiftc -parse-as-library scripts/make_icon.swift XNotch/UI/DesignSystem/AppIcon.swift -o make_icon
//        ./make_icon <dir.iconset>          macOS iconset
//        ./make_icon --ios <file.png> <px>  opaque, full-bleed square (iOS masks it itself)
import AppKit

@main
struct MakeIcon {
    @MainActor
    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 4, args[1] == "--ios", let pixels = Int(args[3]) {
            try opaquePNG(AppIcon.image(tile: false, size: CGFloat(pixels)), pixels: pixels)
                .write(to: URL(fileURLWithPath: args[2]))
            return
        }
        let output = URL(fileURLWithPath: args[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = points * scale
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                AppIcon.drawn.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
                NSGraphicsContext.restoreGraphicsState()
                let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
                try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
            }
        }
    }

    /// App Store icons must not carry an alpha channel.
    @MainActor
    static func opaquePNG(_ image: NSImage, pixels: Int) throws -> Data {
        let cg = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return NSBitmapImageRep(cgImage: cg.makeImage()!).representation(using: .png, properties: [:])!
    }
}
