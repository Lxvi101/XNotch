import AppKit

/// XNotch's icon: the menu bar and notch as one silver mark, with two
/// cut-out lights, centred on a black tile. build_app.sh renders `drawn`
/// into the bundle's AppIcon.icns, and make_icon.swift renders the
/// full-bleed variant for the iOS companion. Builds without an icon file
/// use the drawing directly, so the permission guide and System Settings
/// still show something recognisable.
@MainActor
enum AppIcon {
    /// Read from Info.plist rather than the bundle on disk, which may sit in
    /// a protected folder during development.
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "XNotch"

    static let image: NSImage = {
        let info = Bundle.main.infoDictionary ?? [:]
        if info["CFBundleIconFile"] != nil || info["CFBundleIconName"] != nil {
            return NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        }
        return drawn
    }()

    /// The macOS icon: the mark on a squircle tile with its drop shadow.
    static let drawn = image(tile: true)

    /// `tile: true` draws the macOS squircle on a transparent canvas;
    /// `false` fills the whole square, for platforms that mask it themselves.
    static func image(tile: Bool, size: CGFloat = 512) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { bounds in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            paint(cg, side: bounds.width, tile: tile)
            return true
        }
    }

    // MARK: - Drawing (in a 1024-unit design space, y down)

    private static func paint(_ cg: CGContext, side: CGFloat, tile: Bool) {
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.scaleBy(x: side / 1024, y: side / 1024)
        if !tile {
            // Map the 824-unit tile onto the full canvas.
            cg.scaleBy(x: 1024 / 824, y: 1024 / 824)
            cg.translateBy(x: -100, y: -100)
        }
        // Shadow offsets and blurs are in device pixels, not user space.
        let device = hypot(cg.userSpaceToDeviceSpaceTransform.a, cg.userSpaceToDeviceSpaceTransform.b)
        let tilePath = squircle(CGRect(x: 100, y: 100, width: 824, height: 824))

        if tile {
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: -10 * device), blur: 28 * device,
                         color: CGColor(gray: 0, alpha: 0.32))
            cg.addPath(tilePath)
            cg.setFillColor(CGColor(gray: 0, alpha: 1))
            cg.fillPath()
            cg.restoreGState()
            cg.saveGState()
            cg.addPath(tilePath)
            cg.clip()
        } else {
            cg.saveGState()
        }

        // Black, a touch lighter at the top, with a soft overhead light.
        linear(cg, [(0, rgb(0x1E1E21)), (1, rgb(0x060607))], from: 100, to: 924)
        cg.saveGState()
        cg.translateBy(x: 512, y: 300)
        cg.scaleBy(x: 1, y: 300 / 460)
        let light = gradient([(0, CGColor(gray: 1, alpha: 0.07)), (1, CGColor(gray: 1, alpha: 0))])
        cg.drawRadialGradient(light, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 460, options: [])
        cg.restoreGState()

        // The mark, in brushed silver, floating on a shadow.
        let mark = markPath()
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -18 * device), blur: 44 * device,
                     color: CGColor(gray: 0, alpha: 0.6))
        cg.addPath(mark)
        cg.setFillColor(rgb(0xD8DADF))
        cg.fillPath()
        cg.restoreGState()
        cg.saveGState()
        cg.addPath(mark)
        cg.clip()
        linear(cg, [(0, rgb(0xFFFFFF)), (0.55, rgb(0xC4C6CC)), (1, rgb(0xECEDF0))], from: 380, to: 646)
        cg.restoreGState()

        // The two lights, cut out of the notch.
        cg.setFillColor(rgb(0x0B0B0D))
        for x in [448.0, 576.0] {
            cg.addPath(CGPath(roundedRect: CGRect(x: x - 20, y: 510, width: 40, height: 92),
                              cornerWidth: 20, cornerHeight: 20, transform: nil))
        }
        cg.fillPath()
        cg.restoreGState()

        if tile {
            // Hairline rim: brighter along the top edge.
            cg.saveGState()
            cg.addPath(tilePath)
            cg.setLineWidth(3)
            cg.replacePathWithStrokedPath()
            cg.clip()
            linear(cg, [(0, CGColor(gray: 1, alpha: 0.38)), (0.25, CGColor(gray: 1, alpha: 0.06)),
                        (1, CGColor(gray: 1, alpha: 0.12))], from: 100, to: 924)
            cg.restoreGState()
        }
    }

    /// A 640-wide menu bar with a 360 x 210 notch hanging from it.
    private static func markPath() -> CGPath {
        let p = CGMutablePath()
        let top: CGFloat = 380, bar: CGFloat = 436, bottom: CGFloat = 646
        let left: CGFloat = 192, right: CGFloat = 832, notchL: CGFloat = 332, notchR: CGFloat = 692
        p.move(to: CGPoint(x: 512, y: top))
        p.addArc(tangent1End: CGPoint(x: right, y: top), tangent2End: CGPoint(x: right, y: bar), radius: 28)
        p.addArc(tangent1End: CGPoint(x: right, y: bar), tangent2End: CGPoint(x: notchR, y: bar), radius: 28)
        p.addArc(tangent1End: CGPoint(x: notchR, y: bar), tangent2End: CGPoint(x: notchR, y: bottom), radius: 34)
        p.addArc(tangent1End: CGPoint(x: notchR, y: bottom), tangent2End: CGPoint(x: notchL, y: bottom), radius: 88)
        p.addArc(tangent1End: CGPoint(x: notchL, y: bottom), tangent2End: CGPoint(x: notchL, y: bar), radius: 88)
        p.addArc(tangent1End: CGPoint(x: notchL, y: bar), tangent2End: CGPoint(x: left, y: bar), radius: 34)
        p.addArc(tangent1End: CGPoint(x: left, y: bar), tangent2End: CGPoint(x: left, y: top), radius: 28)
        p.addArc(tangent1End: CGPoint(x: left, y: top), tangent2End: CGPoint(x: right, y: top), radius: 28)
        p.closeSubpath()
        return p
    }

    /// The macOS icon shape: a superellipse (n = 5), close to Apple's
    /// continuous-corner tile.
    private static func squircle(_ r: CGRect) -> CGPath {
        let p = CGMutablePath()
        let a = r.width / 2, steps = 240
        for i in 0..<steps {
            let t = 2 * Double.pi * Double(i) / Double(steps)
            let c = cos(t), s = sin(t)
            let point = CGPoint(x: r.midX + a * copysign(pow(abs(c), 0.4), c),
                                y: r.midY + a * copysign(pow(abs(s), 0.4), s))
            i == 0 ? p.move(to: point) : p.addLine(to: point)
        }
        p.closeSubpath()
        return p
    }

    private static func rgb(_ hex: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private static func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map(\.1) as CFArray,
                   locations: stops.map(\.0))!
    }

    private static func linear(_ cg: CGContext, _ stops: [(CGFloat, CGColor)], from y0: CGFloat, to y1: CGFloat) {
        cg.drawLinearGradient(gradient(stops), start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1),
                              options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
}
