import Foundation
import CoreGraphics

/// 借鉴用户修改的 Saber interactive_canvas.dart 的 pre-stylus palm candidate：
/// 手掌可能先于笔尖落下；等待期间不移动页面，Pencil 到来后整组触摸失去导航资格。
/// UIKit 版本保守地保留完整 150 ms 窗口，不提前按移动距离放行。
nonisolated struct PalmNavigationGuard {
    static let wait: TimeInterval = 0.150
    private(set) var candidateStart: TimeInterval?
    private(set) var released = false
    private(set) var suppressed = false

    mutating func update(fingers: Int, pencilDown: Bool, time: TimeInterval) {
        if pencilDown { suppressed = true }
        if fingers == 0 && !pencilDown {
            self = Self()
        } else if fingers >= 2 && candidateStart == nil && !released && !suppressed {
            candidateStart = time
        }
    }

    /// 只在新的移动事件上放行；超时本身不会使静止的手掌开始平移或缩放。
    mutating func releaseOnMove(at time: TimeInterval) -> Bool {
        guard !released, !suppressed, let candidateStart,
              time - candidateStart >= Self.wait else { return false }
        released = true
        return true
    }
}

/// 同一时刻的两根手指位置；基准从第二根手指落下时开始，避免落指先后造成假位移。
nonisolated struct TwoFingerGeometry: Equatable {
    let center: CGPoint
    let span: CGFloat

    init(_ a: CGPoint, _ b: CGPoint) {
        center = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        span = hypot(a.x - b.x, a.y - b.y)
    }
}

nonisolated enum PageNavigationIntent: String { case pan, pinch }

nonisolated enum PageNavigationStep: Equatable {
    case begin(PageNavigationIntent)
    case pan(CGPoint)
    case pinch(previous: TwoFingerGeometry, current: TwoFingerGeometry)
    case end(PageNavigationIntent)
}

/// 统一仲裁和计算双指导航，不再让原生 pan/pinch 在等待期间各自累积变换。
nonisolated struct TwoFingerNavigation {
    private var guardPolicy = PalmNavigationGuard()
    private var baseline: TwoFingerGeometry?
    private var previous: TwoFingerGeometry?
    private var pinchEvidenceSince: TimeInterval?
    private(set) var intent: PageNavigationIntent?

    mutating func begin(_ geometry: TwoFingerGeometry, at time: TimeInterval) {
        guardPolicy = PalmNavigationGuard()
        baseline = geometry
        previous = geometry
        guardPolicy.update(fingers: 2, pencilDown: false, time: time)
    }

    mutating func suppress() -> PageNavigationStep? {
        guardPolicy.update(fingers: 2, pencilDown: true, time: 0)
        return end()
    }

    mutating func end() -> PageNavigationStep? {
        let last = intent
        intent = nil
        previous = nil
        baseline = nil
        pinchEvidenceSince = nil
        return last.map { .end($0) }
    }

    mutating func move(_ geometry: TwoFingerGeometry, at time: TimeInterval) -> PageNavigationStep? {
        guard !guardPolicy.suppressed, let baseline, let previous, geometry.span >= 16 else { return nil }
        if !guardPolicy.released && !guardPolicy.releaseOnMove(at: time) { return nil }
        let spread = abs(geometry.span - baseline.span)
        let displacement = hypot(geometry.center.x - baseline.center.x, geometry.center.y - baseline.center.y)
        let scaleSlop = min(12, max(6, baseline.span * 0.025))
        // 只有中点移动明显占优才认作平移；一根手指不动的捏合也能识别。
        let pinch = spread >= scaleSlop && spread * 2 > displacement
        let pan = displacement >= 8 && displacement >= spread * 2
        if intent == nil {
            guard pinch || pan else { return nil }
            intent = pinch ? .pinch : .pan
            self.baseline = geometry
            self.previous = geometry
            // 放行这一帧只建立基准，等待期间的位移和缩放完全丢弃。
            return .begin(intent!)
        }
        if intent == .pan {
            // 起步先平移、随后张合手指时可以转为捏合；连续证据需维持 24 ms。
            let localMove = hypot(geometry.center.x - previous.center.x, geometry.center.y - previous.center.y)
            if spread >= scaleSlop && spread * 2 > localMove {
                if pinchEvidenceSince == nil { pinchEvidenceSince = time }
                if time - pinchEvidenceSince! >= 0.024 {
                    intent = .pinch
                    self.previous = geometry
                    return .begin(.pinch)
                }
            } else {
                pinchEvidenceSince = nil
            }
        }
        self.previous = geometry
        if intent == .pinch { return .pinch(previous: previous, current: geometry) }
        return .pan(CGPoint(x: geometry.center.x - previous.center.x, y: geometry.center.y - previous.center.y))
    }
}

