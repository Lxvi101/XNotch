import AppKit
import SwiftUI
import XNotchKit

/// The notch page: a card per drive, with how full it is and an eject button.
struct DrivesPage: View {
    @ObservedObject var monitor: DriveMonitor
    let `extension`: DrivesExtension?
    let size: CGSize
    let isActive: Bool

    private static let spacing: CGFloat = 6
    private static let scrollingCardWidth: CGFloat = 190

    var body: some View {
        Group {
            if monitor.drives.isEmpty {
                Text("No drives connected.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(KitStyle.tertiaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                cards
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(KitMotion.content, value: monitor.drives.map(\.id))
        // Free space changes while the drive is in use; read it again on opening.
        .onChange(of: isActive) { _, active in
            if active { monitor.reload() }
        }
    }

    /// Up to two drives share the width; more scroll.
    private var cardWidth: CGFloat {
        let count = CGFloat(monitor.drives.count)
        guard count <= 2 else { return Self.scrollingCardWidth }
        return (size.width - 4 - Self.spacing * (count - 1)) / count
    }

    private var cards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Self.spacing) {
                ForEach(monitor.drives) { drive in
                    DriveCard(drive: drive, isEjecting: monitor.ejecting.contains(drive.id),
                              failure: monitor.failures[drive.id],
                              onOpen: { `extension`?.open(drive) },
                              onEject: { `extension`?.eject(drive) })
                        .frame(width: cardWidth)
                        .notchContextMenu { menu(for: drive) }
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 2)
            .padding(.top, 6)
        }
        .scrollDisabled(monitor.drives.count <= 2)
    }

    private func menu(for drive: Drive) -> [NotchMenuItem] {
        var items: [NotchMenuItem] = [
            .action("Open", symbol: "folder") { `extension`?.open(drive) },
            .action("Show in Finder", symbol: "magnifyingglass") { `extension`?.reveal(drive) },
            .separator,
            .action("Eject", symbol: "eject") { `extension`?.eject(drive) },
        ]
        if monitor.drives.count > 1 {
            items.append(.action("Eject All", symbol: "eject.circle") { `extension`?.ejectAll() })
        }
        return items
    }
}

private struct DriveCard: View {
    let drive: Drive
    let isEjecting: Bool
    let failure: String?
    let onOpen: () -> Void
    let onEject: () -> Void

    var body: some View {
        NotchHoverReader { hovered in
            HStack(spacing: 10) {
                Button(action: onOpen) {
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: drive.url.path))
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 36, height: 36)
                            .shadow(color: .black.opacity(0.4), radius: 3, y: 1.5)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(drive.name)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(KitStyle.primaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(status)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(failure == nil ? KitStyle.secondaryText : Color(red: 1, green: 0.39, blue: 0.35))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .contentTransition(.opacity)
                            CapacityBar(used: drive.freeFraction.map { 1 - $0 })
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle(scale: 0.97))
                .help(drive.url.path)

                EjectButton(isEjecting: isEjecting, action: onEject)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: KitStyle.tileCornerRadius, style: .continuous)
                    .fill(hovered ? KitStyle.hoverFill : KitStyle.fill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: KitStyle.tileCornerRadius, style: .continuous)
                    .strokeBorder(KitStyle.stroke)
            }
            .opacity(isEjecting ? 0.6 : 1)
            .animation(KitMotion.content, value: hovered)
            .animation(KitMotion.content, value: isEjecting)
            .animation(KitMotion.content, value: failure)
        }
    }

    private var status: String {
        if let failure { return failure }
        if isEjecting { return "Ejecting…" }
        guard let free = drive.free else { return "" }
        guard let total = drive.total else { return "\(DriveFormat.bytes(free)) free" }
        return "\(DriveFormat.bytes(free)) free of \(DriveFormat.bytes(total))"
    }
}

private struct CapacityBar: View {
    /// 0…1; nil while unknown.
    let used: Double?

    private var tint: Color {
        guard let used else { return .white.opacity(0.5) }
        return used >= 0.9 ? Color(red: 1, green: 0.39, blue: 0.35) : Color(hex: DrivesExtension.tint) ?? .orange
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule()
                    .fill(tint)
                    .frame(width: max(proxy.size.width * (used ?? 0), used == nil ? 0 : 4))
            }
        }
        .frame(height: 4)
    }
}

private struct EjectButton: View {
    let isEjecting: Bool
    let action: () -> Void

    var body: some View {
        NotchHoverReader { hovered in
            Button(action: action) {
                ZStack {
                    if isEjecting {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.white)
                    } else {
                        Image(systemName: "eject.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(hovered ? 0.95 : 0.65))
                    }
                }
                .frame(width: 26, height: 26)
                .background(Circle().fill(.white.opacity(hovered && !isEjecting ? 0.16 : 0.08)))
                .scaleEffect(hovered && !isEjecting ? 1.06 : 1)
                .contentShape(Circle())
            }
            .buttonStyle(PressScaleStyle())
            .disabled(isEjecting)
            .animation(KitMotion.content, value: hovered)
            .help("Eject")
        }
    }
}
