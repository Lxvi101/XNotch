import QuickLook
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// What's on its way to the Mac, as square tiles (iPhone) or bigger cards (iPad).
struct BasketItems: View {
    @EnvironmentObject private var link: MacLink
    var large = false

    var body: some View {
        LazyVGrid(columns: columns, spacing: large ? 14 : 12) {
            ForEach(link.outgoing) { item in
                Group {
                    if large { BasketCard(item: item) } else { BasketTile(item: item) }
                }
                .contentShape(Rectangle())
                .contextMenu {
                    if case .failed(let reason) = item.state {
                        Text(reason)
                        Button { link.retry(item.id) } label: { Label("Try Again", systemImage: "arrow.clockwise") }
                    }
                    if !item.isSending {
                        Button(role: .destructive) { link.remove(item.id) } label: { Label("Remove", systemImage: "xmark") }
                    }
                }
                .onTapGesture { if case .failed = item.state { link.retry(item.id) } }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        // Items arriving, finishing or leaving; progress animates in its own ring.
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: link.outgoing.map(\.layoutKey))
    }

    private var columns: [GridItem] {
        large ? [GridItem(.adaptive(minimum: 160), spacing: 14)]
              : Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
    }
}

/// iPhone: a square tile with its state in the corner and the name under it.
private struct BasketTile: View {
    let item: MacLink.Outgoing

    var body: some View {
        VStack(spacing: 6) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { ItemPreview(item: item) }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.line.opacity(0.6)))
                .overlay { StateBadge(state: item.state) }
            Group {
                if case .failed(let reason) = item.state {
                    Text(reason).foregroundStyle(Palette.orange)
                } else {
                    Text(item.name).foregroundStyle(Palette.secondary)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .truncationMode(.middle)
        }
    }
}

/// iPad: a card with the preview, name, size and a progress line.
private struct BasketCard: View {
    let item: MacLink.Outgoing

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay { ItemPreview(item: item) }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay { StateBadge(state: item.state, showsRing: false) }
            Text(item.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, 9)
            if case .sending(let fraction) = item.state {
                GeometryReader { proxy in
                    Capsule().fill(Palette.line)
                        .overlay(alignment: .leading) {
                            Capsule().fill(Palette.ink).frame(width: max(4, proxy.size.width * fraction))
                                .animation(.linear(duration: 0.15), value: fraction)
                        }
                }
                .frame(height: 4)
                .padding(.top, 7)
            }
            HStack {
                Text(FileSizes.label(for: item))
                Spacer()
                stateText
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.secondary)
            .padding(.top, 3)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.raised.opacity(0.6)))
    }

    @ViewBuilder
    private var stateText: some View {
        switch item.state {
        case .waiting: Text("Waiting")
        case .sending(let fraction): Text("\(Int((fraction * 100).rounded()))%").foregroundStyle(Palette.ink).fontWeight(.semibold)
        case .sent: Text("Sent").foregroundStyle(Palette.green).fontWeight(.semibold)
        case .failed(let reason): Text(reason).foregroundStyle(Palette.orange).lineLimit(1)
        }
    }
}

/// A thumbnail, a document glyph, or the start of the text.
private struct ItemPreview: View {
    let item: MacLink.Outgoing
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack {
            Palette.card
            switch item.content {
            case .text(let text):
                Text(text)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(5)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .file(let url):
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    Text(url.pathExtension.uppercased().prefix(4))
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(Palette.secondary)
                }
            }
        }
        .opacity(item.state == .sent ? 0.6 : 1)
        .task(id: item.id) { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        guard case .file(let url) = item.content else { return }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 200, height: 200),
                                                   scale: UIScreen.main.scale, representationTypes: .thumbnail)
        if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            withAnimation(.easeOut(duration: 0.2)) { thumbnail = representation.uiImage }
        }
    }
}

/// Waiting, sending (a ring), sent or failed, in the corner.
private struct StateBadge: View {
    let state: MacLink.Outgoing.State
    var showsRing = true

