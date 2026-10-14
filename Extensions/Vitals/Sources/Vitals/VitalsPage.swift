import AppKit
import SwiftUI
import XNotchKit

/// The notch page: a tile per metric. Each tile is its own graph: it fills
/// like a glass to the current reading, and the surface of what's in it is
/// the last minute or so. CPU and Memory open in place into the apps behind
/// them; the others open Activity Monitor.
///
/// Opening is one object changing shape, not a swap: the tile itself grows
/// across the page on the notch's own spring, pushing its neighbours out by
/// its edges, while its reading dissolves and the apps come into focus.
struct VitalsPage: View {
    static let gap: CGFloat = 8

    @ObservedObject var model: VitalsModel
    /// Nil in the Settings preview, where tiles don't act.
    let `extension`: VitalsExtension?
    let size: CGSize
    let isActive: Bool

    @Environment(\.isNotchSurfaceVisible) private var isVisible
    @State private var token = UUID()
    /// The tile that opened last stays on top while it closes again.
    @State private var raised: Metric?
    /// A tile being dragged to a new place.
    @State private var drag: TileDrag?
    /// When a drag last ended: the click that ends it doesn't also open the tile.
    @State private var droppedAt = Date.distantPast

    private struct TileDrag: Equatable {
        var metric: Metric
        /// The pointer, in the tiles' coordinates.
        var x: CGFloat
        /// Where in the tile it was picked up.
        var grab: CGFloat
    }

    static let space = "vitals.tiles"

    /// The canvas is 260 pt tall, notch and padding included: stay inside it.
    static let maxHeight: CGFloat = 208
    static let tilesHeight: CGFloat = 98

    /// The tiles, or the open breakdown. The extension reports it so XNotch can
    /// size the notch. Room for every row is kept from the start, so the notch
    /// grows once, not again when the apps arrive.
    @MainActor
    static func height(for model: VitalsModel) -> CGFloat {
        model.expanded == nil ? tilesHeight : openHeight(for: model)
    }

    /// The page's height with a tile open: the open tile's rows are laid out
    /// at this size even while closed, so nothing reflows as it opens.
    @MainActor
    static func openHeight(for model: VitalsModel) -> CGFloat {
        let metric = model.expanded ?? .cpu
        let processes = model.topApps(for: metric).first { $0.id == model.expandedApp }
            .map { model.processes(of: $0, for: metric).count } ?? 0
        return min(maxHeight, Breakdown.height(apps: VitalsModel.breakdownLimit, processes: processes) + 4)
    }

    /// Where each tile sits. An open tile fills the page; the others keep
    /// their distance from its edges, so it pushes them out as it grows.
    static func frame(of index: Int, count: Int, in size: CGSize, opened: Int?) -> CGRect {
        let tile = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
        let slot = CGFloat(index) * (tile + gap)
        let rest = CGRect(x: slot, y: 0, width: tile, height: tilesHeight - 4)
        guard let opened else { return rest }
        if index == opened { return CGRect(origin: .zero, size: size) }
        let openedSlot = CGFloat(opened) * (tile + gap)
        let push = index < opened ? -openedSlot : size.width - openedSlot - tile
        return rest.offsetBy(dx: push, dy: 0)
    }

