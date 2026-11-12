import AppKit
import SwiftUI
import XNotchKit

/// An extension's face in the drop zone.
struct FaceDropTarget: Hashable {
    let extensionID: ExtensionID
    let target: NotchDropTarget

    var id: String { "\(extensionID)/\(target.id)" }
}

enum DropTarget: Hashable {
    case shelf, airDrop
    case face(FaceDropTarget)

    var title: String {
        switch self {
        case .shelf: "Tray"
        case .airDrop: "AirDrop"
        case .face(let face): face.target.title
        }
    }

    var symbol: String {
        switch self {
        case .shelf: "tray.and.arrow.down.fill"
        case .airDrop: "dot.radiowaves.left.and.right"
        case .face(let face): face.target.symbol
        }
    }
}

/// Where the drop zone's cells and faces sit, shared by the view and the
/// window's hit testing so they always agree.
enum DropZoneLayout {
    static let maxFaces = 6
    static let faceRowHeight: CGFloat = 64
    static let faceSize: CGFloat = 38
    static let faceSpacing: CGFloat = 16

    static func geometry(faces: Int) -> NotchShellGeometry {
        guard faces > 0 else { return NotchMetrics.dropZone }
        let base = NotchMetrics.dropZone
        return NotchShellGeometry(width: base.width, height: base.height + faceRowHeight,
                                  topCornerRadius: NotchMetrics.dropZoneTopCornerRadius,
                                  bottomRadius: NotchMetrics.dropZoneBottomRadius)
    }

    /// The face under `point`, given in the zone's own coordinates with the
    /// origin at its top left. The row's lower part is generous: a face is
    /// hit anywhere in its column.
    static func face(at point: CGPoint, faces: Int, zoneHeight: CGFloat, zoneWidth: CGFloat) -> Int? {
        guard faces > 0, point.y > zoneHeight - faceRowHeight - 12 else { return nil }
        let pitch = faceSize + faceSpacing
        let rowWidth = CGFloat(faces) * pitch
        let start = (zoneWidth - rowWidth) / 2
        let index = Int(floor((point.x - start) / pitch))
        return (0..<faces).contains(index) ? index : nil
    }
}

/// Shown while files are dragged over the notch. The cell under the pointer
/// lifts toward it; the other recedes.
struct DropZoneView: View {
    let hovered: DropTarget?
    let faces: [FaceDropTarget]
    let notchSize: CGSize

    var body: some View {
        let geometry = DropZoneLayout.geometry(faces: faces.count)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                cell(.shelf)
                cell(.airDrop)
            }
            .frame(height: NotchMetrics.dropZone.height - notchSize.height - 14)
            if !faces.isEmpty {
                DropFacesRow(faces: faces, hovered: hovered)
                    .frame(height: DropZoneLayout.faceRowHeight)
            }
        }
        .padding(.top, notchSize.height + 4)
        .padding(.horizontal, NotchMetrics.dropZoneTopCornerRadius + 10)
        .padding(.bottom, 10)
        .frame(width: geometry.outerWidth, height: geometry.height, alignment: .top)
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

/// Faces under the cells. The face under the pointer grows, gains a ring
/// and names itself; its neighbours lean away to make room.
private struct DropFacesRow: View {
    let faces: [FaceDropTarget]
    let hovered: DropTarget?

    private var hoveredIndex: Int? {
        guard case .face(let face) = hovered else { return nil }
        return faces.firstIndex(of: face)
    }

    var body: some View {
        let hoveredIndex = hoveredIndex
        ZStack(alignment: .bottom) {
            HStack(spacing: DropZoneLayout.faceSpacing) {
                ForEach(Array(faces.enumerated()), id: \.element.id) { index, face in
                    let isHovered = hoveredIndex == index
                    let lean: CGFloat = hoveredIndex.map { index == $0 ? 0 : (index < $0 ? -5 : 5) } ?? 0
                    DropFace(target: face.target)
                        .frame(width: DropZoneLayout.faceSize, height: DropZoneLayout.faceSize)
                        .overlay(Circle().strokeBorder(.white.opacity(isHovered ? 0.95 : 0.14), lineWidth: isHovered ? 2 : 1))
                        .shadow(color: .black.opacity(isHovered ? 0.45 : 0.2), radius: isHovered ? 8 : 3, y: 2)
                        .scaleEffect(isHovered ? 1.22 : hoveredIndex == nil ? 1 : 0.9)
                        .offset(x: lean, y: isHovered ? -6 : 0)
                        .opacity(hoveredIndex == nil || isHovered ? 1 : 0.55)
                        .animation(.spring(response: 0.32, dampingFraction: 0.62), value: hoveredIndex)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .offset(y: -6)
            Text(hoveredIndex.map { "Drop to \(faces[$0].target.title)" } ?? "Drop on a face to send")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(hoveredIndex == nil ? 0.4 : 0.92))
                .contentTransition(.interpolate)
                .animation(Motion.content, value: hoveredIndex)
                .offset(y: 2)
        }
    }
}

/// A round face from an extension: its picture, or its symbol on its tint.
struct DropFace: View {
    let target: NotchDropTarget

    var body: some View {
        if let data = target.image, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .clipShape(Circle())
        } else {
            Circle()
                .fill(target.tint.flatMap { Color(hex: $0) } ?? Color.white.opacity(0.2))
                .overlay(Image(systemName: target.symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white))
        }
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
