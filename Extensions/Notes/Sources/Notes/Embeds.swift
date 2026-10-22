import AppKit
import SwiftUI

// MARK: References

extension Attachments {
    /// A bucket file's name as a markdown destination: bare names point into
    /// the bucket, and parentheses would end the link early.
    static func markdownPath(for name: String) -> String {
        (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)
            .replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
    }

    /// How a bucket file is written into a note: a picture as an image, anything else as a link.
    static func markdown(for url: URL, display: ImageDisplay? = nil) -> String {
        let path = markdownPath(for: url.lastPathComponent)
        let label = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "]", with: ")").replacingOccurrences(of: "|", with: "-")
        guard MainActor.assumeIsolated({ NoteImages.pixelSize(of: url) }) != nil else {
            return "[\(url.lastPathComponent.replacingOccurrences(of: "]", with: ")"))](\(path))"
        }
        let hint = display?.hint.map { "|" + $0 } ?? ""
        return "![\(label)\(hint)](\(path))"
    }
}

// MARK: Mentions

/// `@` at the start of a word, and what's typed after it: `abc@` and
/// addresses never count.
enum MentionTrigger {
    static func find(in text: NSString, caret: Int) -> (range: NSRange, query: String)? {
        guard caret <= text.length else { return nil }
        var start = caret
        while start > 0 {
            let character = text.character(at: start - 1)
            if character == 0x40 { break }
            if isBreak(character) || caret - start >= 40 { return nil }
            start -= 1
        }
        guard start > 0, text.character(at: start - 1) == 0x40 else { return nil }
        let at = start - 1
        if at > 0 {
            let before = text.character(at: at - 1)
            // "(", "[" and quotes open a word too.
            guard isBreak(before) || [0x28, 0x5B, 0x22, 0x27].contains(before) else { return nil }
        }
        return (NSRange(location: at, length: caret - at), text.substring(with: NSRange(location: start, length: caret - start)))
    }

    private static func isBreak(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09 || character == 0x0A || character == 0x0D
    }
}

/// The `@` picker while it's up: what's typed, the bucket files that match, and where it hangs.
struct MentionState: Equatable {
    var range: NSRange
    var query: String
    var files: [Attachment]
    var selection = 0
    /// The caret's line in the note: the picker opens under it, or over it near the bottom.
    var caretTop: CGFloat
    var caretBottom: CGFloat
    var x: CGFloat

    /// Pictures first, then names that start with what's typed.
    static func matches(_ query: String, in attachments: [Attachment]) -> [Attachment] {
        let wanted = query.lowercased()
        let matching = wanted.isEmpty ? attachments : attachments.filter { $0.name.lowercased().contains(wanted) }
        return matching.sorted { a, b in
            let aImage = isImage(a), bImage = isImage(b)
            if aImage != bImage { return aImage }
            let aStarts = a.name.lowercased().hasPrefix(wanted), bStarts = b.name.lowercased().hasPrefix(wanted)
            if aStarts != bStarts { return aStarts }
            return a.added > b.added
        }
    }

    static func isImage(_ attachment: Attachment) -> Bool {
        ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "svg"]
            .contains(attachment.url.pathExtension.lowercased())
    }
}

/// The bucket's files under the caret, for `@`.
struct MentionPopover: View {
    let state: NoteWindowState
    let controller: NoteController
    static let width: CGFloat = 236
    static let rowHeight: CGFloat = 34

    var body: some View {
        GeometryReader { proxy in
            if let mention = state.mention {
                let rows = max(1, min(mention.files.count, 5))
                let height = CGFloat(rows) * Self.rowHeight + 12
                let below = mention.caretBottom + 6 + height < proxy.size.height - 8
                let y = below ? mention.caretBottom + 6 : mention.caretTop - 6 - height
                let x = min(max(10, mention.x - 14), proxy.size.width - Self.width - 10)
                // It settles in at the caret, not across the note: the
                // transition sits inside the offset, so its scale is the card's own.
                MentionList(mention: mention, controller: controller)
                    .frame(width: Self.width, height: height)
                    .transition(.modifier(active: Settle(amount: 1, below: below), identity: Settle(amount: 0, below: below)))
                    .offset(x: x, y: y)
            }
        }
        .allowsHitTesting(state.mention != nil)
    }
}

/// A small drop toward the text from the caret's side, coming into focus.
private struct Settle: ViewModifier {
    let amount: CGFloat
    let below: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(1 - 0.03 * amount, anchor: below ? .top : .bottom)
            .offset(y: (below ? -4 : 4) * amount)
            .blur(radius: NoteMotion.reduced ? 0 : 3 * amount)
            .opacity(1 - Double(amount))
    }
}

