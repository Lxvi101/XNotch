import AppKit
import SwiftUI
import XNotchKit

@MainActor
final class LockScreenCardState: ObservableObject {
    @Published var presented = false
}

/// Now Playing on the Lock Screen: frosted glass over the wallpaper, faintly
/// tinted by the artwork, like the system's own Lock Screen widgets.
struct LockScreenMediaCard: View {
    static let width: CGFloat = 372
    static let cornerRadius: CGFloat = 26

    @ObservedObject var media: NowPlayingService
    @ObservedObject var state: LockScreenCardState
    /// `.behindWindow` blurs the wallpaper; `.withinWindow` blurs whatever
    /// the card sits on inside its window (the Settings preview).
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    var body: some View {
        let track = media.track ?? NowPlayingTrack()
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .circular)

        VStack(spacing: 12) {
            HStack(spacing: 14) {
                ArtworkView(image: media.artwork, cornerRadius: 12)
                    .frame(width: 62, height: 62)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                VStack(alignment: .leading, spacing: 2) {
                    MarqueeText(text: track.title.isEmpty ? "Not Playing" : track.title,
                                font: .system(size: 15, weight: .semibold), color: .white)
                    MarqueeText(text: track.artist, font: .system(size: 13, weight: .medium), color: .white.opacity(0.68))
                }
                Spacer(minLength: 0)
                VisualizerBars(energy: track.isPlaying ? 1 : 0, color: media.accent)
                    .frame(width: MediaLayout.visualizerSize.width, height: MediaLayout.visualizerSize.height)
                    .animation(Motion.content, value: track.isPlaying)
            }
            PlaybackScrubber(track: track, onSeek: media.seek)
            HStack(spacing: 36) {
                TransportButton(symbol: "backward.fill", size: 18, action: media.previousTrack)
                TransportButton(symbol: track.isPlaying ? "pause.fill" : "play.fill", size: 26, action: media.togglePlayPause)
                TransportButton(symbol: "forward.fill", size: 18, action: media.nextTrack)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(width: Self.width)
        .background {
            ZStack {
                BackdropBlur(blending: blending, cornerRadius: Self.cornerRadius)
                shape.fill(LinearGradient(colors: [media.accent.opacity(0.12), .black.opacity(0.08)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
                    .animation(.easeInOut(duration: 0.4), value: media.accent)
            }
        }
        .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .environment(\.colorScheme, .dark)
        .reveal(state.presented ? 1 : 0, hiddenScale: 0.9, maxBlur: 14, travel: 18)
        .animation(state.presented ? Motion.open : Motion.close, value: state.presented)
    }
}