    var body: some View {
        switch state {
        case .waiting:
            corner(symbol: "clock", fill: Palette.ink, foreground: Palette.onInk)
        case .sending(let fraction):
            if showsRing {
                ZStack {
                    Color.black.opacity(0.25)
                    Circle().stroke(.white.opacity(0.3), lineWidth: 3)
                        .frame(width: 32, height: 32)
                    Circle()
                        .trim(from: 0, to: max(0.03, fraction))
                        .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 32, height: 32)
                        .animation(.linear(duration: 0.15), value: fraction)
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        case .sent:
            corner(symbol: "checkmark", fill: Palette.green, foreground: .white)
                .transition(.scale.combined(with: .opacity))
        case .failed:
            corner(symbol: "exclamationmark", fill: Palette.red, foreground: .white)
        }
    }

    private func corner(symbol: String, fill: Color, foreground: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(foreground)
            .frame(width: 22, height: 22)
            .background(Circle().fill(fill))
            .overlay(Circle().strokeBorder(Palette.card, lineWidth: 1.5))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(6)
    }
}

/// Nothing to send yet: the tray, a line of help, and ways to add.
struct EmptyBasket: View {
    var isTargeted = false
    var large = false
    var macName: String?
    let onPhotos: () -> Void
    let onFiles: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: large ? 32 : 28, weight: .medium))
                .foregroundStyle(Palette.onInk)
                .frame(width: large ? 86 : 76, height: large ? 86 : 76)
                .background(RoundedRectangle(cornerRadius: large ? 28 : 24, style: .continuous).fill(Palette.ink))
                .shadow(color: .black.opacity(0.25), radius: 14, y: 10)
                .scaleEffect(isTargeted ? 1.08 : 1)
            Text(isTargeted ? "Drop to send" : "Basket is empty")
                .font(.system(size: large ? 24 : 20, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .padding(.top, 20)
                .contentTransition(.opacity)
            Text(isTargeted ? "It goes straight to \(macName ?? "your Mac")'s shelf." : large
                 ? "Drag files here from any app, or share to XNotch."
                 : "Add photos and files, or share to\nXNotch from any app.")
                .font(.system(size: large ? 15 : 14))
                .foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.top, 6)
                .contentTransition(.opacity)
            HStack(spacing: 8) {
                quickAction("Photos", symbol: "photo", action: onPhotos)
                quickAction("Files", symbol: "folder", action: onFiles)
            }
            .frame(maxWidth: 320)
            .padding(.top, 22)
            .opacity(isTargeted ? 0 : 1)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(isTargeted ? Palette.ink.opacity(0.03) : Palette.card)
                .overlay { DotPattern().clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous)) }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(isTargeted ? Palette.ink : (large ? Palette.line : Palette.line.opacity(0.7)),
                              style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: isTargeted || large ? [6, 5] : []))
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isTargeted)
    }

    private func quickAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Palette.raised))
        }
        .buttonStyle(.plain)
    }
}

/// A file on its way from the Mac.
struct IncomingBanner: View {
    let name: String
    let fraction: Double

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Palette.onInk)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Palette.ink))
            Text(name)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            ProgressView(value: fraction)
                .frame(width: 70)
                .tint(Palette.ink)
        }
        .padding(.leading, 8)
        .padding(.trailing, 16)
        .frame(height: 46)
        .sheetCard(radius: 23)
    }
}

/// The dashed strip under a full basket on iPad, for one more drag.
struct DropStrip: View {
    var isTargeted = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.onInk)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Palette.ink))
            Text(isTargeted ? "Drop to send" : "Drag files here from Photos, Files or any app")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isTargeted ? Palette.ink : Palette.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 92)
        .background { DotPattern().clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous)) }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(isTargeted ? Palette.ink : Palette.line, style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.5, dash: [6, 5]))
        }
        .animation(.easeOut(duration: 0.2), value: isTargeted)
    }
}

/// Files dropped on the basket (iPad, or iPhone from another app's drag).
struct BasketDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let onFiles: ([URL]) -> Void

    func dropEntered(info: DropInfo) {
        withAnimation(.easeOut(duration: 0.25)) { isTargeted = true }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        withAnimation(.easeOut(duration: 0.25)) { isTargeted = false }
    }

    func performDrop(info: DropInfo) -> Bool {
        withAnimation(.easeOut(duration: 0.25)) { isTargeted = false }
        let providers = info.itemProviders(for: [.item])
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await Self.stage(provider) { urls.append(url) }
            }
            onFiles(urls)
        }
        return true
    }

    private static func stage(_ provider: NSItemProvider) async -> URL? {
        guard let type = provider.registeredContentTypes.first(where: { $0.conforms(to: .data) || $0.conforms(to: .folder) })
                ?? provider.registeredContentTypes.first else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, _ in
                let name = provider.suggestedName.map { name in
                    name.contains(".") ? name : name + "." + (type.preferredFilenameExtension ?? "")
                }
                continuation.resume(returning: url.flatMap { try? MacLink.stage($0, named: name ?? $0.lastPathComponent) })
            }
        }
    }
}

// MARK: From your Mac

/// One file the Mac sent: icon, name, size, age. Tap to preview.
struct ReceivedRow: View {
    @EnvironmentObject private var link: MacLink
    let item: MacLink.Received
    @Binding var preview: URL?

    var body: some View {
        Button { preview = item.url } label: {
            HStack(spacing: 12) {
                Image(systemName: ReceivedRow.icon(for: item.url))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Palette.raised))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.url.lastPathComponent)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(size)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondary)
                }
                Spacer(minLength: 8)
                Text(item.date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            ShareLink(item: item.url) { Label("Share", systemImage: "square.and.arrow.up") }
            Button(role: .destructive) { link.deleteReceived(item) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private var size: String {
        let bytes = (try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func icon(for url: URL) -> String {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        return "doc"
    }
}

/// Received files in a white sheet, divided by hairlines.
struct ReceivedList: View {
    let items: [MacLink.Received]
    @Binding var preview: URL?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Rectangle().fill(Palette.line).frame(height: 1).padding(.leading, 62) }
                ReceivedRow(item: item, preview: $preview)
            }
        }
        .sheetCard(radius: 22)
    }
}

/// Every file the Mac sent, for "See all".
struct ReceivedSheet: View {
    @EnvironmentObject private var link: MacLink
    @Environment(\.dismiss) private var dismiss
    @State private var preview: URL?

    var body: some View {
        NavigationStack {
            ScrollView {
                ReceivedList(items: link.received, preview: $preview)
                    .padding(18)
            }
            .background(Palette.background)
            .navigationTitle("From your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .tint(Palette.ink)
        .quickLookPreview($preview, in: link.received.map(\.url))
    }
}
