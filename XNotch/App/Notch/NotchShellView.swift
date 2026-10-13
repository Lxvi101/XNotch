import XNotchKit
import SwiftUI

/// Root of the notch canvas. Every surface is laid out at its own final size
/// and revealed through the live shell clip, so content is never re-laid-out
/// mid-morph; it only resolves from blur as its reveal progress reaches 1.
struct NotchShellView: View {
    static let canvasSpace = KitSpace.canvas

    @ObservedObject var model: NotchViewModel
    @ObservedObject var media: NowPlayingService
    @ObservedObject var extensions: ExtensionManager

    init(model: NotchViewModel) {
        self.model = model
        media = model.media
        extensions = model.extensions
    }

    var body: some View {
        let destinations = model.destinationInfos
        ZStack(alignment: .top) {
            shell(destinations: destinations)
            DestinationPills(reveal: model.pillsReveal, travel: model.pillsTravel,
                             destinations: destinations, highlighted: model.highlightedPill,
                             restingHeight: model.restingGeometry.height, notchSize: model.notchSize,
                             iconOnly: model.pillsIconOnly)
        }
        .frame(width: NotchMetrics.canvasSize.width, height: NotchMetrics.canvasSize.height, alignment: .top)
        .coordinateSpace(name: Self.canvasSpace)
        .onPreferenceChange(ShelfTileFramesKey.self) { frames in
            MainActor.assumeIsolated { model.tileFrames = frames }
        }
    }

    private func shell(destinations: [PageInfo]) -> some View {
        DeformingShell(deformation: model.deformation, geometry: model.geometry) {
            surfaces(destinations: destinations)
        }
    }

    private func surfaces(destinations: [PageInfo]) -> some View {
        ZStack(alignment: .top) {
            TrayWingsView(store: model.shelf, notchSize: model.notchSize)
                .reveal(model.trayWingsReveal, hiddenScale: 0.9, maxBlur: 6, travel: 0, unmountsWhenHidden: true)
                .allowsHitTesting(false)
            DropZoneView(hovered: model.hoveredDropTarget, notchSize: model.notchSize)
                .reveal(model.dropReveal, unmountsWhenHidden: true)
                .allowsHitTesting(false)
            ShelfView(store: model.shelf, notchSize: model.notchSize, showsTitle: destinations.count == 1,
                      onDragOut: model.setDraggingOut)
                .reveal(model.shelfReveal, unmountsWhenHidden: true)
                .allowsHitTesting(model.surface == .open && model.page == .shelf)
            MediaPlayerPage(track: media.track ?? NowPlayingTrack(), media: media, notchSize: model.notchSize)
                .reveal(model.mediaOpenReveal, unmountsWhenHidden: true)
                .allowsHitTesting(model.surface == .open && model.page == .media)
            ForEach(model.extensionPages) { ext in
                ExtensionPageContainer(ext: ext, notchSize: model.notchSize,
                                       isActive: model.surface == .open && model.page == ext.page,
                                       pointer: extensions.pointer)
                    .reveal(model.extensionReveal[ext.page.id] ?? 0, unmountsWhenHidden: true)
                    .allowsHitTesting(model.surface == .open && model.page == ext.page)
            }
            MediaSharedElements(placement: model.mediaPlacement, wingsReveal: model.mediaWingsReveal,
                                openReveal: model.mediaOpenReveal, hover: model.mediaHover,
                                notchSize: model.notchSize, artwork: media.artwork, artworkGlow: media.artworkGlow,
                                accent: media.accent, isPlaying: media.track?.isPlaying ?? false,
                                onArtworkTap: model.openMediaApp)
            if destinations.count > 1 {
                openHeader(destinations)
                    .reveal(model.openReveal, hiddenScale: 0.9, maxBlur: 6, travel: -4, unmountsWhenHidden: true)
                    .allowsHitTesting(model.surface == .open)
            }
        }
    }

    private func openHeader(_ destinations: [PageInfo]) -> some View {
        HStack {
            PageSwitcher(pages: destinations, page: model.page, notchSize: model.notchSize, onSelect: model.selectPage)
            Spacer()
        }
        .padding(.leading, NotchMetrics.shelfTopCornerRadius + MediaLayout.inset - 2)
        .frame(width: MediaLayout.openWidth + 2 * NotchMetrics.shelfTopCornerRadius, height: model.notchSize.height)
    }
}

/// Lays an extension's page out under the notch row, at the shelf's insets.
private struct ExtensionPageContainer: View {
    let ext: ExtensionPage
    let notchSize: CGSize
    let isActive: Bool
    let pointer: NotchPointer

    var body: some View {
        let size = CGSize(width: NotchPageContext.contentWidth, height: ext.descriptor.contentHeight)
        let geometry = NotchMetrics.extensionPage(contentHeight: size.height, notch: notchSize)
        VStack(spacing: 0) {
            Color.clear.frame(height: notchSize.height)
            ext.provider.makePageView(for: ext.descriptor, context: NotchPageContext(size: size, isActive: isActive))
                .frame(width: size.width, height: size.height)
                .clipped()
        }
        .padding(.bottom, NotchMetrics.pageBottomPadding)
        .frame(width: geometry.outerWidth, height: geometry.height, alignment: .top)
        .environmentObject(pointer)
    }
}

/// The only view that observes the deformation: pointer tracking re-renders
/// the silhouette while `content` (built by the parent) is left alone.
private struct DeformingShell<Content: View>: View {
    @ObservedObject var deformation: NotchDeformationState
    let geometry: NotchShellGeometry
    @ViewBuilder let content: Content

    var body: some View {
        content.modifier(NotchShellModifier(geometry: geometry, attraction: deformation.attraction,
                                            impact: deformation.impact))
    }
}

/// Interpolates resting geometry and both deformation channels every frame,
/// then derives the silhouette, clip and shadow from the summed values.
struct NotchShellModifier: ViewModifier, Animatable {
    var geometry: NotchShellGeometry
    var attraction: NotchDeformation
    var impact: NotchDeformation

    var animatableData: AnimatablePair<NotchShellGeometry, AnimatablePair<NotchDeformation, NotchDeformation>> {
        get { AnimatablePair(geometry, AnimatablePair(attraction, impact)) }
        set {
            geometry = newValue.first
            attraction = newValue.second.first
            impact = newValue.second.second
        }
    }

    func body(content: Content) -> some View {
        let width = max(0, geometry.width + attraction.width + impact.width)
        let height = max(0, geometry.height + attraction.height + impact.height)
        let top = max(0, geometry.topCornerRadius)
        let shape = NotchShape(topCornerRadius: top, bottomRadius: max(0, geometry.bottomRadius))
        let shadow = (attraction.shadow + impact.shadow).clamped()

        content
            .frame(width: width + 2 * top, height: height, alignment: .top)
            .clipShape(shape)
            .background {
                shape
                    .fill(.black)
                    .shadow(color: .black.opacity(0.5 * shadow), radius: 4 + 12 * shadow, y: 4 * shadow)
            }
            .contentShape(shape)
            .offset(x: attraction.offsetX + impact.offsetX)
    }
}
