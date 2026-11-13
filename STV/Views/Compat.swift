import SwiftUI

// MARK: - iOS 16 兼容层
// 用于在 deploymentTarget 降到 iOS 16 后，为 iOS 17/18 的 SwiftUI API 提供降级实现。

/// 滚动内容在命名坐标空间里的顶部偏移（minY），用于 iOS 16 上替代 onScrollGeometryChange。
struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

extension View {
    /// iOS 17 `.compatDefaultScrollAnchor(_:)` → iOS 16 无此能力，降级为 no-op。
    @ViewBuilder
    func compatDefaultScrollAnchor(_ anchor: UnitPoint?) -> some View {
        if #available(iOS 17.0, *) {
            self.defaultScrollAnchor(anchor)
        } else {
            self
        }
    }

    /// iOS 17 `.containerRelativeFrame(_:alignment:)` → iOS 16 用 frame 填满对应轴向。
    @ViewBuilder
    func compatContainerRelativeFrame(_ axes: Axis.Set, alignment: Alignment = .center) -> some View {
        if #available(iOS 17.0, *) {
            self.containerRelativeFrame(axes, alignment: alignment)
        } else {
            self.frame(
                maxWidth: axes.contains(.horizontal) ? .infinity : nil,
                maxHeight: axes.contains(.vertical) ? .infinity : nil,
                alignment: alignment
            )
        }
    }

    /// iOS 17 `.contentTransition(.symbolEffect(.replace))` → iOS 16 用 opacity 过渡。
    @ViewBuilder
    func compatSymbolReplaceTransition() -> some View {
        if #available(iOS 17.0, *) {
            self.contentTransition(.symbolEffect(.replace))
        } else {
            self.contentTransition(.opacity)
        }
    }

    /// iOS 17 波形 `.symbolEffect(.variableColor.iterative, isActive:)` → iOS 16 no-op。
    @ViewBuilder
    func compatWaveformSymbolEffect(isActive: Bool) -> some View {
        if #available(iOS 17.0, *) {
            self.symbolEffect(.variableColor.iterative, isActive: isActive)
        } else {
            self
        }
    }

    /// iOS 17 `.sensoryFeedback(.selection, trigger:)` → iOS 16 no-op。
    @ViewBuilder
    func compatSelectionFeedback<T: Equatable>(trigger: T) -> some View {
        if #available(iOS 17.0, *) {
            self.sensoryFeedback(.selection, trigger: trigger)
        } else {
            self
        }
    }
}

/// iOS 17 `ContentUnavailableView` 的 iOS 16 自绘替代。
struct EmptyStateView: View {
    var title: String
    var systemImage: String
    var description: String? = nil
    var actions: AnyView? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            if let description {
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let actions {
                actions
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
