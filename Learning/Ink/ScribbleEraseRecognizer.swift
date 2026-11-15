import CoreGraphics
import Foundation

// 「涂抹即擦除」识别器：从 Saber（Flutter，GPL-3.0）lib/data/tools/scribble_erase_recognizer.dart
// recognizer_version 6 逐行移植。阈值、判定档位与顺序保持一致，便于对照原来的实机调参记录。
// 与原版的差异：坐标单位是 PencilKit 画布的 pt（页面不缩放，canvasScale 固定为 1）；
// 时间来自 PKStrokePoint.timeOffset（秒）；旧笔迹的「可见路径与矩形相交」用 InkTarget.intersects 近似。
// 本地新增 dense 档（version 7）：中文字近似方形、字小，原版要求的长条形/大尺寸/尖锐折返常常不满足。
// dense 不看形状，改以「紧贴旧墨迹的比例」为主要依据——写新字几乎都落在空白处；删除时也只删真正被盖住的笔画。
// version 8：连笔汉字（讠、弓、乙、与等之字形）尖角多、沿主方向只来回 2～4 次，曾被 dense 误删；
// dense 改为只看沿主方向的来回（≥ 5 次），删除改按笔画有多少落在涂抹路径附近（真正被盖住），不再按包围盒。

enum ScribbleEraseReason: String {
    case tooFewSamples, tooShort, tooSlow, tooLong
    case tooFewSharpReversals, tooFewBacktrackReversals, tooFewAxisReversals
    case tooSparse, tooLowSweepRate, tooMuchNetTravel
    case notEnoughInkOverlap, awaitingPenUp, commit
}

enum ScribbleEraseProfile: String {
    case compact, broad, coverage, dense
}

struct ScribbleEraseFeatures {
    let duration: TimeInterval
    let rawPointCount: Int
    let sampledPointCount: Int
    let pathLength: CGFloat
    let bounds: CGRect
    let density: CGFloat
    let netTravelRatio: CGFloat
    let averageSpeed: CGFloat
    let sharpReversals: Int
    let backtrackReversals: Int
    let axisReversals: Int
    let sweepRate: CGFloat
    let visualBoundsWidth: CGFloat
    let visualBoundsHeight: CGFloat
    let inkHitSegments: Int
    let inkHitStrokes: Int
    let inkHitRatio: CGFloat
    let coverageScore: Int
    /// dense 档：按紧贴距离（笔宽一半 + 2pt）测得的命中
    let tightHitSegments: Int
    let tightHitStrokes: Int
    let tightHitRatio: CGFloat
}

struct ScribbleEraseEvaluation {
    let reason: ScribbleEraseReason
    let features: ScribbleEraseFeatures
    let profile: ScribbleEraseProfile?
    let inkOverlapMeasured: Bool

    var shouldCommit: Bool { reason == .commit }

    var isPlausibleCandidate: Bool {
        features.pathLength >= 40 && (features.sharpReversals >= 2 || features.axisReversals >= 2)
    }

    /// 日志字段（与 Saber 的 _scribbleFeatureFields 同名，便于对照）
    var logFields: [String: Any] {
        let f = features
        return [
            "decision": reason.rawValue,
            "recognition_profile": profile?.rawValue ?? "none",
            "recognition_duration_ms": f.duration * 1000,
            "raw_points": f.rawPointCount,
            "sampled_points": f.sampledPointCount,
            "path_length_px": f.pathLength,
            "bbox_left": f.bounds.minX, "bbox_top": f.bounds.minY,
            "bbox_right": f.bounds.maxX, "bbox_bottom": f.bounds.maxY,
            "bbox_width": f.bounds.width, "bbox_height": f.bounds.height,
            "density": f.density,
            "net_travel_ratio": f.netTravelRatio,
            "average_speed_px_s": f.averageSpeed,
            "sharp_reversals": f.sharpReversals,
            "backtrack_reversals": f.backtrackReversals,
            "axis_reversals": f.axisReversals,
            "sweep_rate_per_s": f.sweepRate,
            "visual_bbox_width_px": f.visualBoundsWidth,
            "visual_bbox_height_px": f.visualBoundsHeight,
            "ink_hit_segments": f.inkHitSegments,
            "ink_hit_strokes": f.inkHitStrokes,
            "ink_hit_ratio": f.inkHitRatio,
            "coverage_score": f.coverageScore,
            "ink_overlap_measured": inkOverlapMeasured,
            "tight_hit_segments": f.tightHitSegments,
            "tight_hit_strokes": f.tightHitStrokes,
            "tight_hit_ratio": f.tightHitRatio,
        ]
    }
}

