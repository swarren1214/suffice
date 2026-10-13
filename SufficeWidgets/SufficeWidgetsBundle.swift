import SwiftUI
import WidgetKit

/// Suffice's widgets. They read the snapshot the app writes into the app group
/// (group.com.stephenwarren.suffice); see Shared/WidgetSnapshot.swift.
@main
struct SufficeWidgetsBundle: WidgetBundle {
    var body: some Widget {
        LeftToSpendWidget()
        BillsWidget()
        TotalCashWidget()
    }
}
