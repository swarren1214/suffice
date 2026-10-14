import SwiftUI
import WidgetKit

/// Suffice's complications and Smart Stack widget. They read the snapshot the watch app saves
/// in the watch's app group when the iPhone sends one (see SufficeWatch/WatchStore.swift).
@main
struct SufficeWatchWidgetsBundle: WidgetBundle {
    var body: some Widget {
        LeftToSpendComplication()
        BudgetComplication()
        UpNextWidget()
    }
}
