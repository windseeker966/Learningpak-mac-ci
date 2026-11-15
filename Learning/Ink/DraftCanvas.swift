import PencilKit
import SwiftData
import SwiftUI

// 草稿画布：盖在讲解页、题目页上，只接受 Apple Pencil；手指的点按、长按选字、双指滚动照常传给下面的页面。
// 每一笔、每次擦除、撤销/重做、工具切换都写进 InkLog，供之后调整「涂抹即擦除」等逻辑。

/// 草稿的存储键：按页面区分
enum DraftKey {
    static func lecture(pack: String, section: String, round: Int) -> String { "\(pack)|\(section)|round\(round)|lecture" }
    static func question(pack: String, questionID: String) -> String { "\(pack)|question|\(questionID)" }
    static func review(pack: String, questionID: String) -> String { "\(pack)|review|\(questionID)" }
}

extension Notification.Name {
    /// 某页草稿被删除（如讲解重新生成）。object 为草稿键
    static let draftInkDeleted = Notification.Name("draftInkDeleted")
    /// 请某页草稿立即保存（如 AI 批改前要读取最新笔迹）。object 为草稿键
    static let draftFlushRequested = Notification.Name("draftFlushRequested")
    /// 某页的书写区锚点移动了。object 为草稿键，新位置见 DraftAnchors
    static let draftAnchorMoved = Notification.Name("draftAnchorMoved")
    /// 某页的临时区域（AI 改编）关闭了，删掉其中的笔迹。object 为草稿键，userInfo["top"] 为区域顶边
    static let draftTransientCleared = Notification.Name("draftTransientCleared")
    /// 删除一个书写区及其上的笔迹。object 为草稿键，userInfo["rect"] 为书写区，["shift"] 为下方内容上移的距离
    static let draftAreaDeleteRequested = Notification.Name("draftAreaDeleteRequested")
}

/// 各页画布上当前的笔迹（含不保存的 AI 改编区）。AI 批改改编题时从这里读，数据库里没有这部分笔迹
@MainActor
enum LiveDraft {
    fileprivate static var canvases: [String: WeakCanvas] = [:]

    fileprivate struct WeakCanvas { weak var canvas: PKCanvasView? }

    static func drawing(_ key: String) -> PKDrawing? { canvases[key]?.canvas?.drawing }
}

/// 题目页的书写区锚点（页面坐标）：每个锚点是页面上一段内容的顶边，锚点以下、下一个锚点以上的笔迹跟着它平移。
/// 题目下方书写部分是主锚点（writing），位置随笔迹保存；AI 改编区是临时锚点，其中的笔迹不保存。
@MainActor
enum DraftAnchors {
    /// 主锚点：题目下方的书写部分
    static let writing = "writing"

    /// 各页各锚点最近一次报告的位置；画布创建得晚时从这里取
    static var latest: [String: [String: CGFloat]] = [:]
    /// 各页临时区域的顶边：以下的笔迹不保存
    static var transientTop: [String: CGFloat] = [:]

    static func report(_ key: String, name: String, top: CGFloat, transient: Bool) {
        guard top.isFinite else { return }
        if transient { transientTop[key] = top }
        guard latest[key]?[name].map({ abs($0 - top) > 0.5 }) ?? true else { return }
        latest[key, default: [:]][name] = top
        NotificationCenter.default.post(name: .draftAnchorMoved, object: key)
    }

    /// 临时区域关闭：去掉它的锚点，并通知画布删掉区域里的笔迹
    static func clearTransient(_ key: String, names: [String]) {
        for n in names { latest[key]?[n] = nil }
        guard let top = transientTop.removeValue(forKey: key) else { return }
        NotificationCenter.default.post(name: .draftTransientCleared, object: key, userInfo: ["top": top])
    }

    /// 临时区域（AI 改编区）里当前的笔迹；页面没有临时区域时是整页的。画布不在时为 nil
    static func transientStrokes(_ key: String) -> [PKStroke]? {
        guard let drawing = LiveDraft.drawing(key) else { return nil }
        guard let top = transientTop[key] else { return drawing.strokes }
        return drawing.strokes.filter { $0.renderBounds.midY >= top - 12 }
    }

    /// 清掉临时区域里的笔迹，区域保留（改编题重做）
    static func clearTransientInk(_ key: String) {
        guard let top = transientTop[key] else { return }
        NotificationCenter.default.post(name: .draftTransientCleared, object: key, userInfo: ["top": top])
    }

    /// 删除书写区：rect 为书写区（页面坐标），shift 为它下方的内容上移的距离
    static func deleteArea(_ key: String, rect: CGRect, shift: CGFloat) {
        NotificationCenter.default.post(name: .draftAreaDeleteRequested, object: key,
                                        userInfo: ["rect": rect, "shift": shift])
    }
}

private struct DraftInkAnchor: ViewModifier {
    let key: String
    let name: String
    let transient: Bool

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(draftPageSpace)).minY } action: { top in
            DraftAnchors.report(key, name: name, top: top, transient: transient)
        }
    }
}

extension View {
    /// 标记草稿页的书写区锚点（见 DraftAnchors）。transient：这一段（直到页底）的笔迹不保存
    func draftInkAnchor(_ key: String, name: String = DraftAnchors.writing, transient: Bool = false) -> some View {
        modifier(DraftInkAnchor(key: key, name: name, transient: transient))
    }
}

enum DraftStore {
    static func delete(_ key: String, reason: String, in context: ModelContext) {
        let items = (try? context.fetch(FetchDescriptor<DraftInk>(predicate: #Predicate { $0.key == key }))) ?? []
        for d in items {
            InkLog.write("draft_deleted", ["page": key, "reason": reason, "strokes": d.strokeCount, "bytes": d.data.count])
            context.delete(d)
        }
        try? context.save()
        NotificationCenter.default.post(name: .draftInkDeleted, object: key)
    }

    /// 删除某节所有讲解页的草稿
    static func deleteLectures(pack: String, section: String, reason: String, in context: ModelContext) {
        let prefix = "\(pack)|\(section)|round"
        let all = (try? context.fetch(FetchDescriptor<DraftInk>())) ?? []
        for d in all where d.key.hasPrefix(prefix) && d.key.hasSuffix("|lecture") {
            delete(d.key, reason: reason, in: context)
        }
    }
}

/// 所有草稿页共用一个工具栏，记住上次用的笔
@MainActor
enum DraftToolPicker {
    static let shared: PKToolPicker = {
        let p = PKToolPicker()
        p.stateAutosaveName = "LearningPack.draft"
        return p
    }()
}

/// 草稿模式下 Pencil 也能点的控件区域（页面坐标）。控件用 .draftTappable() 登记，画布命中测试时查询
final class DraftTapTargets {
    var rects: [UUID: CGRect] = [:]
    func contains(_ p: CGPoint) -> Bool { rects.values.contains { $0.contains(p) } }
}

private struct DraftTapTargetsKey: EnvironmentKey {
    static let defaultValue: DraftTapTargets? = nil
}

extension EnvironmentValues {
    var draftTapTargets: DraftTapTargets? {
        get { self[DraftTapTargetsKey.self] }
        set { self[DraftTapTargetsKey.self] = newValue }
    }
}

private struct DraftTappable: ViewModifier {
    let on: Bool
    @Environment(\.draftTapTargets) private var targets
    @State private var id = UUID()
    @State private var frame: CGRect = .null

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(draftPageSpace)) } action: {
                frame = $0
                sync()
            }
            .onChange(of: on) { sync() }
            .onDisappear { targets?.rects[id] = nil }
    }

    private func sync() {
        targets?.rects[id] = on && !frame.isNull ? frame : nil
    }
}

extension View {
    /// 草稿模式下 Apple Pencil 落在这个控件上时，交给控件而不是画笔（按钮、切换、选项等）。
    /// on 为 false 时不登记（例如已作答后选项不再可点，可以在上面写字）
    func draftTappable(_ on: Bool = true) -> some View { modifier(DraftTappable(on: on)) }
}

/// 普通书写透传手指，书写手势挂在外层页面上，只接 Pencil 并避开控件。
/// 套索时改由原生画布处理选区、拖动与复制菜单；控件区域仍透传。
final class PencilOnlyCanvas: PKCanvasView {
    /// 套索的选区、拖动和编辑菜单需要命中原生画布，不能只转移书写手势。
    var receivesSelectionTouches = false
    /// Pencil 落在这些控件区域时不写字，交给下面的控件
    var tapTargets: DraftTapTargets?
    /// 完整页面的未缩放尺寸；画布自身只占当前可见窗口。
    var pageSize: CGSize = .zero
    /// 进入窗口时回调（此时才能成为 first responder 并激活工具栏）
    var onMoveToWindow: (() -> Void)?
    private var pageNavigationActive = false
    private var pausedSelectionGestures: [UIGestureRecognizer] = []

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { onMoveToWindow?() }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        receivesSelectionTouches && super.point(inside: point, with: event)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        constrainSelectionPans()
        if pageNavigationActive { pauseSelectionGestures() }
    }

    /// 第二根手指落下就取消选区操作，避免两指滚动同时微移笔迹。
    /// 一根手指先抬起时仍保持暂停，直到本次所有手指都离开才恢复。
    func setPageNavigationActive(_ active: Bool) {
        guard active != pageNavigationActive else { return }
        pageNavigationActive = active
        if active {
            pauseSelectionGestures()
        } else {
            let paused = pausedSelectionGestures
            pausedSelectionGestures = []
            for gesture in paused { gesture.isEnabled = true }
            constrainSelectionPans()
        }
    }

    private func pauseSelectionGestures() {
        func walk(_ view: UIView) {
            for gesture in view.gestureRecognizers ?? [] where gesture.isEnabled && !(gesture is UIHoverGestureRecognizer) {
                pausedSelectionGestures.append(gesture)
                gesture.isEnabled = false
            }
            for child in view.subviews { walk(child) }
        }
        walk(self)
    }

    /// 选区只用单指或 Pencil 拖动；两根手指留给外层页面。PencilKit 会延迟创建选区视图，
    /// 所以工具切换和布局后均检查，保留原生代理、圈选和编辑菜单。
    func constrainSelectionPans() {
        guard receivesSelectionTouches else { return }
        func walk(_ view: UIView) {
            for case let pan as UIPanGestureRecognizer in view.gestureRecognizers ?? [] {
                guard pan !== drawingGestureRecognizer else { continue }
                if pan.maximumNumberOfTouches > 1 { pan.maximumNumberOfTouches = 1 }
            }
            for child in view.subviews { walk(child) }
        }
        walk(self)
    }
}

