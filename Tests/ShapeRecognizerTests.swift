import CoreGraphics
import Foundation

// 画完停顿后的图形识别：
// swiftc -swift-version 6 -parse-as-library -default-isolation MainActor Learning/Ink/ShapeRecognizer.swift Tests/ShapeRecognizerTests.swift -o /tmp/shape-tests
// /tmp/shape-tests
@main
private enum ShapeRecognizerTests {
    /// 可重复的抖动，模拟手绘
    static var seed: UInt64 = 42
    static func jitter(_ amount: CGFloat) -> CGFloat {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return (CGFloat(seed >> 33) / CGFloat(1 << 31) - 0.5) * 2 * amount
    }

    static func wobble(_ pts: [CGPoint], _ amount: CGFloat = 1.5) -> [CGPoint] {
        pts.map { CGPoint(x: $0.x + jitter(amount), y: $0.y + jitter(amount)) }
    }

    static func path(_ vertices: [CGPoint], closed: Bool, step: CGFloat = 3) -> [CGPoint] {
        RecognizedShape.polyline(closed ? vertices + [vertices[0]] : vertices).points(spacing: step)
    }

    static func name(_ pts: [CGPoint]) -> String { ShapeRecognizer.recognize(pts)?.name ?? "none" }

    static func main() {
        // 直线：接近水平时摆正
        let line = wobble(path([CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 8)], closed: false))
        guard case .line(_, let end)? = ShapeRecognizer.recognize(line) else { preconditionFailure("应识别为直线") }
        precondition(abs(end.y - line[0].y) < 0.01, "接近水平的直线摆正")

        // 折线
        precondition(name(wobble(path([CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100)],
                                      closed: false))) == "polyline")

        // 三角形
        precondition(name(wobble(path([CGPoint(x: 0, y: 0), CGPoint(x: 160, y: 0), CGPoint(x: 80, y: 130)],
                                      closed: true))) == "triangle")

        // 矩形：规整成直角，接近水平时摆正
        let rect = wobble(path([CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 4), CGPoint(x: 198, y: 104),
                                CGPoint(x: -2, y: 100)], closed: true))
        guard case .polygon(let v)? = ShapeRecognizer.recognize(rect), v.count == 4 else {
            preconditionFailure("应识别为矩形：\(name(rect))")
        }
        precondition(abs(v[0].y - v[1].y) < 0.01 || abs(v[0].x - v[1].x) < 0.01, "矩形摆正")

        // 圆与椭圆
        let circle = wobble(RecognizedShape.ellipse(center: CGPoint(x: 100, y: 100), rx: 80, ry: 76, angle: 0).points(spacing: 3))
        guard case .ellipse(_, let rx, let ry, _)? = ShapeRecognizer.recognize(circle) else {
            preconditionFailure("应识别为圆：\(name(circle))")
        }
        precondition(rx == ry, "接近正圆时规整为圆")
        let ellipse = wobble(RecognizedShape.ellipse(center: CGPoint(x: 100, y: 100), rx: 120, ry: 50, angle: 0.4)
            .points(spacing: 3))
        precondition(name(ellipse) == "ellipse", "应识别为椭圆：\(name(ellipse))")

        // 手抖的三角形、四边形：低频漂移 + 拐角冲过头 + 首尾多画一截，不能认成五边形
        func hand(_ v: [CGPoint], amp: CGFloat) -> [CGPoint] {
            var pts: [CGPoint] = []
            for i in 0...v.count {
                let a = v[i % v.count], b = v[(i + 1) % v.count]
                let len = hypot(b.x - a.x, b.y - a.y), steps = max(Int(len / 3), 2)
                for k in 0..<(i == v.count ? steps / 4 : steps) {
                    let t = CGFloat(k) / CGFloat(steps)
                    pts.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                }
                if i < v.count {
                    let over = 6 * (jitter(0.5) + 0.5)
                    pts.append(CGPoint(x: b.x + (b.x - a.x) / len * over, y: b.y + (b.y - a.y) / len * over))
                }
            }
            var drift = CGPoint.zero
            return pts.map { p in
                drift = CGPoint(x: drift.x * 0.92 + jitter(amp * 0.35), y: drift.y * 0.92 + jitter(amp * 0.35))
                return CGPoint(x: p.x + drift.x + jitter(amp * 0.4), y: p.y + drift.y + jitter(amp * 0.4))
            }
        }
        var tri = 0, quad = 0
        for i in 0..<40 {
            let s = CGFloat(100 + i * 4)
            if name(hand([CGPoint(x: 0, y: 0), CGPoint(x: s, y: 10), CGPoint(x: s * 0.45, y: s * 0.85)], amp: 4)) == "triangle" { tri += 1 }
            if name(hand([CGPoint(x: 0, y: 0), CGPoint(x: s, y: 0), CGPoint(x: s, y: s * 0.6), CGPoint(x: 0, y: s * 0.6)],
                         amp: 4)) == "quadrilateral" { quad += 1 }
        }
        precondition(tri >= 38 && quad >= 38, "手抖的三角形 \(tri)/40、四边形 \(quad)/40")

        // 太小的点、乱画的闭合图形不识别
        precondition(ShapeRecognizer.recognize([CGPoint(x: 0, y: 0), CGPoint(x: 2, y: 1)]) == nil)
        var scribble: [CGPoint] = []
        for i in 0..<120 {
            let t = CGFloat(i) / 120 * 2 * .pi
            let r = 60 + 30 * sin(7 * t)
            scribble.append(CGPoint(x: 100 + r * cos(t), y: 100 + r * sin(t)))
        }
        precondition(name(scribble) == "none", "星形乱线不识别：\(name(scribble))")
        print("ShapeRecognizerTests passed")
    }
}
