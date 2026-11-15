import PencilKit
import UIKit

// 主观题笔迹的详细记录。书写本身复用草稿画布（DraftCanvas，含涂抹即擦除、缩放、工具栏），
// 画布显示在主观题页面上时额外挂一个 SubjectiveInkRecorder，把每一笔、每次擦除/撤销/重做
// 和 Pencil 原始采样追加写入 Documents/SubjectiveWork/<书>/<题>/events.jsonl。
// 目前只存储，不分析。编码和写文件都在后台串行队列，不占用书写时的主线程。
// 坐标一律是页面坐标（与 PKDrawing 相同，不受页面缩放影响），单位 pt。

/// 主观题记录用到的题目信息
nonisolated struct SubjectiveRecordContext: Sendable, Equatable {
    let packID: String
    let sectionID: String
    let questionID: String
}

// MARK: - 事件文件

nonisolated enum SubjectiveInkLog {
    static let schemaVersion = 2
    static let sessionID = UUID().uuidString.prefix(8).lowercased()
    private static let queue = DispatchQueue(label: "subjective.ink", qos: .utility)

    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "SubjectiveWork")
    }

    static func folder(_ ctx: SubjectiveRecordContext) -> URL {
        root.appending(path: safe(ctx.packID)).appending(path: safe(ctx.questionID))
    }

    private static func safe(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
    }

    private struct Envelope<P: Encodable>: Encodable {
        let schema_version: Int
        let event: String
        let pack_id: String
        let section_id: String
        let question_id: String
        let session_id: String
        let t_epoch_s: Double
        let t_uptime_s: Double
        let data: P
    }

    /// 追加一条事件。payload 在后台队列编码
    static func write<P: Encodable & Sendable>(_ event: String, _ ctx: SubjectiveRecordContext, _ payload: P) {
        let epoch = Date().timeIntervalSince1970
        let uptime = ProcessInfo.processInfo.systemUptime
        let session = String(sessionID)
        queue.async {
            let env = Envelope(schema_version: schemaVersion, event: event, pack_id: ctx.packID,
                               section_id: ctx.sectionID, question_id: ctx.questionID, session_id: session,
                               t_epoch_s: epoch, t_uptime_s: uptime, data: payload)
            guard let line = try? encoder.encode(env) else { return }
            append(line + Data("\n".utf8), to: folder(ctx).appending(path: "events.jsonl"))
        }
    }

    /// 笔画 id 表：保证同一笔在不同次打开之间 id 不变
    static func loadStrokeIndex(_ ctx: SubjectiveRecordContext) -> [StrokeIndexEntry] {
        queue.sync {
            guard let data = try? Data(contentsOf: folder(ctx).appending(path: "strokes.json")) else { return [] }
            return (try? JSONDecoder().decode([StrokeIndexEntry].self, from: data)) ?? []
        }
    }

    static func saveStrokeIndex(_ entries: [StrokeIndexEntry], _ ctx: SubjectiveRecordContext) {
        queue.async {
            guard let data = try? JSONEncoder().encode(entries) else { return }
            write(data, to: folder(ctx).appending(path: "strokes.json"))
        }
    }

    /// 离开页面时存一份完整的 PKDrawing，事件日志之外可直接恢复
    static func saveSnapshot(_ data: Data, _ ctx: SubjectiveRecordContext) {
        queue.async { write(data, to: folder(ctx).appending(path: "final.drawing")) }
    }

    /// 清除某些题的全部记录（测试用）
    static func delete(packID: String, questionIDs: [String]) {
        queue.async {
            for q in questionIDs {
                try? FileManager.default.removeItem(
                    at: folder(SubjectiveRecordContext(packID: packID, sectionID: "", questionID: q)))
            }
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }()

    private static func append(_ data: Data, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: data)
    }

    private static func write(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - 记录结构

nonisolated struct StrokeIndexEntry: Codable, Sendable {
    let id: String
    let core: String
    let full: String
}

nonisolated struct StrokePointRecord: Codable, Sendable {
    let x: Double, y: Double
    /// 相对本笔开始的秒数
    let t: Double
    let force: Double, azimuth: Double, altitude: Double
    let w: Double, h: Double, opacity: Double
}

nonisolated struct StrokeRecord: Codable, Sendable {
    let stroke_id: String
    /// 像素橡皮擦把一笔切成几段时，新段来自哪一笔
    let split_from: String?
    /// 本笔开始的绝对时间
    let created_at_epoch_s: Double
    let ink_type: String
    let color_rgba: [Double]
    let transform: [Double]
    /// 被像素橡皮擦遮住后仍可见的参数区间；nil 表示整笔可见
    let visible_ranges: [[Double]]?
    let render_bounds: [Double]
    let points: [StrokePointRecord]
    /// 单笔 PKDrawing 的完整序列化，可无损还原
    let pk_stroke_base64: String
}

nonisolated struct StrokeModification: Codable, Sendable {
    let stroke_id: String
    let transform: [Double]
    let visible_ranges: [[Double]]?
    let ink_type: String
    let color_rgba: [Double]
    let render_bounds: [Double]
}

nonisolated struct DrawingChangePayload: Codable, Sendable {
    /// draw / scribble_erase / eraser / lasso / undo / redo / cleared
    let reason: String
    let tool: String
    let added: [StrokeRecord]
    let removed_stroke_ids: [String]
    let modified: [StrokeModification]
    let stroke_count: Int
    let page_size: [Double]
}

nonisolated struct PencilSampleRecord: Codable, Sendable {
    let t_epoch_s: Double
    let t_uptime_s: Double
    let x: Double, y: Double
    let force: Double, max_force: Double
    let altitude: Double, azimuth: Double
}

nonisolated struct PencilTracePayload: Codable, Sendable {
    let phase: String
    let tool: String
    let samples: [PencilSampleRecord]
}

nonisolated struct CanvasOpenPayload: Codable, Sendable {
    let stroke_ids: [String]
    /// 打开时已存在、但 id 表里查不到的笔画（例如 id 表写入前 App 被关闭）
    let untracked: [StrokeRecord]
    let page_size: [Double]
}

nonisolated struct SimplePayload: Codable, Sendable {
    var tool: String? = nil
    var stroke_count: Int? = nil
    var page_count: Int? = nil
    var areas: [[Double]]? = nil
    var note: String? = nil
}

// MARK: - 记录器

/// 挂在草稿画布协调器上：维护笔画 id，比较前后两次的笔迹，写出增加 / 删除 / 修改。
/// 比较只用笔画的创建时间、点数、首点、变换、遮罩等轻量特征，不做序列化。
@MainActor
final class SubjectiveInkRecorder {
    let ctx: SubjectiveRecordContext
    private var entries: [StrokeIndexEntry] = []
    private var trace: PencilTraceRecognizer?

    init(_ ctx: SubjectiveRecordContext) { self.ctx = ctx }

    func open(_ canvas: PencilOnlyCanvas) {
        let saved = SubjectiveInkLog.loadStrokeIndex(ctx)
        var pool: [String: [StrokeIndexEntry]] = [:]
        for e in saved { pool[e.full, default: []].append(e) }
        var untracked: [StrokeRecord] = []
        entries = canvas.drawing.strokes.map { s in
            let (core, full) = Self.keys(s)
            if var list = pool[full], !list.isEmpty {
                let e = list.removeFirst()
                pool[full] = list
                return e
            }
            let e = StrokeIndexEntry(id: UUID().uuidString, core: core, full: full)
            untracked.append(Self.record(s, id: e.id, splitFrom: nil))
            return e
        }
        SubjectiveInkLog.saveStrokeIndex(entries, ctx)
        SubjectiveInkLog.write("canvas_open", ctx, CanvasOpenPayload(
            stroke_ids: entries.map(\.id), untracked: untracked, page_size: Self.size(canvas.pageSize)))

        let r = PencilTraceRecognizer()
        r.space = canvas.superview
        r.onFinish = { [weak self, weak canvas] phase, samples in
            guard let self, let canvas else { return }
            SubjectiveInkLog.write("pencil_trace", self.ctx,
                                   PencilTracePayload(phase: phase, tool: Self.toolName(canvas.tool), samples: samples))
        }
        // 画布不接收触摸，采样手势和书写手势一样挂到外层页面上
        (canvas.superview as? DraftCanvasContainer)?.addInputRecognizer(r)
        trace = r
    }

    func close(_ canvas: PencilOnlyCanvas) {
        if let trace { (canvas.superview as? DraftCanvasContainer)?.removeInputRecognizer(trace) }
        trace = nil
        SubjectiveInkLog.write("canvas_close", ctx, SimplePayload(stroke_count: canvas.drawing.strokes.count))
        if !canvas.drawing.strokes.isEmpty {
            SubjectiveInkLog.saveSnapshot(canvas.drawing.dataRepresentation(), ctx)
        }
    }

    func event(_ name: String, _ payload: SimplePayload = SimplePayload()) {
        SubjectiveInkLog.write(name, ctx, payload)
    }

    /// 与上次比较并写出变化；没有变化时什么都不写
    func sync(_ canvas: PencilOnlyCanvas, reason explicit: String? = nil) {
        let strokes = canvas.drawing.strokes
        let keys = strokes.map(Self.keys)
        var byFull: [String: [Int]] = [:]
        var byCore: [String: [Int]] = [:]
        for (i, e) in entries.enumerated() {
            byFull[e.full, default: []].append(i)
            byCore[e.core, default: []].append(i)
        }
        var used = Set<Int>()
        var next: [StrokeIndexEntry?] = Array(repeating: nil, count: strokes.count)
        // 1. 完全相同
        for (j, k) in keys.enumerated() {
            if let i = byFull[k.full]?.first(where: { !used.contains($0) }) {
                used.insert(i)
                next[j] = entries[i]
            }
        }
        var added: [StrokeRecord] = []
        var modified: [StrokeModification] = []
        // 2. 同一笔被移动、改色或被像素橡皮擦局部擦除
        for (j, k) in keys.enumerated() where next[j] == nil {
            let candidates = byCore[k.core] ?? []
            if let i = candidates.first(where: { !used.contains($0) }) {
                used.insert(i)
                let e = StrokeIndexEntry(id: entries[i].id, core: k.core, full: k.full)
                next[j] = e
                modified.append(Self.modification(strokes[j], id: e.id))
            } else {
                // 3. 新笔画；与已有笔画同源的是像素橡皮擦切出来的一段
                let e = StrokeIndexEntry(id: UUID().uuidString, core: k.core, full: k.full)
                next[j] = e
                added.append(Self.record(strokes[j], id: e.id, splitFrom: candidates.first.map { entries[$0].id }))
            }
        }
        let removed = entries.indices.filter { !used.contains($0) }.map { entries[$0].id }
        guard !added.isEmpty || !removed.isEmpty || !modified.isEmpty else { return }
        entries = next.compactMap { $0 }
        SubjectiveInkLog.saveStrokeIndex(entries, ctx)

        let reason: String
        if let explicit {
            reason = explicit
        } else if canvas.undoManager?.isUndoing == true {
            reason = "undo"
        } else if canvas.undoManager?.isRedoing == true {
            reason = "redo"
        } else {
            reason = canvas.tool is PKEraserTool ? "eraser" : (canvas.tool is PKLassoTool ? "lasso" : "draw")
        }
        SubjectiveInkLog.write("drawing_change", ctx, DrawingChangePayload(
            reason: reason, tool: Self.toolName(canvas.tool), added: added, removed_stroke_ids: removed,
            modified: modified, stroke_count: strokes.count, page_size: Self.size(canvas.pageSize)))
    }

    // MARK: 特征与记录

    /// core：同一笔的不变特征（创建时间、点数、首点）；full：再加上变换、遮罩、墨水
    private static func keys(_ s: PKStroke) -> (core: String, full: String) {
        let p = s.path
        let first = p.first?.location ?? .zero
        let core = String(format: "%.6f|%d|%.2f,%.2f", p.creationDate.timeIntervalSinceReferenceDate, p.count,
                          first.x, first.y)
        let t = s.transform
        let ranges = s.maskedPathRanges.map { String(format: "%.3f-%.3f", $0.lowerBound, $0.upperBound) }
            .joined(separator: ",")
        let full = core + String(format: "|%.3f,%.3f,%.3f,%.3f,%.2f,%.2f|", t.a, t.b, t.c, t.d, t.tx, t.ty)
            + (s.mask == nil ? "-" : ranges) + "|" + s.ink.inkType.rawValue + "|" + colorKey(s.ink.color)
        return (core, full)
    }

    private static func colorKey(_ c: UIColor) -> String {
        rgba(c).map { String(format: "%.3f", $0) }.joined(separator: ",")
    }

    private static func rgba(_ c: UIColor) -> [Double] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b, a].map(Double.init)
    }

    private static func transform(_ t: CGAffineTransform) -> [Double] {
        [t.a, t.b, t.c, t.d, t.tx, t.ty].map(Double.init)
    }

    private static func visibleRanges(_ s: PKStroke) -> [[Double]]? {
        s.mask == nil ? nil : s.maskedPathRanges.map { [Double($0.lowerBound), Double($0.upperBound)] }
    }

    private static func rect(_ r: CGRect) -> [Double] {
        [r.minX, r.minY, r.width, r.height].map(Double.init)
    }

    static func size(_ s: CGSize) -> [Double] { [Double(s.width), Double(s.height)] }

    private static func record(_ s: PKStroke, id: String, splitFrom: String?) -> StrokeRecord {
        let points = s.path.map { p in
            let loc = p.location.applying(s.transform)
            return StrokePointRecord(x: loc.x, y: loc.y, t: p.timeOffset, force: p.force, azimuth: p.azimuth,
                                     altitude: p.altitude, w: p.size.width, h: p.size.height, opacity: p.opacity)
        }
        return StrokeRecord(
            stroke_id: id, split_from: splitFrom,
            created_at_epoch_s: s.path.creationDate.timeIntervalSince1970,
            ink_type: s.ink.inkType.rawValue, color_rgba: rgba(s.ink.color), transform: transform(s.transform),
            visible_ranges: visibleRanges(s), render_bounds: rect(s.renderBounds), points: points,
            pk_stroke_base64: PKDrawing(strokes: [s]).dataRepresentation().base64EncodedString())
    }

    private static func modification(_ s: PKStroke, id: String) -> StrokeModification {
        StrokeModification(stroke_id: id, transform: transform(s.transform), visible_ranges: visibleRanges(s),
                           ink_type: s.ink.inkType.rawValue, color_rgba: rgba(s.ink.color),
                           render_bounds: rect(s.renderBounds))
    }

    static func toolName(_ tool: PKTool) -> String {
        switch tool {
        case let t as PKInkingTool: "ink:\(t.inkType.rawValue):\(String(format: "%.2f", t.width))"
        case let t as PKEraserTool: t.eraserType == .vector ? "eraser:vector" : "eraser:bitmap"
        case is PKLassoTool: "lasso"
        default: String(describing: type(of: tool))
        }
    }
}

