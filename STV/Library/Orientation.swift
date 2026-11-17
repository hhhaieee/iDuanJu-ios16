import SwiftUI
import UIKit

/// Portrait by default; unlock all orientations while the player is on screen.
final class OrientationGate: NSObject, UIApplicationDelegate {
    static var mask: UIInterfaceOrientationMask = .portrait
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask { Self.mask }

    @MainActor static func unlock() {
        mask = .allButUpsideDown
        refresh()
    }
    /// 横屏 button: rotate now; rotation stays unlocked so turning the phone back to portrait exits.
    @MainActor static func enterLandscape() {
        mask = .allButUpsideDown
        refresh()
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { _ in }
        }
    }
    /// 退出横屏 button.
    @MainActor static func exitLandscape() {
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
        }
        mask = .allButUpsideDown
        refresh()
    }
    @MainActor static func lockPortrait() {
        mask = .portrait
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        }
        refresh()
    }
    /// 锁屏按钮：把屏幕方向锁死在当前朝向（横 or 竖），手机翻转不再改变播放器画面。
    @MainActor static func lockCurrent(landscape: Bool) {
        let target: UIInterfaceOrientationMask = landscape ? .landscapeRight : .portrait
        mask = target
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscapeRight : .portrait)) { _ in }
        }
        refresh()
    }
    /// 解锁：恢复跟随设备方向（播放中允许横竖屏）。
    @MainActor static func unlockRotation() { unlock() }
    @MainActor private static func refresh() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for win in scene.windows {
                win.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
    }
}
