import AppKit

/// Draws what the styler marks: checkboxes, bullets, quote bars, rules, code
/// cards and images, and gives hidden syntax no glyphs and no width.
final class MarkdownLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    /// Completed tasks fading away, by fade: how much of the box is left.
    var fadeAlphas: [String: CGFloat] = [:]

    override init() {
        super.init()
        delegate = self
        allowsNonContiguousLayout = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Hiding syntax

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes: UnsafePointer<Int>, font: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage = textStorage, glyphRange.length > 0 else { return 0 }
        let first = characterIndexes[0]
        let last = characterIndexes[glyphRange.length - 1]
        guard last >= first, last < storage.length else { return 0 }
        var hidden = IndexSet()
        storage.enumerateAttribute(.mdHidden, in: NSRange(location: first, length: last - first + 1)) { value, range, _ in
            if value != nil { hidden.insert(integersIn: range.location..<NSMaxRange(range)) }
        }
        guard !hidden.isEmpty else { return 0 }
        var properties = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
        // Zero-width control glyphs rather than null ones: a line that starts
        // with null glyphs is laid out as if it continued the paragraph, and
        // takes its hanging indent.
        for i in 0..<glyphRange.length where hidden.contains(characterIndexes[i]) {
            properties[i] = .controlCharacter
        }
        properties.withUnsafeBufferPointer { buffer in
            setGlyphs(glyphs, properties: buffer.baseAddress!, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
        }
        return glyphRange.length
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        guard let storage = textStorage, charIndex < storage.length,
              storage.attribute(.mdHidden, at: charIndex, effectiveRange: nil) != nil else { return action }
        // A hidden line break still breaks the line.
        let character = (storage.string as NSString).character(at: charIndex)
        return character == 0x0A || character == 0x0D ? action : .zeroAdvancement
    }

    // MARK: Drawing

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let padding = container.lineFragmentPadding

        // One card per code block, its language in the top corner while collapsed.
        var drawnBlocks = Set<Int>()
        storage.enumerateAttribute(.mdCodeBlock, in: characters) { value, run, _ in
            guard value != nil else { return }
            var block = run
            _ = storage.attribute(.mdCodeBlock, at: run.location, longestEffectiveRange: &block,
                                  in: NSRange(location: 0, length: storage.length))
            guard drawnBlocks.insert(block.location).inserted else { return }
            let glyphs = glyphRange(forCharacterRange: block, actualCharacterRange: nil)
            guard glyphs.length > 0 else { return }
            var rect = boundingRect(forGlyphRange: glyphs, in: container)
            // The text column exactly: the code keeps its padding inside the card.
            rect.origin.x = padding
            rect.size.width = container.size.width - padding * 2
            rect = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: 0, dy: -1)
            MarkdownTheme.codeFill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
            NSColor(white: 1, alpha: 0.06).setStroke()
            let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8.5, yRadius: 8.5)
            outline.lineWidth = 1
            outline.stroke()
            if let language = storage.attribute(.mdCodeLanguage, at: block.location, effectiveRange: nil) as? String {
                let label = NSAttributedString(string: language.uppercased(), attributes: [
                    .font: NSFont.systemFont(ofSize: 9.5, weight: .semibold), .kern: 0.6,
                    .foregroundColor: NSColor(white: 1, alpha: 0.32)])
                let size = label.size()
                label.draw(at: CGPoint(x: rect.maxX - size.width - 10, y: rect.minY + 6))
            }
        }

        storage.enumerateAttribute(.mdCodeSpan, in: characters) { value, run, _ in
            guard value != nil else { return }
            let glyphs = glyphRange(forCharacterRange: run, actualCharacterRange: nil)
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                    in: container) { rect, _ in
                guard rect.width > 0.5 else { return }
                let pill = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -3, dy: 1.5).offsetBy(dx: -2, dy: 0)
                MarkdownTheme.codeFill.setFill()
                NSBezierPath(roundedRect: pill, xRadius: 4.5, yRadius: 4.5).fill()
            }
        }

        storage.enumerateAttribute(.mdQuote, in: characters) { value, run, _ in
            guard value != nil else { return }
            let glyphs = glyphRange(forCharacterRange: run, actualCharacterRange: nil)
            let rect = boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: origin.x, dy: origin.y)
            let bar = CGRect(x: origin.x + padding, y: rect.minY + 2, width: 2.5, height: rect.height - 4)
            MarkdownTheme.accent.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1.25, yRadius: 1.25).fill()
        }

        storage.enumerateAttribute(.mdImage, in: characters) { value, run, _ in
            guard let image = value as? NoteImage else { return }
            let glyphs = glyphRange(forCharacterRange: run, actualCharacterRange: nil)
            guard glyphs.length > 0 else { return }
            guard let frame = blockImageFrame(for: run, image: image) else { return }
            drawPicture(image, in: frame.offsetBy(dx: origin.x, dy: origin.y), radius: frame.height > 60 ? 10 : 6)
        }

        storage.enumerateAttribute(.mdInlineImage, in: characters) { value, run, _ in
            guard let image = value as? NoteImage, let frame = inlineImageFrame(for: run, image: image) else { return }
            drawPicture(image, in: frame.offsetBy(dx: origin.x, dy: origin.y), radius: 4)
        }
    }

    /// Where a line's image is drawn, in container coordinates.
    func blockImageFrame(for run: NSRange, image: NoteImage) -> CGRect? {
        guard let container = textContainers.first else { return nil }
        let glyphs = glyphRange(forCharacterRange: run, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let line = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let width = min(image.display.width, container.size.width - container.lineFragmentPadding * 2)
        let height = image.display.width > 0 ? image.display.height * width / image.display.width : image.display.height
        return CGRect(x: container.lineFragmentPadding, y: line.maxY - height - 4, width: width, height: height)
    }

    /// Where an inline thumbnail is drawn: over its `!`, centred on the text.
    func inlineImageFrame(for run: NSRange, image: NoteImage) -> CGRect? {
        guard let container = textContainers.first, let storage = textStorage else { return nil }
        let glyphs = glyphRange(forCharacterRange: NSRange(location: run.location, length: 1), actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let bounds = boundingRect(forGlyphRange: glyphs, in: container)
        let line = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let baseline = line.minY + location(forGlyphAt: glyphs.location).y
        let font = (storage.attribute(.font, at: run.location, effectiveRange: nil) as? NSFont) ?? .systemFont(ofSize: 14)
        let middle = baseline - font.xHeight / 2
        return CGRect(x: bounds.minX + 2, y: middle - image.display.height / 2, width: image.display.width,
                      height: image.display.height)
    }

    /// The picture filling its rounded frame, cropped rather than squeezed.
    private func drawPicture(_ image: NoteImage, in frame: CGRect, radius: CGFloat) {
        MainActor.assumeIsolated {
            guard let picture = NoteImages.image(for: image.url) else { return }
            let scale = max(frame.width / max(image.size.width, 1), frame.height / max(image.size.height, 1))
            let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let rect = CGRect(x: frame.midX - drawn.width / 2, y: frame.midY - drawn.height / 2, width: drawn.width, height: drawn.height)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).addClip()
            picture.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            NSColor(white: 1, alpha: 0.1).setStroke()
            let outline = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
            outline.lineWidth = 1
            outline.stroke()
        }
    }

    /// The image under a point, block or inline, and the character it hangs on.
    func image(at point: CGPoint) -> (image: NoteImage, index: Int)? {
        guard let storage = textStorage, let container = textContainers.first, storage.length > 0 else { return nil }
        let glyph = glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: nil)
        let character = characterIndexForGlyph(at: glyph)
        for index in [character, character - 1, character + 1] where index >= 0 && index < storage.length {
            var run = NSRange()
            if let image = storage.attribute(.mdImage, at: index, longestEffectiveRange: &run,
                                             in: NSRange(location: 0, length: storage.length)) as? NoteImage,
               blockImageFrame(for: run, image: image)?.contains(point) == true {
                return (image, run.location)
            }
            if let image = storage.attribute(.mdInlineImage, at: index, effectiveRange: nil) as? NoteImage,
               inlineImageFrame(for: NSRange(location: index, length: 1), image: image)?.insetBy(dx: -2, dy: -2).contains(point) == true {
                return (image, index)
            }
        }
        return nil
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        storage.enumerateAttribute(.mdCheckbox, in: characters) { value, run, _ in
            guard let checked = value as? Bool, let box = markRect(for: run, origin: origin, side: 14) else { return }
            let alpha = (storage.attribute(.mdFading, at: run.location, effectiveRange: nil) as? String)
                .flatMap { fadeAlphas[$0] } ?? 1
            guard alpha < 1, let context = NSGraphicsContext.current?.cgContext else { return drawCheckbox(in: box, checked: checked) }
            context.saveGState()
            context.setAlpha(alpha)
            drawCheckbox(in: box, checked: checked)
            context.restoreGState()
        }

        storage.enumerateAttribute(.mdBullet, in: characters) { value, run, _ in
            guard value != nil, let dot = markRect(for: run, origin: origin, side: 5) else { return }
            MarkdownTheme.text.withAlphaComponent(0.6).setFill()
            NSBezierPath(ovalIn: dot).fill()
        }

        storage.enumerateAttribute(.mdRule, in: characters) { value, run, _ in
            guard value != nil else { return }
            let glyphs = glyphRange(forCharacterRange: run, actualCharacterRange: nil)
            let line = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil).offsetBy(dx: origin.x, dy: origin.y)
            let rule = CGRect(x: origin.x + container.lineFragmentPadding, y: line.midY.rounded() - 0.5,
                              width: container.size.width - container.lineFragmentPadding * 2, height: 1)
            NSColor(white: 1, alpha: 0.14).setFill()
            rule.fill()
        }
    }

    /// A square of `side` centred on the run's glyphs, at the text's mid-height.
    private func markRect(for run: NSRange, origin: NSPoint, side: CGFloat) -> CGRect? {
        guard let container = textContainers.first, let storage = textStorage else { return nil }
        let glyphs = glyphRange(forCharacterRange: run, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let bounds = boundingRect(forGlyphRange: glyphs, in: container)
        let line = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let baseline = line.minY + location(forGlyphAt: glyphs.location).y
        let font = (storage.attribute(.font, at: run.location, effectiveRange: nil) as? NSFont) ?? .systemFont(ofSize: 14)
        let midY = baseline - font.xHeight / 2
        let midX = run.length > 1 ? bounds.minX + side / 2 + 0.5 : bounds.midX
        return CGRect(x: midX - side / 2 + origin.x, y: midY - side / 2 + origin.y, width: side, height: side).integral
    }

    private func drawCheckbox(in rect: CGRect, checked: Bool) {
        let box = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        if checked {
            MarkdownTheme.accent.withAlphaComponent(0.85).setFill()
            box.fill()
            let tick = NSBezierPath()
            tick.move(to: CGPoint(x: rect.minX + 3.5, y: rect.midY + 0.2))
            tick.line(to: CGPoint(x: rect.minX + 6, y: rect.maxY - 3.6))
            tick.line(to: CGPoint(x: rect.maxX - 3.2, y: rect.minY + 3.8))
            tick.lineWidth = 1.7
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            NSColor(white: 0.08, alpha: 0.9).setStroke()
            tick.stroke()
        } else {
            NSColor(white: 1, alpha: 0.05).setFill()
            box.fill()
            NSColor(white: 1, alpha: 0.38).setStroke()
            box.lineWidth = 1.2
            box.stroke()
        }
    }

    /// The checkbox under a point in the text container, if any.
    func checkbox(at point: CGPoint) -> NSRange? {
        guard let storage = textStorage, let container = textContainers.first, storage.length > 0 else { return nil }
        let glyph = glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: nil)
        let character = characterIndexForGlyph(at: glyph)
        for index in [character, character - 1, character + 1] where index >= 0 && index < storage.length {
            var run = NSRange()
            guard storage.attribute(.mdCheckbox, at: index, longestEffectiveRange: &run,
                                    in: NSRange(location: 0, length: storage.length)) != nil,
                  let box = markRect(for: run, origin: .zero, side: 14), box.insetBy(dx: -5, dy: -4).contains(point) else { continue }
            return run
        }
        return nil
    }

    /// The destination of the link under a point, while it reads as a link
    /// (its syntax hidden); revealed, it's text being edited.
    func link(at point: CGPoint) -> String? {
        guard let storage = textStorage, let container = textContainers.first, storage.length > 0 else { return nil }
        var fraction: CGFloat = 0
        let glyph = glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &fraction)
        let rect = boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard rect.insetBy(dx: -1, dy: -2).contains(point) else { return nil }
        let character = characterIndexForGlyph(at: glyph)
        guard character < storage.length else { return nil }
        return storage.attribute(.mdLink, at: character, effectiveRange: nil) as? String
    }
}