private struct MentionList: View {
    let mention: MentionState
    let controller: NoteController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if mention.files.isEmpty {
                Text(controller.note.attachments.isEmpty ? "Drop files on the note to mention them" : "No files match “\(mention.query)”")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, minHeight: MentionPopover.rowHeight)
            } else {
                ScrollViewReader { reader in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            ForEach(Array(mention.files.enumerated()), id: \.element.id) { index, file in
                                MentionRow(file: file, isSelected: index == mention.selection)
                                    .id(file.id)
                                    .onHover { if $0 { controller.selectMention(index) } }
                                    .onTapGesture { controller.insertMention(file) }
                            }
                        }
                    }
                    .onChange(of: mention.selection) { _, index in
                        guard mention.files.indices.contains(index) else { return }
                        reader.scrollTo(mention.files[index].id)
                    }
                }
            }
        }
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(white: 0.15).opacity(0.96))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(.white.opacity(0.1)))
                .shadow(color: .black.opacity(0.4), radius: 12, y: 5)
        }
    }
}

private struct MentionRow: View {
    let file: Attachment
    let isSelected: Bool
    @State private var image: NSImage?

    var body: some View {
        HStack(spacing: 9) {
            Image(nsImage: image ?? Thumbnails.image(for: file.path))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: MentionState.isImage(file) ? .fill : .fit)
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(file.name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Text(Attachments.formatted(file.size))
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(.horizontal, 7)
        .frame(height: MentionPopover.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isSelected ? noteAccent.opacity(0.24) : .clear)
        }
        .contentShape(Rectangle())
        .animation(NoteMotion.hover, value: isSelected)
        .task(id: file.path) {
            guard image == nil else { return }
            image = await Thumbnails.thumbnail(for: file.path)
        }
    }
}

// MARK: Image menu

extension NoteTextView {
    /// Right-click on a picture: how big it shows, and what to do with it.
    func imageMenu(_ image: NoteImage, markup: NSRange) -> NSMenu {
        let menu = NSMenu()
        let modes: [(String, ImageDisplay, String)] = [
            ("Inline", .inline, "text.below.photo"), ("Preview", .preview, "photo"), ("Medium", .medium, "rectangle"),
            ("Large", .large, "rectangle.expand.vertical"), ("Full Width", .full, "arrow.left.and.right")]
        for (title, mode, symbol) in modes {
            let item = ClosureMenuItem(title, symbol: symbol) { [weak self] in self?.setDisplay(mode, markup: markup) }
            item.state = image.mode == mode || (mode == .preview && image.mode == .width(ImageDisplay.previewSide)) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Open", symbol: "arrow.up.forward.app") { NSWorkspace.shared.open(image.url) })
        menu.addItem(ClosureMenuItem("Quick Look", symbol: "eye") { [weak self] in self?.peek(image, at: markup.location) })
        menu.addItem(ClosureMenuItem("Show in Finder", symbol: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([image.url])
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Edit Markdown", symbol: "chevron.left.forwardslash.chevron.right") { [weak self] in
            // Selecting it reveals it.
            self?.setSelectedRange(markup)
        })
        menu.addItem(ClosureMenuItem("Remove from Note", symbol: "minus.circle") { [weak self] in self?.removeImage(markup: markup) })
        return menu
    }

    /// Rewrites the image's hint. A picture that grows past inline gets a line of its own.
    func setDisplay(_ display: ImageDisplay, markup: NSRange) {
        let string = self.string as NSString
        guard NSMaxRange(markup) <= string.length,
              let match = MarkdownStyler.image.firstMatch(in: string as String, range: markup) else { return }
        let label = ImageDisplay.parse(string.substring(with: match.range(at: 1))).label
        let hint = display.hint.map { "|" + $0 } ?? ""
        var replacement = "![\(label)\(hint)](\(string.substring(with: match.range(at: 2))))"
        if display != .inline {
            let line = string.lineRange(for: NSRange(location: markup.location, length: 0))
            var contentsEnd = 0
            string.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: line)
            let before = string.substring(with: NSRange(location: line.location, length: markup.location - line.location))
            let after = string.substring(with: NSRange(location: NSMaxRange(markup), length: contentsEnd - NSMaxRange(markup)))
            if !before.trimmingCharacters(in: .whitespaces).isEmpty { replacement = "\n" + replacement }
            if !after.trimmingCharacters(in: .whitespaces).isEmpty { replacement += "\n" }
        }
        replace(markup, with: replacement, keepingSelection: true)
    }

    /// Takes the image out of the text; the file stays in the bucket. A line
    /// left empty goes too.
    func removeImage(markup: NSRange) {
        let string = self.string as NSString
        guard NSMaxRange(markup) <= string.length else { return }
        let line = string.lineRange(for: NSRange(location: markup.location, length: 0))
        let rest = string.substring(with: line).replacingOccurrences(of: string.substring(with: markup), with: "")
        let range = rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? line : markup
        replace(range, with: "", keepingSelection: true)
    }
}

// MARK: Peek

