import Foundation

/// Money is stored as whole cents (Int) everywhere, so sums never drift. These turn cents into
/// text and typed text back into cents.
nonisolated enum Money {
    static var currencyCode: String { Locale.current.currency?.identifier ?? "USD" }

    /// "$1,234.56"
    static func text(_ cents: Int) -> String {
        (Decimal(cents) / 100).formatted(.currency(code: currencyCode))
    }

    /// "$1,235": whole dollars, for rings and tiles where cents are noise.
    static func whole(_ cents: Int) -> String {
        (Decimal(cents) / 100).formatted(.currency(code: currencyCode).precision(.fractionLength(0)))
    }

    /// "+$12.00" for income, "−$12.00" for spending.
    static func signed(_ cents: Int) -> String {
        (cents >= 0 ? "+" : "−") + text(abs(cents))
    }

    /// Cents from what someone typed: "12", "12.5", "$1,234.56". Nil when it isn't a number.
    static func cents(from text: String) -> Int? {
        let cleaned = text.filter { $0.isNumber || $0 == "." || $0 == "," }
            .replacingOccurrences(of: ",", with: "")
        guard !cleaned.isEmpty, let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        var scaled = value * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return NSDecimalNumber(decimal: rounded).intValue
    }

    /// An amount field's resting text: "$1,250.00", or "" for zero so its placeholder shows.
    static func field(_ cents: Int) -> String {
        cents == 0 ? "" : text(cents)
    }

    /// The editable form of an amount: "12.50", or "" for zero.
    static func editable(_ cents: Int) -> String {
        guard cents != 0 else { return "" }
        let value = Double(abs(cents)) / 100
        return cents % 100 == 0 ? String(Int(value)) : String(format: "%.2f", value)
    }
}

/// Short dates for lists: "Today", "Yesterday", "Oct 4" this year, "Oct 4, 2025" before.
nonisolated enum DateLabel {
    static func short(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// "October 2026", or "October" this year.
    static func month(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.wide))
        }
        return date.formatted(.dateTime.month(.wide).year())
    }
}
