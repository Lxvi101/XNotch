import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The wheel, and the pill it folds into once something is dropped on it.
/// One glass body throughout: the disc shrinks into the pill.
struct WheelView: View {
    static let pillSize = CGSize(width: 272, height: 58)

    let model: WheelModel
    let controller: WheelController
    @Namespace private var namespace

    var body: some View {
        ZStack {
            Glass(model: model)
            if model.job == nil {
                Sectors(model: model, namespace: namespace)
                    .transition(.collapse)
                Hub(model: model)
                    .transition(.focus)
            } else if let job = model.job {
                Pill(job: job, model: model, namespace: namespace, controller: controller)
                    .transition(.focus)
            }
        }
        .modifier(Presence(isPresented: model.isPresented))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: The glass

/// The disc, then the pill: the same shape changing size, so the wheel
/// visibly becomes the pill rather than being swapped for it.
private struct Glass: View {
    let model: WheelModel

    var body: some View {
        let pill = model.job != nil
        let side = (model.geometry.radius + WheelGeometry.glassInset) * 2
        let size = pill ? WheelView.pillSize : CGSize(width: side, height: side)
        let shape = RoundedRectangle(cornerRadius: min(size.width, size.height) / 2, style: .circular)
        ZStack {
            VisualEffect()
            Color.black.opacity(0.32)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.13), lineWidth: 1))
        .background {
            shape
                .fill(.black.opacity(0.45))
                .blur(radius: WheelGeometry.shadowBlur)
                .offset(y: WheelGeometry.shadowDrop)
                .mask {
                    ZStack {
                        Rectangle().padding(-WheelGeometry.shadowReach * 2)
                        shape.blendMode(.destinationOut)
                    }
                    .compositingGroup()
                }
        }
        .frame(width: size.width, height: size.height)
    }
}

private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: The rings

private struct Sectors: View {
    let model: WheelModel
    let namespace: Namespace.ID

    var body: some View {
        let geometry = model.geometry
        let offer = model.files.offer
        ZStack {
            ForEach(Array(offer.formats.enumerated()), id: \.element.id) { index, format in
                Sector(model: model, hit: .format(index), operation: .convert(format), index: index,
                       count: offer.formats.count, ring: geometry.formatRing, namespace: namespace) {
                    Text(format.title)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .tracking(0.4)
                }
            }
            if let ring = geometry.toolRing {
                ForEach(Array(offer.tools.enumerated()), id: \.element.id) { index, tool in
                    Sector(model: model, hit: .tool(index), operation: .tool(tool), index: index,
                           count: offer.tools.count, ring: ring, namespace: namespace) {
                        VStack(spacing: 2) {
                            Image(systemName: tool.symbol)
                                .font(.system(size: 11, weight: .semibold))
                            Text(tool.title.uppercased())
                                .font(.system(size: 7.5, weight: .bold, design: .rounded))
                                .tracking(0.5)
                        }
                    }
                }
            }
        }
    }
}

/// One slice: lifts out from the centre and turns white under the pointer.
private struct Sector<Label: View>: View {
    let model: WheelModel
    let hit: WheelGeometry.Hit
    let operation: Action
    let index: Int
    let count: Int
    let ring: ClosedRange<CGFloat>
    let namespace: Namespace.ID
    @ViewBuilder let label: () -> Label

    var body: some View {
        let span = WheelGeometry.span(of: index, count: count)
        let middle = (span.start + span.end) / 2
        let hovered = model.hovered == hit
        let isTool = if case .tool = hit { true } else { false }
        let lift = WheelGeometry.point(angle: middle, distance: hovered ? 5 : 0)
        let labelPoint = WheelGeometry.point(angle: count == 1 ? .pi : middle, distance: (ring.lowerBound + ring.upperBound) / 2)
        let needsFFmpeg = model.needsFFmpeg.contains(operation)
        let presented = model.isPresented
        ZStack {
            RingSector(start: span.start, end: span.end, inner: ring.lowerBound, outer: ring.upperBound)
                .fill(hovered ? Color.white : Color.white.opacity(isTool ? 0.055 : 0.1))
            ZStack(alignment: .topTrailing) {
                label()
                    .foregroundStyle(hovered ? Color.black : Color.white.opacity(isTool ? 0.72 : 0.95))
                    .matchedGeometryEffect(id: operation, in: namespace, properties: .position)
                if needsFFmpeg {
                    // Dropping here installs ffmpeg first.
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(hovered ? Color.black.opacity(0.55) : Color.white.opacity(0.4))
                        .offset(x: 9, y: -6)
                }
            }
            .offset(x: labelPoint.x, y: labelPoint.y)
        }
        .frame(width: WheelGeometry.panelSide, height: WheelGeometry.panelSide)
        .offset(x: lift.x, y: lift.y)
        // Each slice turns in a moment after the one before, as the wheel opens.
        .rotationEffect(.degrees(presented || WheelMotion.reduced ? 0 : -14))
        .opacity(presented ? 1 : 0)
        .animation(WheelMotion.appear.delay(presented ? Double(index) * 0.012 : 0), value: presented)
        .allowsHitTesting(false)
    }
}

