import SwiftUI
import XNotchKit

struct OnboardingView: View {
    struct Actions {
        let primary: () -> Void
        let secondary: () -> Void
        let poke: () -> Void
    }

    @ObservedObject var state: OnboardingState
    let eyes: NotchEyes
    let actions: Actions

    var body: some View {
        ZStack(alignment: .top) {
            Scrim(dim: state.dim, glow: state.glow)
            SnapRing(progress: state.ring, notchSize: state.notchSize)
            HeroNotch(state: state, eyes: eyes, actions: actions)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }
}

/// Dims the screen rather than covering it, with a cool glow falling from
/// the notch. Both ride the same `dim` progress as the hero's panel.
private struct Scrim: View {
    let dim: CGFloat
    let glow: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.52 * Double(dim))
            RadialGradient(colors: [Color(red: 0.55, green: 0.64, blue: 1).opacity(0.3),
                                    Color(red: 0.42, green: 0.34, blue: 0.78).opacity(0.12), .clear],
                           center: .top, startRadius: 0, endRadius: 780)
                .opacity(Double(min(1, dim + 0.7 * glow)))
            LinearGradient(colors: [.clear, .black.opacity(0.28)], startPoint: .center, endPoint: .bottom)
                .opacity(Double(dim))
        }
        .allowsHitTesting(false)
    }
}

/// A ring of light the notch sends out as it locks into place.
private struct SnapRing: View, Animatable {
    var progress: CGFloat
    let notchSize: CGSize

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let p = progress.clamped()
        let visible = p > 0.001 && p < 0.999
        Capsule()
            .stroke(Color(red: 0.75, green: 0.82, blue: 1), lineWidth: 2.5 * (1 - p) + 0.5)
            .frame(width: notchSize.width, height: notchSize.height * 1.4)
            .scaleEffect(1 + 2.6 * p)
            .blur(radius: 1 + 6 * p)
            .opacity(visible ? Double(0.8 * (1 - p)) : 0)
            .offset(y: -notchSize.height * 0.2)
            .allowsHitTesting(false)
    }
}

// MARK: Hero

private struct HeroNotch: View {
    @ObservedObject var state: OnboardingState
    let eyes: NotchEyes
    let actions: OnboardingView.Actions

    var body: some View {
        ZStack(alignment: .top) {
            NotchEyesView(eyes: eyes, unit: OnboardingState.eyesUnit)
                .frame(width: 220, height: OnboardingState.eyesHeight)
                .contentShape(Rectangle())
                .onTapGesture(perform: actions.poke)
                .padding(.top, state.eyesTop)
                .reveal(state.showsEyes ? 1 : 0, hiddenScale: 0.45, maxBlur: 6, travel: -18, unmountsWhenHidden: true)
            StepContent(state: state)
                .reveal(state.showsContent ? 1 : 0, hiddenScale: 0.96, maxBlur: 10, travel: -14, unmountsWhenHidden: true)
            StepFooter(state: state, actions: actions)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .reveal(state.showsContent ? 1 : 0, hiddenScale: 0.98, maxBlur: 8, travel: 0, unmountsWhenHidden: true)
        }
        .modifier(HeroShellModifier(geometry: state.geometry, impact: state.impact, glow: state.glow,
                                    lift: state.showsEyes ? 1 : 0))
        .background(alignment: .top) { StepUnderlay(state: state) }
        .overlay(alignment: .topLeading) { StepOverlay(state: state) }
        .modifier(DepthModifier(depth: state.depth))
        .offset(x: state.flightX)
        .offset(y: state.flightY)
        .opacity(Double(state.presence))
    }
}

/// The notch silhouette at any size, with a rim of light while it travels
/// and a soft drop shadow once it has grown off the bezel. Geometry, impact,
/// glow and lift interpolate together every frame.
private struct HeroShellModifier: ViewModifier, Animatable {
    var geometry: NotchShellGeometry
    var impact: NotchDeformation
    var glow: CGFloat
    var lift: CGFloat

    var animatableData: AnimatablePair<NotchShellGeometry, AnimatablePair<NotchDeformation, AnimatablePair<CGFloat, CGFloat>>> {
        get { AnimatablePair(geometry, AnimatablePair(impact, AnimatablePair(glow, lift))) }
        set {
            geometry = newValue.first
            impact = newValue.second.first
            glow = newValue.second.second.first
            lift = newValue.second.second.second
        }
    }

