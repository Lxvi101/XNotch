import SwiftUI
import XNotchKit

/// Someone wrote to you: the notch grows into a banner, their picture on the
/// left (with what kind of message it is in a small badge, as a phone shows
/// it), their name and the start of what they said under the camera.
struct NotchMessageView: View {
    let message: NotchMessage
    let notchSize: CGSize

    @State private var arrived = false

    private static let avatarSize = NotchMetrics.messageAvatar
    private var tint: Color { message.tint.flatMap(Color.init(hex:)) ?? Color(red: 0.36, green: 0.55, blue: 1) }

    var body: some View {
        let geometry = NotchMetrics.message(notchSize, text: message.text)
        let side = geometry.topCornerRadius + NotchMetrics.messageInset
        ZStack(alignment: .topLeading) {
            avatar
                .frame(width: Self.avatarSize, height: Self.avatarSize)
                .scaleEffect(arrived ? 1 : 0.72)
                .opacity(arrived ? 1 : 0)
                // Centred a little low: the camera row above is mostly black.
                .offset(x: side, y: (geometry.height - Self.avatarSize) / 2 + 6)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(message.sender)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer(minLength: 0)
                    Text("now")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.42))
                }
                Text(message.text)
                    .font(Font(NotchMetrics.messageTextFont))
                    .foregroundStyle(.white.opacity(0.74))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .lineLimit(1)
            .padding(.leading, side + Self.avatarSize + 12)
            .padding(.trailing, side + 4)
            .padding(.top, notchSize.height + 5)
            .offset(y: arrived ? 0 : 4)
        }
        .frame(width: geometry.outerWidth, height: geometry.height, alignment: .topLeading)
        .onAppear {
            // The picture lands a beat after the shell opens, then the words settle.
            withAnimation(Motion.reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.72).delay(0.06)) {
                arrived = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(message.sender): \(message.text)")
    }

    private var avatar: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let data = message.image, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    LinearGradient(colors: [tint, tint.opacity(0.62)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay(
                            Text(Self.initials(message.sender))
                                .font(.system(size: Self.avatarSize * 0.38, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        )
                }
            }
            .frame(width: Self.avatarSize, height: Self.avatarSize)
            .clipShape(Circle())
            if let symbol = message.symbol {
                // What it is, like the app icon on a contact's photo.
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 19, height: 19)
                    .background(Circle().fill(tint))
                    .overlay(Circle().strokeBorder(.black, lineWidth: 2).padding(-1.5))
                    .offset(x: 3, y: 2)
                    .scaleEffect(arrived ? 1 : 0.3)
                    .animation(Motion.reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.6).delay(0.22),
                               value: arrived)
            }
        }
    }

    private static func initials(_ name: String) -> String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}