// MARK: The hub

/// The file at rest; what a drop would do while the pointer is over a slice.
private struct Hub: View {
    let model: WheelModel

    var body: some View {
        let operation = model.operation(for: model.hovered)
        let diameter = WheelGeometry.hubRadius * 2
        ZStack {
            Circle()
                .fill(.black.opacity(0.42))
                .overlay(Circle().strokeBorder(.white.opacity(0.08), lineWidth: 1))
            Group {
                if let operation {
                    HubOperation(operation: operation, kind: model.files.kind,
                                 needsFFmpeg: model.needsFFmpeg.contains(operation))
                        .id(operation)
                } else if model.hovered == .hub {
                    VStack(spacing: 3) {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Cancel")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(.white.opacity(0.6))
                    .id("cancel")
                } else {
                    HubFile(model: model)
                        .id("file")
                }
            }
            .transition(.focus)
            .animation(WheelMotion.hover, value: model.hovered)
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
    }
}

private struct HubFile: View {
    let model: WheelModel

    var body: some View {
        let files = model.files
        VStack(spacing: 3) {
            ZStack {
                if let thumbnail = model.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .transition(.focus)
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(for: files.kind.placeholderType))
                        .resizable()
                        .scaledToFit()
                        .transition(.focus)
                }
            }
            .frame(width: 40, height: 40)
            Text(files.urls.count > 1 ? "\(files.urls.count) files"
                    : ByteCountFormatter.string(fromByteCount: model.totalSize, countStyle: .file))
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .monospacedDigit()
        }
    }
}

private struct HubOperation: View {
    let operation: Action
    let kind: FileKind
    let needsFFmpeg: Bool

