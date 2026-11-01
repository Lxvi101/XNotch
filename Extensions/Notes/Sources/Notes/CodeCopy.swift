import AppKit
import QuartzCore

/// Where notes copy to. Tests point it at a pasteboard of their own.
@MainActor
var notePasteboard = NSPasteboard.general

/// Puts plain text on the clipboard.
@MainActor
func copyToPasteboard(_ text: String) {
    notePasteboard.clearContents()
    notePasteboard.setString(text, forType: .string)
}

// MARK: Finding code

extension MarkdownLayoutManager {
    /// These rects are asked for right after a restyle, before any drawing.
    /// With non-contiguous layout a range's position is only an estimate until
    /// everything above it is laid out too.
    private func layOut(through glyphs: NSRange) {
        ensureLayout(forGlyphRange: NSRange(location: 0, length: NSMaxRange(glyphs)))
    }

    /// A code block's card, in container coordinates.
    func cardRect(for block: NSRange) -> CGRect? {
        guard let container = textContainers.first else { return nil }
        let glyphs = glyphRange(forCharacterRange: block, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        layOut(through: glyphs)
        var rect = boundingRect(forGlyphRange: glyphs, in: container)
        // The text column exactly: the code keeps its padding inside the card.
        rect.origin.x = container.lineFragmentPadding
        rect.size.width = container.size.width - container.lineFragmentPadding * 2
        return rect.insetBy(dx: 0, dy: -1)
    }

    /// The pills behind inline code, one per line it wraps over, in container coordinates.
    func pillRects(for span: NSRange) -> [CGRect] {
        guard let container = textContainers.first else { return [] }
        var pills: [CGRect] = []
        let glyphs = glyphRange(forCharacterRange: span, actualCharacterRange: nil)
        layOut(through: glyphs)
        enumerateEnclosingRects(forGlyphRange: glyphs,
                                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
            guard rect.width > 0.5 else { return }
            pills.append(rect.insetBy(dx: -3, dy: 1.5).offsetBy(dx: -2, dy: 0))
        }
        return pills
    }

    /// The inline code under a point, for ⌘-click.
    func codeSpan(at point: CGPoint) -> NSRange? {
        guard let storage = textStorage, let container = textContainers.first, storage.length > 0 else { return nil }
        let character = characterIndexForGlyph(at: glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: nil))
        let line = (storage.string as NSString).lineRange(for: NSRange(location: min(character, storage.length - 1), length: 0))
        for index in [character, character - 1, character + 1] where NSLocationInRange(index, line) {
            var run = NSRange()
            guard storage.attribute(.mdCodeSpan, at: index, longestEffectiveRange: &run, in: line) != nil,
                  pillRects(for: run).contains(where: { $0.contains(point) }) else { continue }
            return run
        }
        return nil
    }

    /// The code block whose card is under a point.
    func codeBlock(at point: CGPoint) -> NSRange? {
        guard let storage = textStorage, let container = textContainers.first, storage.length > 0 else { return nil }
        let character = characterIndexForGlyph(at: glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: nil))
        guard character < storage.length, storage.attribute(.mdCodeBlock, at: character, effectiveRange: nil) != nil,
              let block = MarkdownStyler.codeBlocks(in: storage.string as NSString).first(where: { NSLocationInRange(character, $0) }),
              cardRect(for: block)?.contains(point) == true else { return nil }
        return block
    }
}

// MARK: Overlay

/// What the pointer can copy: a button in the corner of the code card it's
/// over, and a highlight on the inline code it's over. Both float above the
/// text on their own layers, so hovering never redraws it.
@MainActor
final class CodeCopyOverlay {
    private weak var textView: NoteTextView?
    private lazy var button: CodeCopyButton = {
        let button = CodeCopyButton()
        textView?.addSubview(button)
        return button
    }()
    /// The block under the pointer and its card, so moves within it cost a comparison.
    private var block: (range: NSRange, card: CGRect)?
    private var pill: CodePill?

    /// Inline code only answers the pointer with ⌘ down; without it, it's text.
    var isCommandHeld = false
    /// Behind the bucket or the switcher, the text isn't there to copy from.
    var isSuspended = false {
        didSet { if isSuspended { pointerMoved(to: nil) } }
    }

    init(textView: NoteTextView) {
        self.textView = textView
    }

    private var origin: CGPoint { textView?.textContainerOrigin ?? .zero }

