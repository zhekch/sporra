import SwiftUI

/// Pushed history screens use native expanding/collapsing titles rather than
/// inheriting the menu root's inline-large toolbar title.
struct NativeHistoryTitleStyle: ViewModifier {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.toolbarTitleDisplayMode(verticalSizeClass == .compact ? .inline : .large)
        } else {
            content.navigationBarTitleDisplayMode(verticalSizeClass == .compact ? .inline : .large)
        }
    }
}
