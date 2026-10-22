import AppKit
import QuartzCore

/// The editor settings, as the text view needs them.
struct EditorOptions: Equatable {
    var cursorGlide = true
    var checkSpelling = true
    var predictiveText = false
    var moveCompletedTasks = false
    var clearCompletedTasks = false
}

// MARK: Cursor glide

/// A caret that slides to where the text moves it instead of jumping,
/// animated on the render server. The system caret stays hidden while it's on.
@MainActor
final class GlideCaret {
    private let view = CaretView()
    private weak var textView: NoteTextView?
    private var lastFrame: CGRect?
    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            textView?.insertionPointColor = isEnabled ? .clear : MarkdownTheme.accent
            view.isHidden = !isEnabled
            lastFrame = nil
            update(animated: false)
        }
    }

    init(textView: NoteTextView) {
        self.textView = textView
        view.isHidden = true
        textView.addSubview(view)
    }

    /// Moves the caret to the selection, gliding when `animated`, and restarts
    /// its blink so it stays solid while you type.
    func update(animated: Bool = true) {
        guard isEnabled, let textView, let layout = textView.layoutManager as? MarkdownLayoutManager,
              let container = textView.textContainer else { return }
        let selection = textView.selectedRange()
        guard textView.isFocused, selection.length == 0,
              let rect = layout.insertionRect(at: selection.location, in: container,
                                              upstream: textView.selectionAffinity == .upstream) else {
            view.isHidden = true
            lastFrame = nil
            return
        }
        let origin = textView.textContainerOrigin
        let frame = CGRect(x: (rect.minX + origin.x - 1).rounded(.down), y: rect.minY + origin.y, width: 2, height: rect.height)
        let wasHidden = view.isHidden
        view.isHidden = false
        guard frame != lastFrame else { return view.restartBlink() }
        let glide = animated && !wasHidden && lastFrame != nil && !NoteMotion.reduced
            // A jump across the note is a click, not typing: it lands at once.
            && abs(frame.midY - (lastFrame?.midY ?? 0)) < 80
        lastFrame = frame
        if glide {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.09
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.3, 1)
                context.allowsImplicitAnimation = true
                view.animator().frame = frame
            }
        } else {
            // A jump replaces any glide still on its way.
            view.layer?.removeAllAnimations()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            view.frame = frame
            CATransaction.commit()
        }
        view.restartBlink()
    }

    func hide() {
        view.isHidden = true
        lastFrame = nil
    }
}

private final class CaretView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = MarkdownTheme.accent.cgColor
        layer?.cornerRadius = 1
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Solid for half a second after each move, then the system's rhythm.
    func restartBlink() {
        guard let layer else { return }
        layer.removeAnimation(forKey: "blink")
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [1, 0, 1]
        blink.keyTimes = [0, 0.5, 1]
        blink.calculationMode = .discrete
        blink.duration = 1.06
        blink.repeatCount = .infinity
        blink.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + 0.5
        layer.add(blink, forKey: "blink")
    }
}

