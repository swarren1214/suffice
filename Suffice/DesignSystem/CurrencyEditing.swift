import SwiftUI
import UIKit

extension View {
    /// An amount field that reads as currency ("$1,250.00") and turns into plain digits
    /// ("1250") while it's being typed in. The text stays parseable by `Money.cents(from:)`
    /// either way. Empty for zero, so the field's placeholder shows.
    func currencyEditing(_ text: Binding<String>, isFocused: Bool) -> some View {
        modifier(CurrencyEditing(text: text, isFocused: isFocused))
    }
}

private struct CurrencyEditing: ViewModifier {
    @Binding var text: String
    var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .onAppear {
                if !isFocused { text = Money.field(Money.cents(from: text) ?? 0) }
            }
            .onChange(of: isFocused) { _, focused in
                let cents = Money.cents(from: text) ?? 0
                text = focused ? Money.editable(cents) : Money.field(cents)
            }
    }
}

/// Tapping anywhere outside a text field puts the keyboard away, across the app and its
/// sheets. Added once, at the root, as an invisible view that hooks its window.
struct KeyboardDismissal: UIViewRepresentable {
    func makeUIView(context: Context) -> InstallerView { InstallerView() }
    func updateUIView(_ uiView: InstallerView, context: Context) {}

    final class InstallerView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, !(window.gestureRecognizers ?? []).contains(where: { $0.delegate is Handler }) else { return }
            let tap = UITapGestureRecognizer(target: Handler.shared, action: #selector(Handler.tapped(_:)))
            // Let the tap through to whatever was tapped (a button still works).
            tap.cancelsTouchesInView = false
            tap.delegate = Handler.shared
            window.addGestureRecognizer(tap)
        }
    }

    final class Handler: NSObject, UIGestureRecognizerDelegate {
        static let shared = Handler()

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            recognizer.view?.endEditing(true)
        }

        /// Taps on a text field (moving between fields) don't count.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UITextField || current is UITextView { return false }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