// MARK: - Pencil 原始采样

/// 不拦截触摸、不影响 PencilKit，只收集 Pencil 的原始采样（含合并采样）。
/// 坐标换算到页面坐标：画布的父视图（DraftCanvasContainer）就是整页大小。
private final class PencilTraceRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onFinish: ((String, [PencilSampleRecord]) -> Void)?
    private var samples: [PencilSampleRecord] = []

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    convenience init() { self.init(target: nil, action: nil) }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool {
        true
    }

    /// 页面坐标空间（草稿画布容器，整页大小）
    weak var space: UIView?

    private func collect(_ touches: Set<UITouch>, _ event: UIEvent) {
        let space = self.space ?? view
        let offset = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
        for touch in touches where touch.type == .pencil {
            for s in event.coalescedTouches(for: touch) ?? [touch] {
                let p = s.location(in: space)
                samples.append(PencilSampleRecord(
                    t_epoch_s: offset + s.timestamp, t_uptime_s: s.timestamp, x: p.x, y: p.y,
                    force: s.force, max_force: s.maximumPossibleForce, altitude: s.altitudeAngle,
                    azimuth: s.azimuthAngle(in: space)))
            }
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        samples = []
        collect(touches, event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { collect(touches, event) }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        collect(touches, event)
        finish("ended")
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        collect(touches, event)
        finish("cancelled")
    }

    private func finish(_ phase: String) {
        if !samples.isEmpty { onFinish?(phase, samples) }
        samples = []
        state = .failed
    }

    override func reset() { samples = [] }
}
