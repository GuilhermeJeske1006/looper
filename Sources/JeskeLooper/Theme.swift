import AppKit
import SwiftUI

enum Theme {
    static let brand = Color(red: 0.49, green: 0.36, blue: 1.0)
    static let record = Color(red: 1.0, green: 0.29, blue: 0.25)
    static let play = Color(red: 0.16, green: 0.76, blue: 0.50)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let cardStroke = Color.primary.opacity(0.08)
    static let background = Color(nsColor: .windowBackgroundColor)
}

struct Card<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.cardStroke))
    }
}

/// Large rounded button. `filled` uses the color as background; `active` keeps it lit while disabled.
struct BigButtonStyle: ButtonStyle {
    var color: Color
    var filled: Bool
    var active = false
    var height: CGFloat = 54

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, style: self)
    }

    private struct StyledBody: View {
        let configuration: Configuration
        let style: BigButtonStyle
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let lit = isEnabled || style.active
            configuration.label
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(style.filled ? Color.white : (lit ? style.color : Color.secondary))
                .frame(maxWidth: .infinity, minHeight: style.height)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(style.filled
                              ? AnyShapeStyle(LinearGradient(colors: [style.color.opacity(0.92), style.color],
                                                             startPoint: .top, endPoint: .bottom))
                              : AnyShapeStyle(style.color.opacity(lit ? 0.12 : 0.06)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(style.filled ? Color.white.opacity(0.18) : style.color.opacity(lit ? 0.35 : 0.12))
                )
                .opacity(lit ? (configuration.isPressed ? 0.8 : 1) : 0.45)
                .scaleEffect(configuration.isPressed ? 0.985 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}