    var body: some View {
        let metrics = model.settings.visible
        let opened = `extension` == nil ? nil : model.expanded.flatMap { metrics.firstIndex(of: $0) }
        Group {
            if metrics.isEmpty {
                Text("Nothing to show. Pick vitals in XNotch Settings.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(KitStyle.tertiaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let area = CGSize(width: size.width - 8,
                                  height: (opened == nil ? Self.tilesHeight : Self.height(for: model)) - 4)
                let openArea = CGSize(width: area.width, height: Self.openHeight(for: model) - 4)
                let arranged = arranged(metrics, in: area)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(arranged.enumerated()), id: \.element) { index, metric in
                        let isDragged = drag?.metric == metric
                        let frame = isDragged ? draggedFrame(count: metrics.count, in: area)
                            : Self.frame(of: index, count: metrics.count, in: area, opened: opened)
                        VitalCard(metric: metric, model: model, extension: `extension`,
                                  isOpen: opened == index, isPushedAway: opened != nil && opened != index,
                                  isDragged: isDragged, canDrag: `extension` != nil && opened == nil,
                                  size: frame.size,
                                  closedSize: Self.frame(of: index, count: metrics.count, in: area, opened: nil).size,
                                  openSize: openArea,
                                  onDrag: { value in dragged(metric, value, metrics: metrics, in: area) },
                                  onDrop: { drop(arranged) },
                                  tapAllowed: { drag == nil && Date().timeIntervalSince(droppedAt) > 0.25 })
                            .offset(x: frame.minX, y: frame.minY)
                            .zIndex(isDragged ? 2 : metric == raised ? 1 : 0)
                            // The dragged tile sits under the pointer; only the others make way.
                            .animation(isDragged ? nil : KitMotion.content, value: arranged)
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                }
                .coordinateSpace(name: Self.space)
                .onChange(of: arranged) { _, _ in if drag != nil { `extension`?.tick() } }
                .frame(width: area.width, height: area.height, alignment: .topLeading)
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
                .animation(KitMotion.content, value: metrics)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .onAppear { watch(isActive && isVisible) }
        .onDisappear { watch(false) }
        .onChange(of: isActive && isVisible) { _, watching in watch(watching) }
        .onChange(of: model.expanded) { _, metric in
            if let metric { raised = metric }
        }
    }

    // MARK: Rearranging

    /// The tiles as they'd land if the dragged one were let go now.
    private func arranged(_ metrics: [Metric], in area: CGSize) -> [Metric] {
        guard let drag, let from = metrics.firstIndex(of: drag.metric) else { return metrics }
        let center = draggedFrame(count: metrics.count, in: area).midX
        let slot = (0..<metrics.count).min {
            abs(Self.frame(of: $0, count: metrics.count, in: area, opened: nil).midX - center)
                < abs(Self.frame(of: $1, count: metrics.count, in: area, opened: nil).midX - center)
        } ?? from
        var result = metrics
        result.remove(at: from)
        result.insert(drag.metric, at: slot)
        return result
    }

    /// The dragged tile under the pointer, kept within the row.
    private func draggedFrame(count: Int, in area: CGSize) -> CGRect {
        let first = Self.frame(of: 0, count: count, in: area, opened: nil)
        let last = Self.frame(of: count - 1, count: count, in: area, opened: nil)
        let x = (drag?.x ?? 0) - (drag?.grab ?? 0)
        return CGRect(x: min(last.minX, max(first.minX, x)), y: first.minY, width: first.width, height: first.height)
    }

    private func dragged(_ metric: Metric, _ value: DragGesture.Value, metrics: [Metric], in area: CGSize) {
        if drag?.metric == metric {
            drag?.x = value.location.x
        } else if let index = metrics.firstIndex(of: metric) {
            let start = Self.frame(of: index, count: metrics.count, in: area, opened: nil)
            drag = TileDrag(metric: metric, x: value.location.x, grab: value.startLocation.x - start.minX)
            `extension`?.tick()
        }
    }

    /// Settles the tile where it was let go and keeps the new order.
    private func drop(_ arranged: [Metric]) {
        guard drag != nil else { return }
        droppedAt = Date()
        withAnimation(KitMotion.content) {
            drag = nil
            model.settings.order = arranged + model.settings.order.filter { !arranged.contains($0) }
        }
    }

    private func watch(_ watching: Bool) {
        model.setWatching(token, watching)
    }
}

/// The springs of a tile opening: what leaves dissolves fast, in place; what
/// arrives resolves into focus once the way is clear.
enum VitalsMotion {
    static let dissolve = Animation.easeOut(duration: 0.1)
    static let resolve = Animation.spring(response: 0.3, dampingFraction: 1)
    /// When arriving content starts, after leaving content has gone.
    static let arrival: TimeInterval = 0.08
}

/// One metric: a tile, or the same tile grown into the apps behind it. Both
/// layers stay mounted and are driven by `isOpen`, so opening never swaps
/// views: the tile grows, its reading dissolves where it stands, and the rows
/// (already laid out at their final size) resolve as the tile reaches them.
private struct VitalCard: View {
    let metric: Metric
    @ObservedObject var model: VitalsModel
    let `extension`: VitalsExtension?
    let isOpen: Bool
    let isPushedAway: Bool
    /// Lifted under the pointer while being dragged to a new place.
    let isDragged: Bool
    let canDrag: Bool
    /// The tile's size now. Exact, so the open layout it keeps mounted (wider
    /// than a closed tile) can never stretch it.
    let size: CGSize
    let closedSize: CGSize
    let openSize: CGSize
    let onDrag: (DragGesture.Value) -> Void
    let onDrop: () -> Void
    let tapAllowed: () -> Bool

    private var gauge: Gauge { model.gauge(for: metric) }
    private var tint: Color { Color(hex: metric.tintHex) ?? .white }
    private var opensBreakdown: Bool { metric.breaksDown && `extension` != nil }

