import SwiftUI

/// Shared design tokens + reusable styling for a consistent, native, dark-mode-correct look.
/// Everything uses semantic system colors so light/dark adapt automatically.
enum Theme {
    /// Spacing scale.
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 22

    static let radius: CGFloat = 12
    static let radiusSmall: CGFloat = 8

    /// Card surface — sits above the window background, adapts to appearance.
    static var cardFill: Color { Color(nsColor: .controlBackgroundColor) }
    static var hairline: Color { Color(nsColor: .separatorColor) }
    static var fieldFill: Color { Color(nsColor: .textBackgroundColor) }
}

extension View {
    /// Wrap content as a card: padded surface with a hairline border and rounded corners.
    func card(padding: CGFloat = Theme.s4, radius: CGFloat = Theme.radius) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

/// A section heading: small, uppercase, secondary — used above grouped content.
struct SectionLabel: View {
    let title: String
    var systemImage: String? = nil
    init(_ title: String, systemImage: String? = nil) { self.title = title; self.systemImage = systemImage }
    var body: some View {
        HStack(spacing: Theme.s2) {
            if let systemImage { Image(systemName: systemImage).font(.caption) }
            Text(title.uppercased())
                .font(.caption).fontWeight(.semibold)
                .tracking(0.6)
        }
        .foregroundStyle(.secondary)
    }
}

/// A small green/orange/red status dot.
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 9
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.black.opacity(0.12)))
    }
}