/// The note's text view: markdown-aware editing on top of NSTextView.
final class NoteTextView: NSTextView {
    /// Files dropped or pasted on the text go to the note's bucket.
    weak var fileHandler: NoteFileHandling?
    var options = EditorOptions()
    lazy var tidier = TaskTidier(textView: self)

    /// The checker's marks, except on code, links, #tags and hidden syntax.
    override func setSpellingState(_ value: Int, range charRange: NSRange) {
        if value != 0, isExemptFromSpelling(charRange) { return }
        super.setSpellingState(value, range: charRange)
    }

    var markdownLayout: MarkdownLayoutManager? { layoutManager as? MarkdownLayoutManager }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Focus

    /// Called when focus or the selection changes, to reveal syntax where the caret is.
    var onRevealChange: (() -> Void)?
    /// Opens a link's destination, resolved against the note's bucket.
    var openLink: ((String) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onRevealChange?() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onRevealChange?() } } }
        return resigned
    }

    /// Tests stand in for a key window, which a test process can't have.
    var assumesFocus = false

    var isFocused: Bool { assumesFocus || (window?.isKeyWindow == true && window?.firstResponder === self) }

    func updateActiveRange() { onRevealChange?() }

    // MARK: Clicks

    override func mouseDown(with event: NSEvent) {
        let point = containerPoint(for: event)
        if let layout = markdownLayout {
            // A picture keeps showing when clicked: the caret stays where it was.
            if let hit = layout.image(at: point) {
                window?.makeFirstResponder(self)
                if event.clickCount == 2 { peek(hit.image, at: hit.index) }
                return
            }
            if let box = layout.checkbox(at: point) {
                toggleCheckbox(box)
                return
            }
            if let destination = layout.link(at: point) {
                openLink?(destination)
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let hit = markdownLayout?.image(at: containerPoint(for: event)),
              let markup = MarkdownStyler.imageMarkup(at: hit.index, in: string as NSString) else { return super.menu(for: event) }
        return imageMenu(hit.image, markup: markup.range)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = containerPoint(for: event)
        if markdownLayout?.image(at: point) != nil {
            NSCursor.arrow.set()
            return
        }
        if let layout = markdownLayout, layout.checkbox(at: point) != nil || layout.link(at: point) != nil {
            NSCursor.pointingHand.set()
            return
        }
        super.mouseMoved(with: event)
    }

    private func containerPoint(for event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
    }

    /// Checking and the move that follows are one step for ⌘Z.
    private func toggleCheckbox(_ box: NSRange) {
        let current = (string as NSString).substring(with: box).lowercased()
        undoManager?.beginUndoGrouping()
        replace(box, with: current == "[x]" ? "[ ]" : "[x]", keepingSelection: true)
        tidier.taskToggled(at: box.location, options: options)
        undoManager?.endUndoGrouping()
    }

    /// Replaces text as one undoable step.
    /// Replaces text as one undoable step, then puts the selection at `selection`.
    func replace(_ range: NSRange, with replacement: String, selection target: NSRange) {
        replace(range, with: replacement)
        let length = (string as NSString).length
        let location = min(target.location, length)
        setSelectedRange(NSRange(location: location, length: min(target.length, length - location)))
    }

    func replace(_ range: NSRange, with replacement: String, keepingSelection: Bool = false) {
        let selection = selectedRange()
        // Its own step, not folded into the typing before it.
        breakUndoCoalescing()
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
        if keepingSelection {
            let delta = (replacement as NSString).length - range.length
            var kept = selection
            if selection.location >= NSMaxRange(range) { kept.location += delta }
            setSelectedRange(NSRange(location: min(kept.location, (string as NSString).length), length: 0))
        }
    }

    // MARK: Caret

    /// A task's `- ` is hidden even on the caret's line, so the caret never
    /// stops inside it: it lands after the box, and stepping left from there
    /// goes on to the line before.
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        guard ranges.count == 1, let range = ranges.first?.rangeValue, range.length == 0,
              let prefix = taskPrefix(ofLineAt: range.location),
              range.location >= prefix.location, range.location < NSMaxRange(prefix) else {
            return super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        }
        let previous = selectedRange()
        let movingLeft = previous.length == 0 && previous.location == NSMaxRange(prefix) && range.location < previous.location
        let target = movingLeft && prefix.location > 0 ? prefix.location - 1 : NSMaxRange(prefix)
        super.setSelectedRanges([NSValue(range: NSRange(location: target, length: 0))], affinity: affinity, stillSelecting: stillSelecting)
    }

    /// From the start of a task's line to the end of its box and the space after it.
    private func taskPrefix(ofLineAt location: Int) -> NSRange? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let string = storage.string as NSString
        let line = string.lineRange(for: NSRange(location: min(location, string.length), length: 0))
        var box = NSRange()
        var index = line.location
        while index < NSMaxRange(line), index < storage.length {
            if storage.attribute(.mdCheckbox, at: index, longestEffectiveRange: &box, in: line) != nil { break }
            guard storage.attribute(.mdHidden, at: index, effectiveRange: nil) != nil
                    || string.character(at: index) == 0x20 || string.character(at: index) == 0x09 else { return nil }
            index += 1
        }
        guard box.length > 0 else { return nil }
        var end = NSMaxRange(box)
        if end < NSMaxRange(line), string.character(at: end) == 0x20 { end += 1 }
        return NSRange(location: line.location, length: end - line.location)
    }

    // MARK: Lists

    private struct ListPrefix {
        var range: NSRange
        var next: String
    }

    /// The list or quote marker at the start of a line, and what the next line's would be.
    private func listPrefix(ofLineAt location: Int) -> ListPrefix? {
        let string = self.string as NSString
        let line = string.lineRange(for: NSRange(location: location, length: 0))
        let text = string.substring(with: line) as NSString
        let patterns: [(String, (NSTextCheckingResult, NSString) -> String)] = [
            (#"^([ \t]*)([-*+])([ \t]+)\[[ xX]\]([ \t]+|$)"#, { m, s in s.substring(with: m.range(at: 1)) + s.substring(with: m.range(at: 2)) + " [ ] " }),
            (#"^([ \t]*)([-*+])([ \t]+)"#, { m, s in s.substring(with: m.range(at: 1)) + s.substring(with: m.range(at: 2)) + " " }),
            (#"^([ \t]*)(\d{1,9})([.)])([ \t]+)"#, { m, s in
                s.substring(with: m.range(at: 1)) + String((Int(s.substring(with: m.range(at: 2))) ?? 0) + 1) + s.substring(with: m.range(at: 3)) + " "
            }),
            (#"^([ \t]*)>([ \t]?)"#, { m, s in s.substring(with: m.range(at: 1)) + "> " })
        ]
        for (pattern, next) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text as String, range: NSRange(location: 0, length: text.length)) else { continue }
            return ListPrefix(range: NSRange(location: line.location, length: match.range.length), next: next(match, text))
        }
        return nil
    }

    override func insertNewline(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length == 0, let prefix = listPrefix(ofLineAt: selection.location) else {
            return super.insertNewline(sender)
        }
        let string = self.string as NSString
        let line = string.lineRange(for: NSRange(location: selection.location, length: 0))
        var contentsEnd = 0
        string.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: line)
        guard selection.location >= NSMaxRange(prefix.range) else { return super.insertNewline(sender) }
        if contentsEnd == NSMaxRange(prefix.range) {
            // An empty item ends the list.
            replace(prefix.range, with: "")
            setSelectedRange(NSRange(location: prefix.range.location, length: 0))
            return
        }
        insertText("\n" + prefix.next, replacementRange: selection)
    }

    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length == 0, let prefix = listPrefix(ofLineAt: selection.location),
           selection.location == NSMaxRange(prefix.range), prefix.range.length > 0 {
            // Backspace right after a marker removes the marker, not one character of it.
            return replace(prefix.range, with: "")
        }
        super.deleteBackward(sender)
    }

    /// ⌘⌫ with nothing left before the caret on its line takes the line
    /// itself, joining it to the one above.
    override func deleteToBeginningOfLine(_ sender: Any?) {
        let before = string
        let selection = selectedRange()
        super.deleteToBeginningOfLine(sender)
        if string == before, selection.length == 0, selection.location > 0 { deleteBackward(sender) }
    }

    // MARK: Moving lines

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (event.keyCode, modifiers) {
        case (126, [.option]): moveLines(up: true)
        case (125, [.option]): moveLines(up: false)
        case (126, [.option, .shift]): copyLines(up: true)
        case (125, [.option, .shift]): copyLines(up: false)
        default: super.keyDown(with: event)
        }
    }

    /// The whole lines the selection touches, without the last one's line
    /// break, and whether there is one. A selection ending at the start of a
    /// line leaves that line out.
    private func selectedLines() -> (range: NSRange, text: String, hasBreak: Bool) {
        let string = self.string as NSString
        let selection = selectedRange()
        var end = NSMaxRange(selection)
        if selection.length > 0, end > 0, string.character(at: end - 1) == 0x0A { end -= 1 }
        let lines = string.lineRange(for: NSRange(location: selection.location, length: end - selection.location))
        let hasBreak = lines.length > 0 && string.character(at: NSMaxRange(lines) - 1) == 0x0A
        let text = string.substring(with: NSRange(location: lines.location, length: lines.length - (hasBreak ? 1 : 0)))
        return (lines, text, hasBreak)
    }

    /// ⌥↑ and ⌥↓: the selected lines trade places with the line above or below.
    func moveLines(up: Bool) {
        let string = self.string as NSString
        let selection = selectedRange()
        let (lines, text, hasBreak) = selectedLines()
        if up {
            guard lines.location > 0 else { return }
            let above = string.lineRange(for: NSRange(location: lines.location - 1, length: 0))
            let aboveText = string.substring(with: NSRange(location: above.location, length: above.length - 1))
            replace(NSRange(location: above.location, length: NSMaxRange(lines) - above.location),
                    with: text + "\n" + aboveText + (hasBreak ? "\n" : ""),
                    selection: NSRange(location: selection.location - above.length, length: selection.length))
        } else {
            guard hasBreak, NSMaxRange(lines) < string.length else { return }
            let below = string.lineRange(for: NSRange(location: NSMaxRange(lines), length: 0))
            let belowBreak = string.character(at: NSMaxRange(below) - 1) == 0x0A
            let belowText = string.substring(with: NSRange(location: below.location, length: below.length - (belowBreak ? 1 : 0)))
            replace(NSRange(location: lines.location, length: NSMaxRange(below) - lines.location),
                    with: belowText + "\n" + text + (belowBreak ? "\n" : ""),
                    selection: NSRange(location: selection.location + (belowText as NSString).length + 1, length: selection.length))
        }
        scrollRangeToVisible(selectedRange())
    }

    /// ⌥⇧↑ and ⌥⇧↓: a copy of the selected lines above or below them; the
    /// selection goes with the copy that's in that direction.
    func copyLines(up: Bool) {
        let selection = selectedRange()
        let (lines, text, hasBreak) = selectedLines()
        let shift = up ? 0 : (text as NSString).length + 1
        if hasBreak {
            replace(NSRange(location: NSMaxRange(lines), length: 0), with: text + "\n",
                    selection: NSRange(location: selection.location + shift, length: selection.length))
        } else {
            replace(NSRange(location: NSMaxRange(lines), length: 0), with: "\n" + text,
                    selection: NSRange(location: selection.location + shift, length: selection.length))
        }
        scrollRangeToVisible(selectedRange())
    }

    override func insertTab(_ sender: Any?) {
        guard selectedRange().length == 0, let prefix = listPrefix(ofLineAt: selectedRange().location) else {
            return super.insertTab(sender)
        }
        let caret = selectedRange().location
        replace(NSRange(location: prefix.range.location, length: 0), with: "  ")
        setSelectedRange(NSRange(location: caret + 2, length: 0))
    }

    override func insertBacktab(_ sender: Any?) {
        let string = self.string as NSString
        let caret = selectedRange().location
        let line = string.lineRange(for: NSRange(location: caret, length: 0))
        var spaces = 0
        while spaces < 2, line.location + spaces < string.length, string.character(at: line.location + spaces) == 0x20 { spaces += 1 }
        guard spaces > 0 else { return }
        replace(NSRange(location: line.location, length: spaces), with: "")
        setSelectedRange(NSRange(location: max(line.location, caret - spaces), length: 0))
    }

    // MARK: Formatting

    /// Wraps the selection in `marker`, or unwraps it when it's wrapped already.
    func toggleWrap(_ marker: String) {
        let string = self.string as NSString
        let selection = selectedRange()
        let length = (marker as NSString).length
        let before = NSRange(location: selection.location - length, length: length)
        let after = NSRange(location: NSMaxRange(selection), length: length)
        if before.location >= 0, NSMaxRange(after) <= string.length,
           string.substring(with: before) == marker, string.substring(with: after) == marker {
            replace(after, with: "")
            replace(before, with: "")
            setSelectedRange(NSRange(location: selection.location - length, length: selection.length))
            return
        }
        let selected = string.substring(with: selection)
        replace(selection, with: marker + selected + marker)
        setSelectedRange(NSRange(location: selection.location + length, length: selection.length))
    }

    /// Plain line → task → plain line; a bullet becomes a task. Indentation stays.
    func toggleTask() {
        let string = self.string as NSString
        let caret = selectedRange().location
        let line = string.lineRange(for: NSRange(location: caret, length: 0))
        let text = string.substring(with: line) as NSString
        var indent = 0
        while indent < text.length, [0x20, 0x09].contains(text.character(at: indent)) { indent += 1 }
        let rest = text.substring(from: indent)
        let start = line.location + indent
        func marker(_ pattern: String) -> Int? {
            guard let range = rest.range(of: pattern, options: .regularExpression) else { return nil }
            return (String(rest[range]) as NSString).length
        }
        let (length, replacement): (Int, String)
        if let task = marker(#"^[-*+][ \t]+\[[ xX]\][ \t]?"#) {
            (length, replacement) = (task, "")
        } else if let bullet = marker(#"^[-*+][ \t]+"#) {
            (length, replacement) = (bullet, "- [ ] ")
        } else {
            (length, replacement) = (0, "- [ ] ")
        }
        replace(NSRange(location: start, length: length), with: replacement)
        let shift = (replacement as NSString).length - length
        setSelectedRange(NSRange(location: max(start + (replacement as NSString).length, caret + shift), length: 0))
    }

    // MARK: Files

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if Attachments.carriesFiles(pasteboard), let fileHandler {
            fileHandler.attach(from: pasteboard, at: nil, insertingAt: selectedRange().location)
            return
        }
        pasteAsPlainText(sender)
    }

    /// Whether the current drag is NSTextView's own, text dragged about,
    /// so its exit and end go back to it and to nothing else.
    private var textDrag = false

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        textDrag = false
        if let operation = fileDrag(sender) { return operation }
        textDrag = true
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let operation = fileDrag(sender) { return operation }
        return super.draggingUpdated(sender)
    }

    /// Files over the text land where the pointer is, and the caret shows
    /// where. `nil` for anything else, which the text view takes as text.
    private func fileDrag(_ sender: NSDraggingInfo) -> NSDragOperation? {
        guard let fileHandler else { return nil }
        if isFromOwnBucket(sender) {
            // Over the open drawer it's still in the bucket, not on the text.
            guard fileHandler.acceptsBucketDrag(sender) else {
                fileHandler.bucketDragLeftText()
                return []
            }
            return followDrop(sender)
        }
        if referencesBucket(sender) { return followDrop(sender) }
        guard Attachments.carriesFiles(sender.draggingPasteboard) else { return nil }
        _ = followDrop(sender)
        return fileHandler.fileDragMoved(sender)
    }

    /// A file dragged out of this note's own bucket.
    private func isFromOwnBucket(_ sender: NSDraggingInfo) -> Bool {
        guard let fileHandler else { return false }
        return (sender.draggingSource as AnyObject?) === fileHandler
    }

    /// The last drag's answer to `referencesBucket`, so the pasteboard is read once per drag, not per move.
    private var bucketReference: (drag: Int, answer: Bool)?

    /// One of this note's bucket files from elsewhere, like Finder, goes into
    /// the text as a reference, not in again as a copy.
    private func referencesBucket(_ sender: NSDraggingInfo) -> Bool {
        if let bucketReference, bucketReference.drag == sender.draggingSequenceNumber { return bucketReference.answer }
        let answer = fileHandler?.bucketFiles(on: sender.draggingPasteboard).isEmpty == false
        bucketReference = (sender.draggingSequenceNumber, answer)
        return answer
    }

    private func dropIndex(_ sender: NSDraggingInfo) -> Int {
        characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
    }

    /// The caret follows the drag, so it's clear where the file lands. It
    /// only moves when the spot changes, so a drag doesn't restyle per move.
    private func followDrop(_ sender: NSDraggingInfo) -> NSDragOperation {
        let index = dropIndex(sender)
        if selectedRange() != NSRange(location: index, length: 0) { setSelectedRange(NSRange(location: index, length: 0)) }
        if window?.isKeyWindow == false { window?.makeKey() }
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if textDrag { return super.draggingExited(sender) }
        fileHandler?.fileDragEnded()
        if let sender, isFromOwnBucket(sender) { fileHandler?.bucketDragLeftText() }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if textDrag { return super.performDragOperation(sender) }
        guard let fileHandler else { return false }
        if isFromOwnBucket(sender) || referencesBucket(sender) {
            guard fileHandler.acceptsBucketDrag(sender) else { return false }
            let files = fileHandler.bucketFiles(on: sender.draggingPasteboard)
            guard !files.isEmpty else { return false }
            fileHandler.insertReferences(files, at: dropIndex(sender))
            return true
        }
        guard Attachments.carriesFiles(sender.draggingPasteboard) else { return false }
        return fileHandler.fileDropped(sender, insertingAt: dropIndex(sender))
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        if textDrag { return super.concludeDragOperation(sender) }
        fileHandler?.fileDragEnded()
    }
}