extension MarkdownLayoutManager {
    /// Where the caret sits before the character at `index`, in container
    /// coordinates, as tall as the text it's in.
    func insertionRect(at index: Int, in container: NSTextContainer, upstream: Bool = false) -> CGRect? {
        guard let storage = textStorage else { return nil }
        let length = storage.length
        let string = storage.string as NSString
        let fallback = MarkdownTheme().body
        func height(of font: NSFont) -> CGFloat { ceil(font.ascender - font.descender) }

        // An empty note, or a new last line: the extra line fragment.
        if length == 0 || (index >= length && string.character(at: length - 1) == 0x0A) {
            ensureLayout(for: container)
            let extra = extraLineFragmentRect
            guard extra.height > 0 else { return nil }
            return CGRect(x: extra.minX + container.lineFragmentPadding, y: extra.minY + 1, width: 2, height: height(of: fallback))
        }
        // A picture's line holds no visible text: the caret stands beside the
        // picture, a line of text tall, along its bottom.
        if let (run, image) = imageLine(at: index, in: storage), let frame = blockImageFrame(for: run, image: image) {
            let tall = height(of: fallback)
            let x = index <= run.location ? max(0, frame.minX - 4) : frame.maxX + 3
            return CGRect(x: x, y: frame.maxY - tall, width: 2, height: tall)
        }
        let character = min(index, length - 1)
        let glyph = glyphIndexForCharacter(at: character)
        ensureLayout(forGlyphRange: NSRange(location: glyph, length: 1))
        var fragment = NSRange()
        let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: &fragment)
        // At a soft wrap the caret can belong to the end of the line above, as
        // after ⌘→ or a click past the line's end.
        if upstream, index < length, index > 0, glyph == fragment.location, glyph > 0,
           string.character(at: index - 1) != 0x0A {
            let previous = glyph - 1
            let above = lineFragmentRect(forGlyphAt: previous, effectiveRange: nil)
            let font = (storage.attribute(.font, at: index - 1, effectiveRange: nil) as? NSFont) ?? fallback
            let x = boundingRect(forGlyphRange: NSRange(location: previous, length: 1), in: container).maxX
            let baseline = above.minY + location(forGlyphAt: previous).y
            return CGRect(x: x, y: baseline - font.ascender, width: 2, height: height(of: font))
        }
        let position = location(forGlyphAt: glyph)
        // The caret takes the size of the text before it, as typing would.
        let fontIndex = index > 0 && string.character(at: index - 1) != 0x0A ? index - 1 : character
        let font = (storage.attribute(.font, at: fontIndex, effectiveRange: nil) as? NSFont) ?? fallback
        let x: CGFloat
        if index >= length {
            // Where the last character sits plus its width: a hidden one has
            // none, and its bounding box would be empty, not where it is.
            let width = boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).width
            x = line.minX + position.x + width
        } else {
            x = line.minX + position.x
        }
        let baseline = line.minY + position.y
        return CGRect(x: x, y: baseline - font.ascender, width: 2, height: height(of: font))
    }

    /// The picture whose line `index` is on, from its start to the end of its markdown.
    private func imageLine(at index: Int, in storage: NSTextStorage) -> (NSRange, NoteImage)? {
        let string = storage.string as NSString
        for probe in [index, index - 1] where probe >= 0 && probe < storage.length {
            var run = NSRange()
            guard let image = storage.attribute(.mdImage, at: probe, longestEffectiveRange: &run,
                                                in: NSRange(location: 0, length: storage.length)) as? NoteImage else { continue }
            var end = NSMaxRange(run)
            if end > run.location, string.character(at: end - 1) == 0x0A { end -= 1 }
            if index >= run.location, index <= end { return (run, image) }
        }
        return nil
    }
}

// MARK: Completed tasks

extension NSAttributedString.Key {
    /// A checked task's line while it fades out, before it's removed. The
    /// value names the fade; it travels with the text as you type around it.
    static let mdFading = NSAttributedString.Key("xnotch.md.fading")
}

/// What happens to a task once it's checked: it moves below its list, or
/// fades and goes.
@MainActor
final class TaskTidier {
    private weak var textView: NoteTextView?
    private struct Fading {
        let id: String
        let start: CFTimeInterval
        var tinted: NSRange?
    }
    private var fading: [Fading] = []
    private var timer: Timer?
    private static let fadeDuration: CFTimeInterval = 1

    init(textView: NoteTextView) {
        self.textView = textView
    }

