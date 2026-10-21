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
    /// Only screenshot mode pushes onto it (Profile and Household).
    @State private var overviewPath = NavigationPath()
    @State private var purchases = HearthPurchases.shared
    /// Ask Suffice, typed or by voice, comes with Suffice Plus or Hearth+.
    @State private var showsAskPaywall = false

    static let askFeature = HearthPaywallFeature(
        "Ask Suffice",
        detail: "Ask about your budget, bills and spending, typed or out loud. Answered on your device.",
        symbol: "sparkles"
    )

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            Tab(value: AppTab.overview) {
                NavigationStack(path: $overviewPath) {
                    OverviewView().screenshotDestinations()
                }
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
                if sizeClass == .regular {
                    Label { Text("Search") } icon: { Image.menuIcon("magnifyingglass") }
                } else {
                    Label("Search", systemImage: "magnifyingglass")
                }
            }
        }
        // iPad: a tab bar at the top that opens into a sidebar.
        .tabViewStyle(.sidebarAdaptable)
        .tabViewSearchActivation(.searchTabSelection)
        .tabBarMinimizeBehavior(.onScrollDown)
        // Profile, opened by the photo at the top right of every main screen.
        .hearthProfile { ProfileView() }
        // The tour (HearthTour.swift): Welcome after onboarding, then one step per tab.
        .hearthTour(app: .suffice, steps: SufficeTour.steps, finishTitle: "Got It", autoStart: !ScreenshotMode.isOn) { step in
            router.tab = SufficeTour.tab(for: step)
        }
        .sheet(isPresented: Binding(
            get: { self.router.showsAsk && purchases.isUnlocked },
            set: { self.router.showsAsk = $0 }
        )) {
            AskView()
        }
        // The ✨ button, ⌘K: without the plan, the paywall instead of Ask.
        .onChange(of: router.showsAsk, initial: true) { _, shows in
            guard shows, !purchases.isUnlocked else { return }
            self.router.showsAsk = false
            showsAskPaywall = true
        }
        .hearthPaywall(isPresented: $showsAskPaywall, feature: Self.askFeature)
        .screenshotStage(overviewPath: $overviewPath)
    }

    /// Icon only in the iPhone tab bar (VoiceOver still reads the name); icon and name on
    /// iPad, where the tabs also show in the sidebar.
    @ViewBuilder
    private func tabIcon(_ title: String, _ systemImage: String) -> some View {
        if sizeClass == .regular {
            // The sidebar tints tab icons with the app's color; keep each icon the color of its
            // name instead (black in Light Mode, white in Dark Mode). See AGENT.md.
            Label { Text(title) } icon: { Image.menuIcon(systemImage) }
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
