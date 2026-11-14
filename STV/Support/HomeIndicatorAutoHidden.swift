import SwiftUI
import UIKit

/// 在宿主的 UIViewController 上设置 prefersHomeIndicatorAutoHidden = true，
/// 隐藏 iOS 底部的白色 Home 指示条（播放页）。
struct HomeIndicatorAutoHidden: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.isHidden = true
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        apply(from: uiView)
    }

    private func apply(from view: UIView) {
        // 可能要等一拍才能找到宿主 VC（SwiftUI 挂载时序）。
        func walk(_ r: UIResponder?) -> UIViewController? {
            guard let r else { return nil }
            if let vc = r as? UIViewController { return vc }
            return walk(r.next)
        }
        func set(_ vc: UIViewController) {
            vc.prefersHomeIndicatorAutoHidden = true
        }
        if let vc = walk(uiView) {
            set(vc)
        } else {
            DispatchQueue.main.async { [weak view] in
                guard let view else { return }
                if let vc = walk(view.next) { set(vc) }
            }
        }
    }
}
