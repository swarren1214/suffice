import SwiftUI

enum AppTab: Hashable {
    case overview, activity, budget, bills, search
}

/// The system Liquid Glass tab bar from the designs: Overview, Activity, Budget and Bills in
/// the capsule, and Search as the separate round button (the search tab, which iOS draws in
/// its own circle).
struct RootTabView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            Tab("Overview", systemImage: "square.grid.2x2", value: AppTab.overview) {
                NavigationStack { OverviewView() }
            }

            Tab("Activity", systemImage: "creditcard", value: AppTab.activity) {
                NavigationStack { ActivityView() }
            }

            Tab("Budget", systemImage: "chart.pie", value: AppTab.budget) {
                NavigationStack { BudgetView() }
            }

            Tab("Bills", systemImage: "calendar.badge.clock", value: AppTab.bills) {
                NavigationStack { BillsView() }
            }

            Tab(value: AppTab.search, role: .search) {
                NavigationStack { SearchView() }
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
        }
        .tabViewSearchActivation(.searchTabSelection)
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}

#Preview {
    RootTabView()
        .previewEnvironment()
}
