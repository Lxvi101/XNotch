import AppKit
import ImageIO

extension NSAttributedString.Key {
    /// Characters drawn as nothing and taking no room: syntax the caret isn't touching.
    static let mdHidden = NSAttributedString.Key("xnotch.md.hidden")
    /// A task's `[ ]` or `[x]`, drawn as a box. The value is whether it's checked.
    static let mdCheckbox = NSAttributedString.Key("xnotch.md.checkbox")
    /// A list's `-`, drawn as a dot.
    static let mdBullet = NSAttributedString.Key("xnotch.md.bullet")
    /// A quote's line, drawn with a bar down its left.
    static let mdQuote = NSAttributedString.Key("xnotch.md.quote")
    /// A `---` line the caret isn't on, drawn as a hairline.
    static let mdRule = NSAttributedString.Key("xnotch.md.rule")
    /// Inline code, drawn on a rounded pill.
    static let mdCodeSpan = NSAttributedString.Key("xnotch.md.codespan")
    /// A fenced code block's lines, drawn on one rounded card.
    static let mdCodeBlock = NSAttributedString.Key("xnotch.md.codeblock")
    /// A collapsed opening fence's language, shown in the card's corner.
    static let mdCodeLanguage = NSAttributedString.Key("xnotch.md.codelanguage")
    /// A link's destination, opened on click while its syntax is hidden.
    static let mdLink = NSAttributedString.Key("xnotch.md.link")
    /// A line showing an image instead of its markdown. The value is a `NoteImage`.
    static let mdImage = NSAttributedString.Key("xnotch.md.image")
}

/// Mote's look, in TextKit terms.
struct MarkdownTheme {
    var bodySize: CGFloat = 14

    var body: NSFont { .systemFont(ofSize: bodySize) }
    var mono: NSFont { .monospacedSystemFont(ofSize: bodySize - 1.5, weight: .regular) }

    func heading(_ level: Int) -> NSFont {
        switch level {
        case 1: .systemFont(ofSize: bodySize + 9, weight: .bold)
        case 2: .systemFont(ofSize: bodySize + 5, weight: .bold)
        case 3: .systemFont(ofSize: bodySize + 2, weight: .semibold)
        default: .systemFont(ofSize: bodySize, weight: .semibold)
        }
    }

    static let text = NSColor(white: 1, alpha: 0.86)
    static let heading = NSColor(white: 1, alpha: 0.97)
    static let secondary = NSColor(white: 1, alpha: 0.5)
    static let marker = NSColor(white: 1, alpha: 0.3)
    static let done = NSColor(white: 1, alpha: 0.36)
    /// Mote's caret orange.
    static let accent = NSColor(red: 1, green: 0.54, blue: 0.3, alpha: 1)
    static let link = NSColor(red: 1, green: 0.66, blue: 0.47, alpha: 1)
    static let codeText = NSColor(red: 0.98, green: 0.82, blue: 0.7, alpha: 0.95)
    static let codeFill = NSColor(white: 1, alpha: 0.075)
}

/// An image shown in place of its markdown line.
final class NoteImage: NSObject {
    let url: URL
    let size: CGSize

    init(url: URL, size: CGSize) {
        self.url = url
        self.size = size
    }
}

/// Image sizes read from file headers and pictures decoded at display size,
/// so styling a line never decodes a full photo.
@MainActor
enum NoteImages {
    private static var sizes: [URL: CGSize] = [:]
    private static var images: [URL: NSImage] = [:]

    static func pixelSize(of url: URL) -> CGSize? {
        if let size = sizes[url] { return size }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              var height = properties[kCGImagePropertyPixelHeight] as? CGFloat, width > 0, height > 0 else { return nil }
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, orientation >= 5 { swap(&width, &height) }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let size = CGSize(width: width / scale, height: height / scale)
        sizes[url] = size
        return size
    }

    static func image(for url: URL) -> NSImage? {
        if let image = images[url] { return image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 1400]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cgImage, size: .zero)
        images[url] = image
        return image
    }

    static func forget(_ url: URL) {
        sizes[url] = nil
        images[url] = nil
    }
}

/// Styles markdown in place, a paragraph at a time. Pure text in, attributes
/// out: it never changes characters, so undo and the saved file see plain markdown.
///
/// Syntax shows only where the selection touches it: inline elements one at
/// a time, block elements (headings, rules, code blocks) by their lines.
struct MarkdownStyler {
    var theme = MarkdownTheme()