extension NoteTextView {
    /// A picture large, beside the note, rising out of where it sits in the text.
    func peek(_ image: NoteImage, at index: Int) {
        guard let layout = markdownLayout, let storage = textStorage, let window, index < storage.length else { return }
        var run = NSRange()
        var frame: CGRect?
        if storage.attribute(.mdImage, at: index, longestEffectiveRange: &run, in: NSRange(location: 0, length: storage.length)) != nil {
            frame = layout.blockImageFrame(for: run, image: image)
        } else if storage.attribute(.mdInlineImage, at: index, effectiveRange: nil) != nil {
            frame = layout.inlineImageFrame(for: NSRange(location: index, length: 1), image: image)
        }
        let origin = textContainerOrigin
        let inView = (frame ?? CGRect(x: 0, y: 0, width: 40, height: 40)).offsetBy(dx: origin.x, dy: origin.y)
        let source = window.convertToScreen(convert(inView, to: nil))
        ImagePeek.shared.show(image, from: source,
                              beside: window.frame.insetBy(dx: NoteGeometry.margin, dy: NoteGeometry.margin))
    }
}

/// A picture shown large beside its note, in the note's glass: Quick Look
/// opens where it likes, and this opens where you're looking.
@MainActor
final class ImagePeek {
    static let shared = ImagePeek()
    private var panel: PeekPanel?

    func show(_ image: NoteImage, from source: CGRect, beside note: CGRect) {
        close(animated: false)
        guard let picture = NoteImages.image(for: image.url) else {
            NSWorkspace.shared.open(image.url)
            return
        }
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: note.midX, y: note.midY)) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame.insetBy(dx: 12, dy: 12) else { return }

        // Its own size, within most of the screen beside the note; small pictures grow a little.
        let maxSize = CGSize(width: max(visible.width * 0.5, 320), height: visible.height * 0.8)
        var size = image.size
        let longest = max(size.width, size.height)
        if longest < 320 { size = CGSize(width: size.width * 320 / longest, height: size.height * 320 / longest) }
        let scale = min(maxSize.width / size.width, maxSize.height / size.height, 1)
        size = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())

        // Right of the note if it fits, else left, else over it; level with the picture.
        var x = note.maxX + 14
        if x + size.width > visible.maxX { x = note.minX - 14 - size.width }
        if x < visible.minX { x = min(max(visible.minX, note.midX - size.width / 2), visible.maxX - size.width) }
        let y = min(max(visible.minY, source.midY - size.height / 2), visible.maxY - size.height)
        let frame = CGRect(x: x, y: y, width: size.width, height: size.height)

        let panel = PeekPanel(frame: frame, picture: picture, url: image.url)
        panel.onClose = { [weak self] in self?.close(animated: true) }
        self.panel = panel
        panel.present()
    }

    func close(animated: Bool) {
        guard let panel else { return }
        self.panel = nil
        panel.dismiss(animated: animated)
    }
}

private final class PeekPanel: NSPanel {
    var onClose: (() -> Void)?
    private let url: URL
    private var closing = false

    init(frame: CGRect, picture: NSImage, url: URL) {
        self.url = url
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let view = PeekView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.cornerRadius = 14
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        view.layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        view.layer?.borderColor = NSColor(white: 1, alpha: 0.1).cgColor
        view.layer?.borderWidth = 1
        let pictureLayer = CALayer()
        pictureLayer.frame = view.bounds
        pictureLayer.contents = picture
        pictureLayer.contentsGravity = .resizeAspectFill
        pictureLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        view.layer?.addSublayer(pictureLayer)
        view.onClick = { [weak self] clicks in
            guard let self else { return }
            if clicks == 2 { NSWorkspace.shared.open(self.url) }
            self.onClose?()
        }
        contentView = view
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Fades in growing a little from its middle; the window's alpha carries
    /// the shadow with it.
    func present() {
        alphaValue = 0
        orderFrontRegardless()
        makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
        guard !NoteMotion.reduced, let layer = contentView?.layer else { return }
        let grow = CASpringAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.94
        grow.toValue = 1
        grow.stiffness = pow(2 * .pi / 0.34, 2)
        grow.damping = 4 * .pi * 0.9 / 0.34
        grow.duration = grow.settlingDuration
        layer.add(grow, forKey: "grow")
    }

    func dismiss(animated: Bool) {
        guard !closing else { return }
        closing = true
        guard animated else { return orderOut(nil) }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.orderOut(nil) }
        })
    }

    /// Escape, Space or Return put it away.
    override func keyDown(with event: NSEvent) {
        if [53, 49, 36, 76].contains(Int(event.keyCode)) { onClose?() } else { super.keyDown(with: event) }
    }

    /// Clicking anywhere else puts it away.
    override func resignKey() {
        super.resignKey()
        onClose?()
    }
}

private final class PeekView: NSView {
    var onClick: ((Int) -> Void)?
    private var pending: DispatchWorkItem?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A single click waits a beat in case it becomes a double-click, which opens the file.
    override func mouseUp(with event: NSEvent) {
        pending?.cancel()
        if event.clickCount >= 2 {
            onClick?(2)
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.onClick?(1) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }
}