    /// Follows the pointer, in container coordinates; `nil` when it left the
    /// text. Returns whether a click there would copy.
    @discardableResult
    func pointerMoved(to point: CGPoint?) -> Bool {
        guard !isSuspended, let point, let layout = textView?.markdownLayout else {
            setBlock(nil, in: nil)
            setPill(nil, rects: [])
            return false
        }
        if block?.card.contains(point) != true {
            setBlock(layout.codeBlock(at: point), in: layout)
        }
        if block != nil {
            setPill(nil, rects: [])
            let over = isOverButton(point)
            button.isLit = over
            return over
        }
        guard isCommandHeld else {
            setPill(nil, rects: [])
            return false
        }
        if pill?.rects.contains(where: { $0.contains(point) }) == true { return true }
        let span = layout.codeSpan(at: point)
        setPill(span, rects: span.map(layout.pillRects) ?? [])
        return span != nil
    }

    private func isOverButton(_ point: CGPoint) -> Bool {
        block != nil && button.isUp && button.frame.contains(CGPoint(x: point.x + origin.x, y: point.y + origin.y))
    }

    /// Takes a press on the copy button, if that's where it is.
    func handlePress(_ event: NSEvent, at point: CGPoint) -> Bool {
        // No hover comes before the first click on a note that wasn't under the pointer.
        pointerMoved(to: point)
        guard isOverButton(point) else { return false }
        if button.track(event) { copyBlock() }
        return true
    }

    /// The text, its styling or its scroll changed: what's under the pointer
    /// may have too. Costs nothing while the pointer isn't on code.
    func layoutChanged() {
        guard block != nil || pill != nil, let textView, let window = textView.window else { return }
        let point = textView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        block?.card = .null
        pointerMoved(to: CGPoint(x: point.x - origin.x, y: point.y - origin.y))
    }

    private func setBlock(_ range: NSRange?, in layout: MarkdownLayoutManager?) {
        guard let range, let layout, let textView, let card = layout.cardRect(for: range),
              !MarkdownStyler.code(of: range, in: textView.string as NSString).isEmpty else {
            if block != nil { button.lower() }
            block = nil
            return
        }
        if block?.range.location != range.location { button.endCopied() }
        block = (range, card)
        let side = CodeCopyButton.side
        button.raise(at: CGRect(x: card.maxX + origin.x - side - 5, y: card.minY + origin.y + 2, width: side, height: side))
    }

    private func setPill(_ span: NSRange?, rects: [CGRect]) {
        guard pill?.rects != rects else { return }
        pill?.leave()
        pill = nil
        guard span != nil, let textView else { return }
        let new = CodePill(rects: rects, origin: origin)
        new.span = span
        textView.addSubview(new)
        new.arrive()
        pill = new
    }

    private func copyBlock() {
        guard let block, let textView else { return }
        copyToPasteboard(MarkdownStyler.code(of: block.range, in: textView.string as NSString))
        button.showCopied()
    }

    /// Copies the inline code `span`, which lights up to say so.
    func copy(_ span: NSRange) {
        guard let textView, let layout = textView.markdownLayout else { return }
        copyToPasteboard(MarkdownStyler.code(ofSpan: span, in: textView.string as NSString))
        if pill?.span != span { setPill(span, rects: layout.pillRects(for: span)) }
        pill?.flash()
    }
}

// MARK: Motion

/// Moves a layer's value from wherever it is on screen now, so anything can
/// be interrupted. Springs run on the render server; Reduce Motion drops
/// scaling and travel and shortens the fades.
@MainActor
private func spring(_ layer: CALayer, _ keyPath: String, to value: CGFloat, from start: CGFloat? = nil,
                    response: CGFloat = 0.24, damping: CGFloat = 1) {
    let from = start ?? (layer.presentation() ?? layer).value(forKeyPath: keyPath) as? CGFloat ?? value
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.setValue(value, forKeyPath: keyPath)
    defer { CATransaction.commit() }
    guard from != value else { return }
    if NoteMotion.reduced {
        guard !keyPath.hasPrefix("transform") else { return layer.removeAnimation(forKey: keyPath) }
        let fade = CABasicAnimation(keyPath: keyPath)
        fade.fromValue = from
        fade.toValue = value
        fade.duration = 0.12
        layer.add(fade, forKey: keyPath)
        return
    }
    let animation = CASpringAnimation(keyPath: keyPath)
    animation.mass = 1
    animation.stiffness = pow(2 * .pi / response, 2)
    animation.damping = 4 * .pi * damping / response
    animation.fromValue = from
    animation.toValue = value
    animation.duration = animation.settlingDuration
    layer.add(animation, forKey: keyPath)
}

// MARK: Copy button

/// The copy button in a code card's corner. There's one per note: it follows
/// the pointer from card to card, gliding if it's already showing.
private final class CodeCopyButton: NSView {
    static let side: CGFloat = 20
    private static let copiedFor: TimeInterval = 1.2

