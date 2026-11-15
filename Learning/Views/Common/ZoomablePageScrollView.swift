import SwiftUI
import UIKit

private struct PageZoomScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// 已完成重绘的页面倍率；捏合中沿用上次倍率，松手后更新，避免逐帧重新排版。
    var pageZoomScale: CGFloat {
        get { self[PageZoomScaleKey.self] }
        set { self[PageZoomScaleKey.self] = newValue }
    }

    /// 绘制用的像素密度：屏幕倍率 × 页面倍率。只用于生成公式图片、设置图层分辨率；
    /// 排版仍按屏幕的 displayScale，缩放前后行高和位置不变。
    var renderScale: CGFloat { displayScale * pageZoomScale }
}

/// 正文和草稿放在同一个原生缩放容器中，缩放只改变显示，不改变笔迹的页面坐标。
/// 两种模式均支持双指捏合；草稿模式双指平移，阅读模式单指平移。
struct ZoomablePageScrollView<Content: View>: UIViewControllerRepresentable {
    let draftEnabled: Bool
    var resetScrollID: AnyHashable? = nil
    var bottomRequest = 0
    var resetZoomRequest = 0
    @ViewBuilder var content: Content

    // UIHostingController 是新的 SwiftUI 根，需传递原页面的 modelContext、PackStore 等环境。
    @Environment(\.self) private var environment

    func makeUIViewController(context: Context) -> PageZoomController {
        PageZoomController()
    }

    func updateUIViewController(_ controller: PageZoomController, context: Context) {
        controller.update(
            draftEnabled: draftEnabled, resetScrollID: resetScrollID,
            bottomRequest: bottomRequest, resetZoomRequest: resetZoomRequest
        ) { width, zoom, displayScale in
            var renderingEnvironment = environment
            renderingEnvironment.pageZoomScale = zoom
            return AnyView(content.environment(\.self, renderingEnvironment)
                // 页面里不需要任何过渡：系统图标替换/出现时默认的符号动画会让图标从上方飘下来
                .contentTransition(.identity)
                .symbolEffectsRemoved()
                .transaction { $0.animation = nil; $0.disablesAnimations = true }
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true))
        }
    }
}

/// SwiftUI 的文字还有独立绘制层，它们不会自动跟随 hosting 根层的 contentsScale。
private final class PageHostingController: UIHostingController<AnyView> {
    var renderingScale: CGFloat = 0
    /// 上次遍历图层时用的倍率
    private var appliedScale: CGFloat = 0

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard renderingScale > 0 else { return }
        // 未缩放时新建的图层本来就是屏幕密度，不必每次排版都遍历整页图层：
        // AI 流式输出时页面高度不断变化，每次都遍历会让滚动卡顿。倍率刚变回 1 时仍要遍历一次，把放大时提高的密度改回来
        if renderingScale == view.traitCollection.displayScale && appliedScale == renderingScale { return }
        appliedScale = renderingScale
        updateScale(of: view.layer)
    }

    private func updateScale(of layer: CALayer) {
        // PencilKit 子树用自己的原生 zoom 重绘，不叠加正文的渲染倍率。
        if layer.delegate is DraftCanvasContainer { return }
        // 图片层已经带有解码后的 contents；强制 setNeedsDisplay 会清空它，
        // 而 SwiftUI 不一定会再次提交位图，结果只剩空白的图片占位。
        if layer.contents == nil && layer.contentsScale != renderingScale {
            layer.contentsScale = renderingScale
            layer.setNeedsDisplay()
        }
        if layer.shouldRasterize { layer.rasterizationScale = renderingScale }
        for child in layer.sublayers ?? [] { updateScale(of: child) }
    }
}

