import AppKit
import XNotchKit
import SwiftUI

/// Settings → Extension Store: every extension XNotch can run, laid out like
/// the App Store. Adding one puts it in the sidebar; removing it takes it out.
struct ExtensionStorePane: View {
    @ObservedObject var extensions: ExtensionManager
    @ObservedObject var navigation: SettingsNavigation
    @State private var path: [ExtensionID] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if extensions.entries.isEmpty {
                        ContentUnavailableView("No Extensions", systemImage: "puzzlepiece.extension",
                                               description: Text("Put a .xnext bundle in the extensions folder and restart XNotch."))
                    }
                    if let featured {
                        FeaturedCard(entry: featured, extensions: extensions, navigation: navigation) {
                            path.append(featured.id)
                        }
                    }
                    shelf("Available", available)
                    shelf("Installed", installed)
                    developerFooter
                }
                .padding(24)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .navigationDestination(for: ExtensionID.self) { id in
                if let entry = extensions.entries.first(where: { $0.id == id }) {
                    ExtensionDetailView(entry: entry, extensions: extensions, navigation: navigation)
                }
            }
        }
    }

    private var installed: [ExtensionManager.Entry] { extensions.installed }
    private var available: [ExtensionManager.Entry] { extensions.entries.filter { !extensions.isEnabled($0.id) } }
    /// The first extension that isn't added yet, else the first one.
    private var featured: ExtensionManager.Entry? {
        available.first { $0.failure == nil } ?? extensions.entries.first
    }

    @ViewBuilder
    private func shelf(_ title: String, _ entries: [ExtensionManager.Entry]) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.title3.weight(.semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 18, alignment: .top)], spacing: 22) {
                    ForEach(entries) { entry in
                        StoreCard(entry: entry, extensions: extensions, navigation: navigation) { path.append(entry.id) }
                    }
                }
            }
        }
    }

    private var developerFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Text("Extensions are .xnext bundles built with XNotchKit. Put one in the extensions folder and restart XNotch.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.open(ExtensionManager.userDirectory) }
                Button("SDK Guide") {
                    if let guide = Bundle.main.url(forResource: "XNotchKit", withExtension: "md") {
                        NSWorkspace.shared.open(guide)
                    }
                }
            }
            .controlSize(.small)
        }
    }
}

// MARK: Cards

private struct FeaturedCard: View {
    let entry: ExtensionManager.Entry
    @ObservedObject var extensions: ExtensionManager
    @ObservedObject var navigation: SettingsNavigation
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            ZStack(alignment: .bottomLeading) {
                ExtensionPreview(entry: entry, index: 0)
                    .aspectRatio(16 / 7, contentMode: .fill)
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(extensions.isEnabled(entry.id) ? "INSTALLED" : "FEATURED")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.75))
                        Text(entry.manifest.name).font(.title.weight(.bold))
                        Text(entry.manifest.summary)
                            .font(.callout)
                            .lineLimit(2)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .foregroundStyle(.white)
                    Spacer(minLength: 20)
                    GetButton(entry: entry, extensions: extensions, navigation: navigation, prominent: true)
                }
                .padding(20)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct StoreCard: View {
    let entry: ExtensionManager.Entry
    @ObservedObject var extensions: ExtensionManager
    @ObservedObject var navigation: SettingsNavigation
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onOpen) {
                ExtensionPreview(entry: entry, index: 0)
                    .aspectRatio(16 / 10, contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.quaternary))
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            HStack(alignment: .top, spacing: 10) {
                ExtensionIcon(manifest: entry.manifest, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.manifest.name).fontWeight(.semibold).lineLimit(1)
                    Text(entry.failure ?? entry.manifest.summary)
                        .font(.caption)
                        .foregroundStyle(entry.failure == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                GetButton(entry: entry, extensions: extensions, navigation: navigation)
            }
        }
    }
}

/// The App Store's capsule: Get adds the extension, Open goes to it.
private struct GetButton: View {
    let entry: ExtensionManager.Entry
    @ObservedObject var extensions: ExtensionManager
    let navigation: SettingsNavigation
    var prominent = false

    var body: some View {
        let installed = extensions.isEnabled(entry.id)
        Button {
            if !installed {
                withAnimation(.snappy) { extensions.setEnabled(true, for: entry.id) }
            } else {
                navigation.selection = .extensionPane(entry.id)
            }
        } label: {
            Text(entry.failure != nil ? "Unavailable" : installed ? "Open" : "Get")
                .font(.system(size: 12, weight: .bold))
                .frame(minWidth: 44)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .foregroundStyle(prominent ? Color.accentColor : installed ? Color.accentColor : .white)
                .background(Capsule().fill(prominent ? AnyShapeStyle(.white)
                                           : installed ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.accentColor)))
        }
        .buttonStyle(.plain)
        .disabled(entry.failure != nil)
        .opacity(entry.failure != nil ? 0.5 : 1)
    }
}

