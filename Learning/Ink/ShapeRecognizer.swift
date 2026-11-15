import CoreGraphics
import Foundation

/// 画完停顿后识别出的标准图形（页面坐标）
nonisolated enum RecognizedShape: Equatable, Sendable {
    case line(CGPoint, CGPoint)
    /// 不闭合的折线（2～4 段直线）
    case polyline([CGPoint])
    /// 闭合多边形：三角形、四边形（接近直角时为矩形 / 正方形）、五边形
    case polygon([CGPoint])
    case ellipse(center: CGPoint, rx: CGFloat, ry: CGFloat, angle: CGFloat)

    var name: String {
        switch self {
        case .line: "line"
        case .polyline: "polyline"
        case .polygon(let p): p.count == 3 ? "triangle" : p.count == 4 ? "quadrilateral" : "polygon"
        case .ellipse(_, let rx, let ry, _): rx == ry ? "circle" : "ellipse"
        }
    }

    /// 沿图形均匀取点（闭合图形首尾相同），用来生成笔画
    func points(spacing: CGFloat = 2) -> [CGPoint] {
        func along(_ vertices: [CGPoint]) -> [CGPoint] {
            var out: [CGPoint] = []
            for (a, b) in zip(vertices, vertices.dropFirst()) {
                let n = max(Int(ShapeRecognizer.distance(a, b) / spacing), 1)
                for i in 0..<n {
                    let t = CGFloat(i) / CGFloat(n)
                    out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                }
            }
            if let last = vertices.last { out.append(last) }
            return out
        }
        switch self {
        case .line(let a, let b): return along([a, b])
        case .polyline(let v): return along(v)
        case .polygon(let v): return along(v + [v[0]])
        case .ellipse(let c, let rx, let ry, let angle):
            let perimeter = 2 * .pi * sqrt((rx * rx + ry * ry) / 2)
            let n = max(Int(perimeter / spacing), 24)
            return (0...n).map { i in
                let t = CGFloat(i) / CGFloat(n) * 2 * .pi
                let x = rx * cos(t), y = ry * sin(t)
                return CGPoint(x: c.x + x * cos(angle) - y * sin(angle), y: c.y + x * sin(angle) + y * cos(angle))
            }
        }
    }
}

