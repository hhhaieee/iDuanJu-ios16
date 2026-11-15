import UIKit

/// 播放页全屏期间隐藏底部白色 Home 指示条（退出后恢复）。
///
/// SwiftUI 的 `.persistentSystemOverlays(.hidden)` 在 iOS 16 的部分容器里不生效，
/// UIKit 的 `prefersHomeIndicatorAutoHidden` 又是只读属性（只能在子类里 override）。
/// 这里直接替换 UIViewController 的 getter 实现：全局开关打开时所有 VC 都报告
/// 「隐藏 Home 指示条」，系统随即把白条藏起来；关闭时全部恢复默认行为。
enum HomeIndicatorSuppress {
    private static var flag = false
    private static var installed = false

    /// 播放页出现/消失时调用（主线程）。
    static func set(_ on: Bool) {
        install()
        flag = on
    }

    static func install() {
        guard !installed else { return }
        installed = true
        let sel = #selector(getter: UIViewController.prefersHomeIndicatorAutoHidden)
        guard let method = class_getInstanceMethod(UIViewController.self, sel) else { return }
        // ObjC 方法签名: -(BOOL)prefersHomeIndicatorAutoHidden; block 首参数为接收者。
        let block: @convention(block) (AnyObject) -> Bool = { _ in flag }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }
}
