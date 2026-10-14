import CoreGraphics

/// Media geometry, in canvas coordinates relative to the shell's top-center
/// (x = 0 is the notch's center line). Shared elements — the artwork and the
/// visualizer — interpolate between their wing and open placements, so both
/// placements are defined here, side by side.
enum MediaLayout {
    static let wingWidth: CGFloat = 44
    static let openWidth: CGFloat = 432
    static let inset: CGFloat = 16
    static let openArtSize: CGFloat = 100
    static let columnGap: CGFloat = 14
    static let bottomPadding: CGFloat = 18
    static let visualizerSize = CGSize(width: 20, height: 14)
    static let closedArtCornerRadius: CGFloat = 6
    static let openArtCornerRadius: CGFloat = 16

    static func openHeight(_ notch: CGSize) -> CGFloat {
        notch.height + 4 + openArtSize + bottomPadding
    }

    static func closedArtFrame(_ notch: CGSize) -> CGRect {
        let side = notch.height - 16
        let centerX = -notch.width / 2 - wingWidth / 2
        return CGRect(x: centerX - side / 2, y: (notch.height - side) / 2, width: side, height: side)
    }

    static func openArtFrame(_ notch: CGSize) -> CGRect {
        CGRect(x: -openWidth / 2 + inset, y: notch.height + 4, width: openArtSize, height: openArtSize)
    }

    static func closedVisualizerCenter(_ notch: CGSize) -> CGPoint {
        CGPoint(x: notch.width / 2 + wingWidth / 2, y: notch.height / 2)
    }

    static func openVisualizerCenter(_ notch: CGSize) -> CGPoint {
        CGPoint(x: openWidth / 2 - inset - visualizerSize.width / 2, y: notch.height / 2)
    }

    /// The text/scrubber/controls column beside the open artwork.
    static func columnFrame(_ notch: CGSize) -> CGRect {
        let art = openArtFrame(notch)
        let minX = art.maxX + columnGap
        return CGRect(x: minX, y: art.minY, width: openWidth / 2 - inset - minX, height: art.height)
    }
}

/// Destination pills under the closed notch, and the page-switcher segments
/// they hand off to when the notch opens. Same coordinate space as `MediaLayout`.
enum PillLayout {
    static let height: CGFloat = 26
    static let gap: CGFloat = 6
    static let topGap: CGFloat = 9
    static let segmentHeight: CGFloat = 22
    private static let switcherMinX = -MediaLayout.openWidth / 2 + MediaLayout.inset - 2

    static func width(iconOnly: Bool) -> CGFloat { iconOnly ? 36 : 80 }

    static func frames(count: Int, below height: CGFloat, iconOnly: Bool) -> [CGRect] {
        let width = width(iconOnly: iconOnly)
        let total = CGFloat(count) * width + CGFloat(max(count - 1, 0)) * gap
        return (0..<count).map { index in
            CGRect(x: -total / 2 + CGFloat(index) * (width + gap), y: height + topGap,
                   width: width, height: Self.height)
        }
    }

    /// Pages left of the camera. The rest continue on its right, where they'd
    /// otherwise have run under the camera housing.
    static let maxLeading = 4

    static func spillsPastCamera(count: Int) -> Bool { count > maxLeading }

    /// The left group has to fit between the header's leading inset and the
    /// camera housing, so segments narrow as pages are added, up to four.
    static func segmentWidth(count: Int, notch: CGSize) -> CGFloat {
        let available = -notch.width / 2 - 8 - (switcherMinX + 2) - 2
        return min(34, max(20, (available / CGFloat(max(min(count, maxLeading), 1))).rounded(.down)))
    }

    /// Matches `PageSwitcher`'s placement in the open header. Past the fourth,
    /// segments start as far right of the camera as the left group ends left of it.
    static func segmentFrame(index: Int, count: Int, notch: CGSize) -> CGRect {
        let width = segmentWidth(count: count, notch: notch)
        let x = index < maxLeading
            ? switcherMinX + 2 + CGFloat(index) * width
            : notch.width / 2 + 8 + 2 + CGFloat(index - maxLeading) * width
        return CGRect(x: x, y: (notch.height - segmentHeight) / 2, width: width, height: segmentHeight)
    }

    /// The capsules behind the segments: one each side of the camera.
    static func groupFrames(count: Int, notch: CGSize) -> [CGRect] {
        let frames = (0..<count).map { segmentFrame(index: $0, count: count, notch: notch) }
        return [Array(frames.prefix(maxLeading)), Array(frames.dropFirst(maxLeading))]
            .filter { !$0.isEmpty }
            .map { $0.dropFirst().reduce($0[0]) { $0.union($1) }.insetBy(dx: -2, dy: -2) }
    }
}

extension CGFloat {
    func lerp(to other: CGFloat, _ t: CGFloat) -> CGFloat { self + (other - self) * t }
}

extension CGRect {
    func lerp(to other: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: minX.lerp(to: other.minX, t), y: minY.lerp(to: other.minY, t),
               width: width.lerp(to: other.width, t), height: height.lerp(to: other.height, t))
    }
}

extension CGPoint {
    func lerp(to other: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: x.lerp(to: other.x, t), y: y.lerp(to: other.y, t))
    }
}
