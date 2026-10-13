import AppKit
import SwiftUI

/// Shell geometry: `width` is the straight body; the top flares extend
/// `topCornerRadius` past it on each side.
struct NotchShellGeometry: VectorArithmetic {
    var width: CGFloat
    var height: CGFloat
    var topCornerRadius: CGFloat
    var bottomRadius: CGFloat

    var outerWidth: CGFloat { width + 2 * topCornerRadius }

    static let zero = NotchShellGeometry(width: 0, height: 0, topCornerRadius: 0, bottomRadius: 0)

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            width: lhs.width + rhs.width,
            height: lhs.height + rhs.height,
            topCornerRadius: lhs.topCornerRadius + rhs.topCornerRadius,
            bottomRadius: lhs.bottomRadius + rhs.bottomRadius
        )
    }

    static func - (lhs: Self, rhs: Self) -> Self {
        Self(
            width: lhs.width - rhs.width,
            height: lhs.height - rhs.height,
            topCornerRadius: lhs.topCornerRadius - rhs.topCornerRadius,
            bottomRadius: lhs.bottomRadius - rhs.bottomRadius
        )
    }

    mutating func scale(by rhs: Double) {
        width *= rhs
        height *= rhs
        topCornerRadius *= rhs
        bottomRadius *= rhs
    }

    var magnitudeSquared: Double {
        Double(width * width + height * height + topCornerRadius * topCornerRadius + bottomRadius * bottomRadius)
    }
}

/// Additive, transient deformation on top of the resting geometry: pointer
/// attraction, press squash and drop impact.
struct NotchDeformation: VectorArithmetic {
    var width: CGFloat = 0
    var height: CGFloat = 0
    var offsetX: CGFloat = 0
    var shadow: CGFloat = 0

    static let zero = NotchDeformation()

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(width: lhs.width + rhs.width, height: lhs.height + rhs.height,
             offsetX: lhs.offsetX + rhs.offsetX, shadow: lhs.shadow + rhs.shadow)
    }

    static func - (lhs: Self, rhs: Self) -> Self {
        Self(width: lhs.width - rhs.width, height: lhs.height - rhs.height,
             offsetX: lhs.offsetX - rhs.offsetX, shadow: lhs.shadow - rhs.shadow)
    }

    mutating func scale(by rhs: Double) {
        width *= rhs
        height *= rhs
        offsetX *= rhs
        shadow *= rhs
    }

    var magnitudeSquared: Double {
        Double(width * width + height * height + offsetX * offsetX + shadow * shadow)
    }

    func isClose(to other: Self) -> Bool {
        abs(width - other.width) < 0.2 && abs(height - other.height) < 0.2
            && abs(offsetX - other.offsetX) < 0.2 && abs(shadow - other.shadow) < 0.01
    }
}

enum NotchMetrics {
    static let fallbackNotchSize = CGSize(width: 200, height: 32)

    static let closedTopCornerRadius: CGFloat = 8
    static let closedBottomRadius: CGFloat = 14
    static let wingWidth: CGFloat = 58

    static let dropZoneSize = CGSize(width: 372, height: 126)
    static let dropZoneTopCornerRadius: CGFloat = 16
    static let dropZoneBottomRadius: CGFloat = 30

    static let shelfSize = CGSize(width: 432, height: 140)
    static let shelfTopCornerRadius: CGFloat = 22
    static let shelfBottomRadius: CGFloat = 34

    static let autoCollapseDelay: TimeInterval = 0.8
    static let wingsToastDuration: TimeInterval = 2.6

    /// Transparent canvas the shell draws into: room for the largest surface,
    /// its flares, deformation and shadow.
    static let canvasSize = CGSize(width: 640, height: 260)

    static func physicalNotchSize(on screen: NSScreen) -> CGSize {
        let top = screen.safeAreaInsets.top
        guard top > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else {
            return fallbackNotchSize
        }
        return CGSize(width: screen.frame.width - left.width - right.width, height: top)
    }

    static func closed(_ notch: CGSize) -> NotchShellGeometry {
        NotchShellGeometry(width: notch.width, height: notch.height,
                           topCornerRadius: closedTopCornerRadius, bottomRadius: closedBottomRadius)
    }

    static func wings(_ notch: CGSize) -> NotchShellGeometry {
        NotchShellGeometry(width: notch.width + 2 * wingWidth, height: notch.height,
                           topCornerRadius: closedTopCornerRadius, bottomRadius: closedBottomRadius)
    }

    static func mediaWings(_ notch: CGSize) -> NotchShellGeometry {
        NotchShellGeometry(width: notch.width + 2 * MediaLayout.wingWidth, height: notch.height,
                           topCornerRadius: closedTopCornerRadius, bottomRadius: closedBottomRadius)
    }

    static func media(_ notch: CGSize) -> NotchShellGeometry {
        NotchShellGeometry(width: MediaLayout.openWidth, height: MediaLayout.openHeight(notch),
                           topCornerRadius: shelfTopCornerRadius, bottomRadius: shelfBottomRadius)
    }

    static let dropZone = NotchShellGeometry(
        width: dropZoneSize.width, height: dropZoneSize.height,
        topCornerRadius: dropZoneTopCornerRadius, bottomRadius: dropZoneBottomRadius
    )

    static let shelf = NotchShellGeometry(
        width: shelfSize.width, height: shelfSize.height,
        topCornerRadius: shelfTopCornerRadius, bottomRadius: shelfBottomRadius
    )

    /// Space below an extension page's content, matching the shelf.
    static let pageBottomPadding: CGFloat = 10

    static func extensionPage(contentHeight: CGFloat, notch: CGSize) -> NotchShellGeometry {
        NotchShellGeometry(width: shelfSize.width, height: notch.height + contentHeight + pageBottomPadding,
                           topCornerRadius: shelfTopCornerRadius, bottomRadius: shelfBottomRadius)
    }
}
