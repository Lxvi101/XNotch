import AppKit
import SwiftUI
import XNotchKit

/// Colours for faces without a picture, picked from the name so a person
/// keeps theirs everywhere.
enum FacePalette {
    private static let pairs: [(Color, Color)] = [
        (Color(red: 1.00, green: 0.42, blue: 0.24), Color(red: 1.00, green: 0.70, blue: 0.28)),
        (Color(red: 0.36, green: 0.55, blue: 1.00), Color(red: 0.40, green: 0.85, blue: 1.00)),
        (Color(red: 0.62, green: 0.40, blue: 1.00), Color(red: 1.00, green: 0.45, blue: 0.80)),
        (Color(red: 0.20, green: 0.78, blue: 0.55), Color(red: 0.70, green: 0.95, blue: 0.40)),
        (Color(red: 1.00, green: 0.35, blue: 0.45), Color(red: 1.00, green: 0.62, blue: 0.50)),
        (Color(red: 0.25, green: 0.70, blue: 0.80), Color(red: 0.45, green: 0.50, blue: 1.00))
    ]

    static func colors(for seed: String) -> (Color, Color) {
        let hash = seed.unicodeScalars.reduce(UInt32(2166136261)) { ($0 ^ $1.value) &* 16777619 }
        return pairs[Int(hash % UInt32(pairs.count))]
    }

    static func tintHex(for seed: String) -> String {
        let hexes = ["#FF6B3D", "#5C8CFF", "#9E66FF", "#33C78C", "#FF5973", "#40B3CC"]
        let hash = seed.unicodeScalars.reduce(UInt32(2166136261)) { ($0 ^ $1.value) &* 16777619 }
        return hexes[Int(hash % UInt32(hexes.count))]
    }

    static func initials(_ name: String) -> String {
        let words = name.split(separator: " ").prefix(2)
        let letters = words.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

/// A round face: the picture, or initials on a soft gradient.
struct FaceImage: View {
    let name: String
    let seed: String
    let avatar: Data?

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            if let avatar, let image = NSImage(data: avatar) {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                let (a, b) = FacePalette.colors(for: seed)
                Circle()
                    .fill(LinearGradient(colors: [a, b], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(
                        Text(FacePalette.initials(name))
                            .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                    )
                    .frame(width: size, height: size)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// A PNG of the face, for places that take image data (the drop zone).
    @MainActor
    static func png(name: String, seed: String, avatar: Data?, size: CGFloat = 76) -> Data? {
        if let avatar { return avatar }
        let renderer = ImageRenderer(content: FaceImage(name: name, seed: seed, avatar: nil).frame(width: size, height: size))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

/// Rings that keep leaving a face while someone is talking to you.
struct TalkingRipples: View {
    let color: Color
    @State private var phase = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .stroke(color.opacity(0.7), lineWidth: 1.5)
                    .scaleEffect(phase ? 1.9 : 1)
                    .opacity(phase ? 0 : 0.9)
                    .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false).delay(Double(index) * 0.53),
                               value: phase)
            }
        }
        .onAppear { phase = true }
        .allowsHitTesting(false)
    }
}

/// A ring that fills as a voice note plays.
struct PlaybackRing: View {
    let progress: Double

    var body: some View {
        Circle()
            .trim(from: 0, to: max(0.001, progress))
            .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .animation(.linear(duration: 1 / 30), value: progress)
    }
}

/// Small check or cross that pops over a face after a send.
struct SendBadge: View {
    let failed: Bool
    @State private var shown = false

    var body: some View {
        Image(systemName: failed ? "exclamationmark" : "checkmark")
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Circle().fill(failed ? Color.red : KitStyle.green))
            .overlay(Circle().strokeBorder(.black, lineWidth: 2))
            .scaleEffect(shown ? 1 : 0.2)
            .rotationEffect(.degrees(shown ? 0 : -60))
            .onAppear { withAnimation(.smooth(duration: 0.44, extraBounce: 0.18)) { shown = true } }
    }
}