    func body(content: Content) -> some View {
        let width = max(0, geometry.width + impact.width)
        let height = max(0, geometry.height + impact.height)
        let top = max(0, geometry.topCornerRadius)
        let shape = NotchShape(topCornerRadius: top, bottomRadius: max(0, geometry.bottomRadius))
        let light = Double(glow.clamped())
        let shadow = Double(lift.clamped())

        content
            .frame(width: width + 2 * top, height: height, alignment: .top)
            .clipShape(shape)
            .background {
                ZStack {
                    // Bloom: the light the notch carries in with it.
                    if light > 0.001 {
                        shape.fill(Color(red: 0.62, green: 0.72, blue: 1))
                            .scaleEffect(1.06)
                            .blur(radius: 14 + 22 * light)
                            .opacity(light)
                    }
                    shape.fill(.black)
                        .shadow(color: .black.opacity(0.5 * shadow), radius: 24 * shadow, y: 12 * shadow)
                }
            }
            .overlay {
                shape.stroke(.white.opacity(0.9 * light), lineWidth: 1.5)
                    .blur(radius: 0.8)
            }
            .contentShape(shape)
    }
}

/// Distance from the screen: in front of the viewer the notch is huge and
/// out of focus; it sharpens as it reaches the glass.
private struct DepthModifier: ViewModifier, Animatable {
    var depth: CGFloat

    var animatableData: CGFloat {
        get { depth }
        set { depth = newValue }
    }

    func body(content: Content) -> some View {
        let d = max(0, depth)
        content
            .scaleEffect(1 + 6 * d, anchor: .top)
            .blur(radius: d > 0.002 ? 12 * d : 0)
    }
}

// MARK: Steps

private struct StepText {
    let title: String
    let body: String

    @MainActor
    static func of(_ step: OnboardingState.Step, state: OnboardingState) -> StepText {
        let permission = state.permission
        let access = state.access
        return switch step {
        case .hello:
            StepText(title: "Hi, I'm your notch.",
                     body: "I keep files close, play your music and run extensions, right under the camera. Let me show you around.")
        case .shelf:
            StepText(title: "Drop files on me.",
                     body: "They wait on the shelf until you drag them out to wherever they're going.")
        case .music:
            StepText(title: "Your music, by the camera.",
                     body: "Artwork and a live visualizer while something plays. Click me for the full player.")
        case .pills:
            StepText(title: "Hover to see where a click goes.",
                     body: "Pills drop out under me. Click one to jump straight to music, the shelf or an extension.")
        case .access:
            access == .granted
                ? StepText(title: "Thank you.", body: "\(permission.title) is on. I can open anything you hand me.")
                : StepText(title: "Let me reach your files.", body: permission.reason + " Nothing leaves your Mac.")
        case .extensions:
            StepText(title: "Want a few extras?",
                     body: "Extensions add pages to me. Pick any you like; the rest wait in Settings.")
        case .extensionAccess:
            extensions(state)
        case .done:
            StepText(title: "You're all set.",
                     body: "Hover me any time. Right-click for Settings, where you can replay this tour.")
        }
    }
}

extension StepText {
    @MainActor
    fileprivate static func extensions(_ state: OnboardingState) -> StepText {
        let names = Array(NSOrderedSet(array: state.extensionPermissions.map(\.extensionName))) as? [String] ?? []
        let subject = names.count == 1 ? names[0] : "your extensions"
        if state.extensionAccess == .granted {
            return StepText(title: "Thank you.", body: names.count == 1 ? "\(names[0]) is ready." : "Your extensions are ready.")
        }
        let reason = state.extensionPermissions.count == 1
            ? state.extensionPermissions[0].permission.reason
            : "They need your OK before they can work. macOS asks for each one."
        return StepText(title: "Let me unlock \(subject).", body: reason)
    }
}

/// The step's words and demo, laid out at the step's final size and swapped
/// with a blur, so nothing reflows while the panel resizes.
private struct StepContent: View {
    @ObservedObject var state: OnboardingState

