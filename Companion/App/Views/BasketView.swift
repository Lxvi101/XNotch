import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// What's on its way to the Mac. Drop files on it (iPad), or tap + to add.
struct BasketView: View {
    @EnvironmentObject private var link: MacLink
    let onAdd: () -> Void
    @State private var isTargeted = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(Color(white: 0.06))
            DotGrid()
                .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
            // A file held over the basket: a faint tint that fades, nothing that jumps.
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(Palette.cyan.opacity(isTargeted ? 0.08 : 0))
                .opacity(link.outgoing.isEmpty ? 1 : 0.45)
            if link.outgoing.isEmpty {
                emptyState
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                items
                    .transition(.opacity)
            }
            if let incoming = link.incomingProgress {
                IncomingBanner(name: incoming.name, fraction: incoming.fraction)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .strokeBorder(isTargeted ? Palette.cyan.opacity(0.8) : .white.opacity(0.07), lineWidth: isTargeted ? 2 : 1)
                .animation(.easeOut(duration: 0.25), value: isTargeted)
        }
        .contentShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
        // Simultaneous, so Add Files and the tiles keep their taps.
        .onDrop(of: [.item], delegate: BasketDropDelegate(isTargeted: $isTargeted) { urls in
            link.send(files: urls)
        })
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: link.outgoing)
        .animation(.spring(response: 0.4), value: link.incomingProgress?.name)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray.and.arrow.up.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text("Basket")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
            Text("Add photos and files with +, or share\nto XNotch from any app.")
                .font(.system(size: 16))
                .foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center)
            Button(action: onAdd) {
                Label("Add Files", systemImage: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .padding(.horizontal, 18)
                    .frame(height: 40)
                    .background(Capsule().fill(Palette.raised))
            }
            .padding(.top, 4)
        }
        .padding(24)
    }

    private var items: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Basket")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                if link.outgoing.contains(where: { $0.state == .sent }) {
                    Button("Clear Sent") { link.clearFinished() }
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Palette.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 14) {
                    ForEach(link.outgoing) { item in
                        BasketTile(item: item)
                            .contextMenu {
                                if case .failed = item.state {
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
                .padding(16)
            }
        }
    }
}

private struct BasketTile: View {
    let item: MacLink.Outgoing
    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Palette.raised)
                preview
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .opacity(item.state == .sent ? 0.55 : 1)
                stateBadge
            }
            .frame(width: 84, height: 84)
            Text(item.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .frame(width: 92, height: 30, alignment: .top)
        }
        .task(id: item.id) { await loadThumbnail() }
    }

    @ViewBuilder
    private var preview: some View {
        switch item.content {
        case .text:
            Image(systemName: "text.quote")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Palette.cyan)
        case .file:
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFill().frame(width: 84, height: 84)
            } else {
                Image(systemName: "doc.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Palette.secondary)
            }
        }
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch item.state {
        case .waiting:
            Image(systemName: "clock")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(.black.opacity(0.6)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(6)
        case .sending(let fraction):
            ZStack {
                Circle().fill(.black.opacity(0.55))
                Circle().stroke(.white.opacity(0.2), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: max(0.03, fraction))
                    .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.15), value: fraction)
            }
            .frame(width: 36, height: 36)
        case .sent:
            Image(systemName: "checkmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Palette.green))
                .transition(.scale.combined(with: .opacity))
        case .failed:
            Image(systemName: "exclamationmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(.red))
        }
    }

    private func loadThumbnail() async {
        guard case .file(let url) = item.content else { return }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 84, height: 84),
                                                   scale: UIScreen.main.scale, representationTypes: .thumbnail)
        if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            withAnimation(.easeOut(duration: 0.2)) { thumbnail = representation.uiImage }
        }
    }
}

/// A file on its way from the Mac.
private struct IncomingBanner: View {
    let name: String
    let fraction: Double

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(Palette.cyan)
            Text(name)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            ProgressView(value: fraction)
                .frame(width: 70)
                .tint(Palette.cyan)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Capsule().fill(Palette.raised))
    }
}

/// Files dropped on the basket (iPad, or iPhone from another app's drag).
private struct BasketDropDelegate: DropDelegate {
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

/// Files the Mac sent, newest first. Tap to preview.
struct ReceivedStrip: View {
    @EnvironmentObject private var link: MacLink
    let items: [MacLink.Received]
    @Binding var preview: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("From your Mac")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.secondary)
                .padding(.leading, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(items) { item in
                        Button { preview = item.url } label: {
                            HStack(spacing: 10) {
                                Image(systemName: icon(for: item.url))
                                    .font(.system(size: 17))
                                    .foregroundStyle(Palette.cyan)
                                Text(item.url.lastPathComponent)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .frame(maxWidth: 160)
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 48)
                            .background(Capsule().fill(Palette.card))
                        }
                        .contextMenu {
                            ShareLink(item: item.url) { Label("Share", systemImage: "square.and.arrow.up") }
                            Button(role: .destructive) { link.deleteReceived(item) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private func icon(for url: URL) -> String {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return "doc.fill" }
        if type.conforms(to: .image) { return "photo.fill" }
        if type.conforms(to: .movie) { return "film.fill" }
        if type.conforms(to: .pdf) { return "doc.richtext.fill" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        return "doc.fill"
    }
}
