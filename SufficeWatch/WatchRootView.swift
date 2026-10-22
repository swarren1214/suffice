import SwiftUI

/// The watch app's pages, top to bottom.
nonisolated enum WatchPage: Hashable {
    case leftToSpend, budgets, bills
}

/// Three pages, swiped up and down: left to spend, the budgets, and bills coming up.
struct WatchRootView: View {
    @Environment(WatchStore.self) private var store
    /// The first page, or the one screenshot mode asks for.
    @State private var page: WatchPage = ScreenshotMode.screen?.page ?? .leftToSpend

    var body: some View {
        if let snapshot = store.snapshot {
            TabView(selection: $page) {
                LeftToSpendPage(snapshot: snapshot).tag(WatchPage.leftToSpend)
                BudgetsPage(snapshot: snapshot).tag(WatchPage.budgets)
                BillsPage(snapshot: snapshot).tag(WatchPage.bills)
            }
            .tabViewStyle(.verticalPage)
            .containerBackground(Brand.green.gradient.opacity(0.35), for: .tabView)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "iphone")
                    .font(.title)
                    .foregroundStyle(Brand.greenBright)
                Text("Open Suffice on your iPhone to see your budget here.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
    }
}

/// The month's ring: what's left of everything planned.
private struct LeftToSpendPage: View {
    var snapshot: WidgetSnapshot

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.15), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: remaining)
                    .stroke(ringGradient, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text(Money.whole(abs(snapshot.leftCents)))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text(snapshot.leftCents >= 0 ? "left" : "over")
                        .font(.footnote)
                        .foregroundStyle(snapshot.leftCents >= 0 ? Color.secondary : Brand.expenseInk)
                }
                .padding(.horizontal, 18)
            }
            .frame(maxWidth: 140, maxHeight: 140)
            Text("\(Money.whole(snapshot.spentCents)) of \(Money.whole(snapshot.budgetedCents))")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            UpdatedLine(date: snapshot.updated)
        }
        .navigationTitle(snapshot.month.formatted(.dateTime.month(.wide)))
        .accessibilityElement(children: .combine)
    }

    private var remaining: Double { min(max(1 - snapshot.progress, 0), 1) }
}

/// Every budget with its ring and what's left, the tightest first.
private struct BudgetsPage: View {
    var snapshot: WidgetSnapshot

    var body: some View {
        List {
            ForEach(snapshot.budgets.filter { $0.limitCents > 0 }.sorted { $0.progress > $1.progress }) { budget in
                HStack(spacing: 10) {
                    ZStack {
                        Circle().stroke(budget.color.color.opacity(0.25), lineWidth: 4)
                        Circle()
                            .trim(from: 0, to: min(budget.progress, 1))
                            .stroke(budget.progress > 1 ? Brand.expenseInk : budget.color.color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Image(systemName: budget.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(budget.color.color)
                    }
                    .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(budget.name).font(.footnote.weight(.semibold)).lineLimit(1)
                        Text(budget.leftCents >= 0 ? "\(Money.whole(budget.leftCents)) left" : "\(Money.whole(-budget.leftCents)) over")
                            .font(.caption2)
                            .foregroundStyle(budget.leftCents >= 0 ? Color.secondary : Brand.expenseInk)
                            .monospacedDigit()
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .navigationTitle("Budgets")
    }
}

/// Bills still to pay: late ones, then the next two weeks.
private struct BillsPage: View {
    var snapshot: WidgetSnapshot

    var body: some View {
        let calendar = Calendar.current
        let horizon = calendar.date(byAdding: .day, value: 14, to: calendar.startOfDay(for: .now)) ?? .now
        let dues = snapshot.unpaid.filter { $0.date < horizon }
        List {
            if dues.isEmpty {
                Text("Nothing due in the next two weeks.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(dues) { due in
                HStack(spacing: 10) {
                    Text(due.name.first.map { String($0).uppercased() } ?? "?")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(due.color.color, in: .circle)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(due.name).font(.footnote.weight(.semibold)).lineLimit(1)
                        Text("\(Money.text(due.amountCents)) · \(WatchDates.due(due.date))")
                            .font(.caption2)
                            .foregroundStyle(due.date < calendar.startOfDay(for: .now) ? Brand.expenseInk : Color.secondary)
                            .monospacedDigit()
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .navigationTitle("Bills")
    }
}

private struct UpdatedLine: View {
    var date: Date

    var body: some View {
        Text("Updated \(date.formatted(.relative(presentation: .named)))")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}

private let ringGradient = AngularGradient(colors: [Brand.greenBright, Color.mint, Brand.greenBright], center: .center)

enum WatchDates {
    /// "Today", "Tomorrow", "Fri", "Oct 30", or "3 days late".
    static func due(_ date: Date, from today: Date = .now, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: today), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case ..<(-1): return "\(-days) days late"
        case -1: return "1 day late"
        case 0: return "Today"
        case 1: return "Tomorrow"
        case 2...6: return date.formatted(.dateTime.weekday(.abbreviated))
        default: return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}
