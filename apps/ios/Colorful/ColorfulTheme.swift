import SwiftUI

enum ColorfulTheme {
    static let background = Color(hex: 0x0B0B0D)
    static let surface = Color(hex: 0x151519)
    static let surfaceRaised = Color(hex: 0x1E1E24)
    static let ink = Color(hex: 0xF7F7FA)
    static let mutedInk = Color(hex: 0xA5A5AF)
    static let accent = Color(hex: 0xFF5C9A)
    static let accentSecondary = Color(hex: 0x7DE2D1)
    static let warning = Color(hex: 0xFFC857)
    static let border = Color.white.opacity(0.12)
    static let cardRadius: CGFloat = 10
    static let blockShadow = Color.black.opacity(0.42)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

struct ColorfulSurface<Content: View>: View {
    private let content: Content
    private let fill: Color

    init(fill: Color = ColorfulTheme.surface, @ViewBuilder content: () -> Content) {
        self.fill = fill
        self.content = content()
    }

    var body: some View {
        content
            .background(fill)
            .overlay {
                RoundedRectangle(cornerRadius: ColorfulTheme.cardRadius, style: .continuous)
                    .stroke(ColorfulTheme.border, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: ColorfulTheme.cardRadius, style: .continuous))
            .shadow(color: ColorfulTheme.blockShadow, radius: 0, x: 4, y: 4)
    }
}

struct ColorfulAlbumArt: View {
    let title: String
    let accent: UInt32
    var size: CGFloat = 56

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [Color(hex: accent), Color(hex: accent).opacity(0.32), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(title.prefix(1).uppercased())
                .font(.system(size: size * 0.34, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.88))
                .padding(size * 0.12)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityLabel("Artwork for \(title)")
    }
}

struct ColorfulNativeGlass: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: ColorfulTheme.cardRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: ColorfulTheme.cardRadius, style: .continuous))
    }
}

extension View {
    func colorfulNativeGlass() -> some View {
        modifier(ColorfulNativeGlass())
    }
}
