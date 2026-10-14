import AppIntents
import SwiftUI
import WidgetKit

/// A favorite budget on the watch face: its icon in a ring that empties as it's spent, and
/// what's left. Pick the budget when editing the face (or from the suggestions for each one).
struct BudgetComplication: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetStore.Kind.watchBudget, intent: SelectBudgetIntent.self, provider: BudgetProvider()) { entry in
            BudgetComplicationView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Budget")
        .description("What's left in one budget.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Choosing the budget

struct BudgetEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Budget"
    static let defaultQuery = BudgetQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    init(_ budget: WidgetSnapshot.Budget) {
        self.init(id: budget.id.uuidString, name: budget.name)
    }
}

/// The budgets from the last snapshot the iPhone sent.
struct BudgetQuery: EntityQuery {
    func entities(for identifiers: [BudgetEntity.ID]) async throws -> [BudgetEntity] {
        (WidgetStore.load()?.budgets ?? []).filter { identifiers.contains($0.id.uuidString) }.map(BudgetEntity.init)
    }

    func suggestedEntities() async throws -> [BudgetEntity] {
        (WidgetStore.load()?.budgets ?? []).map(BudgetEntity.init)
    }

    func defaultResult() async -> BudgetEntity? {
        WidgetStore.load()?.tightestBudget.map(BudgetEntity.init)
    }
}

struct SelectBudgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Budget"
    static let description: IntentDescription = "Choose the budget to show."

    @Parameter(title: "Budget")
    var budget: BudgetEntity?

    init() {}

    init(budget: BudgetEntity) {
        self.budget = budget
    }
}

// MARK: - Timeline

struct BudgetEntry: TimelineEntry {
    let date: Date
    /// Nil before the iPhone has sent anything.
    let budget: WidgetSnapshot.Budget?
    let hasSnapshot: Bool
    var relevance: TimelineEntryRelevance?
}

struct BudgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> BudgetEntry {
        BudgetEntry(date: .now, budget: WidgetSnapshot.watchSample.budgets.first, hasSnapshot: true)
    }

    func snapshot(for configuration: SelectBudgetIntent, in context: Context) async -> BudgetEntry {
        let snapshot = WidgetStore.load() ?? (context.isPreview ? .watchSample : nil)
        return BudgetEntry(date: .now, budget: Self.budget(for: configuration, in: snapshot), hasSnapshot: snapshot != nil)
    }

    func timeline(for configuration: SelectBudgetIntent, in context: Context) async -> Timeline<BudgetEntry> {
        let snapshot = WidgetStore.load()
        let budget = Self.budget(for: configuration, in: snapshot)
        // Rises in the Smart Stack as the budget runs low.
        let score = Float(min(budget?.progress ?? 0, 1.2) * 60)
        let entry = BudgetEntry(date: .now, budget: budget, hasSnapshot: snapshot != nil, relevance: TimelineEntryRelevance(score: score))
        return Timeline(entries: [entry], policy: .never)
    }

    /// One suggestion per budget, so each can be put on the face without editing.
    func recommendations() -> [AppIntentRecommendation<SelectBudgetIntent>] {
        (WidgetStore.load()?.budgets ?? WidgetSnapshot.watchSample.budgets)
            .filter { $0.limitCents > 0 }
            .prefix(8)
            .map { budget in
                AppIntentRecommendation(intent: SelectBudgetIntent(budget: BudgetEntity(budget)), description: Text(budget.name))
            }
    }

    private static func budget(for configuration: SelectBudgetIntent, in snapshot: WidgetSnapshot?) -> WidgetSnapshot.Budget? {
        guard let snapshot else { return nil }
        if let id = configuration.budget?.id, let chosen = snapshot.budgets.first(where: { $0.id.uuidString == id }) {
            return chosen
        }
        return snapshot.tightestBudget
    }
}

extension WidgetSnapshot {
    /// The budget closest to its amount: the default when none is picked.
    var tightestBudget: Budget? {
        budgets.filter { $0.limitCents > 0 }.max { $0.progress < $1.progress } ?? budgets.first
    }
}

// MARK: - Views

struct BudgetComplicationView: View {
    var entry: BudgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let budget = entry.budget {
            let remaining = remainingFraction(spent: budget.spentCents, limit: budget.limitCents)
            switch family {
            case .accessoryCircular:
                Gauge(value: remaining) {
                    Image(systemName: budget.symbol)
                } currentValueLabel: {
                    Text(Money.compact(budget.leftCents))
                        .minimumScaleFactor(0.5)
                }
                .gaugeStyle(.accessoryCircular)
                .tint(budget.leftCents >= 0 ? budget.color.color : .red)
                .widgetAccentable()
                .accessibilityLabel("\(budget.name), \(leftLabel(budget.leftCents))")
            case .accessoryCorner:
                Image(systemName: budget.symbol)
                    .font(.title3.weight(.semibold))
                    .widgetAccentable()
                    .widgetLabel {
                        Gauge(value: remaining) {
                            Text(budget.name)
                        } currentValueLabel: {
                            Text(Money.compact(budget.leftCents))
                        }
                        .tint(budget.leftCents >= 0 ? budget.color.color : .red)
                    }
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 2) {
                    Label(budget.name, systemImage: budget.symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(budget.color.color)
                        .widgetAccentable()
                        .lineLimit(1)
                    Text(leftLabel(budget.leftCents))
                        .font(.headline)
                        .monospacedDigit()
                    Gauge(value: remaining) {
                        EmptyView()
                    }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .tint(budget.leftCents >= 0 ? budget.color.color : .red)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            default:
                Label("\(budget.name) \(leftLabel(budget.leftCents))", systemImage: budget.symbol)
            }
        } else {
            NoDataView()
        }
    }
}