/// 独立观察手指和 Pencil，即使导航保护已放行，也能在随后落笔时取消导航。
private final class TouchStartTracker: UIGestureRecognizer {
    private(set) var starts: [(touch: UITouch, point: CGPoint)] = []
    var onTouchesChanged: (() -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        let oldFingerCount = starts.filter { $0.touch.type == .direct }.count
        for t in touches { starts.append((t, t.location(in: nil))) }
        if oldFingerCount < 2, starts.filter({ $0.touch.type == .direct }).count >= 2 {
            starts = starts.map { ($0.touch, $0.touch.location(in: nil)) }
        }
        onTouchesChanged?()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { drop(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { drop(touches) }

    private func drop(_ touches: Set<UITouch>) {
        starts.removeAll { touches.contains($0.touch) }
        onTouchesChanged?()
        if starts.isEmpty { state = .failed }
    }

    override func reset() {
        starts = []
        onTouchesChanged?()
    }

    override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }

}

/// 阅读模式用原生手势；草稿模式统一处理双指平移/缩放，避免原生识别器在保护窗口内抢跑。
final class PageScrollView: UIScrollView, UIGestureRecognizerDelegate {
    private let tracker = TouchStartTracker()
    private let palmGate = PalmNavigationGestureRecognizer(target: nil, action: nil)
    private var navigatingCanvases: [PencilOnlyCanvas] = []
    private var pencilSuppressedNavigation = false
    private(set) var isCustomZooming = false
    var onCustomZoomBegin: (() -> Void)?
    var onCustomZoomEnd: ((CGFloat) -> Void)?
    private var inertiaTask: Task<Void, Never>?
    private var inertiaLink: CADisplayLink?
    private var inertiaVelocity = CGPoint.zero
    private var inertiaTime: CFTimeInterval = 0
    private let inertiaTarget = PageInertiaTarget()
    var protectsPencilInput = false {
        didSet {
            guard protectsPencilInput != oldValue else { return }
            stopNavigationMotion()
            finishCustomZoom()
            palmGate.isEnabled = protectsPencilInput
            configureNavigationRecognizers()
            updateCanvasNavigation()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        tracker.cancelsTouchesInView = false
        tracker.delaysTouchesEnded = false
        tracker.allowedTouchTypes = [UITouch.TouchType.direct, .pencil].map { NSNumber(value: $0.rawValue) }
        tracker.delegate = self
        tracker.onTouchesChanged = { [weak self] in self?.updateCanvasNavigation() }
        addGestureRecognizer(tracker)
        palmGate.isEnabled = false
        palmGate.onTouchStart = { [weak self] in self?.stopNavigationMotion() }
        palmGate.onStep = { [weak self] in self?.handleNavigation($0) }
        addGestureRecognizer(palmGate)
        inertiaTarget.page = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// setZoomScale 可能更新原生识别器状态；草稿模式始终只让统一识别器接收导航。
    func configureNavigationRecognizers() {
        let nativeEnabled = !protectsPencilInput && !pencilSuppressedNavigation
        let touchTypes = nativeEnabled ? [NSNumber(value: UITouch.TouchType.direct.rawValue)] : []
        if panGestureRecognizer.allowedTouchTypes != touchTypes { panGestureRecognizer.allowedTouchTypes = touchTypes }
        if pinchGestureRecognizer?.allowedTouchTypes != touchTypes { pinchGestureRecognizer?.allowedTouchTypes = touchTypes }
        if panGestureRecognizer.isEnabled != nativeEnabled { panGestureRecognizer.isEnabled = nativeEnabled }
        if pinchGestureRecognizer?.isEnabled != nativeEnabled { pinchGestureRecognizer?.isEnabled = nativeEnabled }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        configureNavigationRecognizers()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopNavigationMotion(); finishCustomZoom() }
    }

    private func viewportPoint(_ windowPoint: CGPoint) -> CGPoint {
        let point = convert(windowPoint, from: nil)
        return CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY)
    }

    private func limitedOffset(_ offset: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, offset.x), max(0, contentSize.width - bounds.width)),
                y: min(max(0, offset.y), max(0, contentSize.height - bounds.height)))
    }

    private func handleNavigation(_ step: PageNavigationStep) {
        switch step {
        case .begin(let intent):
            stopNavigationMotion()
            if intent == .pinch && !isCustomZooming {
                isCustomZooming = true
                onCustomZoomBegin?()
            }
        case .pan(let delta):
            setContentOffset(limitedOffset(CGPoint(x: contentOffset.x - delta.x, y: contentOffset.y - delta.y)), animated: false)
        case .pinch(let previous, let current):
            let transform = PagePinchTransform.apply(zoom: zoomScale, offset: contentOffset,
                previousCenter: viewportPoint(previous.center), currentCenter: viewportPoint(current.center),
                previousSpan: previous.span, currentSpan: current.span,
                minimum: minimumZoomScale, maximum: maximumZoomScale)
            setZoomScale(transform.zoom, animated: false)
            setContentOffset(limitedOffset(transform.offset), animated: false)
            configureNavigationRecognizers()
        case .end(let intent):
            if intent == .pinch { finishCustomZoom() }
            else if !palmGate.cancelledNavigation { scheduleInertia(palmGate.velocity) }
        }
    }

    private func finishCustomZoom() {
        guard isCustomZooming else { return }
        isCustomZooming = false
        onCustomZoomEnd?(zoomScale)
    }

    private func scheduleInertia(_ fingerVelocity: CGPoint) {
        guard hypot(fingerVelocity.x, fingerVelocity.y) >= 200 else { return }
        inertiaTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard let self, !Task.isCancelled, !pencilSuppressedNavigation else { return }
            inertiaVelocity = CGPoint(x: -fingerVelocity.x, y: -fingerVelocity.y)
            inertiaTime = 0
            let link = CADisplayLink(target: inertiaTarget, selector: #selector(PageInertiaTarget.tick(_:)))
            inertiaLink = link
            link.add(to: .main, forMode: .common)
        }
    }

    private func stopNavigationMotion() {
        inertiaTask?.cancel()
        inertiaTask = nil
        inertiaLink?.invalidate()
        inertiaLink = nil
    }

    fileprivate func advanceInertia(_ link: CADisplayLink) {
        let dt = inertiaTime == 0 ? link.duration : min(0.05, link.timestamp - inertiaTime)
        inertiaTime = link.timestamp
        let old = contentOffset
        let next = limitedOffset(CGPoint(x: old.x + inertiaVelocity.x * dt, y: old.y + inertiaVelocity.y * dt))
        setContentOffset(next, animated: false)
        let decay = pow(Double(decelerationRate.rawValue), dt * 1000)
        inertiaVelocity.x *= decay
        inertiaVelocity.y *= decay
        if next.x == old.x { inertiaVelocity.x = 0 }
        if next.y == old.y { inertiaVelocity.y = 0 }
        if hypot(inertiaVelocity.x, inertiaVelocity.y) < 10 { stopNavigationMotion() }
    }

    #if DEBUG
    func checkNavigationTransforms() {
        palmGate.checkPencilOnlyRelease()
        let originalZoom = zoomScale, originalOffset = contentOffset
        setZoomScale(1.5, animated: false)
        setContentOffset(limitedOffset(CGPoint(x: 100, y: 200)), animated: false)
        let zoomBefore = zoomScale, offsetBefore = contentOffset
        let windowCenter = convert(CGPoint(x: bounds.minX + 120, y: bounds.minY + 220), to: nil)
        let before = TwoFingerGeometry(CGPoint(x: windowCenter.x - 60, y: windowCenter.y),
                                       CGPoint(x: windowCenter.x + 60, y: windowCenter.y))
        let after = TwoFingerGeometry(CGPoint(x: windowCenter.x - 75, y: windowCenter.y),
                                      CGPoint(x: windowCenter.x + 75, y: windowCenter.y))
        handleNavigation(.begin(.pinch))
        precondition(zoomScale == zoomBefore && contentOffset == offsetBefore, "捏合起步不能跳变")
        handleNavigation(.pinch(previous: before, current: after))
        precondition(abs(zoomScale - zoomBefore * 1.25) < 0.001, "捏合必须使用放行后的增量指距比")
        let expected = limitedOffset(CGPoint(x: (offsetBefore.x + 120) * 1.25 - 120,
                                             y: (offsetBefore.y + 220) * 1.25 - 220))
        precondition(hypot(contentOffset.x - expected.x, contentOffset.y - expected.y) < 1, "捏合中心不能漂移")
        handleNavigation(.end(.pinch))
        setZoomScale(originalZoom, animated: false)
        setContentOffset(originalOffset, animated: false)
        configureNavigationRecognizers()
        if protectsPencilInput {
            precondition(!panGestureRecognizer.isEnabled && pinchGestureRecognizer?.isEnabled == false,
                         "草稿页不能由原生导航识别器同时处理双指")
        }
        InkLog.write("debug_page_navigation_checks", ["passed": true])
    }
    #endif

    private func updateCanvasNavigation() {
        let fingers = tracker.starts.filter { $0.touch.type == .direct }
        let pencilDown = tracker.starts.contains { $0.touch.type == .pencil }
        if protectsPencilInput {
            palmGate.setPencilDown(pencilDown)
            if pencilDown && !pencilSuppressedNavigation {
                pencilSuppressedNavigation = true
                // 取消已开始的手掌手势与惯性；只改变页面导航，不碰 PencilKit 的书写手势。
                stopNavigationMotion()
                setContentOffset(contentOffset, animated: false)
                configureNavigationRecognizers()
                InkLog.write("input_navigation_suppressed_by_pencil", ["pointer_count": fingers.count])
            }
        }
        // Pencil 抬起后，仍压着屏幕的手掌不能恢复导航；等整组触摸离开。
        if pencilSuppressedNavigation && ((!pencilDown && fingers.isEmpty) || !protectsPencilInput) {
            pencilSuppressedNavigation = false
            configureNavigationRecognizers()
        }
        if fingers.isEmpty {
            let canvases = navigatingCanvases
            navigatingCanvases = []
            for canvas in canvases { canvas.setPageNavigationActive(false) }
        } else if fingers.count >= 2, panGestureRecognizer.minimumNumberOfTouches == 2 {
            for (touch, _) in fingers {
                var view = touch.view
                while let current = view {
                    if let canvas = current as? PencilOnlyCanvas {
                        if canvas.receivesSelectionTouches, !navigatingCanvases.contains(where: { $0 === canvas }) {
                            navigatingCanvases.append(canvas)
                            canvas.setPageNavigationActive(true)
                        }
                        break
                    }
                    view = current.superview
                }
            }
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        if g === tracker || other === tracker { return true }
        // 套索会让触点命中 PencilKit 的选区视图，其长按等原生手势可能先识别。
        // 草稿模式的双指平移/捏合仍须启动；单指选区拖动由画布独立处理。
        guard panGestureRecognizer.minimumNumberOfTouches == 2,
              g === panGestureRecognizer || g === pinchGestureRecognizer else { return false }
        var view = other.view
        while let current = view {
            if let canvas = current as? PencilOnlyCanvas { return canvas.receivesSelectionTouches }
            view = current.superview
        }
        return false
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === panGestureRecognizer || g === pinchGestureRecognizer {
            guard !protectsPencilInput && !pencilSuppressedNavigation else { return false }
        }
        guard super.gestureRecognizerShouldBegin(g) else { return false }
        guard g === pinchGestureRecognizer else { return true }
        let pinch = pinchEvidence() ?? true
        if !pinch { InkLog.write("page_pinch_rejected", ["scale": zoomScale]) }
        return pinch
    }

    private func pinchEvidence() -> Bool? {
        let active = tracker.starts.filter {
            $0.touch.type == .direct && $0.touch.phase != .ended && $0.touch.phase != .cancelled
        }
        guard active.count >= 2 else { return nil }
        let (a, b) = (active[0], active[1])
        let a1 = a.touch.location(in: nil), b1 = b.touch.location(in: nil)
        let spread = abs(hypot(a1.x - b1.x, a1.y - b1.y) - hypot(a.point.x - b.point.x, a.point.y - b.point.y))
        let move = hypot((a1.x + b1.x - a.point.x - b.point.x) / 2, (a1.y + b1.y - a.point.y - b.point.y) / 2)
        // 单指基本不动时的捏合，中点也会移动；只在平移明显占优时拒绝缩放。
        return !(move >= 8 && move >= spread * 2)
    }
}

