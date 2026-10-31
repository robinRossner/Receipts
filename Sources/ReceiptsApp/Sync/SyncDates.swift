import Foundation

/// Timestamps on the wire and in the local database. The server speaks UTC ISO 8601 with
/// milliseconds and `Z`; the Mac app's older rows hold `2026-07-14T10:20:30Z` or (Python era)
/// `2026-07-14 10:20:30`. Last-write-wins compares INSTANTS, never strings (`...:30.5Z` sorts
/// before `...:30Z` as text).
enum SyncDate {
    /// Parses what `datetime.fromisoformat` (as used by `migrate_mac_data.parse_time`) accepts: date only,
    /// `T` or space separator, optional fraction, optional `Z` / `+hh:mm` / `+hhmm` offset (none = UTC).
    static func parse(_ raw: String?) -> Date? {
        guard var s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        s = s.replacingOccurrences(of: " ", with: "T")
        let chars = Array(s.utf8)
        var i = 0
        func digits(_ n: Int) -> Int? {
            guard i + n <= chars.count else { return nil }
            var v = 0
            for k in 0..<n {
                let c = chars[i + k]
                guard c >= 48, c <= 57 else { return nil }
                v = v * 10 + Int(c - 48)
            }
            i += n
            return v
        }
        func eat(_ c: Character) -> Bool {
            guard i < chars.count, chars[i] == c.asciiValue! else { return false }
            i += 1
            return true
        }
        guard let year = digits(4), eat("-"), let month = digits(2), eat("-"), let day = digits(2) else { return nil }
        var hour = 0, minute = 0, second = 0
        var fraction = 0.0
        var offset = 0
        if i < chars.count {
            guard eat("T"), let h = digits(2), eat(":"), let m = digits(2) else { return nil }
            hour = h; minute = m
            if eat(":") {
                guard let sec = digits(2) else { return nil }
                second = sec
                if eat(".") || eat(",") {
                    var scale = 0.1
                    var any = false
                    while i < chars.count, chars[i] >= 48, chars[i] <= 57 {
                        fraction += Double(chars[i] - 48) * scale
                        scale /= 10
                        i += 1
                        any = true
                    }
                    if !any { return nil }
                }
            }
            if eat("Z") {
                offset = 0
            } else if i < chars.count, chars[i] == UInt8(ascii: "+") || chars[i] == UInt8(ascii: "-") {
                let sign = chars[i] == UInt8(ascii: "-") ? -1 : 1
                i += 1
                guard let oh = digits(2) else { return nil }
                _ = eat(":")
                let om = digits(2) ?? 0
                offset = sign * (oh * 3600 + om * 60)
            }
            if i != chars.count { return nil }
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = hour; c.minute = minute; c.second = second
        guard let base = cal.date(from: c) else { return nil }
        return base.addingTimeInterval(fraction - Double(offset))
    }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// `2026-10-31T12:21:21.775Z`, the wire format.
    static func string(from date: Date) -> String { formatter.string(from: date) }

    static func now() -> String { string(from: Date()) }

    /// Same instant (to the millisecond), whatever the text format.
    static func sameInstant(_ a: String?, _ b: String?) -> Bool {
        guard let x = parse(a), let y = parse(b) else { return a == b }
        return abs(x.timeIntervalSince(y)) < 0.001
    }
}
