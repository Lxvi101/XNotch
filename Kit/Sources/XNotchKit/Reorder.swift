import SwiftUI

/// The rows of a grouped `Form` section, reordered by dragging (API 1.9.0).
/// A Form on macOS ignores `.onMove`, so these lay their rows out
/// themselves: the row you pick up follows the pointer, the others make way,
/// and it springs into the gap when you let go. Put it alone in a `Section`.
///
/// `range` says where an item may land, as its index once moved; nil keeps
/// it in place. `onMove` gets the item and that index.
public struct ReorderableRows<Item: Identifiable, Row: View>: View {
    private let items: [Item]
    private let range: (Item) -> ClosedRange<Int>?
    private let onMove: (Item, Int) -> Void
    private let row: (Item) -> Row

    @State private var heights: [Item.ID: CGFloat] = [:]
    @State private var dragged: Item.ID?
    @State private var from = 0
    @State private var target = 0
    @State private var translation: CGFloat = 0

    public init(_ items: [Item],
                range: @escaping (Item) -> ClosedRange<Int>? = { _ in nil },
                onMove: @escaping (Item, Int) -> Void,
                @ViewBuilder row: @escaping (Item) -> Row) {
        self.items = items
        self.range = range
        self.onMove = onMove
        self.row = row
    }

    /// Every item may land anywhere.
    public init(_ items: [Item],
                onMove: @escaping (Item, Int) -> Void,
                @ViewBuilder row: @escaping (Item) -> Row) {
        let count = items.count
        self.init(items, range: { _ in 0...max(0, count - 1) }, onMove: onMove, row: row)
    }

    public var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let isDragged = item.id == dragged
                let movable = range(item) != nil
                row(item)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                    .background {
                        // The picked-up row lifts off the section as a card.
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
                            .padding(.horizontal, -8)
                            .opacity(isDragged ? 1 : 0)
                    }
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor))
                            .frame(height: 1 / (NSScreen.main?.backingScaleFactor ?? 2))
                            .opacity(isDragged || displayIndex(of: index) == 0 ? 0 : 1)
                    }
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { heights[item.id] = $0 }
                    .offset(y: offset(of: index))
                    .zIndex(isDragged ? 1 : 0)
                    .modifier(GrabPointer(isMovable: movable, isGrabbing: isDragged))
                    .gesture(drag(item, at: index), including: movable ? .all : .subviews)
                    .accessibilityActions {
                        if let range = range(item) {
                            if range.contains(index - 1) {
                                Button("Move Up") { withAnimation(KitMotion.content) { onMove(item, index - 1) } }
                            }
                            if range.contains(index + 1) {
                                Button("Move Down") { withAnimation(KitMotion.content) { onMove(item, index + 1) } }
                            }
                        }
                    }
            }
        }
        .coordinateSpace(name: CoordinateSpaceName.rows)
    }

    private enum CoordinateSpaceName: Hashable { case rows }

    private func height(_ index: Int) -> CGFloat { heights[items[index].id] ?? 0 }

    /// Where the row at `index` sits while a drag is under way, counted in rows.
    private func displayIndex(of index: Int) -> Int {
        guard dragged != nil else { return index }
        if index == from { return target }
        if from < index, index <= target { return index - 1 }
        if target <= index, index < from { return index + 1 }
        return index
    }

    private func offset(of index: Int) -> CGFloat {
        guard dragged != nil else { return 0 }
        if index == from { return rubberBanded(translation, at: index) }
        if from < index, index <= target { return -height(from) }
        if target <= index, index < from { return height(from) }
        return 0
    }

    /// The picked-up row follows the pointer, and pulls against the ends of
    /// the list rather than leaving it.
    private func rubberBanded(_ translation: CGFloat, at index: Int) -> CGFloat {
        let top = -items.indices.prefix(index).reduce(0) { $0 + height($1) }
        let bottom = items.indices.suffix(from: index + 1).reduce(0) { $0 + height($1) }
        func band(_ overshoot: CGFloat) -> CGFloat {
            let limit: CGFloat = 24
            return limit * (1 - 1 / (overshoot * 0.55 / limit + 1))
        }
        if translation < top { return top - band(top - translation) }
        if translation > bottom { return bottom + band(translation - bottom) }
        return translation
    }

    /// The index the picked-up row would land on: past every other row whose
    /// middle its own middle has crossed.
    private func landing(for translation: CGFloat, from index: Int, in range: ClosedRange<Int>) -> Int {
        var y: CGFloat = 0
        for other in items.indices.prefix(index) { y += height(other) }
        let middle = y + height(index) / 2 + translation
        var top: CGFloat = 0
        var landing = 0
        for other in items.indices where other != index {
            if top + height(other) / 2 < middle { landing += 1 }
            top += height(other)
        }
        return min(max(landing, range.lowerBound), range.upperBound)
    }

    private func drag(_ item: Item, at index: Int) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(CoordinateSpaceName.rows))
            .onChanged { value in
                guard let range = range(item) else { return }
                if dragged == nil {
                    from = index
                    target = index
                    withAnimation(KitMotion.press) { dragged = item.id }
                }
                translation = value.translation.height
                let landing = landing(for: translation, from: from, in: range)
                if landing != target {
                    withAnimation(KitMotion.content) { target = landing }
                }
            }
            .onEnded { _ in
                guard dragged != nil else { return }
                withAnimation(KitMotion.content) {
                    if target != from { onMove(item, target) }
                    dragged = nil
                    translation = 0
                }
            }
    }
}

/// An open hand over rows that move, a closed one while one is held.
private struct GrabPointer: ViewModifier {
    let isMovable: Bool
    let isGrabbing: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.pointerStyle(isMovable ? (isGrabbing ? .grabActive : .grabIdle) : nil)
        } else {
            content
        }
    }
}