    /// Whether the pointer's on the button itself.
    var isLit = false {
        didSet {
            guard isLit != oldValue, !isCopied else { return }
            updateLight()
        }
    }
    /// Whether it's wanted where it is, as opposed to fading or gone.
    private(set) var isUp = false

    private let content = CALayer()
    private let fill = CALayer()
    private let copyIcon = CAShapeLayer()
    private let tick = CAShapeLayer()
    private var isCopied = false
    private var copies = 0
    private var isPressed = false

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
        wantsLayer = true
        let bounds = self.bounds
        content.frame = bounds
        content.opacity = 0
        fill.frame = bounds
        fill.cornerRadius = 5
        fill.cornerCurve = .continuous
        fill.backgroundColor = NSColor(white: 1, alpha: 0.1).cgColor
        fill.opacity = 0
        content.addSublayer(fill)
        for (icon, path) in [(copyIcon, Self.copyPath), (tick, Self.tickPath)] {
            icon.frame = bounds
            icon.path = path
            icon.fillColor = nil
            icon.lineCap = .round
            icon.lineJoin = .round
            content.addSublayer(icon)
        }
        copyIcon.strokeColor = NSColor.white.cgColor
        copyIcon.lineWidth = 1.15
        copyIcon.opacity = 0.42
        tick.strokeColor = NSColor(red: 0.16, green: 0.78, blue: 0.25, alpha: 1).cgColor
        tick.lineWidth = 1.5
        tick.strokeEnd = 0
        tick.opacity = 0
        layer?.addSublayer(content)
        updateScale()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The glyphs Raynote draws, on a 16-point grid with y going down, centred in the button.
    private static var glyphSpace: CGAffineTransform {
        let scale: CGFloat = 13 / 16
        let inset = (side - 13) / 2
        return CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: inset, ty: side - inset)
    }

    private static let copyPath: CGPath = {
        let path = CGMutablePath()
        path.addRoundedRect(in: CGRect(x: 5, y: 5, width: 9, height: 9), cornerWidth: 1.5, cornerHeight: 1.5)
        path.move(to: CGPoint(x: 11, y: 5))
        path.addLine(to: CGPoint(x: 11, y: 3.5))
        path.addArc(tangent1End: CGPoint(x: 11, y: 2), tangent2End: CGPoint(x: 9.5, y: 2), radius: 1.5)
        path.addLine(to: CGPoint(x: 3.5, y: 2))
        path.addArc(tangent1End: CGPoint(x: 2, y: 2), tangent2End: CGPoint(x: 2, y: 3.5), radius: 1.5)
        path.addLine(to: CGPoint(x: 2, y: 9.5))
        path.addArc(tangent1End: CGPoint(x: 2, y: 11), tangent2End: CGPoint(x: 3.5, y: 11), radius: 1.5)
        path.addLine(to: CGPoint(x: 5, y: 11))
        return path.copy(using: [glyphSpace])!
    }()

    private static let tickPath: CGPath = {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 3, y: 8.5))
        path.addLine(to: CGPoint(x: 6.5, y: 12))
        path.addLine(to: CGPoint(x: 13.5, y: 5))
        return path.copy(using: [glyphSpace])!
    }()

    private func updateScale() {
        let scale = window?.backingScaleFactor ?? 2
        [content, fill, copyIcon, tick].forEach { $0.contentsScale = scale }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
    }

    private func updateLight() {
        spring(copyIcon, "opacity", to: isCopied ? 0 : (isLit ? 0.92 : 0.42), response: 0.2)
        spring(fill, "opacity", to: isLit && !isCopied ? 1 : 0, response: 0.2)
    }

    // MARK: Showing

    /// Up at `target`: blooming from its corner when it was gone, gliding when it was showing.
    func raise(at target: CGRect) {
        let visible = (content.presentation() ?? content).opacity > 0.02
        if visible, target.origin != frame.origin {
            let carried = content.presentation() ?? content
            let x = carried.value(forKeyPath: "transform.translation.x") as? CGFloat ?? 0
            let y = carried.value(forKeyPath: "transform.translation.y") as? CGFloat ?? 0
            // Up in the layer is down in the flipped text view.
            spring(content, "transform.translation.x", to: 0, from: x + frame.minX - target.minX, response: 0.3, damping: 0.9)
            spring(content, "transform.translation.y", to: 0, from: y + target.minY - frame.minY, response: 0.3, damping: 0.9)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = target
        CATransaction.commit()
        guard !isUp else { return }
        isUp = true
        spring(content, "opacity", to: 1)
        spring(content, "transform.scale", to: 1, from: visible ? nil : 0.8, response: 0.26, damping: 0.86)
    }

    /// Gone, once it's done saying it copied.
    func lower() {
        isUp = false
        isLit = false
        guard !isCopied else { return }
        spring(content, "opacity", to: 0, response: 0.2)
        spring(content, "transform.scale", to: 0.9, response: 0.2)
    }

    func showCopied() {
        copies += 1
        let copy = copies
        if !isCopied {
            isCopied = true
            tick.removeAllAnimations()
            spring(tick, "strokeEnd", to: 1, from: 0, response: 0.3)
            spring(tick, "opacity", to: 1, from: 1)
            updateLight()
            spring(copyIcon, "transform.scale", to: 0.7, response: 0.2)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.copiedFor) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.copies == copy else { return }
                self.endCopied()
            }
        }
    }

    func endCopied() {
        guard isCopied else { return }
        isCopied = false
        spring(tick, "opacity", to: 0, response: 0.2)
        spring(copyIcon, "transform.scale", to: 1, response: 0.26)
        updateLight()
        if !isUp { lower() }
    }

    // MARK: Pressing

    /// Only ever drawn: the hosted text view keeps the clicks, and hands this one's to `track`.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func press(_ down: Bool) {
        guard isPressed != down else { return }
        isPressed = down
        spring(content, "transform.scale", to: down ? 0.88 : 1, response: 0.18, damping: 0.9)
    }

    /// Follows a press to its end, and says whether it let go on the button.
    func track(_ event: NSEvent) -> Bool {
        press(true)
        var inside = true
        window?.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .greatestFiniteMagnitude,
                            mode: .eventTracking) { next, stop in
            guard let next else { return }
            MainActor.assumeIsolated {
                inside = self.bounds.contains(self.convert(next.locationInWindow, from: nil))
                self.press(inside)
                if next.type == .leftMouseUp { stop.pointee = true }
            }
        }
        press(false)
        return inside
    }
}

