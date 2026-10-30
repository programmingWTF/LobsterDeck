import SwiftUI

// MARK: - Palette

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }

    static let lobster = Color(hex: 0xFF7A18)
    static let lobsterDeep = Color(hex: 0xE8500A)
    static let lobsterSoft = Color(hex: 0xFFB067)
    static let ink = Color(hex: 0x1C120B)
}

enum Theme {
    static let corner: CGFloat = 26
    static let gap: CGFloat = 14

    static func bg(_ scheme: ColorScheme) -> [Color] {
        scheme == .dark
        ? [Color(hex: 0x120A05), Color(hex: 0x24120A), Color(hex: 0x0D0704)]
        : [Color(hex: 0xFFF9F3), Color(hex: 0xFFE7D2), Color(hex: 0xFFFDFB)]
    }
}

// MARK: - Background

struct AppBackground: View {
    @Environment(\.colorScheme) private var scheme
    @State private var drift = false

    var body: some View {
        ZStack {
            LinearGradient(colors: Theme.bg(scheme), startPoint: .topLeading, endPoint: .bottomTrailing)

            Circle()
                .fill(Color.lobster.opacity(scheme == .dark ? 0.42 : 0.32))
                .frame(width: 420, height: 420)
                .blur(radius: 110)
                .offset(x: drift ? -120 : -60, y: drift ? -260 : -200)

            Circle()
                .fill(Color(hex: 0xFF3D00).opacity(scheme == .dark ? 0.28 : 0.18))
                .frame(width: 360, height: 360)
                .blur(radius: 120)
                .offset(x: drift ? 150 : 110, y: drift ? 220 : 300)

            if scheme == .dark {
                Rectangle().fill(.black.opacity(0.12)).blendMode(.overlay)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 14).repeatForever(autoreverses: true), value: drift)
        .onAppear { drift = true }
    }
}

// MARK: - Glass surfaces

struct GlassCard<Content: View>: View {
    var tint: Color = .lobster
    var radius: CGFloat = Theme.corner
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(tint.opacity(0.16)).interactive(),
                         in: .rect(cornerRadius: radius))
    }
}

struct GlassPill: View {
    let text: String
    var icon: String? = nil
    var tint: Color = .lobster

    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.caption.weight(.semibold)) }
            Text(text).font(.caption.weight(.semibold))
        }
        .foregroundStyle(.primary.opacity(0.9))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular.tint(tint.opacity(0.22)), in: .capsule)
    }
}

// MARK: - Top bar (unified, scroll-edge glass)
//
// Every page's top navigation bar uses this one modifier, and it
// follows the previous Home page's behaviour, not a permanent mask:
// when the page is scrolled to the top, there is no bar background
// at all and the content shows through; once the user scrolls, a
// thin translucent bar appears behind the title and buttons.
// That is what `.automatic` visibility does: the system only shows
// the bar background off the scroll edge. The previous attempt forced
// `.visible`, which kept an ultraThinMaterial mask on screen even at
// the top and blocked the view, and the even older Agent detail and
// Commit detail forced opaque `.systemBackground`, which looked like
// a solid black bar in dark mode. Neither is used any more.
// `.ultraThinMaterial` is the lightest material, so the bar that does
// appear on scroll is a faint glass strip, not a heavy overlay.

extension View {
    func deckTopBar() -> some View {
        self
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarBackground(.automatic, for: .navigationBar)
    }
}

// MARK: - Small parts

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline.weight(.semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

struct EmptyHint: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }
}

struct RowChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.bold))
            .foregroundStyle(.tertiary)
    }
}

// MARK: - Formatting

enum Fmt {
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let isoLoose: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        return iso.date(from: s) ?? isoLoose.date(from: s)
    }

    static func relative(_ s: String?) -> String {
        guard let d = date(s) else { return s ?? "" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }

    static func day(_ s: String?) -> String {
        guard let d = date(s) else { return s ?? "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: d)
    }

    static func greeting() -> String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<11: return "早上好"
        case 11..<13: return "中午好"
        case 13..<18: return "下午好"
        case 18..<23: return "晚上好"
        default: return "夜深了"
        }
    }
}


/// A light, non-glass container for long lists. Liquid Glass on a very tall
/// card gets expensive and visually heavy, so file/folder lists use this.


extension Color {
    init?(hexString: String?) {
        guard var h = hexString?.trimmingCharacters(in: .whitespaces), !h.isEmpty else { return nil }
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(hex: v)
    }
}

/// Soft card used for long file / memory lists: white translucency with a
/// hairline grey border, no Liquid Glass, so hundreds of rows stay scrollable.
struct SoftList<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.vertical, 4)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.white.opacity(scheme == .dark ? 0.06 : 0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.gray.opacity(0.22), lineWidth: 1)
            )
    }
}