/// 识别器眼中的一条旧笔迹：可见范围 + 「可见墨迹是否碰到某矩形」
struct InkTarget {
    let id: Int
    let visibleBounds: CGRect
    let intersects: (CGRect) -> Bool
    /// 可见墨迹离折线不超过给定距离的比例（0～1），即被涂抹路径盖住的部分
    let fractionNear: ([CGPoint], CGFloat) -> CGFloat
}

/// Conservative dynamic scratch-out recognizer（见 Saber 原注释）。
/// 手势必须时间上紧凑、反复折返、相对包围盒足够密，并且反复覆盖已有墨迹，才允许擦除。
final class ScribbleEraseRecognizer {
    let penSize: CGFloat
    let canvasScale: CGFloat

    init(penSize: CGFloat, canvasScale: CGFloat = 1) {
        self.penSize = penSize
        self.canvasScale = canvasScale
    }

    nonisolated static let version = 8

    private static let sampleSpacing: CGFloat = 5
    private static let minPathLength: CGFloat = 80
    private static let maxDuration: TimeInterval = 1.5
    private static let slowMaxDuration: TimeInterval = 3.2
    private static let minAverageSpeed: CGFloat = 120
    private static let minSharpReversals = 3
    private static let minBacktrackReversals = 3
    private static let minAxisReversals = 3
    private static let minDensity: CGFloat = 3
    private static let minCompactVisualAspectRatio: CGFloat = 1.6
    private static let minSweepRate: CGFloat = 7
    private static let minBroadVisualLongestSide: CGFloat = 160
    private static let minBroadSharpReversals = 2
    private static let minBroadAxisReversals = 6
    private static let minBroadDensity: CGFloat = 3.5
    private static let minBroadSweepRate: CGFloat = 3.5
    private static let maxBroadNetTravelRatio: CGFloat = 0.35
    private static let minCoverageInkHitRatio: CGFloat = 0.42
    private static let minCoverageInkHitStrokes = 2
    private static let minCoverageVisualLongestSide: CGFloat = 80
    private static let minCoverageVisualAspectRatio: CGFloat = 1.6
    private static let minCoverageAxisReversals = 4
    private static let minCoverageScore = 5
    private static let minCoverageDensity: CGFloat = 3
    private static let minCoverageSweepRate: CGFloat = 3
    private static let maxCoverageNetTravelRatio: CGFloat = 0.35
    private static let maxNetTravelRatio: CGFloat = 0.45
    private static let minInkHitSegments = 2
    private static let minStrokeDeleteHitSegments = 2
    private static let sharpReversalDotThreshold: CGFloat = -0.5
    private static let backtrackReversalDotThreshold: CGFloat = -0.8
    private static let minReversalTravel: CGFloat = 10
    // dense 档
    private static let denseMinPathLength: CGFloat = 60
    private static let denseMaxDuration: TimeInterval = 5
    private static let denseMinAverageSpeed: CGFloat = 80
    private static let denseMinDensity: CGFloat = 3.5
    private static let denseMaxNetTravelRatio: CGFloat = 0.35
    /// 只看沿主方向的来回：连笔字的尖角多，不能作为涂抹的依据
    private static let denseMinAxisReversals = 5
    private static let denseMinTightHitSegments = 4
    private static let denseMinTightHitRatio: CGFloat = 0.3
    private static let denseTightExtra: CGFloat = 2
    /// dense 删除：被碰到且一半以上墨迹被涂抹路径盖住（离路径不超过 半个笔宽 + denseCoverExtra）；
    /// 或命中很多段且至少三成被盖住。只擦到边的笔画（如之字形两侧的字、隔壁字的一横）不删。
    /// 实测小涂抹（≤ 90pt）删掉的笔画，按 8pt 算全部有一半以上被盖住
    private static let denseDeleteMinCovered: CGFloat = 0.5
    private static let denseDeleteManyHits = 6
    private static let denseDeleteManyHitsMinCovered: CGFloat = 0.3
    private static let denseCoverExtra: CGFloat = 7

