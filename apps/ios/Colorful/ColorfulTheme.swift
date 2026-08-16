import SwiftUI
import UIKit

struct ColorfulPalette: Equatable, Sendable {
    let primary: UInt32
    let secondary: UInt32
    let background: UInt32

    static let fallback = ColorfulPalette(
        primary: 0xFF5C9A,
        secondary: 0x7DE2D1,
        background: 0x160D14
    )

    var primaryColor: Color { Color(hex: primary) }
    var secondaryColor: Color { Color(hex: secondary) }
    var backgroundColor: Color { Color(hex: background) }
}

@MainActor
final class ColorfulArtworkPaletteLoader: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var palette = ColorfulPalette.fallback

    private static let imageCache = NSCache<NSURL, UIImage>()
    private static var paletteCache = [NSURL: ColorfulPalette]()
    private var task: Task<Void, Never>?
    private var loadedURL: URL?

    deinit {
        task?.cancel()
    }

    func load(for artworkURL: String?) {
        task?.cancel()
        guard let artworkURL,
              let url = URL(string: artworkURL) else {
            loadedURL = nil
            image = nil
            palette = .fallback
            return
        }

        if loadedURL == url, image != nil {
            return
        }
        loadedURL = url

        if let cachedImage = Self.imageCache.object(forKey: url as NSURL) {
            image = cachedImage
            palette = Self.paletteCache[url as NSURL] ?? Self.palette(for: cachedImage)
            Self.paletteCache[url as NSURL] = palette
            return
        }

        task = Task { @MainActor [weak self, url] in
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled,
                      (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) ?? true,
                      let image = UIImage(data: data),
                      let self,
                      self.loadedURL == url else { return }

                Self.imageCache.setObject(image, forKey: url as NSURL)
                let palette = Self.paletteCache[url as NSURL] ?? Self.palette(for: image)
                Self.paletteCache[url as NSURL] = palette
                self.image = image
                self.palette = palette
            } catch {
                // Artwork is optional and must never block playback or navigation.
            }
        }
    }

    private static func palette(for image: UIImage) -> ColorfulPalette {
        guard let source = image.cgImage,
              let context = CGContext(
                  data: nil,
                  width: 16,
                  height: 16,
                  bitsPerComponent: 8,
                  bytesPerRow: 16 * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return .fallback
        }

        context.interpolationQuality = .medium
        context.draw(source, in: CGRect(x: 0, y: 0, width: 16, height: 16))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else {
            return .fallback
        }

        var redTotal = 0.0
        var greenTotal = 0.0
        var blueTotal = 0.0
        var count = 0.0
        var strongest = (score: -1.0, red: 1.0, green: 0.36, blue: 0.60)

        for index in stride(from: 0, to: 16 * 16 * 4, by: 4) {
            let alpha = Double(data[index + 3]) / 255
            guard alpha > 0.25 else { continue }
            let red = Double(data[index]) / 255
            let green = Double(data[index + 1]) / 255
            let blue = Double(data[index + 2]) / 255
            let high = max(red, max(green, blue))
            let low = min(red, min(green, blue))
            let saturation = high == 0 ? 0 : (high - low) / high
            let score = saturation * 0.78 + high * 0.22

            redTotal += red
            greenTotal += green
            blueTotal += blue
            count += 1
            if score > strongest.score {
                strongest = (score, red, green, blue)
            }
        }

        guard count > 0 else { return .fallback }
        let average = (
            red: redTotal / count,
            green: greenTotal / count,
            blue: blueTotal / count
        )
        let primary = pack(red: strongest.red, green: strongest.green, blue: strongest.blue)
        let secondary = pack(red: average.red, green: average.green, blue: average.blue)
        let background = pack(
            red: strongest.red * 0.18,
            green: strongest.green * 0.18,
            blue: strongest.blue * 0.18
        )
        return ColorfulPalette(primary: primary, secondary: secondary, background: background)
    }

    private static func pack(red: Double, green: Double, blue: Double) -> UInt32 {
        (UInt32(max(0, min(1, red)) * 255) << 16)
            | (UInt32(max(0, min(1, green)) * 255) << 8)
            | UInt32(max(0, min(1, blue)) * 255)
    }
}

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
    var artworkURL: String? = nil
    var size: CGFloat = 56
    @StateObject private var paletteLoader: ColorfulArtworkPaletteLoader

    init(title: String, accent: UInt32, artworkURL: String? = nil, size: CGFloat = 56) {
        self.title = title
        self.accent = accent
        self.artworkURL = artworkURL
        self.size = size
        _paletteLoader = StateObject(wrappedValue: ColorfulArtworkPaletteLoader())
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            fallbackArtwork(accent: paletteLoader.palette.primary)

            if let image = paletteLoader.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                .frame(width: size, height: size)
                .clipped()
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityLabel("Artwork for \(title)")
        .task(id: artworkURL) {
            paletteLoader.load(for: artworkURL)
        }
    }

    private func fallbackArtwork(accent: UInt32) -> some View {
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
    }
}

struct ColorfulArtworkBackground: View {
    let palette: ColorfulPalette

    var body: some View {
        ZStack {
            palette.backgroundColor
            LinearGradient(
                colors: [palette.primaryColor.opacity(0.72), palette.backgroundColor, .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(0.94)
            Rectangle()
                .fill(.black.opacity(0.22))
        }
        .ignoresSafeArea()
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
