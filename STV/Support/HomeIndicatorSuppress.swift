import UIKit
import SwiftUI

/// 播放页全屏期间隐藏底部白色 Home 指示条（退出后恢复）。
///
/// SwiftUI 的 `.persistentSystemOverlays(.hidden)` 在 iOS 16 的部分容器里不生效；
/// `prefersHomeIndicatorAutoHidden` 是只读属性，只能在子类 override。
/// 这里替换多个 UIKit 容器类的 getter 实现：开关打开时全部报告「隐藏」，关闭时恢复。
/// 关键补充：改变 flag 后必须对整棵 VC 树调用 `setNeedsUpdateOfHomeIndicatorAutoHidden()`
/// 系统才会立刻重新查询并隐藏（不刷新就一直显示——上一版失效的根因）。
enum HomeIndicatorSuppress {
    private static var flag = false
    private static var installed = false

    /// 播放页出现/消失时调用（主线程）。
    static func set(_ on: Bool) {
        install()
        flag = on
        refresh()
        // 部分容器（Tab/Nav/fullScreenCover 转场）在转场完成后才查询，稍后再刷一次保险。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { refresh() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { refresh() }
    }

    static func install() {
        guard !installed else { return }
        installed = true
        let sel = #selector(getter: UIViewController.prefersHomeIndicatorAutoHidden)
        let block: @convention(block) (AnyObject) -> Bool = { _ in flag }
        let imp = imp_implementationWithBlock(block)
        // 除了基类，还要覆盖会 override 该 getter 的常见容器（子类 override 不会被基类替换命中）。
        let classes: [AnyClass] = [
            UIViewController.self, UINavigationController.self, UITabBarController.self,
            UISplitViewController.self, UIPageViewController.self,
        ]
        for cls in classes {
            if let method = class_getInstanceMethod(cls, sel) { method_setImplementation(method, imp) }
        }
        // SwiftUI 的 UIHostingController 是泛型类，运行时每个特化都是独立的 ObjC class，
        // 无法用 `UIHostingController.self` 直接引用，这里遍历运行时全部类逐个 swizzle。
        swizzleHostingControllers(sel, imp)
    }

    /// 遍历运行时所有类，找到 UIHostingController 及其子类并替换 getter 实现。
    private static func swizzleHostingControllers(_ sel: Selector, _ imp: IMP) {
        let total = objc_getClassList(nil, 0)
        guard total > 0 else { return }
        let buffer = UnsafeMutablePointer<AnyClass>.allocate(capacity: Int(total))
        defer { buffer.deallocate() }
        let count = objc_getClassList(AutoreleasingUnsafeMutablePointer(buffer), total)
        for i in 0..<Int(count) {
            let cls = buffer[i]
            var sup: AnyClass? = cls
            var depth = 0
            while let s = sup, depth < 12 {
                let name = String(cString: class_getName(s))
                if name.contains("UIHostingController") {
                    if let method = class_getInstanceMethod(cls, sel) {
                        method_setImplementation(method, imp)
                    }
                    break
                }
                sup = class_getSuperclass(s)
                depth += 1
            }
        }
    }

    /// 让系统对整棵 VC 树重新查询 `prefersHomeIndicatorAutoHidden`。
    private static func refresh() {
        guard Thread.isMainThread else { DispatchQueue.main.async { refresh() }; return }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                walk(window.rootViewController)
            }
        }
    }

    private static func walk(_ vc: UIViewController?) {
        guard let vc else { return }
        vc.setNeedsUpdateOfHomeIndicatorAutoHidden()
        for child in vc.children { walk(child) }
        walk(vc.presentedViewController)
    }
}