    struct Context {
        /// The selection, when the note has focus; nil reveals nothing.
        var selection: NSRange?
        /// Room for an image, in points.
        var width: CGFloat = 280
        /// Where relative link and image paths point: the note's bucket.
        var base: URL?
    }

    // MARK: Patterns

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants; a typo should fail every test, not ship.
        try! NSRegularExpression(pattern: pattern, options: [])
    }

    private static let heading = regex(#"^(#{1,6})([ \t]+|$)"#)
    private static let rule = regex(#"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)
    private static let task = regex(#"^([ \t]*)([-*+])([ \t]+)(\[[ xX]\])([ \t]+|$)"#)
    private static let bullet = regex(#"^([ \t]*)([-*+])([ \t]+)"#)
    private static let ordered = regex(#"^([ \t]*)(\d{1,9}[.)])([ \t]+)"#)
    private static let quote = regex(#"^([ \t]*)(>)([ \t]?)"#)
    private static let codeSpan = regex(#"(`+)([^`\n]+?)\1"#)
    private static let image = regex(#"!\[([^\]\n]*)\]\(([^)\n]+)\)"#)
    private static let link = regex(#"\[([^\]\n]+)\]\(([^)\n]+)\)"#)
    private static let bareURL = regex(#"\bhttps?://[^\s<>()\[\]]+[^\s<>()\[\].,;:!?'"]"#)
    private static let bold = regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italic = regex(#"(?<![*\w\\])([*_])(?=[^\s*_])(.+?)(?<=[^\s*_\\])\1(?![*\w])"#)
    private static let strike = regex(#"(~~)(?=\S)(.+?)(?<=\S)~~"#)

    // MARK: Fences

    static func isFence(_ line: NSString) -> Bool { isFence(at: 0, in: line) }

    /// Whether the line starting at `start` opens or closes a code block,
    /// read in place: this runs over the whole note on every keystroke.
    static func isFence(at start: Int, in string: NSString) -> Bool {
        var index = start
        while index < string.length, index - start < 3, string.character(at: index) == 0x20 { index += 1 }
        guard index + 3 <= string.length else { return false }
        return string.character(at: index) == 0x60 && string.character(at: index + 1) == 0x60 && string.character(at: index + 2) == 0x60
    }

    private static func forEachLineStart(in string: NSString, before limit: Int, _ body: (Int) -> Void) {
        var start = 0
        while start < limit {
            body(start)
            var end = 0
            string.getLineStart(nil, end: &end, contentsEnd: nil, for: NSRange(location: start, length: 0))
            guard end > start else { break }
            start = end
        }
    }

    static func fenceCount(in string: NSString) -> Int {
        var count = 0
        forEachLineStart(in: string, before: string.length) { if isFence(at: $0, in: string) { count += 1 } }
        return count
    }

    /// Every code block, from its opening fence's line to its closing one's
    /// (or the end of the note, while it's still open).
    static func codeBlocks(in string: NSString) -> [NSRange] {
        var blocks: [NSRange] = []
        var open: Int?
        forEachLineStart(in: string, before: string.length) { start in
            guard isFence(at: start, in: string) else { return }
            if let opening = open {
                let line = string.lineRange(for: NSRange(location: start, length: 0))
                blocks.append(NSRange(location: opening, length: NSMaxRange(line) - opening))
                open = nil
            } else {
                open = start
            }
        }
        if let opening = open { blocks.append(NSRange(location: opening, length: string.length - opening)) }
        return blocks
    }

    // MARK: Styling

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: theme.body, .foregroundColor: MarkdownTheme.text, .paragraphStyle: paragraph()]
    }

    private func paragraph(indent: CGFloat = 0, spacingBefore: CGFloat = 0, height: CGFloat? = nil) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = height == nil ? 3 : 0
        style.paragraphSpacing = height == nil ? 1.5 : 0
        style.paragraphSpacingBefore = spacingBefore
        style.headIndent = indent
        if let height {
            style.minimumLineHeight = height
            style.maximumLineHeight = height
        }
        return style
    }

    /// Code sits inside its card with room on both sides, wrapping before the right edge.
    private func codeParagraph() -> NSParagraphStyle {
        let style = paragraph().mutableCopy() as! NSMutableParagraphStyle
        style.firstLineHeadIndent = MarkdownStyler.codeInset
        style.headIndent = MarkdownStyler.codeInset
        style.tailIndent = -MarkdownStyler.codeInset
        return style
    }

    static let codeInset: CGFloat = 11

    /// Restyles every paragraph `range` touches.
    func style(_ text: NSMutableAttributedString, in range: NSRange, context: Context = Context()) {
        // One immutable copy per pass, shared by every pattern below.
        let snapshot = String(text.mutableString)
        let string = snapshot as NSString
        let length = string.length
        guard length > 0 else { return }
        let start = min(range.location, length)
        let paragraphs = string.paragraphRange(for: NSRange(location: start, length: min(range.length, length - start)))
        let blocks = Self.codeBlocks(in: string)
        let pass = Pass(styler: self, text: text, string: string, snapshot: snapshot, context: context, highlights: Highlights())
        var location = paragraphs.location
        while location < NSMaxRange(paragraphs) {
            let line = string.lineRange(for: NSRange(location: location, length: 0))
            var contentsEnd = 0
            string.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: line)
            let content = NSRange(location: line.location, length: contentsEnd - line.location)
            // A completed task fading out keeps its tag through a restyle.
            let fading = line.length > 0 ? text.attribute(.mdFading, at: line.location, effectiveRange: nil) : nil
            text.setAttributes(baseAttributes, range: line)
            if let fading { text.addAttribute(.mdFading, value: fading, range: line) }
            if let block = blocks.first(where: { NSLocationInRange(line.location, $0) }) {
                pass.styleCode(line: line, content: content, block: block)
            } else {
                pass.styleLine(line: line, content: content)
            }
            location = NSMaxRange(line)
        }
    }

    /// Each code block's tokens, scanned once per pass however many of its lines are styled.
    private final class Highlights {
        var byBlock: [Int: [CodeHighlighter.Token]] = [:]
    }

    /// One styling pass: the text, a snapshot of it, and what's revealed.
    private struct Pass {
        let styler: MarkdownStyler
        let text: NSMutableAttributedString
        let string: NSString
        let snapshot: String
        let context: Context
        let highlights: Highlights

        var theme: MarkdownTheme { styler.theme }

        /// Whether the selection touches `range`, edges included: the caret
        /// right after `**bold**` still shows its stars.
        func touches(_ range: NSRange) -> Bool {
            guard let selection = context.selection else { return false }
            return selection.location <= NSMaxRange(range) && NSMaxRange(selection) >= range.location
        }

        /// Syntax: dim while touched, gone otherwise.
        func marker(_ range: NSRange, revealed: Bool) {
            guard range.length > 0 else { return }
            if revealed {
                text.addAttribute(.foregroundColor, value: MarkdownTheme.marker, range: range)
            } else {
                text.addAttribute(.mdHidden, value: true, range: range)
            }
        }

        // MARK: Code blocks

        func styleCode(line: NSRange, content: NSRange, block: NSRange) {
            let revealed = touches(block)
            let isOpening = line.location == block.location
            let isClosing = !isOpening && Self.isLast(line, in: block) && MarkdownStyler.isFence(at: line.location, in: string)
            text.addAttributes([.font: theme.mono, .foregroundColor: CodeHighlighter.plain, .mdCodeBlock: true,
                                .paragraphStyle: styler.codeParagraph()], range: line)
            guard isOpening || isClosing else { return highlight(line: content, block: block) }
            if revealed {
                text.addAttribute(.foregroundColor, value: MarkdownTheme.marker, range: line)
                return
            }
            // Collapsed: the opening fence becomes the card's top with its
            // language in the corner, the closing one a sliver of padding.
            text.addAttributes([.mdHidden: true, .font: NSFont.systemFont(ofSize: 4),
                                .paragraphStyle: styler.paragraph(height: isOpening ? 20 : 8)], range: line)
            if isOpening {
                let language = string.substring(with: content).trimmingCharacters(in: CharacterSet(charactersIn: "` \t"))
                if !language.isEmpty { text.addAttribute(.mdCodeLanguage, value: language, range: line) }
            }
        }

        private static func isLast(_ line: NSRange, in block: NSRange) -> Bool { NSMaxRange(line) >= NSMaxRange(block) }

        /// Colours a line of code with its block's language, from the opening fence.
        private func highlight(line: NSRange, block: NSRange) {
            guard line.length > 0 else { return }
            let tokens = highlights.byBlock[block.location] ?? {
                let opening = string.lineRange(for: NSRange(location: block.location, length: 0))
                var bodyEnd = NSMaxRange(block)
                let last = string.lineRange(for: NSRange(location: max(block.location, NSMaxRange(block) - 1), length: 0))
                if last.location > opening.location, MarkdownStyler.isFence(at: last.location, in: string) { bodyEnd = last.location }
                let body = NSRange(location: NSMaxRange(opening), length: max(0, bodyEnd - NSMaxRange(opening)))
                let name = string.substring(with: opening).trimmingCharacters(in: CharacterSet(charactersIn: "` \t\n"))
                let language = CodeHighlighter.language(named: name.split(separator: " ").first.map(String.init) ?? "")
                let tokens = CodeHighlighter.tokens(in: string, range: body, language: language)
                highlights.byBlock[block.location] = tokens
                return tokens
            }()
            for token in tokens {
                let overlap = NSIntersectionRange(token.range, line)
                guard overlap.length > 0 else { continue }
                text.addAttribute(.foregroundColor, value: CodeHighlighter.color(for: token.kind), range: overlap)
                if token.kind == .comment {
                    text.addAttribute(.font, value: NSFontManager.shared.convert(theme.mono, toHaveTrait: .italicFontMask),
                                      range: overlap)
                }
            }
        }

        // MARK: Lines

        func styleLine(line full: NSRange, content: NSRange) {
            let line = string.substring(with: content) as NSString
            let whole = NSRange(location: 0, length: line.length)
            func absolute(_ r: NSRange) -> NSRange { NSRange(location: content.location + r.location, length: r.length) }
            let onLine = touches(content)
            var inline = content

            if let image = wholeLineImage(line, content: content), !onLine {
                showImage(image, line: full)
                return
            }

            if let match = Self.heading.firstMatch(in: line as String, range: whole) {
                let level = match.range(at: 1).length
                text.addAttributes([.font: theme.heading(level), .foregroundColor: MarkdownTheme.heading,
                                    .paragraphStyle: styler.paragraph(spacingBefore: content.location == 0 ? 0 : 5)], range: full)
                marker(absolute(match.range), revealed: onLine)
                inline = NSRange(location: content.location + match.range.length, length: content.length - match.range.length)
            } else if Self.rule.firstMatch(in: line as String, range: whole) != nil {
                if onLine {
                    text.addAttribute(.foregroundColor, value: MarkdownTheme.marker, range: content)
                } else {
                    text.addAttributes([.mdRule: true, .mdHidden: true], range: content)
                }
                return
            } else if let match = Self.task.firstMatch(in: line as String, range: whole) {
                let box = absolute(match.range(at: 4))
                let checked = line.substring(with: match.range(at: 4)).lowercased() == "[x]"
                let dash = NSRange(location: match.range(at: 2).location, length: match.range(at: 3).length + 1)
                text.addAttribute(.mdHidden, value: true, range: absolute(dash))
                text.addAttributes([.mdCheckbox: checked, .foregroundColor: NSColor.clear], range: box)
                // The brackets take the box's width whichever mark they hold, so checking it moves nothing.
                let brackets = width(of: line.substring(with: match.range(at: 4)), exact: true)
                text.addAttribute(.kern, value: MarkdownStyler.checkboxWidth - brackets,
                                  range: NSRange(location: NSMaxRange(box) - 1, length: 1))
                let prefix = match.range.length
                let indent = width(of: line.substring(with: match.range(at: 1))) + MarkdownStyler.checkboxWidth
                    + width(of: " ", exact: true)
                text.addAttribute(.paragraphStyle, value: styler.paragraph(indent: indent), range: full)
                if checked {
                    text.addAttribute(.foregroundColor, value: MarkdownTheme.done,
                                      range: NSRange(location: content.location + prefix, length: content.length - prefix))
                }
                inline = NSRange(location: content.location + prefix, length: content.length - prefix)
            } else if let match = Self.bullet.firstMatch(in: line as String, range: whole) {
                text.addAttributes([.mdBullet: true, .foregroundColor: NSColor.clear], range: absolute(match.range(at: 2)))
                text.addAttribute(.paragraphStyle, value: styler.paragraph(indent: width(of: line.substring(with: match.range))),
                                  range: full)
                inline = NSRange(location: content.location + match.range.length, length: content.length - match.range.length)
            } else if let match = Self.ordered.firstMatch(in: line as String, range: whole) {
                text.addAttribute(.foregroundColor, value: MarkdownTheme.secondary, range: absolute(match.range(at: 2)))
                text.addAttribute(.paragraphStyle, value: styler.paragraph(indent: width(of: line.substring(with: match.range))),
                                  range: full)
                inline = NSRange(location: content.location + match.range.length, length: content.length - match.range.length)
            } else if let match = Self.quote.firstMatch(in: line as String, range: whole) {
                text.addAttributes([.mdQuote: true, .foregroundColor: MarkdownTheme.secondary], range: full)
                marker(absolute(match.range(at: 2)), revealed: onLine)
                text.addAttribute(.paragraphStyle, value: styler.paragraph(indent: 12), range: full)
                inline = NSRange(location: content.location + match.range.length, length: content.length - match.range.length)
            }

            styleInline(in: inline)
        }

        private func width(of prefix: String, exact: Bool = false) -> CGFloat {
            let width = (prefix as NSString).size(withAttributes: [.font: theme.body]).width
            return exact ? width : ceil(width)
        }

        // MARK: Images

        /// `![alt](path)` alone on its line, pointing at a picture that's there.
        private func wholeLineImage(_ line: NSString, content: NSRange) -> NoteImage? {
            guard line.length > 5, line.hasPrefix("!") || line.hasPrefix(" "),
                  let match = Self.image.firstMatch(in: line as String, range: NSRange(location: 0, length: line.length)),
                  line.replacingCharacters(in: match.range, with: "").trimmingCharacters(in: .whitespaces).isEmpty,
                  let url = MarkdownStyler.resolve(line.substring(with: match.range(at: 2)), base: context.base),
                  url.isFileURL, let size = MainActor.assumeIsolated({ NoteImages.pixelSize(of: url) }) else { return nil }
            return NoteImage(url: url, size: size)
        }

        private func showImage(_ image: NoteImage, line: NSRange) {
            let width = min(image.size.width, context.width)
            let height = max(24, min(360, (image.size.height * width / max(image.size.width, 1)).rounded()))
            text.addAttributes([.mdHidden: true, .font: NSFont.systemFont(ofSize: 4), .mdImage: image,
                                .paragraphStyle: styler.paragraph(spacingBefore: 4, height: height + 6)], range: line)
        }

        // MARK: Inline

        /// Code first, since nothing inside it is markdown; then images and
        /// links; then emphasis. Each reveals on its own.
        private func styleInline(in range: NSRange) {
            guard range.length > 1 else { return }
            var taken = IndexSet()
            func free(_ r: NSRange) -> Bool { !taken.intersects(integersIn: r.location..<NSMaxRange(r)) }
            func take(_ r: NSRange) { taken.insert(integersIn: r.location..<NSMaxRange(r)) }

            for match in Self.codeSpan.matches(in: snapshot, range: range) {
                let ticks = match.range(at: 1).length
                let revealed = touches(match.range)
                text.addAttributes([.font: theme.mono, .foregroundColor: MarkdownTheme.codeText, .mdCodeSpan: true], range: match.range)
                marker(NSRange(location: match.range.location, length: ticks), revealed: revealed)
                marker(NSRange(location: NSMaxRange(match.range) - ticks, length: ticks), revealed: revealed)
                // Air either side for the pill, which would otherwise touch its neighbours.
                if match.range.location > range.location {
                    text.addAttribute(.kern, value: 4, range: NSRange(location: match.range.location - 1, length: 1))
                }
                text.addAttribute(.kern, value: 4, range: NSRange(location: NSMaxRange(match.range) - ticks - 1, length: 1))
                take(match.range)
            }

            for pattern in [Self.image, Self.link] {
                for match in pattern.matches(in: snapshot, range: range) where free(match.range) {
                    let label = match.range(at: 1)
                    let revealed = touches(match.range)
                    let destination = string.substring(with: match.range(at: 2))
                    marker(NSRange(location: match.range.location, length: label.location - match.range.location), revealed: revealed)
                    marker(NSRange(location: NSMaxRange(label), length: NSMaxRange(match.range) - NSMaxRange(label)), revealed: revealed)
                    var attributes: [NSAttributedString.Key: Any] = [
                        .foregroundColor: MarkdownTheme.link, .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .underlineColor: MarkdownTheme.link.withAlphaComponent(0.4)]
                    // Clickable while it reads as a link; while revealed it's text being edited.
                    if !revealed { attributes[.mdLink] = destination }
                    text.addAttributes(attributes, range: label.length > 0 ? label : match.range(at: 2))
                    take(match.range)
                }
            }

            for match in Self.bareURL.matches(in: snapshot, range: range) where free(match.range) {
                var attributes: [NSAttributedString.Key: Any] = [
                    .foregroundColor: MarkdownTheme.link, .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: MarkdownTheme.link.withAlphaComponent(0.4)]
                if !touches(match.range) { attributes[.mdLink] = string.substring(with: match.range) }
                text.addAttributes(attributes, range: match.range)
                take(match.range)
            }

            emphasize(Self.bold, in: range, marker: 2, taken: taken) { addTrait(.boldFontMask, in: $0) }
            emphasize(Self.strike, in: range, marker: 2, taken: taken) {
                text.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                    .foregroundColor: MarkdownTheme.secondary], range: $0)
            }
            emphasize(Self.italic, in: range, marker: 1, taken: taken) { addTrait(.italicFontMask, in: $0) }
        }

        private func emphasize(_ pattern: NSRegularExpression, in range: NSRange, marker length: Int, taken: IndexSet,
                               apply: (NSRange) -> Void) {
            for match in pattern.matches(in: snapshot, range: range) {
                let r = match.range
                guard !taken.intersects(integersIn: r.location..<NSMaxRange(r)), r.length > length * 2 else { continue }
                apply(NSRange(location: r.location + length, length: r.length - length * 2))
                let revealed = touches(r)
                marker(NSRange(location: r.location, length: length), revealed: revealed)
                marker(NSRange(location: NSMaxRange(r) - length, length: length), revealed: revealed)
            }
        }

        private func addTrait(_ trait: NSFontTraitMask, in range: NSRange) {
            text.enumerateAttribute(.font, in: range) { value, run, _ in
                guard let font = value as? NSFont else { return }
                text.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: run)
            }
        }

        private static let heading = MarkdownStyler.heading
        private static let rule = MarkdownStyler.rule
        private static let task = MarkdownStyler.task
        private static let bullet = MarkdownStyler.bullet
        private static let ordered = MarkdownStyler.ordered
        private static let quote = MarkdownStyler.quote
        private static let codeSpan = MarkdownStyler.codeSpan
        private static let image = MarkdownStyler.image
        private static let link = MarkdownStyler.link
        private static let bareURL = MarkdownStyler.bareURL
        private static let bold = MarkdownStyler.bold
        private static let italic = MarkdownStyler.italic
        private static let strike = MarkdownStyler.strike
    }

    /// Room for a task's box and a little air after it.
    static let checkboxWidth: CGFloat = 19

    /// A link or image destination as a URL: web addresses as they are,
    /// paths as files, and bare names as files in the note's bucket.
    static func resolve(_ destination: String, base: URL?) -> URL? {
        var raw = destination.trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("<"), raw.hasSuffix(">") { raw = String(raw.dropFirst().dropLast()) }
        if let url = URL(string: raw), let scheme = url.scheme, scheme.count > 1 { return url }
        let path = raw.removingPercentEncoding ?? raw
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if path.hasPrefix("~") { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        if let base, !path.isEmpty {
            let file = base.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: file.path) { return file }
        }
        return path.contains(".") && !path.contains(" ") ? URL(string: "https://" + path) : nil
    }
}

// MARK: Plain text

enum MarkdownText {
    /// The first line with words in it, without its markdown: the note's title.
    static func title(of text: String) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(8) {
            let plain = strip(String(line))
            if !plain.isEmpty { return String(plain.prefix(80)) }
        }
        return ""
    }

    /// A couple of lines after the title, for previews.
    static func preview(of text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map { strip(String($0)) }.filter { !$0.isEmpty }
        if !lines.isEmpty { lines.removeFirst() }
        return lines.prefix(3).joined(separator: " ")
    }

    static func strip(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        for prefix in ["- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "* [x] "] where s.hasPrefix(prefix) {
            s.removeFirst(prefix.count)
        }
        while let first = s.first, "#>".contains(first) { s.removeFirst() }
        if s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("+ ") { s.removeFirst(2) }
        if s.hasPrefix("```") { return "" }
        s = s.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(\*\*|__|~~|`)"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }
}
