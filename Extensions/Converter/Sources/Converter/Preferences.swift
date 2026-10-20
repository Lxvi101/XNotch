import AppKit
import Combine

enum Quality: String, CaseIterable, Identifiable, Sendable {
    case high, balanced, small

    var id: String { rawValue }

    var title: String {
        switch self {
        case .high: "Best"
        case .balanced: "Balanced"
        case .small: "Smallest"
        }
    }

    /// JPEG and HEIC quality.
    var image: Double {
        switch self {
        case .high: 0.92
        case .balanced: 0.82
        case .small: 0.65
        }
    }

    /// What Compress re-encodes images at.
    var compressedImage: Double { image - 0.2 }

    /// x264's constant rate factor; lower is better.
    var crf: Int {
        switch self {
        case .high: 19
        case .balanced: 23
        case .small: 27
        }
    }

    var webp: Int {
        switch self {
        case .high: 90
        case .balanced: 80
        case .small: 65
        }
    }
}

/// What opens the wheel while its key is held mid-drag.
enum WheelGesture: String, CaseIterable, Identifiable {
    case pause, shake, press

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pause: "Pause"
        case .shake: "Shake"
        case .press: "Nothing else"
        }
    }

    var detail: String {
        switch self {
        case .pause: "Hold the key and rest the pointer for a moment."
        case .shake: "Hold the key and shake the pointer side to side."
        case .press: "The wheel opens as soon as you press the key."
        }
    }
}

/// How long the pointer rests, key held, before the wheel opens.
enum PauseDelay: String, CaseIterable, Identifiable {
    case quick, normal, relaxed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quick: "Quick"
        case .normal: "Default"
        case .relaxed: "Relaxed"
        }
    }

    var seconds: TimeInterval {
        switch self {
        case .quick: 0.18
        case .normal: 0.32
        case .relaxed: 0.6
        }
    }
}

enum WheelModifier: String, CaseIterable, Identifiable {
    case command, shift, option, control

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shift: "⇧ Shift"
        case .control: "⌃ Control"
        case .option: "⌥ Option"
        case .command: "⌘ Command"
        }
    }

    var flags: NSEvent.ModifierFlags {
        switch self {
        case .shift: .shift
        case .control: .control
        case .option: .option
        case .command: .command
        }
    }
}

enum OutputLocation: String, CaseIterable, Identifiable {
    case besideOriginal, downloads

    var id: String { rawValue }

    var title: String {
        switch self {
        case .besideOriginal: "Next to the original"
        case .downloads: "Downloads"
        }
    }
}

@MainActor
final class ConverterPreferences: ObservableObject {
    private let defaults: UserDefaults

    /// The key held while dragging; nothing opens the wheel without it.
    @Published var modifier: WheelModifier { didSet { defaults.set(modifier.rawValue, forKey: "modifier") } }
    @Published var gesture: WheelGesture { didSet { defaults.set(gesture.rawValue, forKey: "gesture") } }
    @Published var pauseDelay: PauseDelay { didSet { defaults.set(pauseDelay.rawValue, forKey: "pauseDelay") } }
    @Published var quality: Quality { didSet { defaults.set(quality.rawValue, forKey: "quality") } }
    @Published var output: OutputLocation { didSet { defaults.set(output.rawValue, forKey: "output") } }
    @Published var revealWhenDone: Bool { didSet { defaults.set(revealWhenDone, forKey: "revealWhenDone") } }
    @Published var ffmpegPath: String? { didSet { defaults.set(ffmpegPath, forKey: "ffmpegPath") } }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        modifier = defaults.string(forKey: "modifier").flatMap(WheelModifier.init) ?? .command
        gesture = defaults.string(forKey: "gesture").flatMap(WheelGesture.init) ?? .pause
        pauseDelay = defaults.string(forKey: "pauseDelay").flatMap(PauseDelay.init) ?? .normal
        quality = defaults.string(forKey: "quality").flatMap(Quality.init) ?? .balanced
        output = defaults.string(forKey: "output").flatMap(OutputLocation.init) ?? .besideOriginal
        revealWhenDone = defaults.bool(forKey: "revealWhenDone")
        ffmpegPath = defaults.string(forKey: "ffmpegPath")
    }
}
