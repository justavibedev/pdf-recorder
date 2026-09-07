import SwiftUI

/// A small native design system: neutral surfaces, clear hierarchy, and one-pixel borders.
enum StudioTheme {
    static let background = Color(red: 0.035, green: 0.035, blue: 0.043)
    static let sidebar = Color(red: 0.058, green: 0.058, blue: 0.069)
    static let surface = Color(red: 0.094, green: 0.094, blue: 0.106)
    static let elevated = Color(red: 0.125, green: 0.125, blue: 0.141)
    static let border = Color.white.opacity(0.085)
    static let text = Color(red: 0.957, green: 0.957, blue: 0.969)
    static let muted = Color(red: 0.63, green: 0.63, blue: 0.67)
    // Secondary text stays readable even on the lightest panel surface.
    static let faint = Color(red: 0.54, green: 0.54, blue: 0.58)
    static let record = Color(red: 0.78, green: 0.17, blue: 0.20)
}

struct StudioButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, record }
    var kind: Kind = .secondary
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var size
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size == .large ? 13 : 12, weight: .medium))
            .padding(.horizontal, kind == .ghost ? 8 : 12)
            .frame(minHeight: size == .large ? 36 : 30)
            .foregroundStyle(kind == .primary ? StudioTheme.background : StudioTheme.text)
            .background(background(configuration.isPressed), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(kind == .secondary ? StudioTheme.border : .clear))
            .opacity(enabled ? 1 : 0.38)
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
    private func background(_ pressed: Bool) -> Color {
        switch kind {
        case .primary: return StudioTheme.text.opacity(pressed ? 0.8 : 1)
        case .record: return StudioTheme.record.opacity(pressed ? 0.75 : 1)
        case .secondary: return pressed ? StudioTheme.elevated : StudioTheme.surface
        case .ghost: return pressed ? StudioTheme.surface : .clear
        }
    }
}

struct StudioBadge: View {
    let text: String
    var active = false
    var body: some View {
        Text(text).font(.system(size: 10, weight: .medium))
            .foregroundStyle(active ? StudioTheme.text : StudioTheme.muted)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(active ? StudioTheme.elevated : StudioTheme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(StudioTheme.border))
    }
}

extension View {
    func studioPanel(cornerRadius: CGFloat = 8) -> some View {
        background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(StudioTheme.border))
    }
}
