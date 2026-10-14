import SwiftUI

/// Suffice on Apple Watch: what's left to spend this month, each budget, and the bills coming
/// up, from the snapshot the iPhone sends (see WatchStore). The complications live in the
/// SufficeWatchWidgets extension and read the same snapshot.
@main
struct SufficeWatchApp: App {
    @State private var store = WatchStore.shared

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(store)
        }
    }
}
