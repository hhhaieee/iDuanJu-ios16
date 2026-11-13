import SwiftUI

/// Full-screen image viewer shared by Telegram posts, downloads and the manga reader:
/// swipe left/right between images, pinch / double-tap to zoom, drag down to close.
struct ImageViewer: View {
    struct Item: Identifiable, Hashable { var url: String; var id: String { url } }
    let items: [Item]
    @State var index: Int
    var headers: [String: String] = [:]
    var onSave: ((Item) async throws -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var drag: CGFloat = 0
    @State private var zoomed = false
    @State private var toast: String?

    var body: some View {
        ZStack {
            Color.black.opacity(1 - min(0.7, abs(drag) / 600)).ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(items.indices, id: \.self) { i in
                    ZoomableImage(url: items[i].url, headers: headers, zoomed: $zoomed).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // Zoomed: drags pan the image instead of turning the page (zoom out, or double tap, to page again).
            .scrollDisabled(zoomed)
            .offset(y: drag)
            .simultaneousGesture(zoomed ? nil : DragGesture(minimumDistance: 20)
                .onChanged { v in if abs(v.translation.height) > abs(v.translation.width) { drag = v.translation.height } }
                .onEnded { v in
                    if abs(v.translation.height) > 120 || abs(v.predictedEndTranslation.height) > 300 { dismiss() }
                    else { withAnimation(.spring(response: 0.3)) { drag = 0 } }
                })
            VStack {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.headline).padding(12).background(.ultraThinMaterial, in: Circle()) }
                        .accessibilityIdentifier("viewer.close")
                    Spacer()
                    Text("\(index + 1) / \(items.count)").font(.subheadline.monospacedDigit()).foregroundStyle(.white)
                        .accessibilityIdentifier("viewer.counter")
                    Spacer()
                    if let onSave {
                        Button {
                            Task {
                                do { try await onSave(items[index]); toast = "已保存到相册" } catch { toast = error.localizedDescription }
                            }
                        } label: { Image(systemName: "square.and.arrow.down").font(.headline).padding(12).background(.ultraThinMaterial, in: Circle()) }
                            .accessibilityLabel("保存到相册")
                    } else { Color.clear.frame(width: 44, height: 44) }
                }
                .foregroundStyle(.white).padding(.horizontal, 16)
                Spacer()
                if let toast { Text(toast).font(.footnote).foregroundStyle(.white).padding(10).background(.black.opacity(0.6), in: Capsule()).padding(.bottom, 30) }
            }
            .opacity(drag == 0 ? 1 : 0)
        }
        .statusBarHidden()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tg.viewer")
        .preferredColorScheme(.dark)
        .task(id: toast) { if toast != nil { try? await Task.sleep(for: .seconds(2)); toast = nil } }
    }
}

/// One zoomable page. UIScrollView does the zooming: pinch is anchored at the fingers, zoom and pan
/// rubber-band at their limits, panning stays inside the image, and once zoomed to an edge a further swipe
/// goes to the enclosing pager (like Photos). Double tap zooms in on the tapped point / back to fit.
struct ZoomableImage: View {
    let url: String
    var headers: [String: String] = [:]
    @Binding var zoomed: Bool
    @State private var image: UIImage?
    @State private var failed = false
    @State private var isZoomed = false

    var body: some View {
        ZStack {
            if let image {
                ZoomScrollView(image: image) { z in
                    isZoomed = z
                    if zoomed != z { zoomed = z }
                }
                .accessibilityElement()
                .accessibilityAddTraits(.isImage)
                .accessibilityIdentifier("viewer.image")
                .accessibilityValue(isZoomed ? "zoomed" : "fit")
            } else if failed {
                Image(systemName: "photo").font(.largeTitle).foregroundStyle(.white.opacity(0.4))
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            do { image = try await CoverStore.shared.image(url: url, headers: headers) } catch { failed = true }
        }
    }
}

private struct ZoomScrollView: UIViewRepresentable {
    let image: UIImage
    var onZoomChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ZoomView {
        let v = ZoomView()
        v.delegate = context.coordinator
        v.onZoomChange = onZoomChange
        v.set(image)
        let dt = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        dt.numberOfTapsRequired = 2
        v.addGestureRecognizer(dt)
        return v
    }

    func updateUIView(_ v: ZoomView, context: Context) {
        v.onZoomChange = onZoomChange
        if v.imageView.image !== image { v.set(image) }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? ZoomView)?.imageView }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { (scrollView as? ZoomView)?.zoomDidChange() }

        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let v = g.view as? ZoomView else { return }
            if v.zoomScale > v.minimumZoomScale + 0.01 {
                v.setZoomScale(v.minimumZoomScale, animated: true)
            } else {
                // Zoom ×2.5 around the tapped point.
                let p = g.location(in: v.imageView)
                let s = min(v.maximumZoomScale, v.minimumZoomScale * 2.5)
                let w = v.bounds.width / s, h = v.bounds.height / s
                v.zoom(to: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), animated: true)
            }
        }
    }

    final class ZoomView: UIScrollView {
        let imageView = UIImageView()
        var onZoomChange: (Bool) -> Void = { _ in }
        private var lastZoomed = false
        private var laidOutFor: CGSize = .zero

        override init(frame: CGRect) {
            super.init(frame: frame)
            showsHorizontalScrollIndicator = false
            showsVerticalScrollIndicator = false
            contentInsetAdjustmentBehavior = .never
            decelerationRate = .fast
            bouncesZoom = true
            alwaysBounceVertical = false
            alwaysBounceHorizontal = false
            imageView.contentMode = .scaleAspectFit
            addSubview(imageView)
        }

        required init?(coder: NSCoder) { fatalError() }

        func set(_ image: UIImage) {
            imageView.image = image
            laidOutFor = .zero
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.size != laidOutFor, let img = imageView.image, img.size.width > 0, bounds.width > 0 else { center(); return }
            laidOutFor = bounds.size
            // Image at its natural size; min zoom = aspect fit, max = 4× fit (at least 1:1 pixels).
            zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: img.size)
            contentSize = img.size
            let fit = min(bounds.width / img.size.width, bounds.height / img.size.height)
            minimumZoomScale = fit
            maximumZoomScale = max(fit * 4, 1)
            zoomScale = fit
            center()
        }

        /// Keep the image centred while it is smaller than the viewport.
        private func center() {
            let s = imageView.frame.size
            contentInset = UIEdgeInsets(top: max(0, (bounds.height - s.height) / 2), left: max(0, (bounds.width - s.width) / 2),
                                    bottom: 0, right: 0)
        }

        func zoomDidChange() {
            center()
            let z = zoomScale > minimumZoomScale + 0.01
            if z != lastZoomed { lastZoomed = z; onZoomChange(z) }
        }

        /// Paging away / dismissing: come back at fit.
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil, zoomScale != minimumZoomScale { setZoomScale(minimumZoomScale, animated: false) }
        }
    }
}