    var body: some View {
        let step = state.step
        let text = StepText.of(step, state: state)
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: state.contentTop)
            VStack(alignment: .leading, spacing: 7) {
                Text(text.title)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(KitStyle.primaryText)
                Text(text.body)
                    .font(.system(size: 13))
                    .foregroundStyle(KitStyle.secondaryText)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(height: OnboardingState.textHeight, alignment: .topLeading)
            demo(step)
                .frame(height: state.demoHeight(step), alignment: .topLeading)
        }
        .padding(.horizontal, OnboardingState.inset)
        .frame(width: state.panelOuterWidth, height: state.panelHeight(step), alignment: .topLeading)
        .id(StepID(step: step, granted: step == .extensionAccess ? state.extensionAccess == .granted : state.access == .granted))
        .transition(.blurReplace)
    }

    @ViewBuilder
    private func demo(_ step: OnboardingState.Step) -> some View {
        switch step {
        case .shelf: ShelfDemo(landed: state.demo >= 1)
        case .music: MusicDemo(playing: state.demo >= 1)
        case .access: AccessDemo(permission: state.permission, access: state.access)
        case .extensions: ExtensionPicker(state: state)
        case .extensionAccess: ExtensionAccessDemo(state: state)
        case .done: LoginToggle(isOn: $state.launchAtLogin)
        default: EmptyView()
        }
    }
}

private struct StepID: Hashable {
    let step: OnboardingState.Step
    let granted: Bool
}

/// Progress dots and the step's buttons. It stays put across steps (only its
/// labels change), riding the panel's bottom edge as it resizes.
private struct StepFooter: View {
    @ObservedObject var state: OnboardingState
    let actions: OnboardingView.Actions

    private var primaryTitle: String {
        switch state.step {
        case .hello: "Show Me"
        case .access:
            switch state.access {
            case .asking: "Allow \(state.permission.title)"
            case .guiding: "Waiting for System Settings"
            case .granted: "Continue"
            }
        case .extensions:
            switch state.newlyChosenExtensions.count {
            case 0: "Continue"
            case 1: "Add \(state.newlyChosenExtensions[0].name)"
            default: "Add \(state.newlyChosenExtensions.count) Extensions"
            }
        case .extensionAccess:
            switch state.extensionAccess {
            case .asking: "Allow"
            case .guiding: "Waiting for macOS"
            case .granted: "Continue"
            }
        case .done: "Let's Go"
        default: "Continue"
        }
    }

    private var secondaryTitle: String? {
        switch state.step {
        case .access: state.access == .asking ? "Not Now" : nil
        case .extensions: nil
        case .extensionAccess: state.extensionAccess == .asking ? "Not Now" : nil
        case .done: nil
        default: "Skip Tour"
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                ForEach(state.steps, id: \.self) { step in
                    Capsule()
                        .fill(.white.opacity(step == state.step ? 0.9 : 0.22))
                        .frame(width: step == state.step ? 16 : 6, height: 6)
                }
            }
            Spacer(minLength: 0)
            if let secondaryTitle {
                Button(action: actions.secondary) {
                    Text(secondaryTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(KitStyle.secondaryText)
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle(scale: 0.94))
                .transition(.blurReplace)
            }
            Button(action: actions.primary) {
                HStack(spacing: 7) {
                    Text(primaryTitle)
                        .contentTransition(.interpolate)
                    Image(systemName: "return")
                        .font(.system(size: 9, weight: .bold))
                        .opacity(0.5)
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(Capsule().fill(.white))
                .contentShape(Capsule())
            }
            .buttonStyle(PressScaleStyle(scale: 0.95))
            .disabled((state.access == .guiding && state.step == .access)
                || (state.extensionAccess == .guiding && state.step == .extensionAccess))
        }
        .padding(.horizontal, OnboardingState.inset)
        .frame(width: state.panelOuterWidth, height: OnboardingState.footerHeight)
    }
}

/// Behind the panel: the destination pills drop out from under its edge.
private struct StepUnderlay: View {
    @ObservedObject var state: OnboardingState

    var body: some View {
        let showing = state.step == .pills && state.showsContent
        let items: [(String, String)] = [("music.note", "Music"), ("tray.full.fill", "Shelf"), ("folder.fill", "Folders")]
        HStack(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                let out = showing && state.demo >= 1
                let lit = showing && state.demo >= 2 && index == 1
                HStack(spacing: 6) {
                    Image(systemName: item.0).font(.system(size: 11, weight: .semibold))
                    Text(item.1).font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(lit ? .black : .white)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(lit ? Color.white : Color.black))
                .overlay(Capsule().strokeBorder(.white.opacity(lit ? 0 : 0.16), lineWidth: 1))
                .scaleEffect(lit ? 1.07 : 1)
                .offset(y: out ? 12 : -34)
                .animation(.spring(response: 0.42, dampingFraction: 0.74).delay(out ? Double(index) * 0.04 : 0),
                           value: out)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: lit)
            }
        }
        .padding(.top, state.panelHeight(.pills))
        .opacity(state.step == .pills ? 1 : 0)
        .allowsHitTesting(false)
    }
}

