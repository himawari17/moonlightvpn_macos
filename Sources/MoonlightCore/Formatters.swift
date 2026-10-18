import Foundation

/// Byte, duration and date formatting, matching the strings the design shows.
///
/// The design is Russian-first and writes sizes as `24,8 ГБ` — decimal comma,
/// one fraction digit, a non-breaking space before the unit. English is
/// `24.8 GB`. Both come out of here so a screen never hand-rolls a number.
public enum Format {

    /// Binary units (1024), which is what a panel's `subscription-userinfo`
    /// byte counts mean.
    public static func bytes(_ value: Int64?, locale: AppLocale = .ru) -> String {
        guard let value else { return locale == .ru ? "—" : "—" }
        let units = locale == .ru
            ? ["Б", "КБ", "МБ", "ГБ", "ТБ", "ПБ"]
            : ["B", "KB", "MB", "GB", "TB", "PB"]

        var amount = Double(value)
        var index = 0
        while amount >= 1024, index < units.count - 1 {
            amount /= 1024
            index += 1
        }
        // Bytes and kilobytes have no meaningful fraction.
        let digits = index <= 1 ? 0 : (amount >= 100 ? 0 : 1)
        return "\(decimal(amount, digits: digits, locale: locale))\u{00A0}\(units[index])"
    }

    /// How much of a download has arrived: "12,3 МБ из 36,6 МБ", or only what
    /// has arrived when the server did not say how big it is.
    public static func transfer(_ received: Int64, of total: Int64?, locale: AppLocale = .ru) -> String {
        guard let total else { return bytes(received, locale: locale) }
        return "\(bytes(received, locale: locale)) \(locale == .ru ? "из" : "of") \(bytes(total, locale: locale))"
    }

    /// A transfer rate. The design's connect screen updates this every second,
    /// so it stays on one line at any magnitude.
    public static func rate(_ bytesPerSecond: Int64?, locale: AppLocale = .ru) -> String {
        guard let bytesPerSecond else { return "—" }
        return bytes(bytesPerSecond, locale: locale) + (locale == .ru ? "/с" : "/s")
    }

