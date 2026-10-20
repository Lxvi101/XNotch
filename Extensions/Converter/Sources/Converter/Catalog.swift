import Foundation
import UniformTypeIdentifiers

/// What a file is, as far as converting it goes.
enum FileKind: String, Sendable {
    case image, gif, pdf, document, video, audio

    init?(_ type: UTType) {
        if type.conforms(to: .gif) { self = .gif }
        else if type.conforms(to: .pdf) { self = .pdf }
        else if type.conforms(to: .image) { self = .image }
        else if type.conforms(to: .movie) || type.conforms(to: .video) { self = .video }
        else if type.conforms(to: .audio) { self = .audio }
        else if Self.documentTypes.contains(where: type.conforms) { self = .document }
        else { return nil }
    }

    init?(url: URL) {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType, let kind = FileKind(type) {
            self = kind
        } else {
            self.init(extension: url.pathExtension)
        }
    }

    /// From the name alone, without touching the disk.
    init?(extension ext: String) {
        let ext = ext.lowercased()
        if let kind = Self.unregistered[ext] { self = kind; return }
        guard let type = UTType(filenameExtension: ext), let kind = FileKind(type) else { return nil }
        self = kind
    }

    /// The kind all the files share, or nil when they differ or the wheel has nothing for them.
    static func shared(by urls: [URL]) -> FileKind? {
        guard let first = urls.first, let kind = FileKind(extension: first.pathExtension) else { return nil }
        return urls.dropFirst().allSatisfy { FileKind(extension: $0.pathExtension) == kind } ? kind : nil
    }

    /// Formats ffmpeg reads that macOS has no type for unless an app like VLC registered one.
    private static let unregistered: [String: FileKind] = [
        "mkv": .video, "webm": .video, "avi": .video, "flv": .video, "wmv": .video, "ogv": .video,
        "mpg": .video, "mpeg": .video, "ts": .video, "m2ts": .video, "mts": .video, "3gp": .video, "vob": .video,
        "opus": .audio, "ogg": .audio, "oga": .audio, "flac": .audio, "wma": .audio, "ape": .audio, "wv": .audio,
        "m4b": .audio, "mka": .audio, "webp": .image, "avif": .image,
    ]

    /// "Image", "Images": for menus.
    func noun(_ count: Int) -> String {
        let one = count == 1
        switch self {
        case .image: return one ? "Image" : "Images"
        case .gif: return one ? "GIF" : "GIFs"
        case .pdf: return one ? "PDF" : "PDFs"
        case .document: return one ? "Document" : "Documents"
        case .video: return one ? "Video" : "Videos"
        case .audio: return one ? "Audio File" : "Audio Files"
        }
    }

    /// Text documents NSAttributedString reads.
    private static let documentTypes: [UTType] = [
        .rtf, .rtfd, .flatRTFD, .html, .plainText,
        UTType("org.openxmlformats.wordprocessingml.document"),
        UTType("com.microsoft.word.doc"),
        UTType("org.oasis-open.opendocument.text"),
        UTType("net.daringfireball.markdown"),
    ].compactMap { $0 }
}

/// A format a file can become.
struct Format: Hashable, Sendable, Identifiable {
    let id: String
    let title: String
    let fileExtension: String

    static let jpg = Format(id: "jpg", title: "JPG", fileExtension: "jpg")
    static let png = Format(id: "png", title: "PNG", fileExtension: "png")
    static let heic = Format(id: "heic", title: "HEIC", fileExtension: "heic")
    static let webp = Format(id: "webp", title: "WEBP", fileExtension: "webp")
    static let avif = Format(id: "avif", title: "AVIF", fileExtension: "avif")
    static let tiff = Format(id: "tiff", title: "TIFF", fileExtension: "tiff")
    static let gif = Format(id: "gif", title: "GIF", fileExtension: "gif")
    static let pdf = Format(id: "pdf", title: "PDF", fileExtension: "pdf")
    static let txt = Format(id: "txt", title: "TXT", fileExtension: "txt")
    static let docx = Format(id: "docx", title: "DOCX", fileExtension: "docx")
    static let rtf = Format(id: "rtf", title: "RTF", fileExtension: "rtf")
    static let html = Format(id: "html", title: "HTML", fileExtension: "html")
    static let odt = Format(id: "odt", title: "ODT", fileExtension: "odt")
    static let mp4 = Format(id: "mp4", title: "MP4", fileExtension: "mp4")
    static let mov = Format(id: "mov", title: "MOV", fileExtension: "mov")
    static let webm = Format(id: "webm", title: "WEBM", fileExtension: "webm")
    static let mp3 = Format(id: "mp3", title: "MP3", fileExtension: "mp3")
    static let m4a = Format(id: "m4a", title: "M4A", fileExtension: "m4a")
    static let wav = Format(id: "wav", title: "WAV", fileExtension: "wav")
    static let flac = Format(id: "flac", title: "FLAC", fileExtension: "flac")
    static let aiff = Format(id: "aiff", title: "AIFF", fileExtension: "aiff")
    static let ogg = Format(id: "ogg", title: "OGG", fileExtension: "ogg")
    static let opus = Format(id: "opus", title: "OPUS", fileExtension: "opus")