/// Above the panel: the file that flies into the shelf demo.
private struct StepOverlay: View {
    @ObservedObject var state: OnboardingState

    var body: some View {
        if state.step == .shelf && state.showsContent {
            FileTile()
                .rotationEffect(.degrees(Double(state.fileTilt)))
                .offset(x: state.fileX, y: state.fileY)
                .transition(.blurReplace)
                .allowsHitTesting(false)
        }
    }
}

// MARK: Demos

private struct FileTile: View {
    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.white)
                    .frame(width: 34, height: 42)
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 3) {
                            Capsule().frame(width: 18, height: 3)
                            Capsule().frame(width: 22, height: 3)
                            Capsule().frame(width: 14, height: 3)
                        }
                        .foregroundStyle(.black.opacity(0.18))
                        .padding(6)
                    }
                Text("PDF")
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.92, green: 0.3, blue: 0.27)))
                    .offset(x: 4, y: 26)
            }
            Text("Brief.pdf")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(KitStyle.secondaryText)
        }
        .frame(width: ShelfDemo.tileSize.width, height: ShelfDemo.tileSize.height)
        .shadow(color: .black.opacity(0.35), radius: 10, y: 5)
    }
}

struct ShelfDemo: View {
    let landed: Bool

    static let tileSize = CGSize(width: 64, height: 72)
    static let spacing: CGFloat = 10

    var body: some View {
        HStack(spacing: Self.spacing) {
            tile(Color(red: 0.98, green: 0.62, blue: 0.4), "Notes.txt")
            tile(Color(red: 0.45, green: 0.8, blue: 0.62), "Photo.jpg")
            RoundedRectangle(cornerRadius: KitStyle.tileCornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(landed ? 0 : 0.2), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .background(RoundedRectangle(cornerRadius: KitStyle.tileCornerRadius, style: .continuous)
                    .fill(.white.opacity(landed ? 0.1 : 0.03)))
                .frame(width: Self.tileSize.width, height: Self.tileSize.height)
        }
    }

    private func tile(_ color: Color, _ name: String) -> some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(color)
                .frame(width: 36, height: 36)
            Text(name)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(KitStyle.secondaryText)
        }
        .frame(width: Self.tileSize.width, height: Self.tileSize.height)
        .background(RoundedRectangle(cornerRadius: KitStyle.tileCornerRadius, style: .continuous).fill(KitStyle.fill))
    }
}

private struct MusicDemo: View {
    let playing: Bool

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.98, green: 0.45, blue: 0.5), Color(red: 0.48, green: 0.34, blue: 0.95)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 70, height: 70)
                .scaleEffect(playing ? 1 : 0.86)
                .blur(radius: playing ? 0 : 6)
                .shadow(color: Color(red: 0.75, green: 0.4, blue: 0.8).opacity(playing ? 0.5 : 0), radius: 14)
            VStack(alignment: .leading, spacing: 4) {
                Text("Midnight City").font(.system(size: 14, weight: .semibold)).foregroundStyle(KitStyle.primaryText)
                Text("M83").font(.system(size: 12)).foregroundStyle(KitStyle.secondaryText)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    Capsule().fill(.white.opacity(0.8)).frame(width: playing ? 92 : 30)
                }
                .frame(width: 210, height: 4)
                .padding(.top, 8)
                HStack(spacing: 24) {
                    Image(systemName: "backward.fill")
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .contentTransition(.symbolEffect(.replace))
                    Image(systemName: "forward.fill")
                }
                .font(.system(size: 13))
                .foregroundStyle(KitStyle.primaryText)
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
            Visualizer(active: playing)
        }
    }
}

/// Bars that bounce like the notch's visualizer while music plays.
private struct Visualizer: View {
    let active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { timeline in
            HStack(spacing: 3) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(Color(red: 1, green: 0.55, blue: 0.62))
                        .frame(width: 4, height: height(of: index, at: timeline.date))
                }
            }
            .frame(height: 24)
        }
    }

    private func height(of bar: Int, at date: Date) -> CGFloat {
        guard active else { return 4 }
        let t = date.timeIntervalSinceReferenceDate
        let index = Double(bar)
        return 24 * CGFloat(0.3 + 0.7 * abs(sin(t * (5.1 + index * 1.7) + index * 1.3)))
    }
}

