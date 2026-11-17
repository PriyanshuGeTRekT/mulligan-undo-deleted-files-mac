import Foundation

public enum Fmt {
    public static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    public static func ago(_ d: Date, now: Date = Date()) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: now)
    }

    public static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    /// Accepts "now", "30m", "2h ago", "3 days ago", "yesterday", "yesterday 18:00", "today 09:30",
    /// "2026-11-17", "2026-11-17 10:30", "2026-11-17T10:30:00Z".
    public static func parseWhen(_ input: String, now: Date = Date()) -> Date? {
        let s = input.trimmingCharacters(in: .whitespaces).lowercased()
        if s.isEmpty { return nil }
        if s == "now" { return now }
        let cal = Calendar.current

        // relative: 30m, 2h ago, 3 days
        let rel = s.replacingOccurrences(of: " ago", with: "")
        let scanner = Scanner(string: rel)
        if let n = scanner.scanDouble() {
            let unit = rel[scanner.currentIndex...].trimmingCharacters(in: .whitespaces)
            let mult: Double?
            switch unit {
            case "s", "sec", "secs", "second", "seconds": mult = 1
            case "m", "min", "mins", "minute", "minutes": mult = 60
            case "h", "hr", "hrs", "hour", "hours": mult = 3600
            case "d", "day", "days": mult = 86400
            case "w", "wk", "week", "weeks": mult = 604800
            default: mult = nil
            }
            if let m = mult { return now.addingTimeInterval(-n * m) }
        }

        // today / yesterday [HH:mm]
        for (word, offset) in [("today", 0), ("yesterday", -1)] where s.hasPrefix(word) {
            let rest = s.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
            guard let day = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: now)) else { return nil }
            if rest.isEmpty { return word == "today" ? day : day.addingTimeInterval(12 * 3600) }
            let hm = rest.split(separator: ":").compactMap { Int($0) }
            guard hm.count >= 1 else { return nil }
            return cal.date(bySettingHour: hm[0], minute: hm.count > 1 ? hm[1] : 0, second: 0, of: day)
        }

        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: input) { return d }
        for fmt in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = fmt
            if let d = f.date(from: input.trimmingCharacters(in: .whitespaces)) { return d }
        }
        return nil
    }
}