/// 书写手势的代理：只接 Pencil、避开控件区域，其余判断转交 PencilKit 原来的代理
private final class DrawingGate: NSObject, UIGestureRecognizerDelegate {
    nonisolated(unsafe) weak var original: UIGestureRecognizerDelegate?
    weak var container: DraftCanvasContainer?
    private var lastLogged: TimeInterval = 0

    // UIKit 只在主线程调用这些方法
    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        original?.responds(to: aSelector) == true ? original : nil
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard touch.type == .pencil else { return false }
        if let c = container, let targets = c.canvas.tapTargets {
            let p = touch.location(in: c)
            if targets.contains(p) {
                if touch.timestamp != lastLogged {
                    lastLogged = touch.timestamp
                    InkLog.write("pencil_tap_passthrough", ["point": p])
                }
                return false
            }
        }
        return original?.gestureRecognizer?(g, shouldReceive: touch) ?? true
    }
}

/// 外层页面会被 UIScrollView 做 transform；把真正的 PencilKit 画布反向缩放抵消它，
/// 再用 PencilKit 自己的 zoomScale 重绘。笔迹坐标不变，屏幕墨迹不再是被放大的缓存。
final class DraftCanvasContainer: UIView {
    let canvas = PencilOnlyCanvas()
    var pageZoom: CGFloat = 1 {
        didSet { if pageZoom != oldValue { setNeedsLayout() } }
    }
    private weak var pageScrollView: UIScrollView?
    private var offsetObserver: NSKeyValueObservation?
    private var zoomObserver: NSKeyValueObservation?
    private var windowSize: CGSize = .zero
    private var appliedDisplayScale: CGFloat = 0
    /// 挂在外层页面上的输入手势（PencilKit 的书写手势、主观题的 Pencil 采样）
    private var inputRecognizers: [UIGestureRecognizer] = []
    private let gate = DrawingGate()
    private weak var drawingHost: UIView?
    private var inputEnabled = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        addSubview(canvas)
        let drawing = canvas.drawingGestureRecognizer
        drawingHost = drawing.view
        gate.original = drawing.delegate
        gate.container = self
        drawing.delegate = gate
        inputRecognizers.append(drawing)
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 3
        disableCanvasPinch()
    }

    /// PKCanvasView 本身是 UIScrollView：设置缩放范围或 setZoomScale 后 UIKit 会重新启用它的 pinch，
    /// 它接受手指且比外层页面更靠近触点，常抢先识别，把两指拖动/缩放吞掉。清空触摸类型后它不再收到任何触摸。
    private func disableCanvasPinch() {
        guard let pinch = canvas.pinchGestureRecognizer else { return }
        if !pinch.allowedTouchTypes.isEmpty { pinch.allowedTouchTypes = [] }
        if pinch.isEnabled { pinch.isEnabled = false }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 套索交给 PencilKit 的完整视图层级；控件区域和画布窗口外仍穿透到正文。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard canvas.receivesSelectionTouches, !isHidden, alpha > 0.01,
              !(canvas.tapTargets?.contains(point) ?? false) else { return nil }
        return canvas.hitTest(canvas.convert(point, from: self), with: event)
    }

    func setInputEnabled(_ enabled: Bool) {
        inputEnabled = enabled
        // 不直接启用 drawingGestureRecognizer：套索选中时它本来就应该由 PencilKit 停用。
        if canvas.isDrawingEnabled != enabled { canvas.isDrawingEnabled = enabled }
        refreshInputRouting()
    }

    func refreshInputRouting() {
        let nativeSelection = inputEnabled && canvas.tool is PKLassoTool
        canvas.receivesSelectionTouches = nativeSelection
        canvas.constrainSelectionPans()
        let drawing = inputRecognizers[0]
        drawing.delegate = nativeSelection ? gate.original : gate
        for r in inputRecognizers {
            let host = r === drawing && nativeSelection ? drawingHost : pageScrollView
            if r.view !== host {
                r.view?.removeGestureRecognizer(r)
                host?.addGestureRecognizer(r)
            }
        }
    }

    /// 再挂一个输入手势到外层页面（进入窗口时生效）
    func addInputRecognizer(_ r: UIGestureRecognizer) {
        inputRecognizers.append(r)
        pageScrollView?.addGestureRecognizer(r)
    }

    func removeInputRecognizer(_ r: UIGestureRecognizer) {
        inputRecognizers.removeAll { $0 === r }
        r.view?.removeGestureRecognizer(r)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        offsetObserver = nil
        zoomObserver = nil
        for r in inputRecognizers { r.view?.removeGestureRecognizer(r) }
        pageScrollView = nil
        guard window != nil else { return }
        var ancestor = superview
        while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
        pageScrollView = ancestor as? UIScrollView
        refreshInputRouting()
        InkLog.write("drawing_gesture_attached", ["host": pageScrollView.map { String(describing: type(of: $0)) } ?? "none",
                                                  "original_delegate": gate.original.map { String(describing: type(of: $0)) } ?? "nil"])
        // 页面平移时只移动可见画布，避免创建 3 倍大小的整页 Metal 渲染表面。
        offsetObserver = pageScrollView?.observe(\.bounds) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.setNeedsLayout() }
        }
        zoomObserver = pageScrollView?.observe(\.zoomScale) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.setNeedsLayout() }
        }
        disableCanvasPinch()
        GestureTrace.attach(canvas: canvas, page: pageScrollView)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let visible = canvasWindow()
        guard !visible.isEmpty else { return }
        let zoom = pageZoom
        // 此子树已抵消外层 transform，应按真实屏幕密度绘制，而不是文字的高密度。
        let screenScale = pageScrollView?.traitCollection.displayScale ?? window?.screen.scale ?? 2
        // 未设置过的 traitOverrides 不能读取（UIKit 会断言崩溃），用自己的记录比较。
        if appliedDisplayScale != screenScale {
            appliedDisplayScale = screenScale
            traitOverrides.displayScale = screenScale
        }
        canvas.pageSize = bounds.size
        let transform = CGAffineTransform(scaleX: 1 / zoom, y: 1 / zoom)
        if canvas.transform != transform { canvas.transform = transform }
        // 尺寸变化会重建 PencilKit 的渲染表面，只在窗口大小真正改变时设置；平移只改位置和偏移。
        let size = CGSize(width: visible.width * zoom, height: visible.height * zoom)
        if canvas.bounds.size != size { canvas.bounds.size = size }
        let center = CGPoint(x: visible.midX, y: visible.midY)
        if canvas.center != center { canvas.center = center }
        if canvas.zoomScale != zoom {
            canvas.setZoomScale(zoom, animated: false)
            disableCanvasPinch()
        }
        let contentSize = CGSize(width: bounds.width * zoom, height: bounds.height * zoom)
        if canvas.contentSize != contentSize { canvas.contentSize = contentSize }
        let offset = CGPoint(x: visible.minX * zoom, y: visible.minY * zoom)
        if canvas.contentOffset != offset { canvas.contentOffset = offset }
    }

    /// 画布窗口（页面坐标）：取一屏大小并夹在页面内，页顶/页底回弹时大小不变；
    /// 捏合中只在放不下时按 1.25 倍放大、不缩小，避免逐帧改变画布尺寸。
    private func canvasWindow() -> CGRect {
        guard let scroll = pageScrollView else { return bounds }
        let viewport = convert(scroll.bounds, from: scroll)
        let needed = CGSize(width: min(viewport.width, bounds.width), height: min(viewport.height, bounds.height))
        let zooming = scroll.isZooming || (scroll as? PageScrollView)?.isCustomZooming == true
        if !zooming {
            windowSize = needed
        } else if needed.width > windowSize.width + 0.5 || needed.height > windowSize.height + 0.5 {
            windowSize = CGSize(width: min(needed.width * 1.25, bounds.width),
                                height: min(needed.height * 1.25, bounds.height))
        }
        let size = CGSize(width: min(windowSize.width, bounds.width), height: min(windowSize.height, bounds.height))
        let x = min(max(viewport.midX - size.width / 2, bounds.minX), bounds.maxX - size.width)
        let y = min(max(viewport.midY - size.height / 2, bounds.minY), bounds.maxY - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

/// 记录画布与外层滚动视图上的手势识别器，以及它们的 began/ended/cancelled，排查两指手势被谁拿走。
@MainActor
enum GestureTrace {
    private final class Target: NSObject {
        let name: String
        init(name: String) { self.name = name }
        @objc func fire(_ g: UIGestureRecognizer) {
            let state: String
            switch g.state {
            case .began: state = "began"
            case .ended: state = "ended"
            case .cancelled: state = "cancelled"
            case .failed: state = "failed"
            default: return
            }
            InkLog.write("gesture", ["name": name, "state": state, "touches": g.numberOfTouches])
        }
    }
    private static var targets: [ObjectIdentifier: Target] = [:]

    static func attach(canvas: UIView, page: UIScrollView?) {
        var list: [[String: Any]] = []
        func walk(_ v: UIView, _ owner: String) {
            for g in v.gestureRecognizers ?? [] {
                let name = "\(owner).\(type(of: g))"
                // 书写与拖动的识别器每个采样点都会回调，不挂追踪，避免干扰书写输入。
                let traced = !(g is UIPanGestureRecognizer) && !String(describing: type(of: g)).contains("Drawing")
                list.append(["name": name, "enabled": g.isEnabled,
                             "types": g.allowedTouchTypes.map(\.intValue),
                             "cancels": g.cancelsTouchesInView])
                let id = ObjectIdentifier(g)
                if traced, targets[id] == nil {
                    let t = Target(name: name)
                    targets[id] = t
                    g.addTarget(t, action: #selector(Target.fire(_:)))
                }
            }
            for sub in v.subviews { walk(sub, owner == "page" ? "page" : "canvas/\(type(of: sub))") }
        }
        walk(canvas, "canvas")
        if let page { for g in page.gestureRecognizers ?? [] {
            let name = "page.\(type(of: g))"
            list.append(["name": name, "enabled": g.isEnabled, "types": g.allowedTouchTypes.map(\.intValue)])
            let id = ObjectIdentifier(g)
            if targets[id] == nil {
                let t = Target(name: name)
                targets[id] = t
                g.addTarget(t, action: #selector(Target.fire(_:)))
            }
        } }
        InkLog.write("gesture_list", ["recognizers": list])
    }
}

struct DraftCanvas: UIViewRepresentable {
    let key: String
    /// 草稿模式：开启时可写、只允许双指滚动；关闭时只显示已有笔迹
    let enabled: Bool
    /// 主观题页面：额外详细记录每一笔（见 SubjectiveInk.swift）
    var record: SubjectiveRecordContext? = nil
    /// 页面上登记的可点控件区域
    var tapTargets: DraftTapTargets? = nil
    /// false：笔迹只在内存里，不读写数据库（AI 改编页）
    var persist = true

    @Environment(\.modelContext) private var context
    @Environment(\.pageZoomScale) private var pageZoom

    func makeCoordinator() -> Coordinator {
        var shouldPersist = persist
        #if DEBUG && targetEnvironment(simulator)
        if UserDefaults.standard.bool(forKey: "debugLassoFixture") { shouldPersist = false }
        #endif
        return Coordinator(key: key, context: context, recorder: record.map { SubjectiveInkRecorder($0) }, persist: shouldPersist)
    }

    func makeUIView(context ctx: Context) -> DraftCanvasContainer {
        let container = DraftCanvasContainer()
        let canvas = container.canvas
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .pencilOnly
        canvas.isScrollEnabled = false
        canvas.bounces = false
        canvas.showsVerticalScrollIndicator = false
        canvas.showsHorizontalScrollIndicator = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.delegate = ctx.coordinator
        canvas.tapTargets = tapTargets
        ctx.coordinator.attach(canvas)
        return container
    }

    func updateUIView(_ container: DraftCanvasContainer, context ctx: Context) {
        container.pageZoom = pageZoom
        container.canvas.tapTargets = tapTargets
        ctx.coordinator.setEnabled(enabled)
    }

    static func dismantleUIView(_ container: DraftCanvasContainer, coordinator: Coordinator) {
        coordinator.detach()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate, PKToolPickerObserver {
        let key: String
        let context: ModelContext
        weak var canvas: PencilOnlyCanvas?
        private var enabled = false
        /// 套索编辑时系统会让选区视图成为 first responder；页面刷新不能抢回焦点。
        private var pickerActivated = false
        private var strokeCount = 0
        private var suppressChange = false
        private var deleted = false
        private var saveWork: DispatchWorkItem?
        private var lastStrokeEndUptime: TimeInterval?
        private var toolBegin: (uptime: TimeInterval, strokes: Int, tool: [String: Any])?
        private var observers: [NSObjectProtocol] = []
        private var loggedWidth: CGFloat = 0
        private var undoObserved = false
        private var holdRecognizer: PencilHoldRecognizer?
        private var penDown = false
        private var straightenThisStroke = false
        private var strokeBeforeHold = PKDrawing()
        private var holdStrokeCount = 0
        private var holdID = UUID()
        private var linePreview: CAShapeLayer?
        /// 停顿识别出的图形和这一笔采到的点（容器坐标），抬笔后换成标准图形
        private var heldShape: RecognizedShape?
        private var holdPoints: [CGPoint] = []
        private var inkPreview: UIImageView?
        /// 当前笔迹对应的各锚点位置；空表示这页没有锚点（讲解页等）或还没对齐过
        private var anchorTops: [String: CGFloat] = [:]
        private var savedAnchorTop: CGFloat?
        private var anchorWork: DispatchWorkItem?
        /// 画布创建时刻：刚打开页面的一小段时间里锚点还在随加载变化，合并处理；之后的移动立即跟随
        private var attachedAt = Date.distantPast
        /// 平移笔迹后 PencilKit 异步重绘的那几帧，用同步渲染的截图盖住画布
        private var shiftCover: UIImageView?
        private var shiftCoverWork: DispatchWorkItem?
        /// 判定为涂抹、等待执行的擦除；期间又落笔就取消（见 scribbleCommitDelay），记下的是取消时写的日志
        private var pendingErase: (work: DispatchWorkItem, cancelLog: [String: Any])?
        let recorder: SubjectiveInkRecorder?

        let persist: Bool

        init(key: String, context: ModelContext, recorder: SubjectiveInkRecorder?, persist: Bool) {
            self.key = key
            self.context = context
            self.recorder = recorder
            self.persist = persist
        }

        private var scribbleEnabled: Bool {
            UserDefaults.standard.object(forKey: "ink.scribbleErase") as? Bool ?? true
        }

        /// 判定为涂抹后等这么久再删：期间又落笔说明还在连续写字（连笔字的一笔），不删。
        /// 实测误删的连笔字下一笔多在抬笔后 0.1 秒内落下，真涂抹之后九成要过 0.39 秒以上
        private static let scribbleCommitDelay: TimeInterval = 0.25

        // MARK: 生命周期

        func attach(_ canvas: PencilOnlyCanvas) {
            self.canvas = canvas
            attachedAt = Date()
            LiveDraft.canvases[key] = .init(canvas: canvas)
            load()
            recorder?.open(canvas)
            #if DEBUG
            // 调试：-debugInkScript YES 在主观题页面用程序模拟「写两笔 → 移动一笔 → 删一笔」，检查详细记录
            if recorder != nil, UserDefaults.standard.bool(forKey: "debugInkScript") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.runDebugInkScript() }
            }
            // 调试：-debugScribbleErase YES 打开 1 秒后写一笔、再在上面涂抹，检查涂抹擦除
            if UserDefaults.standard.bool(forKey: "debugScribbleErase") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.runDebugScribbleErase() }
            }
            // 调试：-debugInkMark YES 在第 1、2 个书写区各画一道粗折线（红、蓝），便于录屏检查笔迹是否跟着书写区移动
            if UserDefaults.standard.bool(forKey: "debugInkMark") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak canvas] in
                    guard let self, let canvas, let top = DraftAnchors.latest[self.key]?[DraftAnchors.writing] else { return }
                    // 红线在第 1 个书写区，蓝线在第 2 个书写区（书写区高 520、间距 20）
                    func mark(_ y: CGFloat, _ color: UIColor) -> PKStroke {
                        // 中间值拆开写明类型：写在一个表达式里，CI 上较慢的机器会类型检查超时
                        let pts: [PKStrokePoint] = (0..<40).map { (i: Int) -> PKStrokePoint in
                            let x: CGFloat = 80 + CGFloat(i) * 12
                            let dy: CGFloat = i % 2 == 0 ? 0 : 40
                            return PKStrokePoint(location: CGPoint(x: x, y: y + dy),
                                                 timeOffset: Double(i) / 60, size: CGSize(width: 8, height: 8), opacity: 1,
                                                 force: 1, azimuth: 0, altitude: CGFloat.pi / 2)
                        }
                        return PKStroke(ink: PKInk(.pen, color: color),
                                        path: PKStrokePath(controlPoints: pts, creationDate: .now))
                    }
                    let marks = [mark(top + 60, .systemRed), mark(top + 600, .systemBlue)]
                    canvas.drawing = PKDrawing(strokes: canvas.drawing.strokes + marks)
                }
            }
            if UserDefaults.standard.bool(forKey: "debugStraightLineChecks") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.runDebugStraightLineChecks() }
            }
            if UserDefaults.standard.bool(forKey: "debugLassoChecks") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.runDebugLassoChecks() }
            }
            #endif
            let picker = DraftToolPicker.shared
            picker.addObserver(canvas)
            picker.addObserver(self)
            if let tool = picker.selectedToolItem.tool { canvas.tool = tool }
            attachHoldRecognizer(canvas)

            let nc = NotificationCenter.default
            observers.append(nc.addObserver(forName: .draftInkDeleted, object: nil, queue: .main) { [weak self] note in
                guard let self, (note.object as? String) == self.key else { return }
                MainActor.assumeIsolated { self.handleExternalDelete() }
            })
            observers.append(nc.addObserver(forName: .draftFlushRequested, object: nil, queue: nil) { [weak self] note in
                guard let self, (note.object as? String) == self.key else { return }
                MainActor.assumeIsolated { self.flushSave(reason: "flush_request") }
            })
            observers.append(nc.addObserver(forName: .draftAnchorMoved, object: nil, queue: .main) { [weak self] note in
                guard let self, (note.object as? String) == self.key else { return }
                MainActor.assumeIsolated { self.scheduleFollowAnchor() }
            })
            observers.append(nc.addObserver(forName: .draftTransientCleared, object: nil, queue: .main) { [weak self] note in
                guard let self, (note.object as? String) == self.key, let top = note.userInfo?["top"] as? CGFloat else { return }
                MainActor.assumeIsolated { self.clearTransient(below: top) }
            })
            observers.append(nc.addObserver(forName: .draftAreaDeleteRequested, object: nil, queue: .main) { [weak self] note in
                guard let self, (note.object as? String) == self.key, let rect = note.userInfo?["rect"] as? CGRect,
                      let shift = note.userInfo?["shift"] as? CGFloat else { return }
                MainActor.assumeIsolated { self.deleteArea(rect, shift: shift) }
            })
            scheduleFollowAnchor()
            observeUndo(canvas)
            // 进入窗口后激活工具栏；滚动和缩放由外层 ZoomablePageScrollView 统一管理。
            canvas.onMoveToWindow = { [weak self, weak canvas] in
                guard let self, let canvas else { return }
                // 创建时画布还不在窗口里，undoManager 可能为空，这里补上撤销/重做的监听
                self.observeUndo(canvas)
                // updateUIView 可能早于进入窗口，此时 becomeFirstResponder 不会成功。
                self.setEnabled(self.enabled)
                InkLog.write("canvas_ready", ["page": self.key, "enabled": self.enabled,
                                               "size": canvas.bounds.size,
                                               "first_responder": canvas.isFirstResponder,
                                               "drawing_enabled": canvas.isDrawingEnabled])
            }
        }

        #if DEBUG
        private func runDebugLassoChecks() {
            guard let canvas, let container = canvas.superview as? DraftCanvasContainer,
                  canvas.window != nil else { return }
            let tool = canvas.tool
            let point = container.convert(CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY), from: canvas)
            canvas.tool = PKInkingTool(.pen, color: .black, width: 2)
            container.setInputEnabled(true)
            precondition(container.hitTest(point, with: nil) == nil)
            let pageHost = canvas.drawingGestureRecognizer.view
            canvas.tool = PKLassoTool()
            container.refreshInputRouting()
            precondition(canvas.receivesSelectionTouches)
            precondition(canvas.drawingGestureRecognizer.view !== pageHost)
            precondition(!canvas.drawingGestureRecognizer.isEnabled)
            precondition(container.hitTest(point, with: nil)?.isDescendant(of: canvas) == true)
            // SwiftUI 更新草稿开关时不得重新启用套索模式下的墨水书写手势。
            container.setInputEnabled(true)
            precondition(!canvas.drawingGestureRecognizer.isEnabled)
            let targets = canvas.tapTargets
            let testTargets = DraftTapTargets()
            testTargets.rects[UUID()] = CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20)
            canvas.tapTargets = testTargets
            precondition(container.hitTest(point, with: nil) == nil)
            canvas.tapTargets = targets
            container.setInputEnabled(false)
            precondition(!canvas.receivesSelectionTouches && container.hitTest(point, with: nil) == nil)
            canvas.tool = tool
            container.setInputEnabled(enabled)
            InkLog.write("debug_lasso_checks_pass", ["page": key,
                "checks": "native hit testing,original gesture host,no ink gesture,update,controls,disabled,restore"])

            #if targetEnvironment(simulator)
            // 仅模拟器的手指输入夹具：用鼠标验证原生圈选、拖动和复制菜单。
            if UserDefaults.standard.bool(forKey: "debugLassoFixture") {
                if !UserDefaults.standard.bool(forKey: "debugLassoPencilOnly") {
                    canvas.drawingPolicy = .anyInput
                }
                let rect = canvas.convert(CGRect(x: 160, y: 400, width: 210, height: 70), from: nil)
                let points = (0..<30).map { i in
                    PKStrokePoint(location: CGPoint(x: rect.minX + CGFloat(i) * 4,
                                                   y: rect.midY + sin(CGFloat(i) / 3) * 15),
                                  timeOffset: Double(i) / 60, size: CGSize(width: 4, height: 4), opacity: 1,
                                  force: 1, azimuth: 0, altitude: .pi / 2)
                }
                canvas.drawing = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .systemBlue),
                    path: PKStrokePath(controlPoints: points, creationDate: .now))])
                DraftToolPicker.shared.selectedToolItem = PKToolPickerLassoItem()
                syncSelectedTool(DraftToolPicker.shared)
            }
            #endif
        }

        private func runDebugStraightLineChecks() {
            guard let canvas, let undo = canvas.undoManager else { return }
            let baseline = canvas.drawing
            var points: [PKStrokePoint] = []
            for i in 0..<20 {
                let t = CGFloat(i) / 19
                let point = PKStrokePoint(location: CGPoint(x: 100 + 190 * t, y: 900 + 50 * t + sin(t * .pi) * 40),
                                          timeOffset: Double(i) / 60, size: CGSize(width: 3, height: 3),
                                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
                points.append(point)
            }
            let stroke = PKStroke(ink: PKInk(.pen, color: .blue), path: PKStrokePath(controlPoints: points, creationDate: .now))
            strokeBeforeHold = baseline
            holdStrokeCount = baseline.strokes.count
            penDown = true
            previewLine(from: CGPoint(x: 100, y: 900), to: CGPoint(x: 250, y: 920))
            precondition(canvas.alpha == 0 && linePreview != nil && inkPreview != nil)
            previewLine(from: CGPoint(x: 100, y: 900), to: CGPoint(x: 290, y: 950))
            suppressChange = true
            canvas.drawing = PKDrawing(strokes: baseline.strokes + [stroke])
            strokeCount = canvas.drawing.strokes.count
            suppressChange = false
            penDown = false
            commitHeldLineIfReady()
            precondition(canvas.alpha == 1 && linePreview == nil)
            let straight = canvas.drawing.strokes.last!
            for point in straight.path {
                precondition(abs((point.location.x - 100) * 50 - (point.location.y - 900) * 190) < 0.05)
            }
            let reloaded = try! PKDrawing(data: canvas.drawing.dataRepresentation())
            precondition(reloaded.strokes.count == baseline.strokes.count + 1)
            undo.undo()
            precondition(canvas.drawing.strokes.count == baseline.strokes.count)
            undo.redo()
            precondition(canvas.drawing.strokes.count == baseline.strokes.count + 1)
            undo.undo()
            precondition(canvas.drawing.strokes.count == baseline.strokes.count && canvas.drawing.bounds == baseline.bounds)
            for (restored, original) in zip(canvas.drawing.strokes, baseline.strokes) {
                precondition(restored.transform == original.transform && restored.path.count == original.path.count)
                for (a, b) in zip(restored.path, original.path) { precondition(a.location == b.location) }
            }
            InkLog.write("debug_straight_line_checks_pass", ["page": key, "checks": "preview,endpoint,commit,serialization,undo,redo,restore"])
        }

        private func runDebugInkScript() {
            guard let canvas else { return }
            func stroke(_ x: CGFloat, _ y: CGFloat) -> PKStroke {
                let pts = (0..<20).map { i in
                    PKStrokePoint(location: CGPoint(x: x + CGFloat(i) * 5, y: y + CGFloat(i % 3)), timeOffset: Double(i) / 60,
                                  size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
                }
                return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: .now))
            }
            let a = stroke(100, 900), b = stroke(100, 960)
            canvas.drawing = PKDrawing(strokes: canvas.drawing.strokes + [a, b])
            var moved = b
            moved.transform = CGAffineTransform(translationX: 40, y: 10)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                var strokes = canvas.drawing.strokes
                strokes[strokes.count - 1] = moved
                canvas.drawing = PKDrawing(strokes: strokes)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    canvas.drawing = PKDrawing(strokes: Array(canvas.drawing.strokes.dropLast(2)) + [moved])
                    InkLog.write("debug_ink_script_done", ["page": self.key])
                }
            }
        }

        private func runDebugScribbleErase() {
            guard let canvas else { return }
            func stroke(_ pts: [CGPoint], duration: Double) -> PKStroke {
                let points = pts.enumerated().map { i, p in
                    PKStrokePoint(location: p, timeOffset: duration * Double(i) / Double(pts.count - 1),
                                  size: CGSize(width: 2.8, height: 2.8), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
                }
                return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: .now))
            }
            canvas.tool = PKInkingTool(.pen, color: .black, width: 2.8)
            let x = canvas.contentOffset.x / canvas.zoomScale + 300, y = canvas.contentOffset.y / canvas.zoomScale + 300
            // 一笔竖折，当作写好的字
            let written = stroke((0...30).map { CGPoint(x: x + 15 + CGFloat($0 % 10), y: y + CGFloat($0) * 1.5) }, duration: 0.3)
            canvas.drawing = PKDrawing(strokes: canvas.drawing.strokes + [written])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                // 在上面左右来回涂 8 次
                let pts = (0...160).map { i -> CGPoint in
                    let t = Double(i) / 160
                    return CGPoint(x: x + 20 + 22 * CGFloat(sin(t * .pi * 8)), y: y + 8 + CGFloat(t) * 30)
                }
                canvas.drawing = PKDrawing(strokes: canvas.drawing.strokes + [stroke(pts, duration: 0.7)])
            }
        }
        #endif

        private func observeUndo(_ canvas: PencilOnlyCanvas) {
            guard !undoObserved, let um = canvas.undoManager else { return }
            undoObserved = true
            let nc = NotificationCenter.default
            for (name, event) in [(NSNotification.Name.NSUndoManagerDidUndoChange, "input_undo"),
                                  (.NSUndoManagerDidRedoChange, "input_redo")] {
                observers.append(nc.addObserver(forName: name, object: um, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.handleUndoRedo(event) }
                })
            }
        }

        func detach() {
            if LiveDraft.canvases[key]?.canvas === canvas { LiveDraft.canvases[key] = nil }
            anchorWork?.cancel()
            pendingErase?.work.cancel()
            pendingErase = nil
            removeShiftCover()
            if let holdRecognizer {
                (canvas?.superview as? DraftCanvasContainer)?.removeInputRecognizer(holdRecognizer)
                holdRecognizer.isEnabled = false
            }
            clearLinePreview()
            if let canvas { recorder?.close(canvas) }
            flushSave(reason: "page_leave")
            if let canvas {
                DraftToolPicker.shared.removeObserver(canvas)
                DraftToolPicker.shared.setVisible(false, forFirstResponder: canvas)
            }
            DraftToolPicker.shared.removeObserver(self)
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            InkLog.write("canvas_close", ["page": key, "strokes": strokeCount])
        }

        func setEnabled(_ on: Bool) {
            guard let canvas else { return }
            let changed = on != enabled
            enabled = on
            (canvas.superview as? DraftCanvasContainer)?.setInputEnabled(on)
            holdRecognizer?.isEnabled = on
            if on, !pickerActivated, canvas.window != nil {
                canvas.becomeFirstResponder()
                pickerActivated = canvas.isFirstResponder
                if pickerActivated { DraftToolPicker.shared.setVisible(true, forFirstResponder: canvas) }
            } else if !on, changed || pickerActivated {
                DraftToolPicker.shared.setVisible(false, forFirstResponder: canvas)
                if canvas.isFirstResponder { canvas.resignFirstResponder() }
                pickerActivated = false
            }
            if changed { InkLog.write("draft_mode", ["page": key, "enabled": on]) }
        }

        // MARK: 读写

        private func load() {
            guard let canvas else { return }
            let key = self.key
            let saved = persist
                ? try? context.fetch(FetchDescriptor<DraftInk>(predicate: #Predicate { $0.key == key })).first : nil
            var drawing = PKDrawing()
            if let saved, !saved.data.isEmpty {
                do { drawing = try PKDrawing(data: saved.data) }
                catch { InkLog.write("canvas_load_error", ["page": key, "error": String(describing: error)]) }
            }
            suppressChange = true
            canvas.drawing = drawing
            suppressChange = false
            canvas.undoManager?.removeAllActions()
            strokeCount = drawing.strokes.count
            savedAnchorTop = saved?.areaTop.map { CGFloat($0) }
            InkLog.write("canvas_load", [
                "page": key, "strokes": strokeCount, "bytes": saved?.data.count ?? 0,
                "saved_width": saved?.contentWidth ?? 0, "saved_at": saved?.updatedAt.timeIntervalSince1970 ?? 0,
                "bounds": drawing.strokes.isEmpty ? CGRect.zero : drawing.bounds,
            ])
        }

        private func scheduleSave() {
            saveWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                // 保存要序列化整页笔迹并写 SwiftData，都在主线程；正在书写时推迟，免得笔迹卡顿。
                // 以防 PencilKit 漏发结束回调，最多推迟 30 秒。
                if let begin = self.toolBegin, ProcessInfo.processInfo.systemUptime - begin.uptime < 30 {
                    self.scheduleSave()
                } else {
                    self.flushSave(reason: "debounce")
                }
            }
            saveWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
        }

        private func flushSave(reason: String) {
            saveWork?.cancel()
            saveWork = nil
            guard persist, !deleted, let canvas else { return }
            let t0 = CFAbsoluteTimeGetCurrent()
            // AI 改编区（临时区域）的笔迹不保存
            var drawing = canvas.drawing
            if let limit = DraftAnchors.transientTop[key] {
                drawing = PKDrawing(strokes: drawing.strokes.filter { $0.renderBounds.midY < limit - 12 })
            }
            let anchorTop = anchorTops[DraftAnchors.writing]
            let key = self.key
            let existing = try? context.fetch(FetchDescriptor<DraftInk>(predicate: #Predicate { $0.key == key })).first
            if drawing.strokes.isEmpty {
                // 有存档（删过书写区）的记录保留，只清空笔迹
                guard let existing, existing.archivedData == nil else {
                    if let existing, !existing.data.isEmpty {
                        existing.data = Data()
                        existing.strokeCount = 0
                        existing.updatedAt = .now
                        try? context.save()
                    }
                    return
                }
                context.delete(existing)
                try? context.save()
                InkLog.write("canvas_save", ["page": key, "reason": reason, "strokes": 0, "bytes": 0, "action": "delete_empty"])
                return
            }
            let data = drawing.dataRepresentation()
            if let existing {
                guard existing.data != data || existing.areaTop != anchorTop.map({ Double($0) }) else { return }
                existing.data = data
                existing.strokeCount = drawing.strokes.count
                existing.contentWidth = Double(canvas.pageSize.width)
                existing.areaTop = anchorTop.map { Double($0) }
                existing.updatedAt = .now
            } else {
                let ink = DraftInk(key: key, data: data, strokeCount: drawing.strokes.count,
                                   contentWidth: Double(canvas.pageSize.width))
                ink.areaTop = anchorTop.map { Double($0) }
                context.insert(ink)
            }
            try? context.save()
            InkLog.write("canvas_save", ["page": key, "reason": reason, "strokes": drawing.strokes.count,
                                         "bytes": data.count, "width": canvas.pageSize.width,
                                         "save_ms": (CFAbsoluteTimeGetCurrent() - t0) * 1000])
        }

        /// 页面刚出现时进度、图片陆续加载，锚点会先到一个临时位置再回来；稍等一下，只按最终位置平移一次。
        /// 之后（展开答案、解析）书写区移动时立即跟随，和书写区在同一帧到位。
        private func scheduleFollowAnchor() {
            anchorWork?.cancel()
            if !anchorTops.isEmpty, Date().timeIntervalSince(attachedAt) > 1 {
                followAnchor(live: true)
                return
            }
            let work = DispatchWorkItem { [weak self] in self?.followAnchor() }
            anchorWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }

        /// 锚点移动后，每笔跟着它所在的那一段（上方最近的锚点）平移同样的距离
        private func followAnchor(live: Bool = false) {
            guard let canvas, let current = DraftAnchors.latest[key], !current.isEmpty else { return }
            // 第一次对齐：主锚点以保存时的位置为准（旧数据没有记录，就认为当前位置是对的）；其他锚点新出现时不移动
            var old: [String: CGFloat] = [:]
            for (name, top) in current {
                old[name] = anchorTops[name] ?? (name == DraftAnchors.writing ? savedAnchorTop ?? top : top)
            }
            anchorTops = current
            let deltas = current.reduce(into: [String: CGFloat]()) { $0[$1.key] = $1.value - (old[$1.key] ?? $1.value) }
            guard deltas.values.contains(where: { abs($0) > 0.5 }) else { return }
            // 锚点上方留一点余量：贴着书写区顶边写的字也算在书写区里
            let ordered = old.sorted { $0.value < $1.value }
            var moved = 0
            let strokes = canvas.drawing.strokes.map { s -> PKStroke in
                let y = s.renderBounds.midY
                guard let owner = ordered.last(where: { y >= $0.value - 12 }), let dy = deltas[owner.key],
                      abs(dy) > 0.5 else { return s }
                moved += 1
                var t = s
                t.transform = s.transform.concatenating(CGAffineTransform(translationX: 0, y: dy))
                return t
            }
            InkLog.write("ink_follow_anchor", ["page": key, "from": old, "to": current, "moved": moved])
            guard moved > 0 else {
                scheduleSave()
                return
            }
            replaceDrawing(PKDrawing(strokes: strokes), live: live, reason: "area_moved")
        }

        /// 设置平移、删除后的笔迹：盖住异步重绘，清空撤销记录（撤销会把笔迹放回原处），写记录并保存
        private func replaceDrawing(_ drawing: PKDrawing, live: Bool, reason: String) {
            guard let canvas else { return }
            if live { coverWhileRendering(drawing) }
            suppressChange = true
            canvas.drawing = drawing
            suppressChange = false
            strokeCount = drawing.strokes.count
            canvas.undoManager?.removeAllActions()
            recorder?.sync(canvas, reason: reason)
            scheduleSave()
        }

        /// AI 改编区关闭：删掉区域里的笔迹（这些笔迹本来就不保存）
        private func clearTransient(below top: CGFloat) {
            guard let canvas else { return }
            let keep = canvas.drawing.strokes.filter { $0.renderBounds.midY < top - 12 }
            guard keep.count != canvas.drawing.strokes.count else { return }
            InkLog.write("ink_transient_cleared", ["page": key, "top": top,
                                                   "removed": canvas.drawing.strokes.count - keep.count])
            replaceDrawing(PKDrawing(strokes: keep), live: true, reason: "ai_variant_closed")
        }

        /// 删除书写区：区域里的笔迹移进存档，下方的笔迹和锚点上移 shift
        private func deleteArea(_ rect: CGRect, shift: CGFloat) {
            guard let canvas else { return }
            var keep: [PKStroke] = [], removed: [PKStroke] = []
            for s in canvas.drawing.strokes {
                let y = s.renderBounds.midY
                if y >= rect.minY - 12 && y < rect.maxY + 12 {
                    removed.append(s)
                } else if y >= rect.maxY + 12 {
                    var t = s
                    t.transform = s.transform.concatenating(CGAffineTransform(translationX: 0, y: -shift))
                    keep.append(t)
                } else {
                    keep.append(s)
                }
            }
            // 下方的锚点也会随布局上移 shift；先记成移动后的位置，免得报告时再平移一次
            for (name, top) in anchorTops where top > rect.maxY { anchorTops[name] = top - shift }
            if let latest = DraftAnchors.latest[key] {
                for (name, top) in latest where top > rect.maxY { DraftAnchors.latest[key]?[name] = top - shift }
            }
            if let t = DraftAnchors.transientTop[key], t > rect.maxY { DraftAnchors.transientTop[key] = t - shift }
            archive(removed)
            InkLog.write("ink_area_deleted", ["page": key, "rect": rect, "shift": shift, "removed": removed.count])
            replaceDrawing(PKDrawing(strokes: keep), live: true, reason: "area_deleted")
            flushSave(reason: "area_deleted")
        }

        /// 删除书写区时移走的笔迹存进 DraftInk.archivedData（AI 改编区的笔迹不存）
        private func archive(_ strokes: [PKStroke]) {
            let limit = DraftAnchors.transientTop[key]
            let kept = strokes.filter { s in limit.map { s.renderBounds.midY < $0 - 12 } ?? true }
            guard persist, !kept.isEmpty else { return }
            let key = self.key
            let existing = try? context.fetch(FetchDescriptor<DraftInk>(predicate: #Predicate { $0.key == key })).first
            let old = (existing?.archivedData).flatMap { try? PKDrawing(data: $0) } ?? PKDrawing()
            let data = PKDrawing(strokes: old.strokes + kept).dataRepresentation()
            if let existing {
                existing.archivedData = data
            } else if let canvas {
                let ink = DraftInk(key: key, data: canvas.drawing.dataRepresentation(),
                                   strokeCount: canvas.drawing.strokes.count, contentWidth: Double(canvas.pageSize.width))
                ink.archivedData = data
                context.insert(ink)
            }
            try? context.save()
        }

        /// PencilKit 设置新笔迹后要过几帧才画出来，这期间旧位置的笔迹还在。
        /// 把新笔迹在可见窗口内同步渲染成图盖在上面，画布渲染完成（或 0.5 秒后）再撤掉。
        private func coverWhileRendering(_ drawing: PKDrawing) {
            guard let canvas, let container = canvas.superview as? DraftCanvasContainer else { return }
            let visible = canvas.frame
            guard !visible.isEmpty else { return }
            let scale = (container.window?.screen.scale ?? 2) * max(container.pageZoom, 1)
            let image = drawing.image(from: visible, scale: scale)
            let cover = shiftCover ?? UIImageView()
            cover.frame = visible
            cover.image = image
            cover.isUserInteractionEnabled = false
            if cover.superview == nil { container.addSubview(cover) }
            shiftCover = cover
            canvas.alpha = 0
            shiftCoverWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.removeShiftCover() }
            shiftCoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }

        private func removeShiftCover() {
            shiftCoverWork?.cancel()
            shiftCoverWork = nil
            canvas?.alpha = 1
            shiftCover?.removeFromSuperview()
            shiftCover = nil
        }

        private func handleExternalDelete() {
            guard let canvas else { return }
            deleted = true
            saveWork?.cancel()
            suppressChange = true
            canvas.drawing = PKDrawing()
            suppressChange = false
            canvas.undoManager?.removeAllActions()
            strokeCount = 0
            recorder?.sync(canvas, reason: "cleared")
            InkLog.write("canvas_cleared", ["page": key, "reason": "draft_deleted"])
            deleted = false
        }

        // MARK: PKCanvasViewDelegate

        func canvasViewDidFinishRendering(_ canvasView: PKCanvasView) {
            guard let canvas else { return }
            if shiftCover != nil {
                // 再等一帧，确保新渲染的内容已经上屏
                DispatchQueue.main.async { [weak self] in self?.removeShiftCover() }
            }
            InkLog.write("canvas_rendered", ["page": key, "zoom": canvas.zoomScale,
                                            "size": canvas.pageSize, "viewport": canvas.bounds.size,
                                            "offset": canvas.contentOffset, "strokes": canvas.drawing.strokes.count])
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !suppressChange, let canvas else { return }
            // 先记下这次变化（新的一笔），涂抹擦除若随后删掉笔画会另记一条
            recorder?.sync(canvas)
            if canvas.pageSize.width != loggedWidth {
                loggedWidth = canvas.pageSize.width
                InkLog.write("canvas_layout", ["page": key, "size": canvas.pageSize,
                                                "viewport": canvas.bounds.size, "zoom": canvas.zoomScale])
            }
            let strokes = canvas.drawing.strokes
            let before = strokeCount
            strokeCount = strokes.count
            if strokes.count == before + 1, canvas.tool is PKInkingTool, let last = strokes.last {
                handleNewStroke(last, index: strokes.count - 1, all: strokes)
            } else if strokes.count != before || !(canvas.tool is PKInkingTool) {
                InkLog.write("drawing_changed", [
                    "page": key, "strokes_before": before, "strokes_after": strokes.count,
                    "tool": Self.describe(canvas.tool),
                ])
            }
            scheduleSave()
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            guard let canvas else { return }
            // 原生套索选区有自己的 first responder；抢回画布会取消拖动，笔迹弹回原位。
            if enabled, !(canvas.tool is PKLassoTool), !canvas.isFirstResponder { canvas.becomeFirstResponder() }
            let now = ProcessInfo.processInfo.systemUptime
            // 涂抹还没执行就又落笔：是连续写字中的一笔，保留不删
            if let pending = pendingErase {
                pending.work.cancel()
                pendingErase = nil
                var log = pending.cancelLog
                if let last = lastStrokeEndUptime { log["since_pen_up_ms"] = (now - last) * 1000 }
                InkLog.write("input_scribble_erase_reject", log)
            }
            toolBegin = (now, canvas.drawing.strokes.count, Self.describe(canvas.tool))
            recorder?.event("tool_begin", SimplePayload(tool: SubjectiveInkRecorder.toolName(canvas.tool)))
            if !(canvas.tool is PKInkingTool) {
                InkLog.write("input_tool_start", ["page": key, "tool": Self.describe(canvas.tool),
                                                  "strokes": canvas.drawing.strokes.count])
            }
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            guard let canvas, let begin = toolBegin else { return }
            toolBegin = nil
            recorder?.event("tool_end", SimplePayload(tool: SubjectiveInkRecorder.toolName(canvas.tool)))
            // 画笔的每一笔由 input_stroke_end 记录；这里记橡皮擦、套索等其他工具的一次使用
            guard !(canvas.tool is PKInkingTool) else { return }
            InkLog.write("input_tool_end", [
                "page": key, "tool": begin.tool,
                "duration_ms": (ProcessInfo.processInfo.systemUptime - begin.uptime) * 1000,
                "strokes_before": begin.strokes, "strokes_after": canvas.drawing.strokes.count,
            ])
        }

        // MARK: PKToolPickerObserver

        func toolPickerSelectedToolDidChange(_ toolPicker: PKToolPicker) {
            syncSelectedTool(toolPicker)
        }

        func toolPickerSelectedToolItemDidChange(_ toolPicker: PKToolPicker) {
            syncSelectedTool(toolPicker)
        }

        private func syncSelectedTool(_ picker: PKToolPicker) {
            guard let canvas, let tool = picker.selectedToolItem.tool else { return }
            canvas.tool = tool
            (canvas.superview as? DraftCanvasContainer)?.setInputEnabled(enabled)
            InkLog.write("tool_change", ["page": key, "tool": Self.describe(tool),
                                         "canvas_hit_testing": canvas.receivesSelectionTouches,
                                         "drawing_gesture_enabled": canvas.drawingGestureRecognizer.isEnabled])
            recorder?.event("tool_change", SimplePayload(tool: SubjectiveInkRecorder.toolName(tool)))
        }

        func toolPickerVisibilityDidChange(_ toolPicker: PKToolPicker) {
            InkLog.write("tool_picker_visibility", ["page": key, "visible": toolPicker.isVisible])
        }

        private func handleUndoRedo(_ event: String) {
            guard let canvas else { return }
            let before = strokeCount
            strokeCount = canvas.drawing.strokes.count
            recorder?.sync(canvas, reason: event == "input_undo" ? "undo" : "redo")
            InkLog.write(event, ["page": key, "strokes_before": before, "strokes_after": strokeCount])
            scheduleSave()
        }

        // MARK: 每一笔

        private func attachHoldRecognizer(_ canvas: PencilOnlyCanvas) {
            guard let container = canvas.superview as? DraftCanvasContainer else { return }
            let recognizer = PencilHoldRecognizer()
            recognizer.space = container
            recognizer.canBegin = { [weak self] in self?.enabled == true && self?.canvas?.tool is PKInkingTool }
            recognizer.onBegin = { [weak self] in
                guard let self, let canvas = self.canvas else { return }
                self.clearLinePreview()
                self.holdID = UUID()
                self.penDown = true
                self.straightenThisStroke = false
                self.heldShape = nil
                self.holdPoints = []
                self.strokeBeforeHold = canvas.drawing
                self.holdStrokeCount = canvas.drawing.strokes.count
            }
            recognizer.onShape = { [weak self] shape in self?.previewShape(shape) }
            recognizer.onFinish = { [weak self] cancelled, points in
                guard let self else { return }
                self.penDown = false
                self.holdPoints = points
                if cancelled {
                    self.straightenThisStroke = false
                    self.heldShape = nil
                    self.clearLinePreview()
                } else {
                    // PencilKit 的最终 drawing 回调和 Pencil 抬笔回调的先后并不固定。
                    DispatchQueue.main.async { [weak self] in self?.commitHeldLineIfReady() }
                    let id = self.holdID
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                        guard let self, self.holdID == id, !self.penDown else { return }
                        self.straightenThisStroke = false
                        self.clearLinePreview()
                    }
                }
            }
            holdRecognizer = recognizer
            container.addInputRecognizer(recognizer)
        }

        private func previewLine(from start: CGPoint, to end: CGPoint) {
            previewShape(.line(start, end))
        }

        private func previewShape(_ shape: RecognizedShape) {
            guard let canvas, let container = canvas.superview as? DraftCanvasContainer,
                  let tool = canvas.tool as? PKInkingTool else { return }
            heldShape = shape
            if !straightenThisStroke {
                straightenThisStroke = true
                // 只显示本笔之前的墨迹和直线预览，避免自由笔迹仍留在下面。
                let visible = canvas.frame.intersection(container.bounds)
                let imageView = UIImageView(frame: visible)
                imageView.image = strokeBeforeHold.image(from: visible,
                    scale: (container.window?.screen.scale ?? 2) * container.pageZoom)
                container.addSubview(imageView)
                inkPreview = imageView
                let layer = CAShapeLayer()
                layer.frame = container.bounds
                layer.strokeColor = tool.color.cgColor
                layer.fillColor = nil
                layer.lineWidth = tool.width
                layer.lineCap = .round
                container.layer.addSublayer(layer)
                linePreview = layer
                canvas.alpha = 0
                InkLog.write("input_stroke_straighten_hold", ["page": key, "shape": shape.name])
            }
            let path = UIBezierPath()
            let points = shape.points(spacing: 2)
            if let first = points.first { path.move(to: first) }
            for p in points.dropFirst() { path.addLine(to: p) }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            linePreview?.path = path.cgPath
            CATransaction.commit()
        }

        private func clearLinePreview() {
            canvas?.alpha = 1
            linePreview?.removeFromSuperlayer()
            linePreview = nil
            inkPreview?.removeFromSuperview()
            inkPreview = nil
        }

        private func commitHeldLineIfReady() {
            guard !penDown, straightenThisStroke, let canvas else { return }
            let all = canvas.drawing.strokes
            guard all.count == holdStrokeCount + 1, let stroke = all.last else { return }
            straightenThisStroke = false
            let before = PKDrawing(strokes: Array(all.dropLast()))
            let after = PKDrawing(strokes: Array(all.dropLast()) + [shapedStroke(stroke)])
            suppressChange = true
            if let undo = canvas.undoManager, undo.canUndo { undo.undo() }
            if canvas.drawing.strokes.count != before.strokes.count { canvas.drawing = before }
            setDrawing(after, undoTo: before, action: "straighten_stroke")
            suppressChange = false
            recorder?.sync(canvas, reason: "straighten_stroke")
            clearLinePreview()
            InkLog.write("input_stroke_straighten_commit", ["page": key, "stroke_index": all.count - 1,
                                                             "shape": heldShape?.name ?? "line"])
            heldShape = nil
            scheduleSave()
        }

        /// 把识别出的图形换算到笔画自身的坐标：直线用笔画的起点和终点；其他图形按这一笔采到的点和笔画的点的包围盒对齐
        private func shapedStroke(_ stroke: PKStroke) -> PKStroke {
            let own = Array(stroke.path).map(\.location)
            guard let first = own.first, let last = own.last else { return stroke }
            switch heldShape {
            case nil, .line?:
                return stroke.reshaped(to: RecognizedShape.line(first, ShapeRecognizer.snapLine(first, last)).points(spacing: 2))
            case let shape?:
                func box(_ pts: [CGPoint]) -> CGRect {
                    let xs = pts.map(\.x), ys = pts.map(\.y)
                    return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
                }
                guard holdPoints.count > 1 else { return stroke.straightened() }
                let from = box(holdPoints), to = box(own)
                let scale = (to.width + to.height) / max(from.width + from.height, 0.001)
                let mapped = shape.points(spacing: 2 / max(scale, 0.001)).map {
                    CGPoint(x: to.midX + ($0.x - from.midX) * scale, y: to.midY + ($0.y - from.midY) * scale)
                }
                return stroke.reshaped(to: mapped)
            }
        }

        private func handleNewStroke(_ stroke: PKStroke, index: Int, all: [PKStroke]) {
            if straightenThisStroke, all.count == holdStrokeCount + 1 {
                commitHeldLineIfReady()
                return // 拉直的笔画不参与涂抹擦除。
            }
            let now = ProcessInfo.processInfo.systemUptime
            var fields = Self.strokeStats(stroke)
            fields["page"] = key
            fields["stroke_index"] = index
            fields["strokes_total"] = all.count
            fields["canvas_size"] = canvas?.pageSize ?? .zero
            if let last = lastStrokeEndUptime { fields["since_previous_stroke_ms"] = (now - last) * 1000 }
            lastStrokeEndUptime = now

            let inkType = (canvas?.tool as? PKInkingTool)?.inkType
            guard scribbleEnabled, inkType != .marker else {
                fields["scribble"] = scribbleEnabled ? "skipped_marker" : "disabled"
                InkLog.write("input_stroke_end", fields)
                return
            }

            // 按 Saber 的流程：逐点喂给识别器（书写中只算几何），抬笔后与旧墨迹求交做最终判定
            let t0 = CFAbsoluteTimeGetCurrent()
            let width = Self.strokeWidth(stroke)
            let recognizer = ScribbleEraseRecognizer(penSize: width)
            let samples = stroke.path.interpolatedPoints(by: .time(1.0 / 240)).map {
                ($0.location.applying(stroke.transform), $0.timeOffset)
            }
            var maxReversalLevel = 0
            var firstCandidateAtPoint: Int?
            for (i, s) in samples.enumerated() {
                if i == 0 { recognizer.start(s.0, time: s.1); continue }
                let e = recognizer.update(s.0, time: s.1)
                if e.isPlausibleCandidate {
                    if firstCandidateAtPoint == nil { firstCandidateAtPoint = i }
                    maxReversalLevel = max(maxReversalLevel, max(e.features.sharpReversals, e.features.axisReversals))
                }
            }
            let targets = all.indices.dropLast().map { Self.target(for: all[$0], id: $0) }
            let evaluation = recognizer.evaluate(targets, forceInkOverlap: true)
            let evalMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000

            var scribble = evaluation.logFields
            scribble["eval_ms"] = evalMs
            scribble["sample_rate_hz"] = 240
            scribble["in_progress_candidate_at_sample"] = firstCandidateAtPoint ?? -1
            scribble["in_progress_max_reversal_level"] = maxReversalLevel
            fields["scribble"] = scribble
            // 像涂抹的笔画记下采样点（页面坐标，保留 1 位小数），以后可离线回放识别器调参
            if evaluation.isPlausibleCandidate || evaluation.features.density >= 2.5 && evaluation.features.pathLength >= 60 {
                fields["sampled_xy"] = recognizer.sampledPoints.flatMap { [($0.x * 10).rounded() / 10, ($0.y * 10).rounded() / 10] }
            }
            InkLog.write("input_stroke_end", fields)

            if evaluation.shouldCommit {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, let canvas = self.canvas else { return }
                    self.pendingErase = nil
                    // 等待期间画布变了（撤销、换页等）就不删
                    let now = canvas.drawing.strokes
                    guard now.count == all.count, now.last?.path.creationDate == stroke.path.creationDate else { return }
                    self.commitScribbleErase(recognizer: recognizer, evaluation: evaluation, targets: targets,
                                             strokeIndex: index, all: all)
                }
                var cancelLog = recognizer.diagnosticThresholds.merging(evaluation.logFields) { a, _ in a }
                cancelLog["page"] = key
                cancelLog["decision"] = "continuedWriting"
                cancelLog["decision_phase"] = "next_pen_down"
                cancelLog["pen_size"] = width
                cancelLog["stroke_count_at_start"] = index
                pendingErase?.work.cancel()
                pendingErase = (work, cancelLog)
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.scribbleCommitDelay, execute: work)
            } else if evaluation.isPlausibleCandidate {
                var reject = recognizer.diagnosticThresholds.merging(evaluation.logFields) { a, _ in a }
                reject["page"] = key
                reject["decision_phase"] = "pen_up"
                reject["pen_size"] = width
                reject["stroke_count_at_start"] = index
                InkLog.write("input_scribble_erase_reject", reject)
            }
        }

        private func commitScribbleErase(recognizer: ScribbleEraseRecognizer, evaluation: ScribbleEraseEvaluation,
                                         targets: [InkTarget], strokeIndex: Int, all: [PKStroke]) {
            guard let canvas else { return }
            let region = recognizer.eraseRegionBounds
            let hits = recognizer.strokesInEraseRegion(targets, profile: evaluation.profile)
            // 没有要删的笔迹时保留这一笔，不要让涂抹凭空消失
            guard !hits.isEmpty else {
                var reject = recognizer.diagnosticThresholds.merging(evaluation.logFields) { a, _ in a }
                reject["page"] = key
                reject["decision"] = "noStrokesToDelete"
                reject["decision_phase"] = "pen_up"
                reject["pen_size"] = recognizer.penSize
                reject["stroke_count_at_start"] = strokeIndex
                InkLog.write("input_scribble_erase_reject", reject)
                return
            }
            let before = PKDrawing(strokes: Array(all.dropLast()))
            let after = PKDrawing(strokes: all.dropLast().enumerated().filter { hits[$0.offset] == nil }.map(\.element))

            let eraseID = UUID().uuidString
            var commit = recognizer.diagnosticThresholds.merging(evaluation.logFields) { a, _ in a }
            commit["page"] = key
            commit["erase_id"] = eraseID
            commit["decision_phase"] = "pen_up"
            commit["delete_mode"] = evaluation.profile == .dense ? "whole_stroke_covered" : "whole_stroke_hit_segments"
            commit["pen_size"] = recognizer.penSize
            commit["stroke_count_at_start"] = strokeIndex
            commit["erase_region"] = region
            commit["deleted_strokes"] = hits.count
            InkLog.write("input_scribble_erase_commit", commit)
            for (i, count) in hits.sorted(by: { $0.key < $1.key }).prefix(32) {
                let s = all[i]
                InkLog.write("input_scribble_erase_delete_result", [
                    "page": key, "stroke_index": i, "hit_segments": count, "input_points": s.path.count,
                    "stroke_bounds": s.renderBounds, "intersection": s.renderBounds.intersection(region),
                    "masked": s.mask != nil,
                ])
            }

            // 先让 PencilKit 撤销「画下涂抹这一笔」，再删被涂掉的笔迹并登记一次撤销：一次撤销恢复全部
            suppressChange = true
            var undoPath = "pencilkit_undo"
            if let um = canvas.undoManager, um.canUndo {
                um.undo()
                if canvas.drawing.strokes.count != all.count - 1 {
                    undoPath = "fallback_set"
                    canvas.drawing = before
                }
            } else {
                undoPath = "fallback_set"
                canvas.drawing = before
            }
            setDrawing(after, undoTo: before, action: "scribble_erase")
            suppressChange = false
            strokeCount = canvas.drawing.strokes.count
            recorder?.sync(canvas, reason: "scribble_erase")
            InkLog.write("input_scribble_erase_end", [
                "page": key, "erase_id": eraseID, "deleted_strokes": hits.count, "stroke_count_after": strokeCount,
                "remove_scribble_via": undoPath,
            ])
            scheduleSave()
        }

        /// 设置画布内容并登记撤销（撤销后可重做）
        private func setDrawing(_ new: PKDrawing, undoTo old: PKDrawing, action: String) {
            guard let canvas else { return }
            let wasSuppressed = suppressChange
            suppressChange = true
            canvas.drawing = new
            suppressChange = wasSuppressed
            strokeCount = new.strokes.count
            canvas.undoManager?.registerUndo(withTarget: self) { coord in
                MainActor.assumeIsolated {
                    InkLog.write("input_undo_custom", ["page": coord.key, "action": action])
                    coord.setDrawing(old, undoTo: new, action: action)
                    coord.scheduleSave()
                }
            }
        }

        // MARK: 统计与工具

        private static func strokeWidth(_ stroke: PKStroke) -> CGFloat {
            guard let p = stroke.path.first else { return 2 }
            return max(p.size.width, p.size.height)
        }

        /// 一笔的详细统计：点数、时长、长度、速度、压力、倾角、方位角、宽度、范围、墨水
        static func strokeStats(_ stroke: PKStroke) -> [String: Any] {
            let path = stroke.path
            let pts = Array(path)
            var length: CGFloat = 0, maxSpeed: CGFloat = 0
            var forces: [CGFloat] = [], alts: [CGFloat] = [], azis: [CGFloat] = [], widths: [CGFloat] = []
            for (i, p) in pts.enumerated() {
                forces.append(p.force); alts.append(p.altitude); azis.append(p.azimuth); widths.append(p.size.width)
                if i > 0 {
                    let q = pts[i - 1]
                    let d = hypot(p.location.x - q.location.x, p.location.y - q.location.y)
                    length += d
                    let dt = p.timeOffset - q.timeOffset
                    if dt > 1e-4 { maxSpeed = max(maxSpeed, d / CGFloat(dt)) }
                }
            }
            let duration = pts.last?.timeOffset ?? 0
            func stats(_ a: [CGFloat]) -> [String: Any] {
                guard let lo = a.min(), let hi = a.max() else { return [:] }
                return ["min": lo, "avg": a.reduce(0, +) / CGFloat(a.count), "max": hi]
            }
            var color: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, alpha: CGFloat = 0
            stroke.ink.color.getRed(&color, green: &g, blue: &b, alpha: &alpha)
            return [
                "ink": stroke.ink.inkType.rawValue,
                "color_rgba": [color, g, b, alpha],
                "points": pts.count,
                "duration_ms": duration * 1000,
                "path_length_pt": length,
                "avg_speed_pt_s": duration > 0 ? length / CGFloat(duration) : 0,
                "max_speed_pt_s": maxSpeed,
                "force": stats(forces),
                "altitude_rad": stats(alts),
                "azimuth_rad": stats(azis),
                "width_pt": stats(widths),
                "render_bounds": stroke.renderBounds,
                "start": pts.first.map { $0.location.applying(stroke.transform) } ?? .zero,
                "end": pts.last.map { $0.location.applying(stroke.transform) } ?? .zero,
                "masked": stroke.mask != nil,
                "creation_date": path.creationDate.timeIntervalSince1970,
            ]
        }

        /// 旧笔迹 → 识别器用的相交检测：沿可见路径每 2pt 取点，点到矩形的距离不超过半个笔宽即算相交
        static func target(for stroke: PKStroke, id: Int) -> InkTarget {
            final class Cache { var points: [(CGPoint, CGFloat)]? }
            let cache = Cache()
            let transform = stroke.transform
            func points() -> [(CGPoint, CGFloat)] {
                if let pts = cache.points { return pts }
                var pts: [(CGPoint, CGFloat)] = []
                for range in stroke.maskedPathRanges {
                    for p in stroke.path.interpolatedPoints(in: range, by: .distance(2)) {
                        pts.append((p.location.applying(transform), max(p.size.width, p.size.height) / 2))
                    }
                }
                cache.points = pts
                return pts
            }
            return InkTarget(id: id, visibleBounds: stroke.renderBounds, intersects: { rect in
                points().contains { p, r in
                    let dx = max(rect.minX - p.x, 0, p.x - rect.maxX)
                    let dy = max(rect.minY - p.y, 0, p.y - rect.maxY)
                    return hypot(dx, dy) <= r
                }
            }, fractionNear: { path, distance in
                let pts = points()
                guard !pts.isEmpty, path.count >= 2 else { return 0 }
                let near = pts.filter { p, _ in
                    zip(path, path.dropFirst()).contains {
                        ScribbleEraseRecognizer.distance(p, toSegment: $0, $1) <= distance
                    }
                }
                return CGFloat(near.count) / CGFloat(pts.count)
            })
        }

        static func describe(_ tool: PKTool) -> [String: Any] {
            switch tool {
            case let t as PKInkingTool:
                return ["kind": "ink", "ink": t.inkType.rawValue, "width": t.width]
            case let t as PKEraserTool:
                return ["kind": "eraser", "eraser": t.eraserType == .vector ? "vector" : "bitmap", "width": t.width]
            case is PKLassoTool:
                return ["kind": "lasso"]
            default:
                return ["kind": String(describing: type(of: tool))]
            }
        }
    }
}