    var body: some View {
        NotchHoverReader { hovered in
            let lifted = hovered && !isOpen && `extension` != nil
            ZStack(alignment: .topLeading) {
                Liquid(values: model.history(for: metric), secondary: metric == .network ? model.uploadHistory : nil,
                       color: Palette.color(gauge.level))
                    .opacity(isOpen ? 0.3 : 1)
                VStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: 0)
                    reading
                    detail
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 9)
                .frame(width: closedSize.width, height: closedSize.height, alignment: .bottomLeading)
                .modifier(Focus(progress: isOpen ? 0 : 1))
                .animation(isOpen ? VitalsMotion.dissolve : VitalsMotion.resolve.delay(VitalsMotion.arrival), value: isOpen)
                .allowsHitTesting(false)
                if opensBreakdown, let ext = `extension` {
                    let top = Breakdown.padding + Breakdown.headerHeight + Breakdown.gap
                    BreakdownList(metric: metric, model: model, extension: ext, isOpen: isOpen)
                        .frame(width: openSize.width - 2 * Breakdown.padding, height: max(0, openSize.height - top - Breakdown.padding),
                               alignment: .top)
                        .offset(x: Breakdown.padding, y: top)
                        .allowsHitTesting(isOpen)
                        .accessibilityHidden(!isOpen)
                }
                header(hovered: lifted)
                    .padding(.horizontal, isOpen ? Breakdown.padding : 10)
                    .padding(.top, isOpen ? Breakdown.padding : 9)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Shape.tile.fill(.white.opacity(lifted ? 0.09 : 0.06)))
            .clipShape(Shape.tile)
            .contentShape(Shape.tile)
            // Open, the rows take the clicks; closed, the whole tile is one button.
            .gesture(TapGesture().onEnded(activate), including: isOpen ? .subviews : .all)
            // Only once the pointer has moved, so a click still opens the tile.
            .simultaneousGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(VitalsPage.space))
                                    .onChanged(onDrag).onEnded { _ in onDrop() },
                                 including: canDrag ? .all : .subviews)
            .scaleEffect(lifted ? 1.015 : 1)
            .animation(KitMotion.content, value: lifted)
            .modifier(PushedAway(progress: isPushedAway ? 1 : 0))
            .scaleEffect(isDragged ? 1.04 : 1)
            .shadow(color: .black.opacity(isDragged ? 0.55 : 0), radius: 12, y: 5)
            .animation(KitMotion.press, value: isDragged)
            .allowsHitTesting(!isPushedAway)
        }
        .modifier(TileMenu(extension: `extension`, isOpen: isOpen))
        .accessibilityElement(children: isOpen ? .contain : .ignore)
        .accessibilityLabel(metric.title)
        .accessibilityValue(gauge.accessibilityValue)
        .accessibilityAddTraits(isOpen ? [] : .isButton)
        .accessibilityAction(named: opensBreakdown ? "Show apps" : "Open Activity Monitor", activate)
    }

    private enum Shape {
        static let tile = RoundedRectangle(cornerRadius: KitStyle.tileCornerRadius, style: .continuous)
    }

    private func activate() {
        guard !isOpen, tapAllowed() else { return }
        if opensBreakdown {
            withAnimation(KitMotion.shell) { model.expanded = metric }
        } else {
            `extension`?.openActivityMonitor()
        }
    }

    private func close() {
        withAnimation(KitMotion.shell) { model.expanded = nil }
    }

    /// The same symbol and title in both states. The back button grows in
    /// from nothing beside them, carrying them along, and the reading and
    /// Activity Monitor button resolve in place.
    private func header(hovered: Bool) -> some View {
        HStack(spacing: 5) {
            if opensBreakdown {
                RoundButton(symbol: "chevron.left", label: "Back", action: close)
                    .scaleEffect(isOpen ? 1 : 0.4)
                    .opacity(isOpen ? 1 : 0)
                    .frame(width: isOpen ? 20 : 0, alignment: .leading)
                    .padding(.trailing, isOpen ? 1 : -5)
                    .allowsHitTesting(isOpen)
                    .accessibilityHidden(!isOpen)
            }
            Image(systemName: metric.symbol)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 12)
            Text(metric.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isOpen ? KitStyle.primaryText : KitStyle.secondaryText)
                .lineLimit(1)
                .layoutPriority(1)
            if opensBreakdown {
                Text("\(gauge.value)\(gauge.unit == "%" ? "" : " ")\(gauge.unit)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(gauge.level == .normal ? KitStyle.secondaryText : Palette.color(gauge.level))
                    .lineLimit(1)
                    .contentTransition(.numericText())
                    .modifier(Focus(progress: isOpen ? 1 : 0))
                    .animation(isOpen ? VitalsMotion.resolve.delay(VitalsMotion.arrival) : VitalsMotion.dissolve, value: isOpen)
                    .accessibilityHidden(!isOpen)
            }
            Spacer(minLength: 0)
            ZStack(alignment: .trailing) {
                if hovered {
                    Image(systemName: opensBreakdown ? "chevron.down" : "arrow.up.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(KitStyle.tertiaryText)
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
                if let ext = `extension`, opensBreakdown {
                    RoundButton(symbol: "arrow.up.right", label: "Open Activity Monitor") { ext.openActivityMonitor() }
                        .scaleEffect(isOpen ? 1 : 0.4)
                        .opacity(isOpen ? 1 : 0)
                        .allowsHitTesting(isOpen)
                        .accessibilityHidden(!isOpen)
                }
            }
        }
        .frame(height: isOpen ? Breakdown.headerHeight : 14)
    }

    private var reading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            if let symbol = gauge.valueSymbol {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(KitStyle.secondaryText)
            }
            Text(gauge.value)
                .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(gauge.value == Gauge.unknown.value ? KitStyle.tertiaryText : Palette.text(gauge.level))
                .contentTransition(.numericText())
            Text(gauge.unit)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(KitStyle.secondaryText)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .animation(KitMotion.content, value: gauge.value)
    }

    private var detail: some View {
        let icon = metric == .cpu && model.settings.namesBusiestApp ? model.busiestIcon : nil
        return HStack(spacing: 4) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 12, height: 12)
            } else if let symbol = gauge.detailSymbol {
                Image(systemName: symbol)
                    .font(.system(size: 8, weight: .bold))
            }
            Text(gauge.detail ?? " ")
                .truncationMode(.middle)
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .foregroundStyle(gauge.level == .normal ? KitStyle.tertiaryText : Palette.color(gauge.level))
        .lineLimit(1)
        .frame(height: 13)
    }
}

