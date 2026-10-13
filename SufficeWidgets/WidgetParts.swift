import SwiftUI
import WidgetKit

/// The header gradient from the app, for the widgets that use the brand green.
struct BrandBackground: View {
    var body: some View {
        LinearGradient(colors: [Brand.greenDeep, Brand.greenMid], startPoint: .top, endPoint: .bottom)
    }
}

/// The leaf mark and a label, as at the top of the app.
struct WidgetHeader: View {
    var title: String
    var trailing: String?
    var onGreen = false

    var body: some View {
        HStack(spacing: 6) {
            Image("SufficeMark")
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .widgetAccentable()
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .opacity(0.8)
            }
        }
        .foregroundStyle(onGreen ? Color.white : Color.primary)
    }
}

/// A budget's icon in its color on its tint, like in the app.
struct BudgetIcon: View {
    var symbol: String
    var color: CategoryColor
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(color.ink)
            .frame(width: size, height: size)
            .background(color.tint, in: .circle)
            .widgetAccentable()
    }
}

/// A bill's initial on its color, like the Bills tab.
struct BillBadge: View {
    var name: String
    var color: CategoryColor
    var size: CGFloat = 28

    var body: some View {
        Text(name.first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.ink, in: .circle)
            .widgetAccentable()
    }
}

/// A thin rounded bar, full at `progress` 1. Over-budget shows full in red.
struct ThinBar: View {
    var progress: Double
    var color: Color
    var track: Color = Color.primary.opacity(0.1)
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule()
                    .fill(color)
                    .frame(width: max(height, proxy.size.width * min(max(progress, 0), 1)))
                    .widgetAccentable()
            }
        }
        .frame(height: height)
    }
}

/// "$1,234 left" or "$120 over".
func leftText(_ cents: Int) -> String {
    cents >= 0 ? "\(Money.whole(cents)) left" : "\(Money.whole(-cents)) over"
}

/// "Today", "Tomorrow", "Fri", "Oct 30", or "3 days late", seen from `today`.
func dueText(_ date: Date, from today: Date, calendar: Calendar = .current) -> String {
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

func isLate(_ date: Date, from today: Date, calendar: Calendar = .current) -> Bool {
    calendar.startOfDay(for: date) < calendar.startOfDay(for: today)
}

/// Shown before the app has written a snapshot.
struct OpenAppPrompt: View {
    var onGreen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetHeader(title: "Suffice", trailing: nil, onGreen: onGreen)
            Spacer(minLength: 0)
            Text("Open Suffice to set up your budget.")
                .font(.footnote.weight(.medium))
                .foregroundStyle(onGreen ? Color.white : Color.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
