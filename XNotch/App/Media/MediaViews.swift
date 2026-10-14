import AppKit
import XNotchKit
import SwiftUI

/// Artwork and visualizer as single persistent elements: they travel between
/// their wing placement and their open placement instead of crossfading
/// between two copies. Interpolated every frame from the model's values.
struct MediaSharedElements: View, Animatable {
    var placement: CGFloat
    var wingsReveal: CGFloat
    var openReveal: CGFloat
    var hover: CGFloat
    let notchSize: CGSize
    let artwork: NSImage?
    let artworkGlow: NSImage?
    let accent: Color
    let isPlaying: Bool
    let onArtworkTap: () -> Void

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(placement, wingsReveal), AnimatablePair(openReveal, hover)) }
        set {
            placement = newValue.first.first
            wingsReveal = newValue.first.second
            openReveal = newValue.second.first
            hover = newValue.second.second
        }
    }

    var body: some View {
        let p = placement.clamped()
        let art = MediaLayout.closedArtFrame(notchSize).lerp(to: MediaLayout.openArtFrame(notchSize), p)
        let radius = MediaLayout.closedArtCornerRadius.lerp(to: MediaLayout.openArtCornerRadius, p)
        let visualizer = MediaLayout.closedVisualizerCenter(notchSize).lerp(to: MediaLayout.openVisualizerCenter(notchSize), p)
        let closedVisualizer = MediaLayout.closedVisualizerCenter(notchSize)
        let visible = (wingsReveal + openReveal).clamped()
        let glyph = (wingsReveal * hover).clamped()

        ZStack(alignment: .topLeading) {
            if visible > 0.001 {
                elements(art: art, radius: radius, visualizer: visualizer, closedVisualizer: closedVisualizer,
                         visible: visible, glyph: glyph)
            }
        }
        .frame(width: NotchMetrics.canvasSize.width, height: NotchMetrics.canvasSize.height, alignment: .topLeading)
    }

    @ViewBuilder
    private func elements(art: CGRect, radius: CGFloat, visualizer: CGPoint, closedVisualizer: CGPoint,
                          visible: CGFloat, glyph: CGFloat) -> some View {
        let mid = NotchMetrics.canvasSize.width / 2
        ArtworkView(image: artwork, cornerRadius: radius)
                .frame(width: art.width, height: art.height)
                .background {
                    // Blurred once when the artwork arrives; a live blur here
                    // would re-render on every frame of the visualizer.
                    if let artworkGlow, openReveal > 0.001 {
                        Image(nsImage: artworkGlow)
                            .resizable()
                            .scaleEffect(ArtworkGlow.canvasScale)
                            .opacity(0.45 * Double(openReveal.clamped()))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onArtworkTap)
                .allowsHitTesting(openReveal > 0.5)
                .opacity(Double(visible.smoothstep))
                .blur(radius: visible.revealBlur(8))
                .position(x: mid + art.midX, y: art.midY)

            VisualizerBars(energy: isPlaying ? 1 : 0, color: accent)
                .animation(Motion.content, value: isPlaying)
                .environment(\.isNotchSurfaceVisible, visible * (1 - glyph) > 0.001)
                .opacity(Double((visible * (1 - glyph)).smoothstep))
                .blur(radius: (visible * (1 - glyph)).revealBlur(6))
                .position(x: mid + visualizer.x, y: visualizer.y)

            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 13, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(.white)
                .opacity(Double(glyph.smoothstep))
                .blur(radius: glyph.revealBlur(6))
                .scaleEffect(0.8 + 0.2 * glyph)
                .position(x: mid + closedVisualizer.x, y: closedVisualizer.y)
                .allowsHitTesting(false)
    }
}

/// The open media page's text column: title, artist, scrubber, transport.
struct MediaPlayerPage: View {
    /// Passed by value: the first track can arrive before this view would
    /// have subscribed to the service, and identical inputs never re-render it.
    let track: NowPlayingTrack
    let media: NowPlayingService
    let notchSize: CGSize