    /// Extensions that already are this format, so a file isn't offered its own.
    var aliases: Set<String> {
        switch id {
        case "jpg": ["jpg", "jpeg", "jpe"]
        case "tiff": ["tif", "tiff"]
        case "html": ["html", "htm"]
        case "aiff": ["aif", "aiff", "aifc"]
        case "txt": ["txt", "text"]
        default: [fileExtension]
        }
    }
}

/// Something done to a file that isn't a change of format.
enum Tool: String, CaseIterable, Hashable, Sendable, Identifiable {
    case removeBackground, compress, halfSize, stripMetadata, copyText, mute

    var id: String { rawValue }

    var title: String {
        switch self {
        case .removeBackground: "Cut Out"
        case .compress: "Compress"
        case .halfSize: "Half Size"
        case .stripMetadata: "Strip Info"
        case .copyText: "Copy Text"
        case .mute: "Mute"
        }
    }

    /// What the hub says while the tool is under the pointer.
    var verb: String {
        switch self {
        case .removeBackground: "Remove the background"
        case .compress: "Make it smaller"
        case .halfSize: "Halve its size"
        case .stripMetadata: "Remove location and camera info"
        case .copyText: "Copy its text"
        case .mute: "Remove the sound"
        }
    }

    var symbol: String {
        switch self {
        case .removeBackground: "person.crop.rectangle.badge.plus"
        case .compress: "arrow.down.right.and.arrow.up.left"
        case .halfSize: "square.resize.down"
        case .stripMetadata: "location.slash"
        case .copyText: "text.viewfinder"
        case .mute: "speaker.slash"
        }
    }

    /// Added to the file name, for tools that write a file.
    var suffix: String? {
        switch self {
        case .removeBackground: "Cut Out"
        case .compress: "Compressed"
        case .halfSize: "Half Size"
        case .stripMetadata: "No Info"
        case .mute: "Muted"
        case .copyText: nil
        }
    }
}

/// One thing the wheel can do with the dragged files.
enum Action: Hashable, Sendable {
    case convert(Format)
    case tool(Tool)

    var title: String {
        switch self {
        case .convert(let format): format.title
        case .tool(let tool): tool.title
        }
    }
}

/// What the wheel offers for a kind of file.
struct Offer: Equatable, Sendable {
    var formats: [Format]
    var tools: [Tool]

    var isEmpty: Bool { formats.isEmpty && tools.isEmpty }
}

enum Catalog {
    /// The formats and tools for files of a kind, minus a format they're all
    /// in already. Formats run clockwise from the top, the likeliest first.
    static func offer(for kind: FileKind, sourceExtensions: [String]) -> Offer {
        let extensions = Set(sourceExtensions.map { $0.lowercased() })
        let formats: [Format]
        let tools: [Tool]
        switch kind {
        case .image:
            formats = [.jpg, .png, .heic, .webp, .pdf, .avif, .tiff, .gif]
            tools = [.removeBackground, .compress, .halfSize, .stripMetadata, .copyText]
        case .gif:
            formats = [.mp4, .webm, .webp, .png, .jpg, .mov]
            tools = []
        case .pdf:
            formats = [.jpg, .png, .docx, .txt, .rtf, .heic]
            tools = [.compress, .copyText]
        case .document:
            formats = [.pdf, .docx, .txt, .rtf, .html, .odt]
            tools = [.copyText]
        case .video:
            formats = [.mp4, .mov, .gif, .webm, .mp3, .m4a]
            tools = [.compress, .halfSize, .mute, .stripMetadata]
        case .audio:
            formats = [.mp3, .m4a, .wav, .flac, .aiff, .ogg, .opus]
            tools = []
        }
        return Offer(formats: formats.filter { !extensions.isSubset(of: $0.aliases) }, tools: tools)
    }

    /// Whether ffmpeg does the work. Everything else is macOS's own frameworks.
    static func needsFFmpeg(_ operation: Action, kind: FileKind) -> Bool {
        switch kind {
        case .video, .audio: return true
        case .gif:
            if case .convert(let format) = operation { return ![.png, .jpg].contains(format) }
            return false
        case .image:
            if case .convert(let format) = operation { return [.webp, .avif].contains(format) }
            return false
        case .pdf, .document: return false
        }
    }
}
