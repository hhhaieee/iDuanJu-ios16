import SwiftUI

/// 外观与主题设置页：跟随系统 / 浅色 / 深色三选一，实时生效。
struct AppearanceSettingsView: View {
    @EnvironmentObject private var appearance: AppearanceModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("主题模式")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(STVTheme.accent)
                    .padding(.horizontal, 16)
                VStack(spacing: 10) {
                    ForEach(AppTheme.allCases) { theme in
                        option(theme)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 16)
        }
        .background(STVTheme.bg.ignoresSafeArea())
        .navigationTitle("外观与主题")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func option(_ theme: AppTheme) -> some View {
        let selected = appearance.theme == theme
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) { appearance.theme = theme }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: theme.icon)
                    .font(.title3)
                    .foregroundStyle(selected ? STVTheme.accent : STVTheme.secondary)
                    .frame(width: 44, height: 44)
                    .background(selected ? STVTheme.accent.opacity(0.14) : STVTheme.elevated,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(theme.label)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(selected ? STVTheme.accent : STVTheme.text)
                    Text(theme.subtitle)
                        .font(.caption)
                        .foregroundStyle(STVTheme.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(STVTheme.accent)
                }
            }
            .padding(14)
            .background(STVTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(selected ? STVTheme.accent : STVTheme.glassBorder,
                                  lineWidth: selected ? 1.5 : 0.6)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("appearance.\(theme.rawValue)")
    }
}
