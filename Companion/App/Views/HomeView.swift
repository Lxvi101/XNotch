import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import XNotchLink

/// The paired Mac as a dark pass, the basket, and what the Mac sent back.
/// iPhone stacks them; iPad gets a sidebar, or a pass-over-basket stack in portrait.
struct HomeView: View {
    @EnvironmentObject private var link: MacLink
    @EnvironmentObject private var flow: PairingFlow
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var text = ""
    @State private var picksPhotos = false
    @State private var picksFiles = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var confirmsForget = false
    @State private var showsReceived = false
    @State private var preview: URL?
    @State private var stagingFailure: String?
    @State private var isTargeted = false
    @State private var tab = BasketTab.toMac
    @FocusState private var composing: Bool

    enum BasketTab: Hashable { case toMac, fromMac }

    var body: some View {
        GeometryReader { proxy in
            Group {
                // Windows can be any size on iPad: pick by the space we actually have.
                if sizeClass != .regular || proxy.size.width < 700 || proxy.size.height < 560 {
                    compact
                } else if proxy.size.width >= 900 {
                    sidebar
                } else {
                    stacked
                }
            }
        }
        .photosPicker(isPresented: $picksPhotos, selection: $photoItems, matching: .any(of: [.images, .videos]),
                      preferredItemEncoding: .current, photoLibrary: .shared())
        .fileImporter(isPresented: $picksFiles, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task {
                let staged = await MacLink.stage(urls)
                link.send(files: staged.files)
                if !staged.failed.isEmpty {
                    stagingFailure = "XNotch couldn't read \(ListFormatter.localizedString(byJoining: staged.failed)). If it's in iCloud, open it in Files once so it downloads, then try again."
                }
            }
        }
        .alert("Couldn't add a file", isPresented: Binding(get: { stagingFailure != nil }, set: { if !$0 { stagingFailure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(stagingFailure ?? "")
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task {
                var staged: [URL] = []
                for item in items {
                    if let file = try? await item.loadTransferable(type: PickedFile.self) { staged.append(file.url) }
                }
                link.send(files: staged)
            }
        }
        .confirmationDialog("Forget \(link.mac?.name ?? "this Mac")?", isPresented: $confirmsForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { if let id = link.mac?.id { link.forget(id) } }
        } message: {
            Text("To send to it again, scan its code again.")
        }
        .sheet(isPresented: $showsReceived) { ReceivedSheet() }
        .quickLookPreview($preview, in: link.received.map(\.url))
        .animation(.spring(response: 0.4), value: link.incomingProgress?.name)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: link.outgoing.isEmpty)
    }

    // MARK: iPhone

    private var compact: some View {
        VStack(spacing: 0) {
            navBar
                .padding(.horizontal, 18)
            ScrollView {
                VStack(spacing: 0) {
                    PassCard()
                    sectionHeader("Basket") {
                        if link.outgoing.contains(where: { $0.state == .sent }) {
                            Button("Clear sent") { link.clearFinished() }
                        }
                    }
                    if let incoming = link.incomingProgress {
                        IncomingBanner(name: incoming.name, fraction: incoming.fraction)
                            .padding(.bottom, 12)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if link.outgoing.isEmpty {
                        EmptyBasket(isTargeted: isTargeted, macName: link.mac?.name,
                                    onPhotos: { picksPhotos = true }, onFiles: { picksFiles = true })
                            .frame(minHeight: 330)
                            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    } else {
                        BasketItems()
                            .transition(.opacity)
                    }
                    if !link.received.isEmpty {
                        sectionHeader("From your Mac") {
                            if link.received.count > 3 { Button("See all") { showsReceived = true } }
                        }
                        ReceivedList(items: Array(link.received.prefix(3)), preview: $preview)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .onDrop(of: [.item], delegate: BasketDropDelegate(isTargeted: $isTargeted) { link.send(files: $0) })
            dock(showsAdd: true)
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 6)
                .frame(maxWidth: 640)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: iPad, wide

    private var sidebar: some View {
        HStack(spacing: 18) {
            VStack(spacing: 0) {
                navBar
                ScrollView {
                    VStack(spacing: 0) {
                        PassCard()
                        // Only worth a list when there's a choice; otherwise Pair Another is in ⋯.
                        if link.stored.pairings.count > 1 { macsSection }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.hidden)
                dock(showsAdd: false)
                    .padding(.top, 8)
            }
            .frame(width: 360)
            basketPane
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 16)
    }

    // MARK: iPad, portrait

    private var stacked: some View {
        VStack(spacing: 14) {
            navBar
            HStack(alignment: .top, spacing: 14) {
                PassCard()
                    .frame(maxWidth: .infinity)
                if link.stored.pairings.count > 1 {
                    macsSection
                        .frame(width: 260)
                        .padding(.top, -14)
                }
            }
            basketPane
            dock(showsAdd: false)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 12)
    }

    private var macsSection: some View {
        VStack(spacing: 0) {
            sectionHeader("Your Macs") {
                Button("Pair another") { flow.beginScanning() }
            }
            VStack(spacing: 2) {
                ForEach(link.stored.pairings) { mac in
                    let selected = mac.id == link.mac?.id
                    Button { link.select(mac.id) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "laptopcomputer")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(selected ? Palette.onInk : Palette.ink)
                                .frame(width: 38, height: 38)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Palette.ink : Palette.raised))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mac.name)
                                    .font(.system(size: 14.5, weight: .semibold))
                                    .foregroundStyle(Palette.ink)
                                    .lineLimit(1)
                                if selected, let state = selectedState {
                                    Text(state)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Palette.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            if selected && link.status.isConnected { LiveDot() }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(selected ? Palette.raised.opacity(0.7) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .sheetCard(radius: 22)
        }
    }

    /// "Connected over USB" or "Looking for it", under the chosen Mac.
    private var selectedState: String? {
        switch link.status {
        case .connected(_, let title): "Connected over \(title)"
        case .searching, .unpaired: "Looking for it"
        case .failed: "Not reachable"
        }
    }

    private var basketPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Basket")
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(Palette.ink)
                if !link.outgoing.isEmpty {
                    Text("\(link.outgoing.count)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Palette.raised))
                }
                Spacer()
                Picker("Show", selection: $tab) {
                    Text("To Mac").tag(BasketTab.toMac)
                    Text("From Mac").tag(BasketTab.fromMac)
                }
                .pickerStyle(.segmented)
                .frame(width: 230)
                if tab == .toMac, link.outgoing.contains(where: { $0.state == .sent }) {
                    Button("Clear sent") { link.clearFinished() }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 15)
                        .frame(height: 36)
                        .background(Capsule().fill(Palette.raised))
                }
                addMenu {
                    Label("Add", systemImage: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.onInk)
                        .padding(.horizontal, 15)
                        .frame(height: 36)
                        .background(Capsule().fill(Palette.ink))
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 12)

            if let incoming = link.incomingProgress {
                IncomingBanner(name: incoming.name, fraction: incoming.fraction)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            switch tab {
            case .toMac:
                if link.outgoing.isEmpty {
                    EmptyBasket(isTargeted: isTargeted, large: true, macName: link.mac?.name,
                                onPhotos: { picksPhotos = true }, onFiles: { picksFiles = true })
                        .padding([.horizontal, .bottom], 22)
                } else {
                    ScrollView {
                        BasketItems(large: true)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 4)
                    }
                    DropStrip(isTargeted: isTargeted)
                        .padding([.horizontal, .bottom], 22)
                        .padding(.top, 8)
                }
            case .fromMac:
                if link.received.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(Palette.tertiary)
                        Text("Nothing from your Mac yet")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                        Text("Files your Mac sends show up here and in the Files app.")
                            .font(.system(size: 14))
                            .foregroundStyle(Palette.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                            ForEach(link.received) { item in
                                ReceivedRow(item: item, preview: $preview)
                                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.raised.opacity(0.6)))
                            }
                        }
                        .padding(.horizontal, 22)
                        .padding(.bottom, 22)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheetCard(radius: 30)
        .onDrop(of: [.item], delegate: BasketDropDelegate(isTargeted: $isTargeted) { urls in
            tab = .toMac
            link.send(files: urls)
        })
    }

    // MARK: Pieces

    private var navBar: some View {
        HStack(spacing: 10) {
            Image("AppIconImage")
                .resizable()
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text("XNotch")
                .font(.system(size: 21, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(Palette.ink)
            Spacer()
            Menu {
                if link.stored.pairings.count > 1 {
                    Picker("Send to", selection: Binding(get: { link.mac?.id ?? "" }, set: { link.select($0) })) {
                        ForEach(link.stored.pairings) { mac in
                            Label(mac.name, systemImage: "laptopcomputer").tag(mac.id)
                        }
                    }
                }
                Button { flow.beginScanning() } label: { Label("Pair Another Mac", systemImage: "qrcode.viewfinder") }
                if LinkBluetooth.isUndetermined {
                    Button { Task { await link.enableBluetooth() } } label: {
                        Label("Use Bluetooth When There's No Wi-Fi", systemImage: "dot.radiowaves.left.and.right")
                    }
                }
                Button(role: .destructive) { confirmsForget = true } label: { Label("Forget This Mac", systemImage: "trash") }
            } label: {
                CircleButtonLabel(symbol: "ellipsis", size: 42)
            }
        }
        .frame(height: 56)
    }

    private func sectionHeader<Accessory: View>(_ title: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Spacer()
            accessory()
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.top, 22)
        .padding(.bottom, 10)
    }

    private func addMenu<MenuLabel: View>(@ViewBuilder label: () -> MenuLabel) -> some View {
        Menu {
            Button { picksPhotos = true } label: { Label("Photos & Videos", systemImage: "photo.on.rectangle") }
            Button { picksFiles = true } label: { Label("Files", systemImage: "folder") }
        } label: {
            label()
        }
    }

    /// The text box, with Paste beside it and, on iPhone, the black +.
    private func dock(showsAdd: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            // PasteButton reads the clipboard without iOS asking each time. It
            // can't be sized freely, so it sits in a circle like its neighbours.
            PasteButton(payloadType: String.self) { strings in
                Task { @MainActor in
                    link.send(text: strings.joined(separator: "\n"))
                }
            }
            // iOS only lets it paste when its icon contrasts with the tint, so it's ink.
            .labelStyle(.iconOnly)
            .buttonBorderShape(.circle)
            .tint(Palette.ink)
            .controlSize(.large)
            .frame(width: 52, height: 52)

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Send text to Mac", text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.system(size: 16))
                    .foregroundStyle(Palette.ink)
                    .focused($composing)
                    .padding(.leading, 18)
                    .padding(.vertical, 15)
                    .submitLabel(.send)
                    .onSubmit(sendText)
                Button(action: sendText) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(canSendText ? Palette.onInk : Palette.tertiary)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(canSendText ? Palette.ink : Palette.raised))
                }
                .disabled(!canSendText)
                .padding(.trailing, 7)
                .padding(.bottom, 7)
                .animation(.spring(response: 0.3), value: canSendText)
            }
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Palette.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.06), radius: 10, y: 6)

            if showsAdd {
                addMenu { CircleButtonLabel(symbol: "plus", size: 52, prominent: true) }
            }
        }
    }

    private var canSendText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func sendText() {
        guard canSendText else { return }
        link.send(text: text)
        text = ""
        composing = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

/// A photo or video from the picker, copied somewhere the app owns.
struct PickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            PickedFile(url: try MacLink.stage(received.file))
        }
    }
}
