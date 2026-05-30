import SwiftUI

// Mirrors Settings.app behaviour: instant background flash on touch-down,
// quick fade-out on release/cancel. Mic-button in Voice tab is the reference.
struct InstantHighlightStyle: ButtonStyle {
    var pressedColor: Color = Color.white.opacity(0.08)
    var cornerRadius: CGFloat = 0

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(pressedColor)
                    .opacity(configuration.isPressed ? 1 : 0)
                    .animation(configuration.isPressed
                               ? nil
                               : .easeOut(duration: 0.25),
                               value: configuration.isPressed)
            )
    }
}

// Big sheet CTA — Settings-style filled prominent button.
struct ProminentCTAStyle: ButtonStyle {
    var enabled: Bool = true
    var tint: Color = .blue

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundColor(enabled ? .white : Color(hex: "8E8E93"))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(enabled ? tint : Color(hex: "2C2C2E"))
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed && enabled ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// Destructive secondary action — looks like a Settings "Delete Account" row.
struct DestructiveRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .regular))
            .foregroundColor(.red)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(hex: "2C2C2E"))
                    .opacity(configuration.isPressed ? 1 : 0.6)
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