    var body: some View {
        VStack(spacing: 2) {
            switch operation {
            case .convert(let format):
                Text("TO")
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.45))
                Text(format.title)
                    .font(.system(size: 21, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
            case .tool(let tool):
                Image(systemName: tool.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Text(tool.verb)
                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if needsFFmpeg {
                Text("Gets ffmpeg first")
                    .font(.system(size: 7.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(width: 80)
    }
}

// MARK: The pill

/// The job's progress, where the wheel was. Click to cancel, then to show the result.
private struct Pill: View {
    let job: ConversionJob
    let model: WheelModel
    let namespace: Namespace.ID
    let controller: WheelController

    var body: some View {
        HStack(spacing: 11) {
            PillBadge(job: job, namespace: namespace)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.interpolate)
                Text(detail)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(job.phase.isFailure ? Color(red: 1, green: 0.55, blue: 0.5) : .white.opacity(0.55))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .monospacedDigit()
                    .contentTransition(.interpolate)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(WheelMotion.content, value: job.phase)
            PillAccessory(job: job, isHovered: model.isPillHovered)
        }
        .padding(.leading, 11)
        .padding(.trailing, 14)
        .frame(width: WheelView.pillSize.width, height: WheelView.pillSize.height)
        .contentShape(Capsule())
        .onTapGesture { controller.pillClicked() }
    }

    private var title: String {
        switch job.phase {
        case .installing: "Getting ffmpeg"
        case .working:
            switch job.operation {
            case .convert(let format): "Converting to \(format.title)"
            case .tool(let tool): tool == .copyText ? "Reading text" : "\(tool.title)…"
            }
        case .done:
            job.note != nil ? "Copied" : job.outputs.count > 1 ? "Saved \(job.outputs.count) files" : "Saved"
        case .failed: "Couldn't \(job.operation.verb)"
        case .cancelled: "Cancelled"
        }
    }

    private var detail: String {
        switch job.phase {
        case .installing(let fraction):
            fraction.map { "Downloading · \(Int($0 * 100))%" } ?? "Downloading…"
        case .working:
            if job.sources.count > 1 { "\(job.completed) of \(job.sources.count) files" }
            else if let progress = job.progress, progress > 0 { "\(Int(progress * 100))%" }
            else { job.sources[0].lastPathComponent }
        case .done:
            job.note ?? job.outputs.first?.lastPathComponent ?? ""
        case .failed(let message): message
        case .cancelled: job.sources.count > 1 ? "\(job.sources.count) files" : job.sources[0].lastPathComponent
        }
    }
}

/// The format or tool, carried in from its slice, inside a ring that fills
/// as the job runs and turns into a check when it's done.
private struct PillBadge: View {
    let job: ConversionJob
    let namespace: Namespace.ID
    private static let orange = Color(red: 1, green: 0.48, blue: 0.18)
    private static let green = Color(red: 0.36, green: 0.9, blue: 0.56)

    var body: some View {
        let progress: Double = switch job.phase {
        case .installing(let fraction): fraction ?? 0.04
        case .working: max(job.progress ?? 0.04, 0.04)
        case .done, .failed, .cancelled: 1
        }
        let color: Color = switch job.phase {
        case .done: Self.green
        case .failed: Color(red: 1, green: 0.38, blue: 0.35)
        case .cancelled: .white.opacity(0.3)
        default: Self.orange
        }
        ZStack {
            Circle().stroke(.white.opacity(0.12), lineWidth: 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(WheelMotion.content, value: progress)
            Group {
                switch job.phase {
                case .done:
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Self.green)
                case .failed:
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(color)
                case .installing:
                    Image(systemName: "arrow.down")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                default:
                    badge
                        .matchedGeometryEffect(id: job.operation, in: namespace, properties: .position)
                }
            }
            .transition(.focus)
            .animation(WheelMotion.content, value: job.phase)
        }
        .frame(width: 36, height: 36)
    }

    @ViewBuilder private var badge: some View {
        switch job.operation {
        case .convert(let format):
            Text(format.title)
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.7)
                .frame(width: 30)
        case .tool(let tool):
            Image(systemName: tool.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}

/// Cancel while running; a way to the file once done.
private struct PillAccessory: View {
    let job: ConversionJob
    let isHovered: Bool

    var body: some View {
        let symbol: String? = if !job.isFinished { "xmark" }
            else if job.phase == .done && !job.outputs.isEmpty { "magnifyingglass" }
            else { nil }
        ZStack {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(isHovered ? 0.9 : 0.45))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.white.opacity(isHovered ? 0.16 : 0.08)))
                    .id(symbol)
                    .transition(.focus)
            }
        }
        .frame(width: 22, height: 22)
        .animation(WheelMotion.content, value: symbol)
        .animation(WheelMotion.hover, value: isHovered)
    }
}

// MARK: Motion

/// The wheel grows out of the pointer and comes into focus; it leaves the same way.
private struct Presence: ViewModifier {
    let isPresented: Bool

    func body(content: Content) -> some View {
        let reduced = WheelMotion.reduced
        content
            .scaleEffect(isPresented || reduced ? 1 : 0.42)
            .blur(radius: isPresented ? 0 : (reduced ? 2 : 10))
            .opacity(isPresented ? 1 : 0)
    }
}

/// Arriving content comes into focus; leaving content goes out of it.
private struct Focus: ViewModifier {
    let amount: CGFloat

    func body(content: Content) -> some View {
        content
            .blur(radius: 6 * amount)
            .scaleEffect(1 - 0.08 * amount)
            .opacity(1 - amount)
    }
}

/// The rings fold in towards the hub as the wheel becomes the pill.
private struct Collapse: ViewModifier {
    let amount: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(1 - 0.45 * amount)
            .blur(radius: 8 * amount)
            .opacity(1 - amount)
    }
}

private extension AnyTransition {
    static var focus: AnyTransition {
        WheelMotion.reduced ? .opacity : .modifier(active: Focus(amount: 1), identity: Focus(amount: 0))
    }

    static var collapse: AnyTransition {
        WheelMotion.reduced ? .opacity : .modifier(active: Collapse(amount: 1), identity: Collapse(amount: 0))
    }
}

extension ConversionJob.Phase {
    var isFailure: Bool {
        if case .failed = self { true } else { false }
    }
}

extension Action {
    /// "convert to JPG", "compress": after "Couldn't".
    var verb: String {
        switch self {
        case .convert(let format): "convert to \(format.title)"
        case .tool(let tool): tool == .copyText ? "copy the text" : tool.title.lowercased()
        }
    }
}

extension FileKind {
    var placeholderType: UTType {
        switch self {
        case .image: .image
        case .gif: .gif
        case .pdf: .pdf
        case .document: .text
        case .video: .movie
        case .audio: .audio
        }
    }
}
