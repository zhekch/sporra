import SwiftUI

enum NativeMapCardStyle {
    static func cornerRadius(_ verticalSizeClass: UserInterfaceSizeClass?) -> CGFloat {
        UIDevice.current.userInterfaceIdiom == .phone && verticalSizeClass != .compact ? 43 : 24
    }
}

/// Native adaptive glass; layout and corner spacing are shared by map cards.
struct NativeMapCardSurface: ViewModifier {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: NativeMapCardStyle.cornerRadius(verticalSizeClass), style: .continuous)
        if #available(iOS 26.0, *) {
            content.foregroundStyle(.primary).tint(.primary).glassEffect(.regular, in: shape)
        } else {
            content.foregroundStyle(.primary).tint(.primary).background(.regularMaterial, in: shape)
        }
    }
}

struct NativeMapCardButton: View {
    let title: String
    let icon: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// Move the entire glass card while dragging its header. Graphs and expanded
/// day lists retain their own gestures.
struct NativeMapCardDrag: ViewModifier {
    @Binding var offset: CGSize
    var horizontal = true
    var vertical = true
    var simultaneous = false
    var onSwipe: (TrackCardNavigation.Swipe) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if simultaneous {
            content.contentShape(Rectangle()).simultaneousGesture(drag)
        } else {
            content.contentShape(Rectangle()).highPriorityGesture(drag)
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { gesture in
                let delta = gesture.translation
                if horizontal && abs(delta.width) > abs(delta.height) * 1.3 {
                    offset = CGSize(width: delta.width, height: 0)
                } else if vertical && abs(delta.height) > abs(delta.width) * 1.3 {
                    offset = CGSize(width: 0, height: delta.height * 0.5)
                }
            }
            .onEnded { gesture in
                let delta = gesture.translation
                let target =
                    abs(delta.width) >= 20 || abs(delta.height) >= 20
                    ? gesture.predictedEndTranslation : delta
                let swipe = TrackCardNavigation.swipe(x: target.width, y: target.height)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { offset = .zero }
                switch swipe {
                case .next, .previous: if horizontal { onSwipe(swipe) }
                case .expand, .collapse: if vertical { onSwipe(swipe) }
                case .none: break
                }
            }
    }
}