private final class PageInertiaTarget: NSObject {
    weak var page: PageScrollView?
    @objc func tick(_ link: CADisplayLink) { page?.advanceInertia(link) }
}

/// UIScrollView 保持缩放与坐标转换，草稿模式的双指输入由统一导航识别器驱动。
final class PageZoomController: UIViewController, UIScrollViewDelegate {
    let scrollView = PageScrollView()
    private let hosting = PageHostingController(rootView: AnyView(EmptyView()))
    private var makeContent: ((CGFloat, CGFloat, CGFloat) -> AnyView)?
    private var renderingZoom: CGFloat = 1
    private var renderingDisplayScale: CGFloat = 0
    private var contentWidth: CGFloat = 0
    private var contentHeight: CGFloat = 0
    private var needsRootUpdate = false
    private var resetScrollID: AnyHashable?
    private var bottomRequest = 0
    private var resetZoomRequest = 0
    private var pendingTop = false
    private var pendingBottom = false
    private var pendingZoomReset = false

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didBecomeActive() }
        }
        view.backgroundColor = .clear
        scrollView.backgroundColor = .clear
        scrollView.delegate = self
        scrollView.onCustomZoomBegin = { [weak self] in
            guard let self else { return }
            InkLog.write("page_zoom_begin", ["scale": scrollView.zoomScale, "offset": scrollView.contentOffset, "source": "two_finger"])
        }
        scrollView.onCustomZoomEnd = { [weak self] scale in
            guard let self else { return }
            InkLog.write("page_zoom_end", ["scale": scale, "offset": scrollView.contentOffset, "source": "two_finger"])
            refreshRendering(at: scale)
        }
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 3
        scrollView.bouncesZoom = false
        scrollView.alwaysBounceVertical = true
        scrollView.contentInsetAdjustmentBehavior = .never
        // 不让 Pencil 或手掌带动页面；缩放始终只接收两根手指。
        let fingers = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        scrollView.panGestureRecognizer.allowedTouchTypes = fingers
        scrollView.pinchGestureRecognizer?.allowedTouchTypes = fingers
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        hosting.safeAreaRegions = []
        hosting.view.backgroundColor = .clear
        addChild(hosting)
        scrollView.addSubview(hosting.view)
        hosting.didMove(toParent: self)
    }

    // 学习/复习页不用右滑返回（容易和书写、拖动冲突），只保留左上角返回按钮；离开时恢复。
    private var popGestures: [UIGestureRecognizer] {
        guard let nav = navigationController else { return [] }
        var list = [nav.interactivePopGestureRecognizer]
        if #available(iOS 26.0, *) { list.append(nav.interactiveContentPopGestureRecognizer) }
        return list.compactMap { $0 }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        popGestures.forEach { $0.isEnabled = false }
        #if DEBUG
        startDebugZoomTest()
        #endif
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        popGestures.forEach { $0.isEnabled = true }
    }

    func update(draftEnabled: Bool, resetScrollID: AnyHashable?, bottomRequest: Int,
                resetZoomRequest: Int, content: @escaping (CGFloat, CGFloat, CGFloat) -> AnyView) {
        loadViewIfNeeded()
        scrollView.protectsPencilInput = draftEnabled
        makeContent = content
        needsRootUpdate = true
        let touches = draftEnabled ? 2 : 1
        if scrollView.panGestureRecognizer.minimumNumberOfTouches != touches {
            scrollView.panGestureRecognizer.minimumNumberOfTouches = touches
            InkLog.write("scroll_config", ["min_touches": touches])
        }
        scrollView.configureNavigationRecognizers()
        // 初次加载进度不跳动；换题、换轮后保留倍率、回到页顶。
        if self.resetScrollID != nil, self.resetScrollID != resetScrollID { pendingTop = true }
        self.resetScrollID = resetScrollID
        if self.bottomRequest != bottomRequest { pendingBottom = true }
        self.bottomRequest = bottomRequest
        if self.resetZoomRequest != resetZoomRequest { pendingZoomReset = true }
        self.resetZoomRequest = resetZoomRequest
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = scrollView.bounds.width
        guard width > 0, let makeContent else { return }
        if pendingZoomReset {
            pendingZoomReset = false
            scrollView.setZoomScale(1, animated: false)
            refreshRendering(at: 1)
            InkLog.write("page_zoom_reset")
        }
        // 切到后台时系统会按另一方向的尺寸排版来拍多任务快照，随后再改回原尺寸。
        // 后台的这两次重排之后 SwiftUI 内容可能停留在横屏宽度，回到前台时两侧被裁掉；
        // 后台不跟随尺寸变化，回到前台时再按实际宽度检查（didBecomeActive）。
        if UIApplication.shared.applicationState == .background, contentWidth > 0 {
            InkLog.write("page_layout_skipped_background", ["width": width, "content_w": contentWidth])
            return
        }
        let displayScale = scrollView.traitCollection.displayScale * renderingZoom
        if needsRootUpdate || width != contentWidth || displayScale != renderingDisplayScale {
            needsRootUpdate = false
            contentWidth = width
            renderingDisplayScale = displayScale
            // SwiftUI 的文字/形状按放大后的像素密度重绘，而不是拉伸 100% 时的缓存。
            // 只提高图层分辨率，不改 traits 的 displayScale：排版按屏幕像素对齐，
            // 改了它行高、位置会按新像素网格取整，缩放后整页轻微重排。
            hosting.renderingScale = displayScale
            hosting.view.contentScaleFactor = displayScale
            hosting.rootView = AnyView(makeContent(width, renderingZoom, displayScale)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak self] height in
                    // AI 流式讲解、展开解析等也会改变页面高度，不仅是父页面刷新。
                    guard let self, height.isFinite, height > 0, abs(height - self.contentHeight) > 0.5 else { return }
                    self.contentHeight = height
                    self.view.setNeedsLayout()
                })
            contentHeight = hosting.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        }
        layoutPage()
        if pendingTop {
            pendingTop = false
            scrollView.setContentOffset(.zero, animated: false)
        }
        if pendingBottom {
            pendingBottom = false
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x,
                y: max(0, scrollView.contentSize.height - scrollView.bounds.height)), animated: false)
        }
    }

    private func didBecomeActive() {
        // 在后台期间真的旋转过时，这里按新宽度重排
        view.setNeedsLayout()
    }

    private func layoutPage() {
        guard contentHeight.isFinite, contentHeight > 0 else { return }
        // 内容高度变化（切换讲解/原文、展开内容）时直接到位，不能被外层动画带着移动
        UIView.performWithoutAnimation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            applyPageLayout()
            CATransaction.commit()
        }
    }

    private func applyPageLayout() {
        let size = CGSize(width: contentWidth, height: contentHeight)
        let scaled = CGSize(width: size.width * scrollView.zoomScale, height: size.height * scrollView.zoomScale)
        // 不能写 frame：缩放时 frame 已带 transform，改 bounds 才不会重置 PencilKit 坐标。
        if hosting.view.bounds.size != size { hosting.view.bounds.size = size }
        let center = CGPoint(x: scaled.width / 2, y: scaled.height / 2)
        if hosting.view.center != center { hosting.view.center = center }
        if scrollView.contentSize != scaled { scrollView.contentSize = scaled }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { hosting.view }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        InkLog.write("page_zoom_begin", ["scale": scrollView.zoomScale, "offset": scrollView.contentOffset])
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        // 程序化缩放（恢复原大小）也需要刷新，手势中则仅做轻量的 transform。
        if !scrollView.isZooming && !self.scrollView.isCustomZooming && !debugHoldRefresh { refreshRendering(at: scrollView.zoomScale) }
    }

    #if DEBUG
    private var debugHoldRefresh = false
    /// 调试：-debugZoomTest 2 先只做缩放变换（相当于捏合中），4 秒后再按新倍率重绘，便于截图对比
    private func startDebugZoomTest() {
        if UserDefaults.standard.bool(forKey: "debugPageNavigationChecks") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                scrollView.checkNavigationTransforms()
            }
        }
        let zoom = UserDefaults.standard.double(forKey: "debugZoomTest")
        guard zoom > 1 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            debugHoldRefresh = true
            scrollView.setZoomScale(zoom, animated: false)
            debugHoldRefresh = false
            InkLog.write("debug_zoom_transform", ["scale": zoom])
            try? await Task.sleep(for: .seconds(4))
            refreshRendering(at: zoom)
        }
    }
    #else
    private let debugHoldRefresh = false
    #endif

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        guard !self.scrollView.isCustomZooming else { return }
        InkLog.write("page_zoom_end", ["scale": scale, "offset": scrollView.contentOffset])
        refreshRendering(at: scale)
    }

    private func refreshRendering(at scale: CGFloat) {
        guard abs(renderingZoom - scale) > 0.0001 else { return }
        renderingZoom = scale
        needsRootUpdate = true
        view.setNeedsLayout()
        InkLog.write("page_zoom_redraw", ["scale": scale])
    }
}
