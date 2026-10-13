import SwiftUI

enum AppTab: Hashable {
    case overview, activity, budget, bills, search
}

/// The system Liquid Glass tab bar from the designs: Overview, Activity, Budget and Bills in
/// the capsule, and Search as the separate round button (the search tab, which iOS draws in
/// its own circle).
struct RootTabView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            Tab(value: AppTab.overview) {
                NavigationStack { OverviewView() }
            } label: {
                tabIcon("Overview", "square.grid.2x2")
            }

            Tab(value: AppTab.activity) {
                NavigationStack { ActivityView() }
            } label: {
                tabIcon("Activity", "creditcard")
            }

            Tab(value: AppTab.budget) {
                NavigationStack { BudgetView() }
            } label: {
                tabIcon("Budget", "chart.pie")
            }

            Tab(value: AppTab.bills) {
                NavigationStack { BillsView() }
            } label: {
                tabIcon("Bills", "calendar.badge.clock")
            }

            Tab(value: AppTab.search, role: .search) {
                NavigationStack { SearchView() }
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
        }
        // iPad: a tab bar at the top that opens into a sidebar.
        .tabViewStyle(.sidebarAdaptable)
        .tabViewSearchActivation(.searchTabSelection)
        .tabBarMinimizeBehavior(.onScrollDown)
    }

    /// Icon only in the iPhone tab bar (VoiceOver still reads the name); icon and name on
    /// iPad, where the tabs also show in the sidebar.
    @ViewBuilder
    private func tabIcon(_ title: String, _ systemImage: String) -> some View {
        if sizeClass == .regular {
            Label(title, systemImage: systemImage)
        } else {
            Image(systemName: systemImage)
                .accessibilityLabel(title)
        }
    }
}

#Preview {
    RootTabView()
        .previewEnvironment()
}