    private var rawPoints: [CGPoint] = []
    private var rawTimes: [TimeInterval] = []
    private(set) var sampledPoints: [CGPoint] = []
    private var pathLength: CGFloat = 0
    private var bounds: CGRect = .zero
    private var startTime: TimeInterval = 0

    var points: [CGPoint] { rawPoints }

    var eraseRegionPadding: CGFloat { min(max(penSize * 2, 10), 24) }
    var eraseRegionBounds: CGRect { bounds.insetBy(dx: -eraseRegionPadding, dy: -eraseRegionPadding) }

    var tightPadding: CGFloat { penSize / 2 + Self.denseTightExtra }
    var coverDistance: CGFloat { penSize / 2 + Self.denseCoverExtra }

    /// 要删除的笔迹 → 命中段数。原版档位：被实际涂抹路径命中至少 minStrokeDeleteHitSegments 段；
    /// dense：被碰到且大半被涂抹路径盖住（涂小字时不带走旁边的字）
    func strokesInEraseRegion(_ strokes: [InkTarget], profile: ScribbleEraseProfile?) -> [Int: Int] {
        guard profile == .dense else {
            return measureInkOverlap(strokes).hitSegmentsByStroke.filter { $0.value >= Self.minStrokeDeleteHitSegments }
        }
        let byStroke = measureInkOverlap(strokes, padding: tightPadding).hitSegmentsByStroke
        let byID = Dictionary(strokes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return byStroke.filter { id, hits in
            guard let s = byID[id] else { return false }
            let covered = s.fractionNear(sampledPoints, coverDistance)
            return covered >= Self.denseDeleteMinCovered
                || hits >= Self.denseDeleteManyHits && covered >= Self.denseDeleteManyHitsMinCovered
        }
    }

    /// 点到线段的距离
    nonisolated static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        let t = len2 <= 1e-9 ? 0 : min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2, 0), 1)
        return hypot(p.x - a.x - t * dx, p.y - a.y - t * dy)
    }

    var diagnosticThresholds: [String: Any] {
        [
            "recognizer_version": Self.version,
            "threshold_sample_spacing_px": Self.sampleSpacing,
            "threshold_min_path_length_px": max(Self.minPathLength, penSize * 8),
            "threshold_max_duration_ms": Self.maxDuration * 1000,
            "threshold_slow_max_duration_ms": Self.slowMaxDuration * 1000,
            "threshold_min_average_speed_px_s": Self.minAverageSpeed,
            "threshold_min_sharp_reversals": Self.minSharpReversals,
            "threshold_min_backtrack_reversals": Self.minBacktrackReversals,
            "threshold_min_axis_reversals": Self.minAxisReversals,
            "threshold_min_density": Self.minDensity,
            "threshold_min_sweep_rate_per_s": Self.minSweepRate,
            "threshold_compact_min_visual_aspect_ratio": Self.minCompactVisualAspectRatio,
            "threshold_broad_min_visual_longest_side_px": Self.minBroadVisualLongestSide,
            "threshold_broad_min_sharp_reversals": Self.minBroadSharpReversals,
            "threshold_broad_min_axis_reversals": Self.minBroadAxisReversals,
            "threshold_broad_min_density": Self.minBroadDensity,
            "threshold_broad_min_sweep_rate_per_s": Self.minBroadSweepRate,
            "threshold_broad_max_net_travel_ratio": Self.maxBroadNetTravelRatio,
            "threshold_coverage_min_ink_hit_ratio": Self.minCoverageInkHitRatio,
            "threshold_coverage_min_ink_hit_strokes": Self.minCoverageInkHitStrokes,
            "threshold_coverage_min_visual_longest_side_px": Self.minCoverageVisualLongestSide,
            "threshold_coverage_min_visual_aspect_ratio": Self.minCoverageVisualAspectRatio,
            "threshold_coverage_min_axis_reversals": Self.minCoverageAxisReversals,
            "threshold_coverage_min_score": Self.minCoverageScore,
            "threshold_coverage_min_density": Self.minCoverageDensity,
            "threshold_coverage_min_sweep_rate_per_s": Self.minCoverageSweepRate,
            "threshold_coverage_max_net_travel_ratio": Self.maxCoverageNetTravelRatio,
            "threshold_max_net_travel_ratio": Self.maxNetTravelRatio,
            "threshold_min_ink_hit_segments": Self.minInkHitSegments,
            "threshold_min_stroke_delete_hit_segments": Self.minStrokeDeleteHitSegments,
            "threshold_sharp_reversal_dot": Self.sharpReversalDotThreshold,
            "threshold_backtrack_reversal_dot": Self.backtrackReversalDotThreshold,
            "threshold_min_reversal_travel_px": Self.minReversalTravel,
            "threshold_dense_min_path_length_px": max(Self.denseMinPathLength, penSize * 8),
            "threshold_dense_max_duration_ms": Self.denseMaxDuration * 1000,
            "threshold_dense_min_average_speed_px_s": Self.denseMinAverageSpeed,
            "threshold_dense_min_density": Self.denseMinDensity,
            "threshold_dense_max_net_travel_ratio": Self.denseMaxNetTravelRatio,
            "threshold_dense_min_axis_reversals": Self.denseMinAxisReversals,
            "threshold_dense_delete_min_covered": Self.denseDeleteMinCovered,
            "threshold_dense_cover_distance_px": coverDistance,
            "threshold_dense_min_tight_hit_segments": Self.denseMinTightHitSegments,
            "threshold_dense_min_tight_hit_ratio": Self.denseMinTightHitRatio,
            "threshold_dense_tight_padding_px": tightPadding,
            "canvas_scale": safeCanvasScale,
            "erase_region_padding_px": eraseRegionPadding,
        ]
    }

    func start(_ position: CGPoint, time: TimeInterval) {
        startTime = time
        rawPoints = [position]
        rawTimes = [0]
        sampledPoints = [position]
        pathLength = 0
        bounds = CGRect(origin: position, size: .zero)
    }

    @discardableResult
    func update(_ position: CGPoint, time: TimeInterval) -> ScribbleEraseEvaluation {
        if rawPoints.isEmpty { start(position, time: time) }
        let previous = rawPoints[rawPoints.count - 1]
        pathLength += hypot(position.x - previous.x, position.y - previous.y)
        rawPoints.append(position)
        rawTimes.append(max(time - startTime, 0))
        bounds = Self.expand(bounds, position)
        let lastSample = sampledPoints[sampledPoints.count - 1]
        if hypot(position.x - lastSample.x, position.y - lastSample.y) >= Self.sampleSpacing {
            sampledPoints.append(position)
        }
        // 书写过程中只做几何判定；与旧墨迹的相交检测留到抬笔时做一次
        return evaluate([])
    }

    func evaluate(_ existingStrokes: [InkTarget], forceInkOverlap: Bool = false) -> ScribbleEraseEvaluation {
        let duration = self.duration
        let longestSide = max(bounds.width, bounds.height)
        let density = pathLength / max(longestSide, 1)
        let netTravelRatio: CGFloat = rawPoints.count < 2 || pathLength <= 1e-9
            ? 1.0
            : hypot(rawPoints.last!.x - rawPoints.first!.x, rawPoints.last!.y - rawPoints.first!.y) / pathLength
        let seconds = CGFloat(duration)
        let averageSpeed: CGFloat = seconds <= 1e-6 ? 0 : pathLength / seconds
        let sharpReversals = Self.countReversals(sampledPoints, dotThreshold: Self.sharpReversalDotThreshold)
        let backtrackReversals = Self.countReversals(sampledPoints, dotThreshold: Self.backtrackReversalDotThreshold)
        let axisReversals = Self.countMajorAxisReversals(sampledPoints, bounds)
        let sweepRate: CGFloat = seconds <= 1e-6 ? 0 : density / seconds
        let visualW = bounds.width * safeCanvasScale
        let visualH = bounds.height * safeCanvasScale
        let coverageScore = Self.coverageScore(sharpReversals: sharpReversals, backtrackReversals: backtrackReversals,
                                               axisReversals: axisReversals, density: density,
                                               sweepRate: sweepRate, netTravelRatio: netTravelRatio)

        var profile = geometryProfile(duration: duration, sampledPointCount: sampledPoints.count, pathLength: pathLength,
                                      visualW: visualW, visualH: visualH, averageSpeed: averageSpeed,
                                      sharpReversals: sharpReversals, backtrackReversals: backtrackReversals,
                                      axisReversals: axisReversals, density: density, sweepRate: sweepRate,
                                      netTravelRatio: netTravelRatio)

        var inkHitSegments = 0
        var inkHitStrokes = 0
        let coverageProbeReady = forceInkOverlap && self.coverageProbeReady(
            duration: duration, sampledPointCount: sampledPoints.count, pathLength: pathLength,
            visualW: visualW, visualH: visualH, averageSpeed: averageSpeed, axisReversals: axisReversals,
            density: density, sweepRate: sweepRate, netTravelRatio: netTravelRatio, coverageScore: coverageScore)
        let inkOverlapMeasured = forceInkOverlap && (profile != nil || coverageProbeReady)
        if inkOverlapMeasured {
            let overlap = measureInkOverlap(existingStrokes)
            inkHitSegments = overlap.hitSegments
            inkHitStrokes = overlap.hitStrokes
        }
        let inkHitRatio: CGFloat = sampledPoints.count < 2 ? 0 : CGFloat(inkHitSegments) / CGFloat(sampledPoints.count - 1)

        if profile == nil && coverageProbeReady
            && inkHitStrokes >= Self.minCoverageInkHitStrokes && inkHitRatio >= Self.minCoverageInkHitRatio {
            profile = .coverage
        }

        var tight = (hitSegments: 0, hitStrokes: 0)
        if forceInkOverlap && profile == nil && denseProbeReady(
            duration: duration, sampledPointCount: sampledPoints.count, pathLength: pathLength,
            averageSpeed: averageSpeed, axisReversals: axisReversals,
            density: density, netTravelRatio: netTravelRatio) {
            let m = measureInkOverlap(existingStrokes, padding: tightPadding)
            tight = (m.hitSegments, m.hitStrokes)
        }
        let tightRatio: CGFloat = sampledPoints.count < 2 ? 0 : CGFloat(tight.hitSegments) / CGFloat(sampledPoints.count - 1)
        if profile == nil && tight.hitStrokes >= 1 && tight.hitSegments >= Self.denseMinTightHitSegments
            && tightRatio >= Self.denseMinTightHitRatio {
            profile = .dense
        }

        let features = ScribbleEraseFeatures(
            duration: duration, rawPointCount: rawPoints.count, sampledPointCount: sampledPoints.count,
            pathLength: pathLength, bounds: bounds, density: density, netTravelRatio: netTravelRatio,
            averageSpeed: averageSpeed, sharpReversals: sharpReversals, backtrackReversals: backtrackReversals,
            axisReversals: axisReversals, sweepRate: sweepRate, visualBoundsWidth: visualW, visualBoundsHeight: visualH,
            inkHitSegments: inkHitSegments, inkHitStrokes: inkHitStrokes, inkHitRatio: inkHitRatio,
            coverageScore: coverageScore, tightHitSegments: tight.hitSegments, tightHitStrokes: tight.hitStrokes,
            tightHitRatio: tightRatio)
        return ScribbleEraseEvaluation(reason: reasonFor(features, profile, inkOverlapMeasured: inkOverlapMeasured),
                                       features: features, profile: profile, inkOverlapMeasured: inkOverlapMeasured)
    }

    // MARK: - 判定档位

    private func geometryProfile(duration: TimeInterval, sampledPointCount: Int, pathLength: CGFloat,
                                 visualW: CGFloat, visualH: CGFloat, averageSpeed: CGFloat,
                                 sharpReversals: Int, backtrackReversals: Int, axisReversals: Int,
                                 density: CGFloat, sweepRate: CGFloat, netTravelRatio: CGFloat) -> ScribbleEraseProfile? {
        let basicReady = sampledPointCount >= 7 && pathLength >= max(Self.minPathLength, penSize * 8)
            && averageSpeed >= Self.minAverageSpeed
        guard basicReady else { return nil }
        let longest = max(visualW, visualH), shortest = min(visualW, visualH)
        let aspect = longest / max(shortest, 1)
        let compactReady = duration <= Self.maxDuration
            && aspect >= Self.minCompactVisualAspectRatio
            && sharpReversals >= Self.minSharpReversals
            && backtrackReversals >= Self.minBacktrackReversals
            && axisReversals >= Self.minAxisReversals
            && density >= Self.minDensity
            && sweepRate >= Self.minSweepRate
            && netTravelRatio <= Self.maxNetTravelRatio
        if compactReady { return .compact }
        let broadReady = longest >= Self.minBroadVisualLongestSide
            && duration <= Self.slowMaxDuration
            && sharpReversals >= Self.minBroadSharpReversals
            && axisReversals >= Self.minBroadAxisReversals
            && density >= Self.minBroadDensity
            && sweepRate >= Self.minBroadSweepRate
            && netTravelRatio <= Self.maxBroadNetTravelRatio
        return broadReady ? .broad : nil
    }

    private static func coverageScore(sharpReversals: Int, backtrackReversals: Int, axisReversals: Int,
                                      density: CGFloat, sweepRate: CGFloat, netTravelRatio: CGFloat) -> Int {
        var score = 0
        if axisReversals >= 5 { score += 2 }
        if backtrackReversals >= 2 { score += 1 }
        if sharpReversals >= 2 { score += 1 }
        if density >= 3.5 { score += 1 }
        if sweepRate >= 5 { score += 1 }
        if netTravelRatio <= 0.25 { score += 1 }
        return score
    }

    private func coverageProbeReady(duration: TimeInterval, sampledPointCount: Int, pathLength: CGFloat,
                                    visualW: CGFloat, visualH: CGFloat, averageSpeed: CGFloat, axisReversals: Int,
                                    density: CGFloat, sweepRate: CGFloat, netTravelRatio: CGFloat,
                                    coverageScore: Int) -> Bool {
        let longest = max(visualW, visualH), shortest = min(visualW, visualH)
        let aspect = longest / max(shortest, 1)
        return sampledPointCount >= 7
            && pathLength >= max(Self.minPathLength, penSize * 8)
            && longest >= Self.minCoverageVisualLongestSide
            && aspect >= Self.minCoverageVisualAspectRatio
            && duration <= Self.slowMaxDuration
            && averageSpeed >= Self.minAverageSpeed
            && axisReversals >= Self.minCoverageAxisReversals
            && density >= Self.minCoverageDensity
            && sweepRate >= Self.minCoverageSweepRate
            && netTravelRatio <= Self.maxCoverageNetTravelRatio
            && coverageScore >= Self.minCoverageScore
    }

    /// dense 档的几何前提：足够长、沿主方向来回、密、不走远；尺寸与长宽比不限
    private func denseProbeReady(duration: TimeInterval, sampledPointCount: Int, pathLength: CGFloat,
                                 averageSpeed: CGFloat, axisReversals: Int,
                                 density: CGFloat, netTravelRatio: CGFloat) -> Bool {
        sampledPointCount >= 7
            && pathLength >= max(Self.denseMinPathLength, penSize * 8)
            && duration <= Self.denseMaxDuration
            && averageSpeed >= Self.denseMinAverageSpeed
            && axisReversals >= Self.denseMinAxisReversals
            && density >= Self.denseMinDensity
            && netTravelRatio <= Self.denseMaxNetTravelRatio
    }

    private func reasonFor(_ f: ScribbleEraseFeatures, _ profile: ScribbleEraseProfile?,
                           inkOverlapMeasured: Bool) -> ScribbleEraseReason {
        if f.sampledPointCount < 7 { return .tooFewSamples }
        // dense 的全部条件已在判定档位时检查过
        if profile == .dense { return .commit }
        if f.pathLength < max(Self.minPathLength, penSize * 8) { return .tooShort }
        if f.duration > Self.slowMaxDuration { return .tooLong }
        if profile == nil && f.duration > Self.maxDuration { return .tooLong }
        if f.averageSpeed < Self.minAverageSpeed { return .tooSlow }
        if profile == nil && f.sharpReversals < Self.minSharpReversals { return .tooFewSharpReversals }
        if profile == nil && f.backtrackReversals < Self.minBacktrackReversals { return .tooFewBacktrackReversals }
        if f.axisReversals < Self.minAxisReversals { return .tooFewAxisReversals }
        if f.density < Self.minDensity { return .tooSparse }
        if f.sweepRate < Self.minSweepRate && profile == nil { return .tooLowSweepRate }
        if f.netTravelRatio > Self.maxNetTravelRatio { return .tooMuchNetTravel }
        if profile != nil && !inkOverlapMeasured { return .awaitingPenUp }
        if f.inkHitSegments < Self.minInkHitSegments || f.inkHitStrokes == 0 { return .notEnoughInkOverlap }
        return .commit
    }

    // MARK: - 与旧墨迹的相交

    private func measureInkOverlap(_ strokes: [InkTarget], padding: CGFloat? = nil)
        -> (hitSegments: Int, hitStrokes: Int, hitSegmentsByStroke: [Int: Int]) {
        guard sampledPoints.count >= 2, !strokes.isEmpty else { return (0, 0, [:]) }
        let pad = padding ?? eraseRegionPadding
        let overall = bounds.insetBy(dx: -pad, dy: -pad)
        let candidates = strokes.filter { Self.isFinite($0.visibleBounds) && Self.overlaps($0.visibleBounds, overall) }
        guard !candidates.isEmpty else { return (0, 0, [:]) }
        var hitSegments = 0
        var byStroke: [Int: Int] = [:]
        for i in 1..<sampledPoints.count {
            let a = sampledPoints[i - 1], b = sampledPoints[i]
            let seg = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                .insetBy(dx: -pad, dy: -pad)
            var segmentHit = false
            for s in candidates {
                guard Self.overlaps(s.visibleBounds, seg), s.intersects(seg) else { continue }
                segmentHit = true
                byStroke[s.id, default: 0] += 1
            }
            if segmentHit { hitSegments += 1 }
        }
        return (hitSegments, byStroke.count, byStroke)
    }

    // MARK: - 几何工具

    private var duration: TimeInterval {
        guard rawTimes.count >= 2 else { return 0 }
        return max(rawTimes[rawTimes.count - 1] - rawTimes[0], 0)
    }

    private var safeCanvasScale: CGFloat { canvasScale.isFinite && canvasScale > 0 ? canvasScale : 1 }

    private static func countReversals(_ points: [CGPoint], dotThreshold: CGFloat) -> Int {
        guard points.count >= 3 else { return 0 }
        var count = 0
        var travel = CGFloat.infinity
        for i in 2..<points.count {
            let a = CGVector(dx: points[i - 1].x - points[i - 2].x, dy: points[i - 1].y - points[i - 2].y)
            let b = CGVector(dx: points[i].x - points[i - 1].x, dy: points[i].y - points[i - 1].y)
            let ad = hypot(a.dx, a.dy), bd = hypot(b.dx, b.dy)
            travel += bd
            if ad <= 1e-9 || bd <= 1e-9 { continue }
            let dot = (a.dx * b.dx + a.dy * b.dy) / (ad * bd)
            if dot <= dotThreshold && travel >= minReversalTravel {
                count += 1
                travel = 0
            }
        }
        return count
    }

    private static func countMajorAxisReversals(_ points: [CGPoint], _ bounds: CGRect) -> Int {
        guard points.count >= 3 else { return 0 }
        let horizontal = bounds.width >= bounds.height
        var previousSign = 0
        var count = 0
        var travel = CGFloat.infinity
        for i in 1..<points.count {
            let dx = points[i].x - points[i - 1].x, dy = points[i].y - points[i - 1].y
            let projection = horizontal ? dx : dy
            travel += hypot(dx, dy)
            if abs(projection) < 1 { continue }
            let sign = projection > 0 ? 1 : -1
            if previousSign != 0 && sign != previousSign && travel >= minReversalTravel {
                count += 1
                travel = 0
            }
            previousSign = sign
        }
        return count
    }

    private static func expand(_ r: CGRect, _ p: CGPoint) -> CGRect {
        let minX = min(r.minX, p.x), minY = min(r.minY, p.y)
        return CGRect(x: minX, y: minY, width: max(r.maxX, p.x) - minX, height: max(r.maxY, p.y) - minY)
    }

    /// 与 Flutter Rect.overlaps 一致：边缘相接不算重叠
    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        if a.maxX <= b.minX || b.maxX <= a.minX { return false }
        if a.maxY <= b.minY || b.maxY <= a.minY { return false }
        return true
    }

    private static func isFinite(_ r: CGRect) -> Bool {
        r.minX.isFinite && r.minY.isFinite && r.maxX.isFinite && r.maxY.isFinite
    }
}
