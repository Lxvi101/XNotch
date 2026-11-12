import SwiftUI

/// The recording's waveform: newest sound enters on the right and scrolls
/// left. Quiet moments are dots, speech rises into rounded bars, and the
/// oldest bars fade out at the left edge.
struct LiveWaveform: View {
    let levels: [Float]
    var color: Color = .white

    var body: some View {
        Canvas { context, size in
            let count = levels.count
            guard count > 0 else { return }
            let pitch = size.width / CGFloat(count)
            let barWidth = max(2, pitch * 0.42)
            for (index, level) in levels.enumerated() {
                let x = CGFloat(index) * pitch + pitch / 2
                let position = CGFloat(index) / CGFloat(max(1, count - 1))
                let fade = min(1, position * 3.2)
                let shaped = CGFloat(pow(Double(level), 0.8))
                let height = max(barWidth, shaped * size.height)
                let rect = CGRect(x: x - barWidth / 2, y: (size.height - height) / 2, width: barWidth, height: height)
                let opacity = (level < 0.04 ? 0.35 : 0.55 + 0.45 * Double(shaped)) * Double(fade)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color.opacity(opacity)))
            }
        }
        .drawingGroup()
    }
}

/// A finished voice note's waveform; bars up to `progress` light up.
struct NoteWaveform: View {
    let levels: [UInt8]
    let progress: Double
    var bars = 36
    var tint: Color = .white

    var body: some View {
        Canvas { context, size in
            let samples = Self.resample(levels, to: bars)
            let pitch = size.width / CGFloat(bars)
            let barWidth = max(2, pitch * 0.5)
            for (index, sample) in samples.enumerated() {
                let level = CGFloat(sample) / 255
                let height = max(barWidth, pow(level, 0.8) * size.height)
                let x = CGFloat(index) * pitch + (pitch - barWidth) / 2
                let rect = CGRect(x: x, y: (size.height - height) / 2, width: barWidth, height: height)
                let played = (Double(index) + 0.5) / Double(bars) <= progress
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                             with: .color(tint.opacity(played ? 1 : 0.38)))
            }
        }
    }

    static func resample(_ levels: [UInt8], to count: Int) -> [UInt8] {
        guard !levels.isEmpty else { return Array(repeating: 20, count: count) }
        return (0..<count).map { index in
            let from = index * levels.count / count
            let to = max(from + 1, (index + 1) * levels.count / count)
            return levels[from..<min(to, levels.count)].max() ?? 0
        }
    }
}

enum Durations {
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
