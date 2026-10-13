import Foundation

enum Money {
    static func format(_ amount: Double, _ currencyCode: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        formatter.maximumFractionDigits = amount >= 1000 ? 0 : 2
        return formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.2f %@", amount, currencyCode)
    }
}

enum UsageFormat {
    /// "62%", "0.4%", "<0.1%". Unknown is a dash, never 0%.
    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "–" }
        if value > 0, value < 0.1 { return "<0.1%" }
        if value > 0, value < 10, value.rounded() != value { return String(format: "%.1f%%", value) }
        return "\(Int(value.rounded()))%"
    }

    /// "45m", "2h 14m", "3d 4h". Past or now is "now".
    static func countdown(to date: Date, from now: Date) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 59 else { return "now" }
        let minutes = seconds / 60, hours = minutes / 60, days = hours / 24
        if days > 0 { return hours % 24 == 0 ? "\(days)d" : "\(days)d \(hours % 24)h" }
        if hours > 0 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
        return "\(minutes)m"
    }

    /// Local wall-clock time of a reset: "3:40 PM" today, "Thu 9:00 AM" this week, "Oct 21" later.
    static func resetTime(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.setLocalizedDateFormatFromTemplate("jmm")
        } else if date.timeIntervalSince(now) < 6 * 24 * 3600 {
            formatter.setLocalizedDateFormatFromTemplate("EEEjmm")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
        }
        return formatter.string(from: date)
    }

    /// Full local date and time, for help text and VoiceOver.
    static func fullResetTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// "just now", "4m ago", "2h ago".
    static func age(of date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }
}
