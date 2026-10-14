import SwiftUI
import WidgetKit

/// The ring's colors: green while there's plenty left, through yellow, to red near the end.
/// Gauges fill with what's left, so the color at the tip shows how close it's getting.
let leftGradient = Gradient(colors: [.red, .orange, .yellow, Color(hex: 0x2FB45E)])

/// What's left of a budget (or of everything), 0...1.
func remainingFraction(spent: Int, limit: Int) -> Double {
    guard limit > 0 else { return 0 }
    return min(max(1 - Double(spent) / Double(limit), 0), 1)
}

/// "$19 left" or "$12 over".
func leftLabel(_ cents: Int) -> String {
    cents >= 0 ? "\(Money.whole(cents)) left" : "\(Money.whole(-cents)) over"
}

/// Before the iPhone has sent anything.
struct NoDataView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline:
            Text("Open Suffice on iPhone")
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Text("Suffice").font(.headline).widgetAccentable()
                Text("Open Suffice on your iPhone").font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "dollarsign")
                    .font(.title3.weight(.semibold))
                    .widgetAccentable()
            }
        }
    }
}

extension WidgetSnapshot {
    /// What the complication picker shows before real numbers arrive.
    static var watchSample: WidgetSnapshot {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let month = calendar.dateInterval(of: .month, for: today)?.start ?? today
        return WidgetSnapshot(
            updated: .now,
            month: month,
            budgetedCents: 5_200_00,
            spentCents: 3_046_18,
            incomeCents: 6_400_00,
            cashCents: 8_412_55,
            budgets: [
                Budget(id: UUID(), name: "Dining Out", symbol: "fork.knife", color: .red, spentCents: 231_40, limitCents: 250_00),
                Budget(id: UUID(), name: "Groceries", symbol: "cart", color: .green, spentCents: 512_40, limitCents: 900_00),
                Budget(id: UUID(), name: "Home", symbol: "house", color: .orange, spentCents: 2_201_79, limitCents: 2_400_00),
            ],
            dues: [
                Due(billID: UUID(), name: "T-Mobile", amountCents: 161_06, date: today, color: .pink, isPaid: false, isAutopay: true, isSubscription: false),
            ]
        )
    }
}
