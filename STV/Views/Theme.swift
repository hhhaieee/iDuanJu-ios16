import SwiftUI
import UIKit

/// App palette, light + dark (follows the system). Dark is the PlutoFish mini-app palette; light is its
/// counterpart (white surfaces on a soft grey ground). Brand gold (matching the app icon) marks focus and playback progress.
/// Screens that must stay dark (player, image viewer, manga reader) force `.preferredColorScheme(.dark)`,
/// so the same tokens resolve to the dark values there.
enum STVTheme {
    static let bg = adaptive(light: (0.957, 0.961, 0.969), dark: (0.067, 0.075, 0.090))
    static let surface = adaptive(light: (1, 1, 1), dark: (0.110, 0.122, 0.145))
    static let elevated = adaptive(light: (0.910, 0.918, 0.933), dark: (0.224, 0.239, 0.259))
    static let text = adaptive(light: (0.071, 0.078, 0.094), dark: (0.933, 0.941, 0.953))
    static let secondary = adaptive(light: (0.373, 0.400, 0.447), dark: (0.68, 0.71, 0.75))
    static let accent = adaptive(light: (0.835, 0.686, 0.216), dark: (0.945, 0.835, 0.478))
    static let accentWarm = adaptive(light: (0.835, 0.522, 0.078), dark: (0.949, 0.710, 0.361))
    static let glass = text.opacity(0.07)
    static let glassBorder = text.opacity(0.12)

    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(UIColor { t in
            let c = t.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

struct GlassBackground: ViewModifier {
    var radius: CGFloat = 20
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.05)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 0.8)
            )
    }
}

extension View {
    func stvGlass(_ radius: CGFloat = 20) -> some View { modifier(GlassBackground(radius: radius)) }
}

struct GlassChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? STVTheme.bg : STVTheme.secondary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background {
                    if selected {
                        Capsule().fill(STVTheme.text)
                    } else {
                        Capsule().fill(STVTheme.elevated)
                            .overlay(Capsule().strokeBorder(STVTheme.glassBorder, lineWidth: 0.6))
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

struct GlassChipBar<T: Hashable>: View {
    let items: [T]
    @Binding var selection: T
    let label: (T) -> String
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { it in
                    GlassChip(title: label(it), selected: selection == it) { selection = it }
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - 外观（主题模式）

/// 用户可选的界面外观：跟随系统 / 浅色 / 深色。
enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色模式"
        case .dark: "深色模式"
        }
    }
    var subtitle: String {
        switch self {
        case .system: "随设备的深色或浅色模式自动切换视觉主题"
        case .light: "清爽明亮界面，适合白天或明亮环境阅读与挑选短剧"
        case .dark: "沉浸式暗黑背景，适合夜晚观剧，低功耗防眩光"
        }
    }
    var icon: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }
    /// nil = 跟随系统，由 SwiftUI 自动解析。
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// 全局外观设置。App 根部持有一个 `@StateObject`，切换时驱动 `.preferredColorScheme`。
final class AppearanceModel: ObservableObject {
    static let key = "stv.appearance.theme"
    @Published var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Self.key) }
    }
    init() {
        theme = UserDefaults.standard.string(forKey: Self.key).flatMap(AppTheme.init(rawValue:)) ?? .system
    }
}
