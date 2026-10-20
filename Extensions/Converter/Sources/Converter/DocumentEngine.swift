import AppKit
import CoreText
import PDFKit

/// Text documents, through NSAttributedString, with CoreText laying out PDFs.
enum DocumentEngine {
    /// HTML is read with WebKit, which only runs on the main thread.
    static func needsMainThread(_ url: URL) -> Bool {
        ["html", "htm", "webarchive"].contains(url.pathExtension.lowercased())
    }

    static func read(_ url: URL) throws -> NSAttributedString {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return try readPDF(url) }
        if ["md", "markdown", "txt", "text"].contains(ext) || (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .plainText)) == true {
            let text = try String(contentsOf: url, encoding: .utf8)
            return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
        }
        return try NSAttributedString(url: url, options: [:], documentAttributes: nil)
    }

    /// A PDF's text with its fonts, page after page.
    private static func readPDF(_ url: URL) throws -> NSAttributedString {
        guard let document = PDFDocument(url: url) else { throw ConversionError.message("This PDF couldn't be read.") }
        let text = NSMutableAttributedString()
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let content = page.attributedString else { continue }
            if text.length > 0 { text.append(NSAttributedString(string: "\n\n")) }
            text.append(content)
        }
        guard text.length > 0 else { throw ConversionError.message("This PDF has no text to convert, only images.") }
        return text
    }

    static func write(_ text: NSAttributedString, as format: Format, to url: URL) throws {
        let range = NSRange(location: 0, length: text.length)
        let type: NSAttributedString.DocumentType
        switch format {
        case .pdf: return try writePDF(text, to: url)
        case .txt:
            return try text.string.write(to: url, atomically: true, encoding: .utf8)
        case .docx: type = .officeOpenXML
        case .rtf: type = .rtf
        case .html: type = .html
        case .odt: type = .openDocument
        default: throw ConversionError.message("Documents can't become \(format.title).")
        }
        let data = try text.data(from: range, documentAttributes: [.documentType: type])
        try data.write(to: url, options: .atomic)
    }

    /// Lays the text out on pages: A4, or US Letter where that's the custom.
    private static func writePDF(_ text: NSAttributedString, to url: URL) throws {
        let letter = ["US", "CA", "MX", "PH", "CL", "CO", "VE"].contains(Locale.current.region?.identifier ?? "")
        var page = letter ? CGRect(x: 0, y: 0, width: 612, height: 792) : CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        let frame = page.insetBy(dx: 64, dy: 64)
        guard let context = CGContext(url as CFURL, mediaBox: &page, nil) else {
            throw ConversionError.message("The PDF couldn't be saved.")
        }
        let framesetter = CTFramesetterCreateWithAttributedString(Self.printable(text))
        var start = 0
        let length = text.length
        repeat {
            context.beginPDFPage(nil)
            let path = CGPath(rect: frame, transform: nil)
            let ctFrame = CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: 0), path, nil)
            CTFrameDraw(ctFrame, context)
            let visible = CTFrameGetVisibleStringRange(ctFrame)
            context.endPDFPage()
            // A frame that fits nothing (a giant image or glyph) would loop forever.
            guard visible.length > 0 else { break }
            start += visible.length
        } while start < length
        context.closePDF()
    }

    /// Dark-mode colours and missing fonts would print badly: text without a
    /// colour is black, and on a white page.
    private static func printable(_ text: NSAttributedString) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: text)
        let range = NSRange(location: 0, length: copy.length)
        copy.enumerateAttribute(.foregroundColor, in: range) { value, subrange, _ in
            if value == nil { copy.addAttribute(.foregroundColor, value: NSColor.black, range: subrange) }
        }
        copy.enumerateAttribute(.font, in: range) { value, subrange, _ in
            if value == nil { copy.addAttribute(.font, value: NSFont.systemFont(ofSize: 12), range: subrange) }
        }
        return copy
    }
}
