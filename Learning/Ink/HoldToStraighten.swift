import Foundation
import PencilKit
import UIKit

/// 只跟踪本次连续落笔；停住片刻后识别这一笔画的是什么图形（见 ShapeRecognizer）。
/// 识别为直线时起点固定、终点随笔尖移动；其余图形识别后固定。认不出的保留原笔迹。
nonisolated struct HoldToStraighten {
    static let delay: TimeInterval = 0.5
    var tolerance: CGFloat = 3
    private(set) var start: CGPoint?
    private(set) var points: [CGPoint] = []
    /// 停顿时识别出的图形；直线的终点之后随笔尖更新
    private(set) var shape: RecognizedShape?
    /// 停顿过但没认出图形：这一笔不再识别
    private(set) var unrecognized = false
    private var anchor: CGPoint?
    private var stationarySince: TimeInterval = 0

    var straightened: Bool { shape != nil }

    mutating func begin(at point: CGPoint, time: TimeInterval) {
        start = point
        points = [point]
        anchor = point
        stationarySince = time
        shape = nil
        unrecognized = false
    }

    mutating func move(to point: CGPoint, time: TimeInterval) {
        points.append(point)
        if case .line(let a, _)? = shape {
            shape = .line(a, ShapeRecognizer.snapLine(a, point))
            return
        }
        guard shape == nil, !unrecognized, let anchor else { return }
        if hypot(point.x - anchor.x, point.y - anchor.y) > tolerance {
            self.anchor = point
            stationarySince = time
        }
        poll(time: time)
    }

    mutating func poll(time: TimeInterval) {
        guard start != nil, shape == nil, !unrecognized, time - stationarySince >= Self.delay else { return }
        shape = ShapeRecognizer.recognize(points)
        unrecognized = shape == nil
    }
}

/// 被动采样，不抢占 PencilKit 书写或手指滚动。
@MainActor
final class PencilHoldRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    weak var space: DraftCanvasContainer?
    var canBegin: (() -> Bool)?
    var onBegin: (() -> Void)?
    var onShape: ((RecognizedShape) -> Void)?
    /// 抬笔或取消；附上这一笔采到的全部点（与预览同一坐标系）
    var onFinish: ((Bool, [CGPoint]) -> Void)?
    private var hold = HoldToStraighten()
    private var timer: Timer?
    private var tracking = false

    init() {
        super.init(target: nil, action: nil)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard touch.type == .pencil, canBegin?() == true, let space else { return false }
        return !(space.canvas.tapTargets?.contains(touch.location(in: space)) ?? false)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, let space else { return }
        tracking = true
        hold.tolerance = 3 / max(space.pageZoom, 1)
        hold.begin(at: touch.location(in: space), time: touch.timestamp)
        onBegin?()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.tracking else { return }
                self.hold.poll(time: ProcessInfo.processInfo.systemUptime)
                self.publish()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard tracking, let touch = touches.first, let space else { return }
        for sample in event.coalescedTouches(for: touch) ?? [touch] {
            hold.move(to: sample.location(in: space), time: sample.timestamp)
        }
        publish()
    }

    private func publish() {
        if let shape = hold.shape { onShape?(shape) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        touchesMoved(touches, with: event)
        finish(cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(cancelled: true) }

    private func finish(cancelled: Bool) {
        timer?.invalidate()
        timer = nil
        if tracking { onFinish?(cancelled, hold.points) }
        tracking = false
        state = .failed
    }

    override func reset() {
        timer?.invalidate()
        timer = nil
        if tracking { onFinish?(true, hold.points) }
        tracking = false
        hold = HoldToStraighten()
    }
}

extension PKStroke {
    /// 换成识别出的图形：points 为笔画自身坐标里的点，保留墨水和这一笔的平均粗细、压力
    func reshaped(to points: [CGPoint]) -> PKStroke {
        let src = Array(path)
        guard points.count > 1, let mid = src.isEmpty ? nil : src[src.count / 2] else { return self }
        let duration = src.last?.timeOffset ?? 0
        let out = points.enumerated().map { i, p in
            PKStrokePoint(location: p, timeOffset: duration * Double(i) / Double(points.count - 1), size: mid.size,
                          opacity: mid.opacity, force: mid.force, azimuth: mid.azimuth, altitude: mid.altitude)
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: out, creationDate: path.creationDate), transform: transform)
    }

    /// 保留墨水、压力、宽度和时间，只将点的位置排到两端之间。
    func straightened() -> PKStroke {
        guard path.count > 1, let first = path.first, let last = path.last else { return self }
        let points = Array(path).enumerated().map { i, point in
            let t = CGFloat(i) / CGFloat(path.count - 1)
            return PKStrokePoint(location: CGPoint(x: first.location.x + (last.location.x - first.location.x) * t,
                                                   y: first.location.y + (last.location.y - first.location.y) * t),
                                 timeOffset: point.timeOffset, size: point.size, opacity: point.opacity,
                                 force: point.force, azimuth: point.azimuth, altitude: point.altitude)
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: path.creationDate), transform: transform)
    }
}
