import SwiftUI

/// Suffice's stops on the shared tour (HearthTour.swift): Overview, Activity, Budget, Bills and
/// Search. It shows once after onboarding and again from Profile › Take the Tour. Screens mark
/// what each step points at with `.hearthTourTarget(_:)`.
enum SufficeTour {
    static let overview = "overview"
    static let activity = "activity"
    static let budget = "budget"
    static let bills = "bills"
    static let search = "search"

    static let steps: [HearthTourStep] = [
        HearthTourStep(overview, title: "Overview", message: "Your cash, cards and loans in one place. Swipe through your accounts, and change the month up top.", symbol: "square.grid.2x2", color: .green),
        HearthTourStep(activity, title: "Activity", message: "Every transaction for the month, sorted into your budget as it comes in. Filter by kind or by person.", symbol: "creditcard", color: .blue),
        HearthTourStep(budget, title: "Budget", message: "What you planned for each category and what's left. Set money aside for the things that come once a year.", symbol: "chart.pie", color: .orange),
        HearthTourStep(bills, title: "Bills", message: "What's due and when. Suffice reminds you before each one, and marks it paid when the payment comes through.", symbol: "calendar.badge.clock", color: .purple),
        HearthTourStep(search, title: "Search", message: "Find any transaction by merchant, amount, category or note.", symbol: "magnifyingglass", color: .pink),
    ]

    static func tab(for step: HearthTourStep) -> AppTab {
        switch step.id {
        case activity: .activity
        case budget: .budget
        case bills: .bills
        case search: .search
        default: .overview
        }
    }
}