private struct AccessDemo: View {
    let permission: Permission
    let access: OnboardingState.Access

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: permission.symbol, color: Color(nsColor: permission.tint), size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(KitStyle.primaryText)
                Text("System Settings → Privacy & Security").font(.system(size: 11)).foregroundStyle(KitStyle.tertiaryText)
            }
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Image(systemName: access == .granted ? "checkmark.circle.fill" : "lock.fill")
                    .contentTransition(.symbolEffect(.replace))
                Text(access == .granted ? "On" : "Off")
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(access == .granted ? KitStyle.green : KitStyle.secondaryText)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(access == .granted ? KitStyle.green.opacity(0.14) : KitStyle.fill))
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
        .background(RoundedRectangle(cornerRadius: KitStyle.tileCornerRadius, style: .continuous).fill(KitStyle.fill))
    }
}

/// Every extension, each a row that toggles between Add and Added.
private struct ExtensionPicker: View {
    @ObservedObject var state: OnboardingState

    var body: some View {
        VStack(spacing: OnboardingState.permissionRowSpacing) {
            ForEach(state.offeredExtensions, id: \.id) { manifest in
                let chosen = state.chosenExtensions.contains(manifest.id)
                Button {
                    withAnimation(KitMotion.press) {
                        if chosen { state.chosenExtensions.remove(manifest.id) } else { state.chosenExtensions.insert(manifest.id) }
                    }
                    Haptics.tap()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(symbol: manifest.symbol, color: manifest.tint.flatMap { Color(hex: $0) } ?? .gray, size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(manifest.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(KitStyle.primaryText)
                            Text(manifest.summary).font(.system(size: 11)).foregroundStyle(KitStyle.tertiaryText).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        HStack(spacing: 5) {
                            Image(systemName: chosen ? "checkmark" : "plus")
                                .contentTransition(.symbolEffect(.replace))
                            Text(chosen ? "Added" : "Add")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(chosen ? .black : KitStyle.primaryText)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Capsule().fill(chosen ? Color.white : KitStyle.hoverFill))
                    }
                    .padding(.horizontal, 12)
                    .frame(height: OnboardingState.permissionRowHeight)
                    .background(RoundedRectangle(cornerRadius: KitStyle.tileCornerRadius, style: .continuous)
                        .fill(.white.opacity(chosen ? 0.1 : 0.06)))
                    .contentShape(RoundedRectangle(cornerRadius: KitStyle.tileCornerRadius, style: .continuous))
                }
                .buttonStyle(PressScaleStyle(scale: 0.98))
                .accessibilityAddTraits(chosen ? .isSelected : [])
                .accessibilityHint(manifest.summary)
            }
        }
    }
}

/// One row per permission an extension asks for, styled like Full Disk Access's.
private struct ExtensionAccessDemo: View {
    @ObservedObject var state: OnboardingState

    var body: some View {
        VStack(spacing: OnboardingState.permissionRowSpacing) {
            ForEach(state.extensionPermissions, id: \.key) { pending in
                let granted = state.isGranted(pending)
                let permission = pending.permission
                HStack(spacing: 12) {
                    SettingsIcon(symbol: permission.symbol, color: permission.tint.flatMap { Color(hex: $0) } ?? .gray, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(permission.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(KitStyle.primaryText)
                        Text(permission.detail).font(.system(size: 11)).foregroundStyle(KitStyle.tertiaryText)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 5) {
                        Image(systemName: granted ? "checkmark.circle.fill" : "lock.fill")
                            .contentTransition(.symbolEffect(.replace))
                        Text(granted ? "On" : "Off")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(granted ? KitStyle.green : KitStyle.secondaryText)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Capsule().fill(granted ? KitStyle.green.opacity(0.14) : KitStyle.fill))
                }
                .padding(.horizontal, 12)
                .frame(height: OnboardingState.permissionRowHeight)
                .background(RoundedRectangle(cornerRadius: KitStyle.tileCornerRadius, style: .continuous).fill(KitStyle.fill))
            }
        }
    }
}

private struct LoginToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(KitMotion.press) { isOn.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(isOn ? .white : KitStyle.secondaryText)
                    .contentTransition(.symbolEffect(.replace))
                Text("Open XNotch at login")
                    .font(.system(size: 12.5))
                    .foregroundStyle(KitStyle.primaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
