import Foundation

// 不依赖模拟器的输入时序回归：
// swiftc -parse-as-library Learning/Ink/PalmNavigationGuard.swift Tests/PalmNavigationGuardTests.swift -o /tmp/palm-navigation-tests
// /tmp/palm-navigation-tests
@main
private enum PalmNavigationGuardTests {
    static func main() {
        var guardPolicy = PalmNavigationGuard()
        guardPolicy.update(fingers: 1, pencilDown: false, time: 0)
        precondition(!guardPolicy.releaseOnMove(at: 1), "一根手指不能放行草稿页导航")
        guardPolicy.update(fingers: 2, pencilDown: false, time: 1)
        precondition(!guardPolicy.releaseOnMove(at: 1.080), "落笔前 80 ms 的手掌运动不能移动页面")
        guardPolicy.update(fingers: 2, pencilDown: true, time: 1.090)
        precondition(!guardPolicy.releaseOnMove(at: 2), "Pencil 落下后不能超时放行")
        guardPolicy.update(fingers: 2, pencilDown: false, time: 2)
        precondition(!guardPolicy.releaseOnMove(at: 3), "抬笔后还在屏幕上的手掌不能恢复导航")
        guardPolicy.update(fingers: 0, pencilDown: false, time: 3)
        precondition(!guardPolicy.suppressed && guardPolicy.candidateStart == nil)

        guardPolicy.update(fingers: 2, pencilDown: false, time: 4)
        precondition(!guardPolicy.released, "时间经过本身不应放行")
        precondition(guardPolicy.releaseOnMove(at: 4.151), "明确继续移动的双指操作可以放行")
        precondition(!guardPolicy.releaseOnMove(at: 4.2), "只放行一次，以免反复重置位移")
        guardPolicy.update(fingers: 2, pencilDown: true, time: 4.3)
        precondition(guardPolicy.suppressed, "已经放行的导航仍必须能被 Pencil 取消")
        guardPolicy.update(fingers: 0, pencilDown: true, time: 4.4)
        precondition(guardPolicy.suppressed, "Pencil 未抬起时不能重置保护")
        guardPolicy.update(fingers: 0, pencilDown: false, time: 4.5)
        guardPolicy.update(fingers: 2, pencilDown: false, time: 5)
        precondition(!guardPolicy.releaseOnMove(at: 5.1))
        precondition(guardPolicy.releaseOnMove(at: 5.151), "新的一组手指操作恢复正常")
        checkTwoFingerNavigation()
        print("Palm navigation timing checks passed")
    }

    private static func geometry(center: CGPoint = .zero, span: CGFloat) -> TwoFingerGeometry {
        TwoFingerGeometry(CGPoint(x: center.x - span / 2, y: center.y),
                          CGPoint(x: center.x + span / 2, y: center.y))
    }

    private static func checkTwoFingerNavigation() {
        var nav = TwoFingerNavigation()
        nav.begin(geometry(span: 100), at: 0)
        precondition(nav.move(geometry(span: 180), at: 0.08) == nil, "保护窗口内不能应用大幅缩放")
        guard case .begin(.pinch) = nav.move(geometry(center: CGPoint(x: 30, y: 0), span: 200), at: 0.16) else {
            preconditionFailure("伴随中心移动的不对称捏合应识别为缩放")
        }
        guard case .pinch(let previous, let current) = nav.move(geometry(center: CGPoint(x: 35, y: 0), span: 220), at: 0.18) else {
            preconditionFailure("明确捏合后不能又变回滚动")
        }
        precondition(previous.span == 200 && current.span == 220, "第一帧只缩放 1.1 倍，而非从落指时累计的 2.2 倍")
        let result = PagePinchTransform.apply(zoom: 1.5, offset: CGPoint(x: 100, y: 200),
            previousCenter: CGPoint(x: 120, y: 220), currentCenter: CGPoint(x: 125, y: 220),
            previousSpan: previous.span, currentSpan: current.span, minimum: 1, maximum: 3)
        precondition(abs(result.zoom - 1.65) < 0.0001)
        precondition(abs(result.offset.x - 117) < 0.0001 && abs(result.offset.y - 242) < 0.0001, "缩放应保持中心对应的页面点")
        guard case .end(.pinch) = nav.suppress() else { preconditionFailure("Pencil 落下必须结束缩放") }
        precondition(nav.move(geometry(span: 300), at: 0.5) == nil)

        var pan = TwoFingerNavigation()
        pan.begin(geometry(span: 160), at: 1)
        guard case .begin(.pan) = pan.move(geometry(center: CGPoint(x: 0, y: 30), span: 163), at: 1.16) else {
            preconditionFailure("平行移动伴随少量指距噪声应识别为滚动")
        }
        guard case .pan(let delta) = pan.move(geometry(center: CGPoint(x: 0, y: 50), span: 164), at: 1.18) else {
            preconditionFailure("应继续平移")
        }
        precondition(delta.y == 20, "不能回放等待期间的 30 点位移")
        _ = pan.move(geometry(center: CGPoint(x: 0, y: 50), span: 190), at: 1.20)
        guard case .begin(.pinch) = pan.move(geometry(center: CGPoint(x: 0, y: 50), span: 200), at: 1.23) else {
            preconditionFailure("起步先滑动的手势随后张合时应能转为捏合")
        }
        let limited = PagePinchTransform.apply(zoom: 2.9, offset: .zero, previousCenter: .zero,
            currentCenter: .zero, previousSpan: 100, currentSpan: 200, minimum: 1, maximum: 3)
        precondition(limited.zoom == 3)
    }
}