/// 增量指距比与捏合中心来自同一帧；已放行时的第一帧不会应用旧的累计 scale。
nonisolated enum PagePinchTransform {
    static func apply(zoom: CGFloat, offset: CGPoint, previousCenter: CGPoint, currentCenter: CGPoint,
                      previousSpan: CGFloat, currentSpan: CGFloat, minimum: CGFloat, maximum: CGFloat)
        -> (zoom: CGFloat, offset: CGPoint) {
        guard previousSpan >= 16, zoom > 0 else { return (zoom, offset) }
        let next = min(maximum, max(minimum, zoom * currentSpan / previousSpan))
        let ratio = next / zoom
        return (next, CGPoint(x: (offset.x + previousCenter.x) * ratio - currentCenter.x,
                              y: (offset.y + previousCenter.y) * ratio - currentCenter.y))
    }
}

#if canImport(UIKit)
import UIKit

/// 草稿模式由这一只识别器处理双指导航；原生 UIScrollView 仍负责页面缩放与排版，
/// 但不让它的 pan/pinch 同时处理这些触摸。PencilKit 输入独立保留。
final class PalmNavigationGestureRecognizer: UIGestureRecognizer {
    var onStep: ((PageNavigationStep) -> Void)?
    var onTouchStart: (() -> Void)?
    private var fingers: [UITouch] = []
    private var navigation = TwoFingerNavigation()
    private var pencilDown = false
    private var suppressed = false
    private var lastMoveTime: TimeInterval?
    private(set) var velocity = CGPoint.zero
    private(set) var cancelledNavigation = false

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    func setPencilDown(_ down: Bool) {
        guard down != pencilDown else { return }
        pencilDown = down
        guard down else {
            // 只有 Pencil 接触、没有手掌触摸时，观察器不会走 touchesEnded/reset。
            // 抬笔要立即解除保护，不能把下一次正常双指操作也吞掉。
            if fingers.isEmpty {
                suppressed = false
                navigation = TwoFingerNavigation()
                cancelledNavigation = false
            }
            return
        }
        suppressed = true
        cancelledNavigation = true
        if let step = navigation.suppress() { onStep?(step) }
        if state == .possible && !fingers.isEmpty { state = .began }
        InkLog.write("input_pre_stylus_palm_rejected", ["pointer_count": fingers.count])
    }

    private var geometry: TwoFingerGeometry? {
        guard fingers.count >= 2 else { return nil }
        return TwoFingerGeometry(fingers[0].location(in: nil), fingers[1].location(in: nil))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        let previousCount = fingers.count
        fingers.append(contentsOf: touches)
        onTouchStart?()
        if pencilDown || suppressed {
            suppressed = true
            if state == .possible { state = .began }
        } else if previousCount < 2, let geometry {
            navigation.begin(geometry, at: event.timestamp)
            InkLog.write("input_pre_stylus_palm_candidate_start", [
                "pointer_count": fingers.count, "window_ms": PalmNavigationGuard.wait * 1000,
            ])
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard !suppressed, let geometry, let step = navigation.move(geometry, at: event.timestamp) else { return }
        switch step {
        case .begin(let intent):
            velocity = .zero
            if state == .possible { state = .began }
            InkLog.write("input_navigation_intent_commit", ["intent": intent.rawValue,
                "span": geometry.span, "center": geometry.center])
        case .pan(let delta):
            if let lastMoveTime {
                let dt = event.timestamp - lastMoveTime
                if dt > 0, dt < 0.1 {
                    velocity = CGPoint(x: velocity.x * 0.65 + delta.x / dt * 0.35,
                                       y: velocity.y * 0.65 + delta.y / dt * 0.35)
                } else { velocity = .zero }
            }
            state = .changed
        case .pinch:
            velocity = .zero
            state = .changed
        case .end: break
        }
        lastMoveTime = event.timestamp
        onStep?(step)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches, event: event, cancelled: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches, event: event, cancelled: true) }

    private func finish(_ touches: Set<UITouch>, event: UIEvent, cancelled: Bool) {
        fingers.removeAll { touches.contains($0) }
        if fingers.count < 2 {
            cancelledNavigation = cancelled || suppressed
            if event.timestamp - (lastMoveTime ?? 0) > 0.08 { velocity = .zero }
            if let step = navigation.end() { onStep?(step) }
        } else if let geometry {
            // 原先参与的一根手指离开、另一根仍在时，重新建立双指基准。
            if let step = navigation.end() { cancelledNavigation = true; onStep?(step) }
            navigation = TwoFingerNavigation()
            if !suppressed { navigation.begin(geometry, at: event.timestamp) }
        }
        if fingers.isEmpty { state = state == .possible ? .failed : .ended }
    }

    override func reset() {
        fingers = []
        navigation = TwoFingerNavigation()
        suppressed = pencilDown
        velocity = .zero
        lastMoveTime = nil
        cancelledNavigation = false
        super.reset()
    }

    override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }

    #if DEBUG
    func checkPencilOnlyRelease() {
        precondition(fingers.isEmpty)
        setPencilDown(true)
        precondition(suppressed)
        setPencilDown(false)
        precondition(!suppressed, "没有残留手掌时，抬笔后下一次双指操作应立即有导航资格")
    }
    #endif
}
#endif
