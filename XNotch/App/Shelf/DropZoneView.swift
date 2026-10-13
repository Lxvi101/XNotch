import SwiftUI

enum DropTarget: Equatable {
    case shelf, airDrop

    var title: String {
        switch self {
        case .shelf: "Shelf"
        case .airDrop: "AirDrop"
        }
    }

    var symbol: String {
        switch self {
        case .shelf: "tray.and.arrow.down.fill"
        case .airDrop: "dot.radiowaves.left.and.right"
        }
    }
}

/// Shown while files are dragged over the notch. The cell under the pointer
/// lifts toward it; the other recedes.
struct DropZoneView: View {
    let hovered: DropTarget?
    let notchSize: CGSize

    var body: some View {
        HStack(spacing: 8) {
            cell(.shelf)
            cell(.airDrop)
        }
        .padding(.top, notchSize.height + 4)
        .padding(.horizontal, NotchMetrics.dropZoneTopCornerRadius + 10)
        .padding(.bottom, 10)
        .frame(width: NotchMetrics.dropZone.outerWidth, height: NotchMetrics.dropZone.height)
    }

    private func cell(_ target: DropTarget) -> some View {
        let isHovered = hovered == target
        let isReceding = hovered != nil && !isHovered
        return VStack(spacing: 7) {
            Image(systemName: target.symbol)
                .font(.system(size: 19, weight: .semibold))
                .symbolEffect(.bounce, value: isHovered)
            Text(target.title)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(isHovered ? 1 : isReceding ? 0.42 : 0.72))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(isHovered ? 0.14 : 0.055))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(isHovered ? 0.14 : 0), lineWidth: 1)
                }
        }
        .scaleEffect(isHovered ? 1.03 : isReceding ? 0.97 : 1)
        .animation(Motion.content, value: hovered)
    }
}

/// Closed-notch activity shown briefly after files land on the shelf: wings
/// grow out of the notch's sides carrying an icon and the item count.
struct TrayWingsView: View {
    @ObservedObject var store: ShelfStore
    let notchSize: CGSize

    private var count: Int { store.items.count }

    var body: some View {
        HStack {
            Image(systemName: "tray.full.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
            Spacer(minLength: notchSize.width)
            Text("\(count)")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.36, green: 0.9, blue: 0.56))
                .contentTransition(.numericText())
        }
        .padding(.horizontal, NotchMetrics.closedTopCornerRadius + 16)
        .frame(width: NotchMetrics.wings(notchSize).outerWidth, height: notchSize.height)
    }
}
