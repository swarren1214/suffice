import Foundation

/// The arithmetic of splitting one charge across budgets. Pure functions, pinned by
/// SufficeTests/SplitMathTests.swift.
nonisolated enum SplitMath {
    /// What's left to assign: positive when the parts fall short, negative when they're over.
    static func remaining(total: Int, parts: [EntrySplit]) -> Int {
        total - parts.reduce(0) { $0 + $1.amountCents }
    }

    /// `total` in `count` even shares; the last takes the odd cents.
    static func evenly(total: Int, count: Int) -> [Int] {
        guard count > 0 else { return [] }
        let each = total / count
        return (0..<count).map { $0 == count - 1 ? total - each * (count - 1) : each }
    }

    /// The category a split charge shows as when one is needed: its biggest part's (the first,
    /// on a tie).
    static func primaryCategory(_ parts: [EntrySplit]) -> UUID? {
        var best: EntrySplit?
        for part in parts where best == nil || part.amountCents > best!.amountCents {
            best = part
        }
        return best?.categoryID
    }

    /// The parts kept when a split is saved: those with an amount. One part (or none) left means
    /// it isn't split any more.
    static func cleaned(_ parts: [EntrySplit]) -> [EntrySplit] {
        let kept = parts.filter { $0.amountCents > 0 }
        return kept.count > 1 ? kept : []
    }

    /// The parts after the charge's amount changes (the bank settled a different amount): the
    /// difference comes off, or goes onto, the last part, then earlier ones if the last runs
    /// out. Parts that reach zero drop off.
    static func rebalanced(_ parts: [EntrySplit], total: Int) -> [EntrySplit] {
        guard !parts.isEmpty else { return [] }
        var result = parts
        var difference = remaining(total: total, parts: parts)
        var index = result.count - 1
        while difference != 0 && index >= 0 {
            let adjusted = result[index].amountCents + difference
            if adjusted >= 0 {
                result[index].amountCents = adjusted
                difference = 0
            } else {
                difference = adjusted
                result[index].amountCents = 0
            }
            index -= 1
        }
        return cleaned(result)
    }

    /// Item amounts read from a receipt, grouped by category and scaled so they add up to the
    /// charge (tax, discounts and anything unread spread across them by size). Nil categories
    /// are kept as a part to file by hand.
    static func fromItems(_ items: [(categoryID: UUID?, cents: Int)], total: Int) -> [EntrySplit] {
        var order: [UUID?] = []
        var sums: [UUID?: Int] = [:]
        for item in items where item.cents > 0 {
            if sums[item.categoryID] == nil { order.append(item.categoryID) }
            sums[item.categoryID, default: 0] += item.cents
        }
        let read = sums.values.reduce(0, +)
        guard read > 0, total > 0 else { return [] }
        var parts = order.map { id in
            EntrySplit(categoryID: id, amountCents: Int((Double(sums[id] ?? 0) * Double(total) / Double(read)).rounded()))
        }
        // Rounding can leave a cent or two; the biggest part takes it.
        let difference = remaining(total: total, parts: parts)
        if difference != 0, let biggest = parts.indices.max(by: { parts[$0].amountCents < parts[$1].amountCents }) {
            parts[biggest].amountCents += difference
        }
        return parts.sorted { $0.amountCents > $1.amountCents }
    }
}
