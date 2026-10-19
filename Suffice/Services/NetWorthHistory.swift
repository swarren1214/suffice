import Foundation
import SwiftData

/// One point on the net worth trend.
struct NetWorthPoint: Identifiable, Hashable {
    var month: Date
    var netCents: Int

    var id: Date { month }
}

/// The net worth trend's history: one snapshot a month, written as the totals change, so the
/// chart has something to draw for months gone by. Only months the app was opened in have one.
enum NetWorthHistory {
    /// Saves this month's totals, if they changed since last time.
    static func record(_ totals: NetWorthTotals, in context: ModelContext, now: Date = .now, calendar: Calendar = .current) {
        let span = MonthSpan(containing: now, calendar: calendar)
        let start = span.start
        let end = span.end
        let descriptor = FetchDescriptor<NetWorthSnapshot>(predicate: #Predicate { $0.month >= start && $0.month < end })
        let existing = (try? context.fetch(descriptor)) ?? []
        if let latest = existing.max(by: { $0.updatedAt < $1.updatedAt }) {
            guard latest.assetsCents != totals.assetsCents || latest.debtsCents != totals.debtsCents else { return }
            latest.assetsCents = totals.assetsCents
            latest.debtsCents = totals.debtsCents
            latest.updatedAt = now
        } else {
            context.insert(NetWorthSnapshot(month: start, assetsCents: totals.assetsCents, debtsCents: totals.debtsCents))
        }
        try? context.save()
    }

    /// One point a month, oldest first: the latest snapshot for each month (two devices may
    /// each have written one), and this month from the live totals.
    static func points(_ snapshots: [NetWorthSnapshot], current: NetWorthTotals, now: Date = .now, calendar: Calendar = .current) -> [NetWorthPoint] {
        let thisMonth = MonthSpan(containing: now, calendar: calendar).start
        var latest: [Date: NetWorthSnapshot] = [:]
        for snapshot in snapshots {
            let month = MonthSpan(containing: snapshot.month, calendar: calendar).start
            guard month < thisMonth else { continue }
            if let kept = latest[month], kept.updatedAt >= snapshot.updatedAt { continue }
            latest[month] = snapshot
        }
        var points = latest.map { NetWorthPoint(month: $0.key, netCents: $0.value.netCents) }
        points.append(NetWorthPoint(month: thisMonth, netCents: current.netCents))
        return points.sorted { $0.month < $1.month }
    }
}