/// 把一笔手绘识别成直线、折线、三角形、矩形、多边形、圆或椭圆。认不出时返回 nil（保留原笔迹）
nonisolated enum ShapeRecognizer {
    /// 角度吸附：直线、矩形边与水平 / 竖直相差不到这么多度时摆正
    static let snapDegrees: CGFloat = 6

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    static func recognize(_ raw: [CGPoint]) -> RecognizedShape? {
        let pts = dedup(raw)
        guard pts.count >= 2, let first = pts.first, let last = pts.last else { return nil }
        let box = bounds(pts)
        let size = hypot(box.width, box.height)
        guard size >= 8 else { return nil }

        guard let loop = closedLoop(pts, size: size) else {
            // 不闭合：没有拐角是直线，1～3 个拐角是折线；更多的弯来弯去仍拉成直线（与以前按住拉直一致）
            let samples = resample(pts, count: 90)
            // 开放笔画两端常有小钩，只认中间、转得更急的拐角
            let (raw, turns) = cornerIndicesWithTurns(samples, closed: false)
            let margin = samples.count / 10
            let corners = raw.filter { $0 >= margin && $0 <= samples.count - 1 - margin && turns[$0] >= 60 }
            // 没有拐角，或整体仍贴着首尾连线（抖动造成的假拐角）：直线
            if corners.isEmpty || meanDistance(pts, toPath: [first, last]) < 0.03 * size {
                return .line(first, snapLine(first, last))
            }
            if corners.count <= 3 {
                let cuts = [0] + corners + [samples.count - 1]
                var v = [first]
                for i in 1..<(cuts.count - 1) {
                    v.append(intersect(fitLine(samples, cuts[i - 1], cuts[i]), fitLine(samples, cuts[i], cuts[i + 1]))
                             ?? samples[cuts[i]])
                }
                v.append(last)
                if meanDistance(pts, toPath: v) < 0.04 * size { return .polyline(v) }
            }
            return .line(first, snapLine(first, last))
        }

        // 闭合：按急转弯找拐角，平缓的抖动不算；3～5 个拐角是多边形，没有拐角是圆或椭圆
        let samples = resample(loop, count: 120)
        var (corners, turns) = cornerIndicesWithTurns(samples, closed: true)
        func polygon(_ cs: [Int]) -> (vertices: [CGPoint], error: CGFloat) {
            var v: [CGPoint] = []
            for i in cs.indices {
                let prev = cs[(i + cs.count - 1) % cs.count], cur = cs[i], next = cs[(i + 1) % cs.count]
                v.append(intersect(fitLine(samples, prev, cur), fitLine(samples, cur, next)) ?? samples[cur])
            }
            return (v, meanDistance(loop, toPath: v + [v[0]]) / size)
        }
        if (3...7).contains(corners.count) {
            var best = polygon(corners)
            // 手抖多出的拐角：去掉转得最小的一个后贴合程度差不多，就用顶点更少的
            while corners.count > 3 {
                let weakest = corners.indices.min { turns[corners[$0]] < turns[corners[$1]] }!
                var fewer = corners
                fewer.remove(at: weakest)
                let candidate = polygon(fewer)
                guard candidate.error < max(best.error * 1.35, 0.01) else { break }
                corners = fewer
                best = candidate
            }
            // 椭圆贴合得更好（扁椭圆两端被当成拐角）时不算多边形
            let ellipseError = fitEllipse(loop).map { meanDistance(loop, toEllipse: $0) / size } ?? .infinity
            if (3...5).contains(corners.count), best.error < 0.05, best.error <= ellipseError {
                var v = best.vertices
                if v.count == 4 { v = regularizeQuad(v) }
                return .polygon(v)
            }
        }
        if corners.count <= 2, let e = fitEllipse(loop), meanDistance(loop, toEllipse: e) / size < 0.06 {
            return .ellipse(e: e)
        }
        return nil
    }

    // MARK: - 闭合与拐角

    /// 末端回到起点附近就算闭合：剪掉回到起点之后多画的一截。不闭合时返回 nil
    private static func closedLoop(_ pts: [CGPoint], size: CGFloat) -> [CGPoint]? {
        guard pts.count >= 8, let start = pts.first else { return nil }
        let length = zip(pts, pts.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
        guard length > 1.6 * size else { return nil }
        // 只在后 40% 里找离起点最近的点
        let from = pts.count * 6 / 10
        guard let k = (from..<pts.count).min(by: { distance(pts[$0], start) < distance(pts[$1], start) }),
              distance(pts[k], start) < max(0.18 * size, 6) else { return nil }
        return Array(pts[...k])
    }

    /// 按弧长均匀重采样
    static func resample(_ pts: [CGPoint], count: Int) -> [CGPoint] {
        guard pts.count > 1 else { return pts }
        let seg = zip(pts, pts.dropFirst()).map { distance($0.0, $0.1) }
        let total = seg.reduce(0, +)
        guard total > 0 else { return [pts[0]] }
        let step = total / CGFloat(count - 1)
        var out = [pts[0]]
        var i = 0, acc: CGFloat = 0, target = step
        while out.count < count - 1 && i < seg.count {
            if acc + seg[i] >= target {
                let t = (target - acc) / max(seg[i], 0.0001)
                out.append(CGPoint(x: pts[i].x + (pts[i + 1].x - pts[i].x) * t, y: pts[i].y + (pts[i + 1].y - pts[i].y) * t))
                target += step
            } else {
                acc += seg[i]
                i += 1
            }
        }
        out.append(pts[pts.count - 1])
        return out
    }

    /// 拐角：前后各隔 window 个点的方向相差超过 cornerDegrees 的局部最大处；相近的并成一个（拐角处的小钩、抖动）
    static let cornerDegrees: CGFloat = 50

    static func cornerIndices(_ r: [CGPoint], closed: Bool) -> [Int] {
        cornerIndicesWithTurns(r, closed: closed).corners
    }

    /// 拐角下标和每个点的转角（度）
    static func cornerIndicesWithTurns(_ r: [CGPoint], closed: Bool) -> (corners: [Int], turns: [CGFloat]) {
        let n = r.count, w = max(n / 24, 3)
        guard n > 2 * w + 1 else { return ([], []) }
        func at(_ i: Int) -> CGPoint { r[closed ? ((i % n) + n) % n : min(max(i, 0), n - 1)] }
        var turn = [CGFloat](repeating: 0, count: n)
        for i in (closed ? 0 : w)..<(closed ? n : n - w) {
            let a = at(i - w), b = at(i), c = at(i + w)
            let u = CGPoint(x: b.x - a.x, y: b.y - a.y), v = CGPoint(x: c.x - b.x, y: c.y - b.y)
            let d = max(hypot(u.x, u.y) * hypot(v.x, v.y), 0.0001)
            turn[i] = acos(min(max((u.x * v.x + u.y * v.y) / d, -1), 1)) * 180 / .pi
        }
        // 从大到小取，压掉附近（前后 2.5 个窗口内）更小的
        let radius = Int(CGFloat(w) * 2.5)
        var taken: [Int] = []
        for i in (0..<n).sorted(by: { turn[$0] > turn[$1] }) where turn[i] >= cornerDegrees {
            let near = taken.contains { j in
                let d = abs(i - j)
                return (closed ? min(d, n - d) : d) <= radius
            }
            if !near { taken.append(i) }
        }
        return (taken.sorted(), turn)
    }

    /// 两个拐角之间的一条边：去掉靠近拐角的两端，用主方向拟合直线（点 + 方向）
    private static func fitLine(_ r: [CGPoint], _ from: Int, _ to: Int) -> (CGPoint, CGPoint) {
        let n = r.count
        var idx: [Int] = []
        var i = from
        while i != to { idx.append(i); i = (i + 1) % n }
        idx.append(to)
        let trim = idx.count / 6
        let core = idx.count > 4 ? Array(idx[trim..<(idx.count - trim)]) : idx
        let p = core.map { r[$0] }
        let m = CGFloat(p.count)
        let c = CGPoint(x: p.map(\.x).reduce(0, +) / m, y: p.map(\.y).reduce(0, +) / m)
        var sxx: CGFloat = 0, syy: CGFloat = 0, sxy: CGFloat = 0
        for q in p { let dx = q.x - c.x, dy = q.y - c.y; sxx += dx * dx; syy += dy * dy; sxy += dx * dy }
        let angle = 0.5 * atan2(2 * sxy, sxx - syy)
        return (c, CGPoint(x: cos(angle), y: sin(angle)))
    }

    /// 两条直线的交点；几乎平行时为 nil
    private static func intersect(_ l1: (CGPoint, CGPoint), _ l2: (CGPoint, CGPoint)) -> CGPoint? {
        let (p, d) = l1, (q, e) = l2
        let cross = d.x * e.y - d.y * e.x
        guard abs(cross) > 0.15 else { return nil }
        let t = ((q.x - p.x) * e.y - (q.y - p.y) * e.x) / cross
        return CGPoint(x: p.x + d.x * t, y: p.y + d.y * t)
    }

    // MARK: - 规整

    static func snapLine(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        let angle = atan2(b.y - a.y, b.x - a.x) * 180 / .pi
        let snapped = (angle / 90).rounded() * 90
        guard abs(angle - snapped) < snapDegrees else { return b }
        let r = distance(a, b), t = snapped * .pi / 180
        return CGPoint(x: a.x + r * cos(t), y: a.y + r * sin(t))
    }

    /// 四个角都接近直角时变成矩形（边长接近时为正方形），边接近水平时摆正
    private static func regularizeQuad(_ v: [CGPoint]) -> [CGPoint] {
        let angles = (0..<4).map { i -> CGFloat in
            let a = v[(i + 3) % 4], b = v[i], c = v[(i + 1) % 4]
            let u = CGPoint(x: a.x - b.x, y: a.y - b.y), w = CGPoint(x: c.x - b.x, y: c.y - b.y)
            let cosv = (u.x * w.x + u.y * w.y) / max(hypot(u.x, u.y) * hypot(w.x, w.y), 0.001)
            return acos(min(max(cosv, -1), 1)) * 180 / .pi
        }
        guard angles.allSatisfy({ abs($0 - 90) < 18 }) else { return v }
        // 以最长边的方向为矩形方向
        let edges = (0..<4).map { (v[$0], v[($0 + 1) % 4]) }
        let longest = edges.max { distance($0.0, $0.1) < distance($1.0, $1.1) }!
        var theta = atan2(longest.1.y - longest.0.y, longest.1.x - longest.0.x)
        let deg = theta * 180 / .pi
        let snapped = (deg / 90).rounded() * 90
        if abs(deg - snapped) < snapDegrees { theta = snapped * .pi / 180 }
        let c = CGPoint(x: v.map(\.x).reduce(0, +) / 4, y: v.map(\.y).reduce(0, +) / 4)
        let (cs, sn) = (cos(theta), sin(theta))
        let local = v.map { p -> CGPoint in
            let d = CGPoint(x: p.x - c.x, y: p.y - c.y)
            return CGPoint(x: d.x * cs + d.y * sn, y: -d.x * sn + d.y * cs)
        }
        var hw = local.map { abs($0.x) }.reduce(0, +) / 4
        var hh = local.map { abs($0.y) }.reduce(0, +) / 4
        if min(hw, hh) / max(hw, hh) > 0.88 { hw = (hw + hh) / 2; hh = hw }
        // 保持原来的顶点顺序（按各点所在象限）
        return local.map { p in
            let x = (p.x >= 0 ? hw : -hw), y = (p.y >= 0 ? hh : -hh)
            return CGPoint(x: c.x + x * cs - y * sn, y: c.y + x * sn + y * cs)
        }
    }

    // MARK: - 椭圆

    struct Ellipse { var center: CGPoint; var rx: CGFloat; var ry: CGFloat; var angle: CGFloat }

    /// 按点的协方差求主轴，再用各点在主轴上的投影估计半轴长
    static func fitEllipse(_ pts: [CGPoint]) -> Ellipse? {
        guard pts.count >= 8 else { return nil }
        let n = CGFloat(pts.count)
        let c = CGPoint(x: pts.map(\.x).reduce(0, +) / n, y: pts.map(\.y).reduce(0, +) / n)
        var sxx: CGFloat = 0, syy: CGFloat = 0, sxy: CGFloat = 0
        for p in pts {
            let dx = p.x - c.x, dy = p.y - c.y
            sxx += dx * dx; syy += dy * dy; sxy += dx * dy
        }
        var angle = 0.5 * atan2(2 * sxy, sxx - syy)
        let (cs, sn) = (cos(angle), sin(angle))
        let us = pts.map { ($0.x - c.x) * cs + ($0.y - c.y) * sn }
        let vs = pts.map { -($0.x - c.x) * sn + ($0.y - c.y) * cs }
        // 均匀分布在椭圆上的点，投影的均方根 = 半轴 / √2
        var rx = sqrt(us.map { $0 * $0 }.reduce(0, +) / n * 2)
        var ry = sqrt(vs.map { $0 * $0 }.reduce(0, +) / n * 2)
        guard rx > 1, ry > 1 else { return nil }
        if min(rx, ry) / max(rx, ry) > 0.85 {
            let r = (rx + ry) / 2
            rx = r; ry = r; angle = 0
        } else {
            let deg = angle * 180 / .pi
            let snapped = (deg / 90).rounded() * 90
            if abs(deg - snapped) < snapDegrees { angle = snapped * .pi / 180 }
        }
        return Ellipse(center: c, rx: rx, ry: ry, angle: angle)
    }

    private static func meanDistance(_ pts: [CGPoint], toEllipse e: Ellipse) -> CGFloat {
        let (cs, sn) = (cos(e.angle), sin(e.angle))
        let total = pts.reduce(CGFloat(0)) { sum, p in
            let u = (p.x - e.center.x) * cs + (p.y - e.center.y) * sn
            let v = -(p.x - e.center.x) * sn + (p.y - e.center.y) * cs
            let r = sqrt(u * u / (e.rx * e.rx) + v * v / (e.ry * e.ry))
            // 沿径向到椭圆的近似距离
            return sum + abs(r - 1) * hypot(u, v) / max(r, 0.001)
        }
        return total / CGFloat(pts.count)
    }

    // MARK: - 多边形

    private static func meanDistance(_ pts: [CGPoint], toPath v: [CGPoint]) -> CGFloat {
        let segments = Array(zip(v, v.dropFirst()))
        guard !segments.isEmpty else { return .infinity }
        let total = pts.reduce(CGFloat(0)) { sum, p in sum + segments.map { segmentDistance(p, $0.0, $0.1) }.min()! }
        return total / CGFloat(pts.count)
    }

    static func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return distance(p, a) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2, 0), 1)
        return distance(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    /// Douglas–Peucker 化简（保留首尾）
    static func simplify(_ pts: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard pts.count > 2, let a = pts.first, let b = pts.last else { return pts }
        var maxD: CGFloat = 0, index = 0
        for i in 1..<(pts.count - 1) {
            let d = segmentDistance(pts[i], a, b)
            if d > maxD { maxD = d; index = i }
        }
        guard maxD > epsilon else { return [a, b] }
        let left = simplify(Array(pts[...index]), epsilon: epsilon)
        let right = simplify(Array(pts[index...]), epsilon: epsilon)
        return left.dropLast() + right
    }

    // MARK: - 工具

    private static func dedup(_ pts: [CGPoint]) -> [CGPoint] {
        var out: [CGPoint] = []
        for p in pts where out.last.map({ distance($0, p) > 0.5 }) ?? true { out.append(p) }
        return out
    }

    private static func bounds(_ pts: [CGPoint]) -> CGRect {
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}

nonisolated private extension RecognizedShape {
    static func ellipse(e: ShapeRecognizer.Ellipse) -> RecognizedShape {
        .ellipse(center: e.center, rx: e.rx, ry: e.ry, angle: e.angle)
    }
}