    private static let taskLine = try! NSRegularExpression(pattern: #"^([ \t]*)[-*+][ \t]+\[([ xX])\]"#)

    /// The task on the line at `location`: its indent, and whether it's done.
    private func task(at location: Int, in string: NSString) -> (indent: Int, checked: Bool, range: NSRange)? {
        let line = string.lineRange(for: NSRange(location: min(location, string.length), length: 0))
        let text = string.substring(with: line) as NSString
        guard let match = Self.taskLine.firstMatch(in: text as String, range: NSRange(location: 0, length: text.length)) else {
            return nil
        }
        return (match.range(at: 1).length, text.substring(with: match.range(at: 2)).lowercased() == "x", line)
    }

    private static func indent(of line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.count
    }

    /// A checkbox at `location` was just checked or unchecked.
    func taskToggled(at location: Int, options: EditorOptions) {
        guard let textView else { return }
        let string = textView.string as NSString
        guard let task = task(at: location, in: string) else { return }
        if task.checked, options.clearCompletedTasks {
            startFading(task.range)
        } else {
            if !task.checked { cancelFading(on: task.range) }
            if options.moveCompletedTasks { reorder(at: location) }
        }
    }

    /// Done tasks below the rest of their list; unchecking brings one back up
    /// above them. A task moves with the lines indented under it.
    private func reorder(at location: Int) {
        guard let textView else { return }
        let string = textView.string as NSString
        guard let moving = task(at: location, in: string) else { return }
        let indent = moving.indent
        func belongs(_ line: NSRange) -> Bool {
            let text = string.substring(with: line)
            if let sibling = task(at: line.location, in: string), sibling.indent == indent { return true }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && Self.indent(of: text) > indent
        }
        // The run of sibling tasks around it, with what's nested under each.
        var start = moving.range.location
        while start > 0 {
            let previous = string.lineRange(for: NSRange(location: start - 1, length: 0))
            guard belongs(previous) else { break }
            start = previous.location
        }
        var end = NSMaxRange(moving.range)
        while end < string.length {
            let next = string.lineRange(for: NSRange(location: end, length: 0))
            guard belongs(next) else { break }
            end = NSMaxRange(next)
        }
        // Units: a sibling task and its nested lines, by position, not text,
        // so two identical tasks can't be mistaken for each other.
        struct Unit { var range: NSRange; var checked: Bool }
        var units: [Unit] = []
        var cursor = start
        while cursor < end {
            let line = string.lineRange(for: NSRange(location: cursor, length: 0))
            if let sibling = task(at: cursor, in: string), sibling.indent == indent {
                units.append(Unit(range: line, checked: sibling.checked))
            } else if !units.isEmpty {
                units[units.count - 1].range.length += line.length
            } else {
                start = NSMaxRange(line) // nested lines above the first sibling aren't ours
            }
            cursor = NSMaxRange(line)
        }
        guard let from = units.firstIndex(where: { $0.range.location == moving.range.location }) else { return }
        let block = NSRange(location: start, length: end - start)
        let endsWithNewline = block.length > 0 && string.character(at: NSMaxRange(block) - 1) == 0x0A
        var texts = units.map { string.substring(with: $0.range) }
        if !endsWithNewline { texts[texts.count - 1] += "\n" }
        var order = Array(units.indices)
        order.remove(at: from)
        let to = moving.checked ? order.count : (order.firstIndex { units[$0].checked } ?? order.count)
        guard to != from else { return }
        order.insert(from, at: to)
        var rebuilt = order.map { texts[$0] }.joined()
        if !endsWithNewline { rebuilt.removeLast() }

        // The caret goes with its line.
        let selection = textView.selectedRange()
        var newSelection = selection
        if NSLocationInRange(selection.location, block) || (selection.location == NSMaxRange(block) && !endsWithNewline) {
            let old = units.firstIndex { NSLocationInRange(selection.location, $0.range) } ?? units.count - 1
            let offset = selection.location - units[old].range.location
            let newStart = order.prefix { $0 != old }.reduce(block.location) { $0 + (texts[$1] as NSString).length }
            let fitsInLine = offset + selection.length <= units[old].range.length
            newSelection = NSRange(location: newStart + offset, length: fitsInLine ? selection.length : 0)
        }
        textView.replace(block, with: rebuilt, selection: newSelection)
    }

    // MARK: Fading

    private func startFading(_ line: NSRange) {
        guard let storage = textView?.textStorage else { return }
        let id = UUID().uuidString
        // Tagged in the text, so the fade follows the line through any typing.
        storage.addAttribute(.mdFading, value: id, range: line)
        fading.append(Fading(id: id, start: CACurrentMediaTime()))
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                // The note closed mid-fade: nothing left to fade.
                guard let self else { return timer.invalidate() }
                self.step()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Where a fade's line is now, if it's still there.
    private func range(of id: String) -> NSRange? {
        guard let storage = textView?.textStorage, storage.length > 0 else { return nil }
        var found: NSRange?
        storage.enumerateAttribute(.mdFading, in: NSRange(location: 0, length: storage.length)) { value, run, stop in
            guard value as? String == id else { return }
            found = run
            stop.pointee = true
        }
        return found
    }

    private func cancelFading(on line: NSRange) {
        guard let storage = textView?.textStorage else { return }
        for item in fading {
            guard let found = range(of: item.id), NSIntersectionRange(found, line).length > 0 else { continue }
            end(item, removingTag: found)
            storage.removeAttribute(.mdFading, range: found)
        }
        fading.removeAll { range(of: $0.id) == nil }
    }

    private func step() {
        guard let textView, let storage = textView.textStorage else { return stop() }
        let now = CACurrentMediaTime()
        // A line isn't pulled out from under a drag.
        let dragging = NSEvent.pressedMouseButtons != 0
        var remaining: [Fading] = []
        var finished: [(Fading, NSRange)] = []
        for var item in fading {
            guard let line = range(of: item.id) else {
                end(item, removingTag: nil)
                continue
            }
            let progress = min(1, (now - item.start) / Self.fadeDuration)
            // Eases in, so it reads as done before it goes.
            tint(&item, line: line, alpha: CGFloat(1 - progress * progress))
            if progress >= 1, !dragging {
                finished.append((item, line))
            } else {
                remaining.append(item)
            }
        }
        fading = remaining
        // Bottom first, so removing one doesn't move the next.
        for (item, tagged) in finished.sorted(by: { $0.1.location > $1.1.location }) {
            let string = storage.string as NSString
            let line = string.lineRange(for: NSRange(location: tagged.location, length: 0))
            end(item, removingTag: tagged)
            storage.removeAttribute(.mdFading, range: tagged)
            // Unchecked or rewritten since, it stays.
            guard task(at: line.location, in: string)?.checked == true else { continue }
            var removal = line
            if string.character(at: NSMaxRange(line) - 1) != 0x0A, line.location > 0 {
                removal = NSRange(location: line.location - 1, length: line.length + 1)
            }
            let selection = textView.selectedRange()
            var kept = selection
            if selection.location >= NSMaxRange(removal) {
                kept.location -= removal.length
            } else if NSMaxRange(selection) > removal.location {
                kept = NSRange(location: removal.location, length: 0)
            }
            textView.replace(removal, with: "", selection: kept)
        }
        if fading.isEmpty { stop() }
    }

    private func tint(_ item: inout Fading, line: NSRange, alpha: CGFloat) {
        guard let layout = textView?.markdownLayout else { return }
        if let old = item.tinted, old != line { layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: old) }
        layout.fadeAlphas[item.id] = alpha
        layout.addTemporaryAttribute(.foregroundColor, value: MarkdownTheme.done.withAlphaComponent(0.36 * alpha),
                                     forCharacterRange: line)
        item.tinted = line
        layout.invalidateDisplay(forCharacterRange: line)
    }

    private func end(_ item: Fading, removingTag tagged: NSRange?) {
        guard let layout = textView?.markdownLayout else { return }
        layout.fadeAlphas[item.id] = nil
        for range in [item.tinted, tagged].compactMap({ $0 }) {
            let length = textView?.textStorage?.length ?? 0
            let clamped = NSRange(location: min(range.location, length), length: min(range.length, max(0, length - range.location)))
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: clamped)
            layout.invalidateDisplay(forCharacterRange: clamped)
        }
    }

