import AppKit
import CoreImage
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

enum ConversionError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): text
        }
    }
}

/// Images and PDF pages, with ImageIO, PDFKit and Vision. Thread-safe: runs
/// off the main thread.
enum ImageEngine {
    static func type(for format: Format) -> UTType? {
        switch format {
        case .jpg: .jpeg
        case .png: .png
        case .heic: .heic
        case .tiff: .tiff
        case .gif: .gif
        default: nil
        }
    }

    // MARK: Converting

    static func convert(_ input: URL, to format: Format, output: URL, quality: Quality) throws {
        if format == .pdf { return try makePDF(from: input, output: output) }
        guard let type = type(for: format) else { throw ConversionError.message("macOS can't write \(format.title) images.") }
        let image = try loadImage(input)
        let flattened = format == .jpg ? flatten(image) : image
        try write(flattened, type: type, to: output, quality: quality.image, metadataFrom: input)
    }

    /// The first image in a file, upright.
    static func loadImage(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw ConversionError.message("This image couldn't be read.")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        // A thumbnail as big as the image is the cheapest way to get it rotated upright.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ConversionError.message("This image couldn't be read.")
        }
        return image
    }

    static func write(_ image: CGImage, type: UTType, to url: URL, quality: Double, metadataFrom source: URL? = nil,
                      stripMetadata: Bool = false) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ConversionError.message("This format can't be written.")
        }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if !stripMetadata, let source, let input = CGImageSourceCreateWithURL(source as CFURL, nil),
           let metadata = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any] {
            // The pixels are already upright, so the orientation tag would turn them again.
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
                if let value = metadata[key] { properties[key] = value }
            }
        }
        properties[kCGImagePropertyOrientation] = 1
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.message("The image couldn't be saved.") }
    }

    /// JPEG has no transparency: transparent parts become white, not black.
    static func flatten(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return image
        default: break
        }
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(.white)
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage() ?? image
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    private static func makePDF(from input: URL, output: URL) throws {
        let image = try loadImage(input)
        guard let page = PDFPage(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))) else {
            throw ConversionError.message("This image couldn't be put in a PDF.")
        }
        let document = PDFDocument()
        document.insert(page, at: 0)
        guard document.write(to: output) else { throw ConversionError.message("The PDF couldn't be saved.") }
    }

    // MARK: Tools

    static func compress(_ input: URL, output: URL, quality: Quality) throws -> URL {
        let image = try loadImage(input)
        let ext = input.pathExtension.lowercased()
        // Lossless files become the lossy format that keeps what they have.
        let type: UTType
        var output = output
        if ["jpg", "jpeg", "heic", "heif"].contains(ext) {
            type = ext == "heic" || ext == "heif" ? .heic : .jpeg
        } else {
            type = hasAlpha(image) ? .heic : .jpeg
            output = output.deletingPathExtension().appendingPathExtension(type == .heic ? "heic" : "jpg")
        }
        try write(image, type: type, to: output, quality: quality.compressedImage, metadataFrom: input)
        return output
    }

    static func halfSize(_ input: URL, output: URL, quality: Quality) throws {
        let image = try loadImage(input)
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else { throw ConversionError.message("This image couldn't be read.") }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(max(image.width, image.height) / 2, 1),
        ]
        guard let half = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ConversionError.message("This image couldn't be resized.")
        }
        try write(half, type: outputType(for: input), to: output, quality: quality.image, metadataFrom: input)
    }

    static func stripMetadata(_ input: URL, output: URL) throws {
        let image = try loadImage(input)
        try write(image, type: outputType(for: input), to: output, quality: 0.95, stripMetadata: true)
    }

    /// The input's own type when ImageIO writes it, else PNG.
    static func outputType(for input: URL) -> UTType {
        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        if let type = UTType(filenameExtension: input.pathExtension), writable.contains(type.identifier) { return type }
        return .png
    }

    /// The subject cut out on transparency, as a PNG.
    static func removeBackground(_ input: URL, output: URL) throws {
        let image = try loadImage(input)
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            throw ConversionError.message("No subject stands out in this image.")
        }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false)
        let context = CIContext()
        let cutout = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = context.createCGImage(cutout, from: cutout.extent, format: .RGBA8,
                                                  colorSpace: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw ConversionError.message("The cut-out couldn't be made.")
        }
        try write(cgImage, type: .png, to: output, quality: 1)
    }

    /// The words Vision reads in an image.
    static func recognizeText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    // MARK: PDF pages

    /// Each page as an image, at print resolution. One page lands beside the
    /// PDF; more go in a folder named after it.
    static func renderPages(of input: URL, as format: Format, output: URL, quality: Quality,
                            progress: @Sendable (Double) -> Void) throws -> [URL] {
        guard let document = PDFDocument(url: input), document.pageCount > 0 else {
            throw ConversionError.message(PDFDocument(url: input)?.isLocked == true ? "This PDF is locked." : "This PDF couldn't be read.")
        }
        guard let type = type(for: format) else { throw ConversionError.message("macOS can't write \(format.title) images.") }
        let count = document.pageCount
        var urls: [URL] = []
        var folder: URL?
        if count > 1 {
            let directory = Output.available(output.deletingPathExtension())
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            folder = directory
        }
        let base = output.deletingPathExtension().lastPathComponent
        for index in 0..<count {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let image = try render(page, dpi: 300)
            let url = folder.map { $0.appendingPathComponent("\(base) \(index + 1).\(format.fileExtension)") } ?? output
            try write(format == .jpg ? flatten(image) : image, type: type, to: url, quality: quality.image)
            urls.append(url)
            progress(Double(index + 1) / Double(count))
        }
        return folder.map { [$0] } ?? urls
    }

    static func render(_ page: PDFPage, dpi: CGFloat) throws -> CGImage {
        let bounds = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let size = rotated ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        // Capped, so a poster-sized page doesn't take gigabytes.
        let scale = min(dpi / 72, 12_000 / max(size.width, size.height, 1))
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ConversionError.message("This page is too big to render.")
        }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        guard let image = context.makeImage() else { throw ConversionError.message("This page couldn't be rendered.") }
        return image
    }

    static func compressPDF(_ input: URL, output: URL) throws {
        guard let document = PDFDocument(url: input) else { throw ConversionError.message("This PDF couldn't be read.") }
        let options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]
        guard document.write(to: output, withOptions: options) else { throw ConversionError.message("The PDF couldn't be saved.") }
    }

    /// A PDF's text layer, or what Vision reads on its first pages when it has none.
    static func pdfText(_ input: URL) throws -> String {
        guard let document = PDFDocument(url: input) else { throw ConversionError.message("This PDF couldn't be read.") }
        let text = document.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty { return text }
        var pages: [String] = []
        for index in 0..<min(document.pageCount, 20) {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            pages.append(try recognizeText(in: render(page, dpi: 200)))
        }
        return pages.joined(separator: "\n\n")
    }
}