    var body: some View {
        let column = MediaLayout.columnFrame(notchSize)
        let pageWidth = MediaLayout.openWidth + 2 * NotchMetrics.shelfTopCornerRadius

        VStack(alignment: .leading, spacing: 0) {
            MarqueeText(text: track.title.isEmpty ? Self.appName(for: track.bundleIdentifier) : track.title,
                        font: .system(size: 15, weight: .semibold), color: .white)
            MarqueeText(text: track.artist, font: .system(size: 12.5, weight: .medium), color: .white.opacity(0.55))
                .padding(.top, 1)
            Spacer(minLength: 0)
            PlaybackScrubber(track: track, onSeek: media.seek)
            HStack(spacing: 18) {
                TransportButton(symbol: "backward.fill", size: 15, action: media.previousTrack)
                TransportButton(symbol: track.isPlaying ? "pause.fill" : "play.fill", size: 21, action: media.togglePlayPause)
                TransportButton(symbol: "forward.fill", size: 15, action: media.nextTrack)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: column.width, height: column.height, alignment: .topLeading)
        .offset(x: pageWidth / 2 + column.minX, y: column.minY)
        .frame(width: pageWidth, height: MediaLayout.openHeight(notchSize), alignment: .topLeading)
    }

    private static func appName(for bundleIdentifier: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return "Not Playing" }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// Segmented switcher beside the camera: up to four pages left of it, the
/// rest on its right. The indicator's edges ride separate springs — the
/// leading edge in the direction of travel is faster — so it stretches
/// toward the target and contracts as it arrives, passing behind the camera
/// on its way from one side to the other. Laid out across the whole header.
///
/// Drag a segment to rearrange the pages: it lifts and follows the pointer
/// one to one, the others make way, and it settles where it's let go.
struct PageSwitcher: View {
    let pages: [PageInfo]
    let page: OpenPage
    let notchSize: CGSize
    let onSelect: (OpenPage) -> Void
    let onMove: (OpenPage, Int) -> Void

    private struct Drag: Equatable {
        var page: OpenPage
        /// The pointer, in header coordinates.
        var x: CGFloat
        /// Where in the segment it was picked up.
        var grab: CGFloat
    }

    @State private var leading: CGFloat = 0
    @State private var trailing: CGFloat = 0
    @State private var drag: Drag?

    static var headerWidth: CGFloat { MediaLayout.openWidth + 2 * NotchMetrics.shelfTopCornerRadius }
    private static let space = "pageSwitcher"

    /// A segment in header coordinates (PillLayout's are from the notch's centre).
    private func frame(of index: Int) -> CGRect {
        PillLayout.segmentFrame(index: index, count: pages.count, notch: notchSize).offsetBy(dx: Self.headerWidth / 2, dy: 0)
    }

    /// The pages as they'd land if the dragged one were let go now.
    private var arranged: [PageInfo] {
        guard let drag, let from = pages.firstIndex(where: { $0.page == drag.page }) else { return pages }
        var result = pages
        let moved = result.remove(at: from)
        result.insert(moved, at: slot(for: draggedFrame(drag).midX))
        return result
    }

    /// The nearest segment to a point, across both sides of the camera.
    private func slot(for x: CGFloat) -> Int {
        (0..<pages.count).min { abs(frame(of: $0).midX - x) < abs(frame(of: $1).midX - x) } ?? 0
    }

    /// The dragged segment under the pointer, kept within the switcher.
    private func draggedFrame(_ drag: Drag) -> CGRect {
        let base = frame(of: 0)
        let lowest = base.minX
        let highest = frame(of: pages.count - 1).minX
        return CGRect(x: min(highest, max(lowest, drag.x - drag.grab)), y: base.minY, width: base.width, height: base.height)
    }

    var body: some View {
        let arranged = arranged
        ZStack(alignment: .topLeading) {
            groups
            if drag?.page != page { indicator }
            segments(arranged)
        }
        .frame(width: Self.headerWidth, height: notchSize.height, alignment: .topLeading)
        .coordinateSpace(name: Self.space)
        .onAppear { setEdges(for: page, from: nil) }
        .onChange(of: page) { old, new in setEdges(for: new, from: old) }
        .onChange(of: arranged.map(\.page)) { _, _ in
            if drag != nil { Haptics.tap() }
            withAnimation(Motion.content) { setEdges(for: page, from: nil) }
        }
    }

    private var groups: some View {
        ForEach(PillLayout.groupFrames(count: pages.count, notch: notchSize), id: \.minX) { group in
            Capsule()
                .fill(.white.opacity(0.06))
                .frame(width: group.width, height: group.height)
                .offset(x: group.minX + Self.headerWidth / 2, y: group.minY)
        }
    }

    /// Hidden while its page is the one being dragged, which lights itself.
    private var indicator: some View {
        let height = PillLayout.segmentHeight
        return Capsule()
            .fill(.white.opacity(0.15))
            .frame(width: max(height, trailing - leading), height: height)
            .offset(x: leading, y: (notchSize.height - height) / 2)
    }

    private func segments(_ arranged: [PageInfo]) -> some View {
        let order = arranged.map(\.page)
        return ForEach(Array(arranged.enumerated()), id: \.element.id) { index, info in
            let isDragged = drag?.page == info.page
            let frame: CGRect = if isDragged, let drag { draggedFrame(drag) } else { frame(of: index) }
            segmentButton(info, isDragged: isDragged)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .zIndex(isDragged ? 1 : 0)
                // The dragged one sits under the pointer; only the others make way.
                .animation(isDragged ? nil : Motion.content, value: order)
        }
    }

    private func segmentButton(_ info: PageInfo, isDragged: Bool) -> some View {
        Button { onSelect(info.page) } label: {
            Image(systemName: info.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(page == info.page || isDragged ? 1 : 0.45))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    Capsule()
                        .fill(.white.opacity(isDragged ? (page == info.page ? 0.24 : 0.16) : 0))
                        .shadow(color: .black.opacity(isDragged ? 0.5 : 0), radius: 6, y: 2)
                }
                .overlay(alignment: .topTrailing) {
                    if info.badge > 0 {
                        Text("\(info.badge)")
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 3.5)
                            .frame(minWidth: 13, minHeight: 13)
                            .background(Capsule().fill(Color(red: 0.36, green: 0.9, blue: 0.56)))
                            .contentTransition(.numericText())
                            .offset(x: 2, y: -3)
                    }
                }
                .scaleEffect(isDragged ? 1.18 : 1)
                .animation(Motion.press, value: isDragged)
                .contentShape(Rectangle())
                .animation(Motion.content, value: page)
        }
        .buttonStyle(PressScaleStyle())
        // Takes over only once the pointer has moved, so a click still switches pages.
        .highPriorityGesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
                .onChanged { value in
                    if drag?.page != info.page {
                        let start = frame(of: pages.firstIndex { $0.page == info.page } ?? 0)
                        drag = Drag(page: info.page, x: value.location.x, grab: value.startLocation.x - start.minX)
                        Haptics.tap()
                    } else {
                        drag?.x = value.location.x
                    }
                }
                .onEnded { _ in
                    guard let dropped = drag else { return }
                    let index = arranged.firstIndex { $0.page == dropped.page } ?? 0
                    withAnimation(Motion.content) {
                        drag = nil
                        onMove(dropped.page, index)
                    }
                }
        )
    }

    private func index(of target: OpenPage) -> Int {
        arranged.firstIndex { $0.page == target } ?? 0
    }

    private func setEdges(for target: OpenPage, from old: OpenPage?) {
        let segment = frame(of: index(of: target))
        let minX = segment.minX
        let maxX = segment.maxX
        guard let old, old != target else {
            leading = minX
            trailing = maxX
            return
        }
        let fast = Animation.spring(response: 0.22, dampingFraction: 0.9)
        let slow = Animation.spring(response: 0.44, dampingFraction: 0.84)
        let movingRight = index(of: target) > index(of: old)
        withAnimation(movingRight ? fast : slow) { trailing = maxX }
        withAnimation(movingRight ? slow : fast) { leading = minX }
    }
}