/// Where the note's file drops and pastes go.
@MainActor
protocol NoteFileHandling: AnyObject {
    func fileDragMoved(_ info: NSDraggingInfo) -> NSDragOperation
    /// Copies the dropped files into the bucket and writes them into the
    /// text at `index`, or at the caret when it's `nil`.
    func fileDropped(_ info: NSDraggingInfo, insertingAt index: Int?) -> Bool
    func fileDragEnded()
    func attach(from pasteboard: NSPasteboard, at point: CGPoint?, insertingAt index: Int?)
    /// Whether a drag of the note's own bucket files is over the text, not the open drawer.
    func acceptsBucketDrag(_ info: NSDraggingInfo) -> Bool
    /// A drag out of the bucket left the text: the drawer keeps the keys again.
    func bucketDragLeftText()
    /// Files on the pasteboard that are already in this note's bucket.
    func bucketFiles(on pasteboard: NSPasteboard) -> [URL]
    func insertReferences(_ urls: [URL], at index: Int)
    func sendToTray(_ urls: [URL])
}

/// The scroll view and text view for one note window, kept by its controller
/// so SwiftUI never rebuilds the editor.
@MainActor
final class MarkdownEditor: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
    let scrollView: NSScrollView
    let textView: NoteTextView
    private let styler = MarkdownStyler()
    /// Text changed by the edit in progress, styled once the edit is done.
    private var pendingStyle: NSRange?
    /// The lines last styled with their syntax showing, to hide again when the caret leaves.
    private var revealed: NSRange?
    private var styledWidth: CGFloat = 0
    private var fenceCount = 0
    var onChange: ((String) -> Void)?
    /// After the caret moves or text changes, once styling has caught up.
    var onCaretMove: (() -> Void)?
    /// The note's bucket: where bare file names in links and images point.
    var base: URL?
    private var isLoading = false

    override init() {
        let storage = NSTextStorage()
        let layout = MarkdownLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 4
        layout.addTextContainer(container)

        // The scroll view starts the size of the text view, so autoresizing
        // keeps them the same width from then on.
        scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        textView = NoteTextView(frame: CGRect(origin: .zero, size: scrollView.contentSize), textContainer: container)
        super.init()

        storage.delegate = self
        textView.delegate = self
        textView.minSize = .zero
        textView.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.insertionPointColor = MarkdownTheme.accent
        textView.textContainerInset = CGSize(width: 18, height: 8)
        textView.typingAttributes = styler.baseAttributes
        textView.selectedTextAttributes = [.backgroundColor: MarkdownTheme.accent.withAlphaComponent(0.28)]
        textView.linkTextAttributes = [:]
        textView.focusRingType = .none
        textView.postsFrameChangedNotifications = true
        textView.onRevealChange = { [weak self] in
            self?.revealSelection()
            self?.caret.update(animated: false)
        }
        textView.openLink = { [weak self] destination in
            guard let url = MarkdownStyler.resolve(destination, base: self?.base) else { return NSSound.beep() }
            NSWorkspace.shared.open(url)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(frameChanged), name: NSView.frameDidChangeNotification,
                                               object: textView)

        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.scrollerKnobStyle = .light
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 2, left: 0, bottom: 34, right: 0)
    }

    var text: String { textView.string }

    private(set) lazy var caret = GlideCaret(textView: textView)

    /// Blurs and dims the text on its own layer, on the GPU. SwiftUI effects on
    /// this view would re-host it, and the re-host loses the scroll position.
    /// The filter comes off once the text is sharp again, so typing never pays for it.
    func setFocus(blur: CGFloat, opacity: Float, duration: TimeInterval, from start: (blur: CGFloat, opacity: Float)? = nil,
                  easeIn: Bool = false) {
        guard let layer = scrollView.layer else { return }
        scrollView.layerUsesCoreImageFilters = true
        let current = layer.presentation()
        let fromBlur = start?.blur ?? (current?.value(forKeyPath: "filters.focus.inputRadius") as? CGFloat
            ?? layer.value(forKeyPath: "filters.focus.inputRadius") as? CGFloat ?? 0)
        let fromOpacity = start?.opacity ?? current?.opacity ?? layer.opacity
        let reduced = NoteMotion.reduced
        let targetBlur = reduced ? 0 : blur
        if layer.filters?.isEmpty ?? true, fromBlur > 0 || targetBlur > 0 {
            let filter = CIFilter(name: "CIGaussianBlur")!
            filter.name = "focus"
            layer.filters = [filter]
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak layer] in
            guard let layer, (layer.value(forKeyPath: "filters.focus.inputRadius") as? CGFloat ?? 0) == 0 else { return }
            layer.filters = nil
        }
        if layer.filters?.isEmpty == false { layer.setValue(targetBlur, forKeyPath: "filters.focus.inputRadius") }
        layer.opacity = opacity
        let timing = CAMediaTimingFunction(name: easeIn ? .easeIn : .easeOut)
        if layer.filters?.isEmpty == false, fromBlur != targetBlur {
            let animation = CABasicAnimation(keyPath: "filters.focus.inputRadius")
            animation.fromValue = fromBlur
            animation.toValue = targetBlur
            animation.duration = duration
            animation.timingFunction = timing
            layer.add(animation, forKey: "focusBlur")
        }
        if fromOpacity != opacity {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = fromOpacity
            animation.toValue = opacity
            animation.duration = duration
            animation.timingFunction = timing
            layer.add(animation, forKey: "focusOpacity")
        }
        CATransaction.commit()
    }

    func apply(_ options: EditorOptions) {
        textView.options = options
        caret.isEnabled = options.cursorGlide
        if textView.isContinuousSpellCheckingEnabled != options.checkSpelling {
            textView.isContinuousSpellCheckingEnabled = options.checkSpelling
        }
        textView.inlinePredictionType = options.predictiveText ? .yes : .no
    }

    /// Shows a note's text, scrolled to the top, with a fresh undo history.
    func load(_ text: String) {
        textView.tidier.reset()
        isLoading = true
        textView.string = text
        isLoading = false
        pendingStyle = NSRange(location: 0, length: (text as NSString).length)
        fenceCount = MarkdownStyler.fenceCount(in: text as NSString)
        revealed = nil
        flushStyle()
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        textView.scrollToBeginningOfDocument(nil)
    }

    /// New text for the same note, from elsewhere: the selection and scroll
    /// stay where they were, and it isn't an undoable edit. The undo history
    /// goes, since its ranges were for the old text.
    func replaceText(_ text: String) {
        guard text != textView.string else { return }
        let selection = textView.selectedRange()
        let scroll = scrollView.contentView.bounds.origin
        textView.tidier.reset()
        isLoading = true
        textView.string = text
        isLoading = false
        pendingStyle = NSRange(location: 0, length: (text as NSString).length)
        fenceCount = MarkdownStyler.fenceCount(in: text as NSString)
        flushStyle()
        textView.undoManager?.removeAllActions()
        let length = (text as NSString).length
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        scrollView.contentView.scroll(to: scroll)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        caret.update(animated: false)
    }

    func focus(atEnd: Bool) {
        textView.window?.makeFirstResponder(textView)
        if atEnd {
            let end = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: end, length: 0))
            textView.scrollRangeToVisible(NSRange(location: end, length: 0))
        }
    }

    // MARK: Styling

    private var context: MarkdownStyler.Context {
        let container = textView.textContainer
        let width = (container?.size.width ?? 300) - 2 * (container?.lineFragmentPadding ?? 4)
        return MarkdownStyler.Context(selection: textView.isFocused ? textView.selectedRange() : nil,
                                      width: max(80, width), base: base)
    }

    /// The selection's paragraphs, grown to whole code blocks, which reveal together.
    private func revealRange(for selection: NSRange?) -> NSRange? {
        guard let selection else { return nil }
        let string = textView.string as NSString
        let start = min(selection.location, string.length)
        var range = string.paragraphRange(for: NSRange(location: start, length: min(selection.length, string.length - start)))
        for block in MarkdownStyler.codeBlocks(in: string) where NSIntersectionRange(block, range).length > 0
            || NSLocationInRange(range.location, block) {
            range = NSUnionRange(range, block)
        }
        return range
    }

    /// Restyles `range` with the syntax revealed around the selection.
    private func restyle(_ range: NSRange) {
        guard let storage = textView.textStorage, storage.length > 0, range.location <= storage.length else { return }
        let clamped = NSRange(location: range.location, length: min(range.length, storage.length - range.location))
        // An attribute-only edit, after any text edit is done: it moves no caret.
        storage.beginEditing()
        styler.style(storage, in: clamped, context: context)
        storage.endEditing()
        styledWidth = context.width
    }

    /// Shows syntax where the caret now is and hides it where it was.
    private func revealSelection() {
        // Inside an edit, the edit's own styling pass covers it.
        guard pendingStyle == nil else { return }
        let target = revealRange(for: context.selection)
        let ranges = [revealed, target].compactMap { $0 }
        revealed = target
        guard let first = ranges.first else { return }
        restyle(ranges.dropFirst().reduce(first, NSUnionRange))
    }

    /// Styles what the last edit touched, after the text view has placed the caret.
    private func flushStyle() {
        guard let range = pendingStyle else { return }
        pendingStyle = nil
        let target = revealRange(for: context.selection)
        let all = [range, revealed, target].compactMap { $0 }.reduce(range) { NSUnionRange($0, $1) }
        revealed = target
        restyle(all)
    }

    /// Images fit the text's width, so a resize that changes it restyles them.
    @objc private func frameChanged() {
        defer { caret.update(animated: false) }
        guard abs(context.width - styledWidth) > 1, textView.string.contains("![") else { return }
        restyle(NSRange(location: 0, length: (textView.string as NSString).length))
    }

    /// Text storage edits only ever happen on the main thread, from the text view.
    nonisolated func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
                                 range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            let string = textStorage.mutableString as NSString
            // Lines after the edit moved; keep the revealed lines pointing at the same text.
            if var shown = revealed {
                let editStart = editedRange.location
                if shown.location > editStart {
                    shown.location = max(0, shown.location + delta)
                } else if NSMaxRange(shown) >= editStart {
                    shown.length = max(0, shown.length + delta)
                }
                revealed = shown
            }
            // A fence opening or closing changes every line below it.
            var range = editedRange
            let paragraph = string.paragraphRange(for: editedRange)
            let count = MarkdownStyler.fenceCount(in: string)
            if count != fenceCount || (string.substring(with: paragraph) as NSString).range(of: "```").location != NSNotFound {
                range = NSRange(location: paragraph.location, length: string.length - paragraph.location)
            } else if let block = MarkdownStyler.codeBlocks(in: string).first(where: { NSLocationInRange(paragraph.location, $0) }) {
                // A quote or "/*" typed in code changes the colours of the lines after it.
                range = NSUnionRange(range, block)
            }
            fenceCount = count
            // Not styled here: attributes set inside the edit widen its range to
            // the whole line, and the text view puts the caret at the end of
            // whatever range changed, past what was typed.
            if let pending = pendingStyle { range = NSUnionRange(range, pending) }
            pendingStyle = range
            // Text changed without an edit notification (marked text) still gets styled.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.flushStyle() }
            }
        }
    }

    func textDidChange(_ notification: Notification) {
        flushStyle()
        caret.update()
        onCaretMove?()
        guard !isLoading else { return }
        onChange?(textView.string)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        revealSelection()
        // Mid-edit the line isn't styled yet; the edit's own pass moves the caret.
        if pendingStyle == nil {
            caret.update()
            onCaretMove?()
        }
        // New text picks up plain attributes; the styler takes it from there.
        textView.typingAttributes = styler.baseAttributes
    }
}