    /// `HH:MM:SS`, the connect dial's timer. Hours are not capped at 24 —
    /// a tunnel up for two days reads `48:12:07`, not `00:12:07`.
    public static func duration(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        return String(format: "%02d:%02d:%02d",
                      seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }

    /// "12 дней" / "12 days", with Russian's three-way plural.
    public static func days(_ count: Int?, locale: AppLocale = .ru) -> String {
        guard let count else { return locale == .ru ? "без срока" : "no expiry" }
        return counted(count, locale, en: ("day", "days"), ru: ("день", "дня", "дней"))
    }

    /// Days left, or hours once it is under a day — "12 дней", "7 часов".
    ///
    /// A plan with nine hours on it reading "1 день" is the kind of rounding
    /// that loses someone a day of service.
    public static func timeLeft(_ expire: Date?, locale: AppLocale = .ru) -> String {
        guard let expire else { return locale == .ru ? "без срока" : "no expiry" }
        let seconds = expire.timeIntervalSinceNow
        guard seconds > 0 else { return days(0, locale: locale) }
        if seconds >= 86_400 { return days(Int(ceil(seconds / 86_400)), locale: locale) }
        return hours(max(1, Int(ceil(seconds / 3600))), locale: locale)
    }

    /// Russian's three-way plural again, for hours.
    public static func hours(_ count: Int, locale: AppLocale = .ru) -> String {
        return counted(count, locale, en: ("hour", "hours"), ru: ("час", "часа", "часов"))
    }

    /// "19 узлов" / "19 nodes". The count used to be followed by the one word
    /// whatever it was, so a plan with three servers read "3 узлов" and one
    /// with a single server, in English, "1 nodes".
    public static func nodes(_ count: Int, locale: AppLocale = .ru) -> String {
        return counted(count, locale, en: ("node", "nodes"), ru: ("узел", "узла", "узлов"))
    }

    /// `count` and the noun in the form that follows it: one of English's
    /// two, or of Russian's three.
    private static func counted(_ count: Int, _ locale: AppLocale,
                                en: (one: String, many: String),
                                ru: (one: String, few: String, many: String)) -> String {
        let noun = locale == .en ? (count == 1 ? en.one : en.many) : russian(count, ru.one, ru.few, ru.many)
        return "\(count) \(noun)"
    }

    /// The form a Russian noun takes after `count`: the first for 1, 21, 31…,
    /// the second for 2–4, 22–24…, the third for everything else — and for
    /// 11–14, which take it despite what they end in.
    private static func russian(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        let mod100 = count % 100
        let mod10 = count % 10
        if (11...14).contains(mod100) { return many }
        if mod10 == 1 { return one }
        if (2...4).contains(mod10) { return few }
        return many
    }

    /// "24,8 из 100 ГБ" / "24.8 of 100 GB". An unlimited plan says so rather
    /// than showing a denominator it does not have.
    public static func quota(used: Int64?, total: Int64?, locale: AppLocale = .ru) -> String {
        guard let total, total > 0 else {
            let usedText = bytes(used, locale: locale)
            return locale == .ru ? "\(usedText) · без лимита" : "\(usedText) · unlimited"
        }
        // The unit is taken from the total so both halves read in the same one.
        let totalText = bytes(total, locale: locale)
        let unit = totalText.split(separator: "\u{00A0}").last.map(String.init) ?? ""
        let scale = unitScale(unit, locale: locale)
        let usedValue = decimal(Double(used ?? 0) / scale, digits: 1, locale: locale)
        return locale == .ru
            ? "\(usedValue) из \(totalText)"
            : "\(usedValue) of \(totalText)"
    }

    /// "3 слота" / "3 slots" — the free device slots line.
    public static func slots(_ count: Int, locale: AppLocale = .ru) -> String {
        if locale == .en { return "\(count) slot\(count == 1 ? "" : "s")" }
        let mod100 = count % 100
        let mod10 = count % 10
        let word: String
        if (11...14).contains(mod100) { word = "слотов" }
        else if mod10 == 1 { word = "слот" }
        else if (2...4).contains(mod10) { word = "слота" }
        else { word = "слотов" }
        return "\(count) \(word)"
    }

    /// `n/a` rather than a dash for a node that has not answered: a dash reads
    /// as "not measured yet", and the two are worth telling apart when one of
    /// them means the node is down.
    /// How long ago something started: "4 с", "2 мин", "1 ч".
    public static func age(_ since: Date, locale: AppLocale = .ru) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(since)))
        if seconds < 60 { return "\(seconds) \(locale == .ru ? "с" : "s")" }
        if seconds < 3600 { return "\(seconds / 60) \(locale == .ru ? "мин" : "m")" }
        return "\(seconds / 3600) \(locale == .ru ? "ч" : "h")"
    }

    /// "24 ms"; "n/a" for a node whose probe timed out; a dash for one not
    /// measured yet. Only a probe that ran and got nothing says `n/a`.
    public static func latency(_ ms: Int?, unreachable: Bool = false, locale: AppLocale = .ru) -> String {
        if let ms { return "\(ms) ms" }
        return unreachable ? "n/a" : "–"
    }

    /// "1 сентября" — the reset/expiry date line on the subscription card.
    public static func date(_ date: Date?, locale: AppLocale = .ru) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: locale == .ru ? "ru_RU" : "en_US")
        formatter.setLocalizedDateFormatFromTemplate("d MMMM")
        return formatter.string(from: date)
    }

    // MARK: -

    private static func unitScale(_ unit: String, locale: AppLocale) -> Double {
        let units = locale == .ru
            ? ["Б", "КБ", "МБ", "ГБ", "ТБ", "ПБ"]
            : ["B", "KB", "MB", "GB", "TB", "PB"]
        let index = units.firstIndex(of: unit) ?? 0
        return pow(1024, Double(index))
    }

    private static func decimal(_ value: Double, digits: Int, locale: AppLocale) -> String {
        let text = String(format: "%.\(digits)f", value)
        return locale == .ru ? text.replacingOccurrences(of: ".", with: ",") : text
    }
}

public enum AppLocale: String, Codable, CaseIterable, Sendable {
    case ru
    case en
}
