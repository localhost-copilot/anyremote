import SwiftUI

/// The tvOS-style focus effect for a card the pointer is over: the card
/// sinks a little and tilts in 3D so the part under the pointer is pushed
/// in, following the pointer; pressing pushes it in further and it springs
/// back on release. `tiltGlare` adds the matching highlight to the part of
/// the card that should catch the light.
///
/// The press is watched with a simultaneous gesture so it never takes the
/// card's own clicks and double-clicks, as long as those are attached
/// inside it (apply this after them): a gesture inside a view wins over one
/// attached outside. With Reduce Motion the card only sinks, without tilting.
///
/// With `tilts` off the card itself stays still and only tells its content
/// where the pointer is and whether it's pressed (`cardPointer`), for
/// `pressBounce` on a part of it, such as an app's icon.
struct TiltEffect: ViewModifier {
    var tilts = true
    @State private var pointer: CGPoint?
    @State private var size: CGSize = .zero
    @State private var isPressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far the card turns with the pointer at its edge.
    private static let maxAngle: Double = 7

    func body(content: Content) -> some View {
        let tilt = reduceMotion || !tilts ? nil : pointer
        content
            .environment(\.cardPointer, pointer.map { CardPointer(location: $0, isPressed: isPressed) })
            .scaleEffect(!tilts ? 1 : isPressed ? 0.94 : pointer == nil ? 1 : 0.975)
            // Positive turns push the right edge (about y) and the top edge
            // (about x) away, so the side under the pointer is the one that sinks.
            .rotation3DEffect(.degrees((tilt?.x ?? 0) * Self.maxAngle), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            .rotation3DEffect(.degrees(-(tilt?.y ?? 0) * Self.maxAngle), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isPressed)
            .animation(pointer == nil ? .spring(response: 0.45, dampingFraction: 0.55) : .smooth(duration: 0.12),
                       value: pointer)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location) where size.width > 0 && size.height > 0:
                    // -1…1 across the card, 0 at its middle.
                    pointer = CGPoint(x: (location.x / size.width * 2 - 1).clamped,
                                      y: (location.y / size.height * 2 - 1).clamped)
                default:
                    pointer = nil
                    isPressed = false
                }
            }
            .simultaneousGesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false })
    }
}

/// A soft highlight that follows the pointer over a tilting card, as light
/// would catch a tilted surface.
struct TiltGlare: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.cardPointer) private var card

    func body(content: Content) -> some View {
        content.overlay {
            if let pointer = card?.location {
                RadialGradient(colors: [.white.opacity(0.22), .white.opacity(0)],
                               center: UnitPoint(x: (pointer.x + 1) / 2, y: (pointer.y + 1) / 2),
                               startRadius: 0, endRadius: 220)
                    .blendMode(.plusLighter)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.2), value: card == nil)
    }
}

/// Lifts a part of a card a little while the pointer is over the card, and
/// pushes it in while it's pressed, springing back on release.
struct PressBounce: ViewModifier {
    @Environment(\.cardPointer) private var card

    func body(content: Content) -> some View {
        // Keyed on the state, not the pointer, so moving over the card doesn't restart it.
        let scale: CGFloat = card?.isPressed == true ? 0.88 : card == nil ? 1 : 1.06
        content
            .scaleEffect(scale)
            .animation(.spring(response: 0.3, dampingFraction: 0.55), value: scale)
    }
}

struct CardPointer: Equatable {
    /// -1…1 on each axis across the card, 0 at its middle.
    var location: CGPoint
    var isPressed: Bool
}

extension View {
    func tiltOnHover(tilts: Bool = true) -> some View { modifier(TiltEffect(tilts: tilts)) }
    func pressBounce() -> some View { modifier(PressBounce()) }
    func tiltGlare(cornerRadius: CGFloat) -> some View { modifier(TiltGlare(cornerRadius: cornerRadius)) }
}

extension EnvironmentValues {
    /// The pointer over the enclosing `TiltEffect` card, or nil when it isn't over it.
    @Entry var cardPointer: CardPointer?
}

private extension CGFloat {
    var clamped: CGFloat { Swift.min(Swift.max(self, -1), 1) }
}