    /// Drops every fade, for a note being swapped in.
    func reset() {
        if let storage = textView?.textStorage, storage.length > 0 {
            storage.removeAttribute(.mdFading, range: NSRange(location: 0, length: storage.length))
        }
        for item in fading { end(item, removingTag: nil) }
        fading.removeAll()
        stop()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: Spelling

extension NoteTextView {
    /// Code, links, hidden syntax, file names and #tags aren't prose: the
    /// checker's marks are dropped there.
    func isExemptFromSpelling(_ range: NSRange) -> Bool {
        guard let storage = textStorage, range.location < storage.length else { return false }
        let clamped = NSRange(location: range.location, length: min(range.length, storage.length - range.location))
        var exempt = false
        storage.enumerateAttributes(in: clamped) { attributes, _, stop in
            if attributes[.mdCodeSpan] != nil || attributes[.mdCodeBlock] != nil || attributes[.mdLink] != nil
                || attributes[.underlineStyle] != nil || attributes[.mdHidden] != nil || attributes[.mdImage] != nil {
                exempt = true
                stop.pointee = true
            }
        }
        if exempt { return true }
        let string = storage.string as NSString
        // A #tag, or a word glued to a path or file name.
        if clamped.location > 0, string.character(at: clamped.location - 1) == 0x23 { return true }
        let word = string.substring(with: clamped)
        return word.contains("/") || word.contains("_")
    }
}

// MARK: Whole-note task edits

/// Task edits across a whole note, as pure text: a task moves or goes with
/// the lines indented under it.
enum TaskText {
    private static let task = try! NSRegularExpression(pattern: #"^([ \t]*)[-*+][ \t]+\[([ xX])\]"#)

    private struct Line {
        var text: String
        var task: (indent: Int, checked: Bool)?
        var indent: Int { text.prefix { $0 == " " || $0 == "\t" }.count }
        var isBlank: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private static func lines(_ text: String) -> [Line] {
        text.components(separatedBy: "\n").map { line in
            let ns = line as NSString
            guard let match = task.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
                return Line(text: line, task: nil)
            }
            return Line(text: line, task: (match.range(at: 1).length, ns.substring(with: match.range(at: 2)).lowercased() == "x"))
        }
    }

    /// A task line and the lines nested under it.
    private static func unitEnd(_ lines: [Line], from start: Int) -> Int {
        guard let indent = lines[start].task?.indent else { return start + 1 }
        var end = start + 1
        while end < lines.count, !lines[end].isBlank, lines[end].indent > indent { end += 1 }
        return end
    }

    /// Every checked task, and what's under it, removed.
    static func clearingCompleted(_ text: String) -> String {
        let all = lines(text)
        var kept: [Line] = []
        var index = 0
        while index < all.count {
            let end = unitEnd(all, from: index)
            if all[index].task?.checked != true { kept.append(contentsOf: all[index..<end]) }
            index = end
        }
        return kept.map(\.text).joined(separator: "\n")
    }

    /// In every run of sibling tasks, the done ones last, in their order.
    static func sortingCompleted(_ text: String) -> String {
        let all = lines(text)
        var result: [Line] = []
        var index = 0
        while index < all.count {
            guard let indent = all[index].task?.indent else {
                result.append(all[index])
                index += 1
                continue
            }
            var open: [ArraySlice<Line>] = [], done: [ArraySlice<Line>] = []
            while index < all.count, all[index].task?.indent == indent {
                let end = unitEnd(all, from: index)
                if all[index].task?.checked == true { done.append(all[index..<end]) } else { open.append(all[index..<end]) }
                index = end
            }
            for unit in open + done { result.append(contentsOf: unit) }
        }
        return result.map(\.text).joined(separator: "\n")
    }

    static func uncheckingAll(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?m)^([ \t]*[-*+][ \t]+)\[[xX]\]"#, with: "$1[ ]", options: .regularExpression)
    }

    /// The note without its markdown, line by line.
    static func plain(_ text: String) -> String {
        var inCode = false
        return text.components(separatedBy: "\n").compactMap { line -> String? in
            if MarkdownStyler.isFence(line as NSString) {
                inCode.toggle()
                return nil
            }
            return inCode ? line : MarkdownText.strip(line)
        }.joined(separator: "\n")
    }
}

extension NoteTextView {
    /// Swaps the whole text in one undoable step, keeping the caret near where it was.
    func rewrite(_ transform: (String) -> String) {
        let old = string
        let new = transform(old)
        guard new != old else { return NSSound.beep() }
        let caret = selectedRange().location
        replace(NSRange(location: 0, length: (old as NSString).length), with: new)
        setSelectedRange(NSRange(location: min(caret, (new as NSString).length), length: 0))
        scrollRangeToVisible(selectedRange())
    }

    /// Text on a line of its own at the caret, with the caret placed `caretOffset` into it.
    func insertBlock(_ block: String, caretOffset: Int? = nil) {
        let text = string as NSString
        let selection = selectedRange()
        let lineStart = text.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let prefix = selection.location == lineStart ? "" : "\n"
        insertText(prefix + block, replacementRange: selection)
        if let caretOffset {
            setSelectedRange(NSRange(location: selection.location + (prefix as NSString).length + caretOffset, length: 0))
        }
    }
}