// MARK: Inline highlight

/// A tint over inline code under the pointer, which goes green as it's
/// copied. Each pill gets its own, so moving between two crossfades them.
private final class CodePill: NSView {
    private static let copiedFor: TimeInterval = 0.6
    private static let green = NSColor(red: 0.16, green: 0.78, blue: 0.25, alpha: 1)

    /// In container coordinates.
    let rects: [CGRect]
    var span: NSRange?
    private let shape = CAShapeLayer()
    private var isCopied = false
    private var isLeaving = false

    init(rects: [CGRect], origin: CGPoint) {
        self.rects = rects
        let union = rects.reduce(CGRect.null) { $0.union($1) }
        super.init(frame: union.offsetBy(dx: origin.x, dy: origin.y))
        wantsLayer = true
        let path = CGMutablePath()
        for rect in rects {
            // Measured down from the top, for a layer that goes up from the bottom.
            let local = CGRect(x: rect.minX - union.minX, y: union.maxY - rect.maxY, width: rect.width, height: rect.height)
            path.addRoundedRect(in: local.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 4, cornerHeight: 4)
        }
        shape.frame = CGRect(origin: .zero, size: union.size)
        shape.path = path
        shape.lineWidth = 1
        shape.opacity = 0
        shape.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        tint(MarkdownTheme.accent, fill: 0.14, stroke: 0.32, animated: false)
        layer?.addSublayer(shape)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func arrive() {
        spring(shape, "opacity", to: 1, from: 0, response: 0.2)
    }

    /// Fades and goes, after any flash has run.
    func leave() {
        isLeaving = true
        guard !isCopied else { return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in MainActor.assumeIsolated { self?.removeFromSuperview() } }
        spring(shape, "opacity", to: 0, response: 0.24)
        CATransaction.commit()
    }

    func flash() {
        isCopied = true
        spring(shape, "opacity", to: 1, response: 0.12)
        tint(Self.green, fill: 0.24, stroke: 0.48, animated: true)
        flashes += 1
        let flash = flashes
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.copiedFor) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.flashes == flash else { return }
                self.isCopied = false
                if self.isLeaving {
                    self.leave()
                } else {
                    self.tint(MarkdownTheme.accent, fill: 0.14, stroke: 0.32, animated: true)
                }
            }
        }
    }

    private var flashes = 0

    private func tint(_ color: NSColor, fill: CGFloat, stroke: CGFloat, animated: Bool) {
        for (keyPath, alpha) in [("fillColor", fill), ("strokeColor", stroke)] {
            let target = color.withAlphaComponent(alpha).cgColor
            let from = (shape.presentation() ?? shape).value(forKeyPath: keyPath)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shape.setValue(target, forKeyPath: keyPath)
            if animated {
                let animation = CABasicAnimation(keyPath: keyPath)
                animation.fromValue = from
                animation.toValue = target
                animation.duration = 0.16
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                shape.add(animation, forKey: keyPath)
            }
            CATransaction.commit()
        }
    }
}