/// A neighbour shoved aside by an opening tile: it shrinks a little and
/// dissolves on its way out. Blur only mid-way, never at rest, where it would
/// cost an offscreen pass every frame for nothing.
private struct PushedAway: ViewModifier, Animatable {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = min(1, max(0, progress))
        content
            .scaleEffect(1 - 0.08 * p)
            .blur(radius: p > 0.001 && p < 0.999 ? 6 * p : 0)
            .opacity(Double(1 - p * p * (3 - 2 * p)))
    }
}

/// Blur-to-focus: content resolves in place instead of switching on.
struct Focus: ViewModifier, Animatable {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = min(1, max(0, progress))
        content
            .scaleEffect(0.97 + 0.03 * p, anchor: .topLeading)
            .blur(radius: p > 0.001 && p < 0.999 ? 5 * (1 - p) : 0)
            .opacity(Double(p * p * (3 - 2 * p)))
    }
}

extension AnyTransition {
    static var focus: AnyTransition { .modifier(active: Focus(progress: 0), identity: Focus(progress: 1)) }
}

/// Closed: Activity Monitor or choosing vitals. Open, the rows have their own
/// menus, and a menu over the whole tile would swallow their right-clicks.
/// Not in the Settings preview, where tiles don't act. The menu sits in an
/// overlay so the tile keeps its identity, and its animation, as it opens.
private struct TileMenu: ViewModifier {
    let `extension`: VitalsExtension?
    let isOpen: Bool

    func body(content: Content) -> some View {
        content.overlay {
            if let ext = `extension`, !isOpen {
                Color.clear.notchContextMenu {
                    [.action("Open Activity Monitor", symbol: "waveform.path.ecg") { ext.openActivityMonitor() },
                     .separator,
                     .action("Choose Vitals…", symbol: "slider.horizontal.3") { ext.customize() }]
                }
            }
        }
    }
}