// MARK: Detail

struct ExtensionDetailView: View {
    let entry: ExtensionManager.Entry
    @ObservedObject var extensions: ExtensionManager
    @ObservedObject var navigation: SettingsNavigation

    private var installed: Bool { extensions.isEnabled(entry.id) }
    private var previewCount: Int { max(entry.previewURLs.count, 1) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(0..<previewCount, id: \.self) { index in
                            ExtensionPreview(entry: entry, index: index)
                                .frame(width: 420, height: 262)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.quaternary))
                        }
                    }
                }
                if let failure = entry.failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                Text(entry.manifest.description ?? entry.manifest.summary)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Divider()
                information
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(entry.manifest.name)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            ExtensionIcon(manifest: entry.manifest, size: 88)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.manifest.name).font(.title.weight(.bold))
                Text(entry.manifest.summary)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    if installed {
                        Button("Remove", role: .destructive) {
                            withAnimation(.snappy) { extensions.setEnabled(false, for: entry.id) }
                        }
                        if extensions.settingsPane(for: entry.id) != nil, navigation.selection != .extensionPane(entry.id) {
                            Button("Options…") { navigation.selection = .extensionPane(entry.id) }
                        }
                    } else {
                        Button("Get") {
                            withAnimation(.snappy) { extensions.setEnabled(true, for: entry.id) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(entry.failure != nil)
                    }
                }
                .buttonBorderShape(.capsule)
                .padding(.top, 6)
            }
        }
    }

    private var information: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Information").font(.title3.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                infoRow("Developer", entry.manifest.creator?.name ?? "Unknown")
                infoRow("Version", entry.manifest.version)
                infoRow("Requires", "XNotchKit \(entry.manifest.kit.minAPI)")
                infoRow("Source", entry.isBuiltIn ? "Built into XNotch" : "Extensions folder")
            }
            if let link = entry.manifest.creator?.url.flatMap(URL.init(string:)) {
                Link("Developer Website", destination: link).font(.callout)
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
        .font(.callout)
    }
}

// MARK: Artwork

/// The extension's tile, with a little depth for the store.
private struct ExtensionIcon: View {
    let manifest: ExtensionManifest
    let size: CGFloat

    var body: some View {
        SettingsIcon(symbol: manifest.symbol, color: manifest.tint.flatMap(Color.init(hex:)) ?? .blue, size: size)
            .shadow(color: .black.opacity(0.18), radius: size * 0.06, y: size * 0.03)
    }
}

/// One of the manifest's preview images, or, when it has none, a card drawn
/// from the extension's symbol and tint: its page opening under a notch.
struct ExtensionPreview: View {
    let entry: ExtensionManager.Entry
    let index: Int

    var body: some View {
        let urls = entry.previewURLs
        if urls.indices.contains(index), let image = NSImage(contentsOf: urls[index]) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            GeneratedPreview(manifest: entry.manifest)
        }
    }
}

private struct GeneratedPreview: View {
    let manifest: ExtensionManifest

    var body: some View {
        let tint = manifest.tint.flatMap(Color.init(hex:)) ?? .blue
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Rectangle().fill(.black)
                LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.55)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: manifest.symbol)
                    .font(.system(size: size.height * 0.9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.12))
                    .rotationEffect(.degrees(-12))
                    .offset(x: size.width * 0.32, y: size.height * 0.22)
                // The open notch, showing the extension's page.
                UnevenRoundedRectangle(bottomLeadingRadius: size.height * 0.12,
                                       bottomTrailingRadius: size.height * 0.12, style: .continuous)
                    .fill(.black)
                    .frame(width: size.width * 0.58, height: size.height * 0.5)
                    .overlay {
                        HStack(spacing: size.height * 0.05) {
                            SettingsIcon(symbol: manifest.symbol, color: tint, size: size.height * 0.16)
                            VStack(alignment: .leading, spacing: size.height * 0.025) {
                                Text(manifest.name)
                                    .font(.system(size: max(size.height * 0.065, 8), weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                ForEach([0.9, 0.65], id: \.self) { width in
                                    Capsule()
                                        .fill(.white.opacity(0.22))
                                        .frame(width: size.width * 0.28 * width, height: max(size.height * 0.022, 2))
                                }
                            }
                        }
                        .padding(.top, size.height * 0.06)
                    }
                    .shadow(color: .black.opacity(0.35), radius: size.height * 0.05, y: size.height * 0.02)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }
}