/// The reading as a fill: a soft gradient under a crisp surface line, and a
/// dot at the newest point that ripples with each new reading.
struct Liquid: View {
    let values: [Double]
    /// A second series drawn as a dashed line over the first (upload).
    let secondary: [Double]?
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let current = values.last ?? 0
        ZStack {
            LiquidShape(values: SampleVector(values), isFilled: true)
                .fill(LinearGradient(colors: [color.opacity(0.2), color.opacity(0.03)], startPoint: .top, endPoint: .bottom))
            LiquidShape(values: SampleVector(values), isFilled: false)
                .stroke(color.opacity(0.5), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            if let secondary {
                LiquidShape(values: SampleVector(secondary), isFilled: false)
                    .stroke(.white.opacity(0.28), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [2, 2.5]))
            }
            GeometryReader { proxy in
                Ripple(color: color, trigger: values, isEnabled: !reduceMotion)
                    .position(LiquidShape.endPoint(in: CGRect(origin: .zero, size: proxy.size), value: current))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.7), value: values)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct Ripple: View {
    let color: Color
    let trigger: [Double]
    let isEnabled: Bool

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 4, height: 4)
            .background {
                if isEnabled {
                    Circle()
                        .stroke(color, lineWidth: 1)
                        .keyframeAnimator(initialValue: 1.0, trigger: trigger) { ring, progress in
                            ring.scaleEffect(1 + progress * 2.2).opacity(0.6 * (1 - progress))
                        } keyframes: { _ in
                            KeyframeTrack {
                                MoveKeyframe(0)
                                LinearKeyframe(1, duration: 0.9)
                            }
                        }
                }
            }
    }
}

/// The history as a smooth curve across the tile, newest at the right, or
/// the area under it. Animates between readings point by point, which reads
/// as the surface settling.
struct LiquidShape: Shape {
    var values: SampleVector
    let isFilled: Bool

    /// The newest point sits this far in from the right edge, clear of the
    /// tile's corner, and the surface runs flat from there.
    static let endInset: CGFloat = 9
    /// Room above a full reading, and below an empty one, so the line shows.
    static let topRoom: CGFloat = 0.1
    static let floor: CGFloat = 1.5

    var animatableData: SampleVector {
        get { values }
        set { values = newValue }
    }

    static func y(_ value: Double, in rect: CGRect) -> CGFloat {
        let usable = rect.height * (1 - topRoom) - floor
        return rect.maxY - floor - usable * CGFloat(min(1, max(0, value)))
    }

    static func endPoint(in rect: CGRect, value: Double) -> CGPoint {
        CGPoint(x: rect.maxX - endInset, y: y(value, in: rect))
    }

    func path(in rect: CGRect) -> Path {
        let samples = values.values
        guard samples.count > 1 else { return Path() }
        let span = rect.width - Self.endInset
        let step = span / CGFloat(samples.count - 1)
        let points = samples.enumerated().map { CGPoint(x: rect.minX + CGFloat($0.offset) * step, y: Self.y($0.element, in: rect)) }

        var path = Path()
        path.move(to: points[0])
        for index in 1..<points.count {
            let previous = points[index - 1]
            let mid = CGPoint(x: (previous.x + points[index].x) / 2, y: (previous.y + points[index].y) / 2)
            path.addQuadCurve(to: mid, control: previous)
        }
        path.addLine(to: points[points.count - 1])
        path.addLine(to: CGPoint(x: rect.maxX, y: points[points.count - 1].y))
        if isFilled {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

/// A list of readings SwiftUI can animate between.
struct SampleVector: VectorArithmetic {
    var values: [Double]

    init(_ values: [Double]) {
        self.values = values
    }

    static var zero: SampleVector { SampleVector([]) }

    static func + (lhs: SampleVector, rhs: SampleVector) -> SampleVector { combine(lhs, rhs, +) }
    static func - (lhs: SampleVector, rhs: SampleVector) -> SampleVector { combine(lhs, rhs, -) }

    mutating func scale(by rhs: Double) {
        values = values.map { $0 * rhs }
    }

    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }

    /// Pads the shorter side with zeros, so `zero` combines with anything.
    private static func combine(_ lhs: SampleVector, _ rhs: SampleVector, _ op: (Double, Double) -> Double) -> SampleVector {
        let count = max(lhs.values.count, rhs.values.count)
        return SampleVector((0..<count).map { index in
            op(index < lhs.values.count ? lhs.values[index] : 0, index < rhs.values.count ? rhs.values[index] : 0)
        })
    }
}

enum Palette {
    static let caution = Color(red: 1, green: 0.74, blue: 0.3)
    static let critical = Color(red: 1, green: 0.39, blue: 0.36)

    static func color(_ level: Gauge.Level) -> Color {
        switch level {
        case .normal: .white
        case .caution: caution
        case .critical: critical
        }
    }

    static func text(_ level: Gauge.Level) -> Color {
        level == .normal ? KitStyle.primaryText : color(level)
    }
}
