import CoreGraphics
import Foundation

/// 按天分文件的 JSONL 日志：每行一个 JSON 事件，存在 Documents/<folder>/<prefix>-YYYY-MM-DD.jsonl。
/// 笔迹日志（InkLog）和操作日志（ActivityLog）共用；两者的 session 相同，可以按时间对起来。
nonisolated final class JSONLLog: @unchecked Sendable {
    /// 本次启动的标识，写在每条事件上
    static let sessionID = String(UUID().uuidString.prefix(8).lowercased())

    let directory: URL
    private let prefix: String
    /// 保留天数；nil 表示不删
    private let keepDays: Int?
    /// 开关存在 UserDefaults 的键；nil 表示总是记录
    private let enabledKey: String?
    /// 每次启动第一条 session_start 事件里附加的字段
    private let headerFields: [String: Any]
    private let queue: DispatchQueue
    /// 只在 queue 上读写
    private var headerWritten = false

    init(folder: String, prefix: String, keepDays: Int?, enabledKey: String?, headerFields: [String: Any] = [:]) {
        directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: folder)
        self.prefix = prefix
        self.keepDays = keepDays
        self.enabledKey = enabledKey
        self.headerFields = headerFields
        queue = DispatchQueue(label: "log.\(prefix)", qos: .utility)
    }

    var enabled: Bool {
        guard let enabledKey else { return true }
        return UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private nonisolated(unsafe) static let timeFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// 写一条事件。fields 里的数值、字符串、布尔、数组、字典都可以
    func write(_ event: String, _ fields: [String: Any] = [:]) {
        guard enabled else { return }
        let now = Date()
        var record: [String: Any] = [
            "t": Self.timeFormatter.string(from: now),
            "mono_s": ProcessInfo.processInfo.systemUptime,
            "session": Self.sessionID,
            "event": event,
        ]
        for (k, v) in fields { record[k] = Self.sanitize(v) }
        let day = Self.dayFormatter.string(from: now)
        // 在调用线程上序列化好，后台队列只负责追加写文件
        guard let line = Self.encode(record) else { return }
        queue.async { [self] in
            if !headerWritten {
                headerWritten = true
                if let header = Self.encode(headerRecord(now)) { appendLine(header, day: day) }
                pruneOldFiles()
            }
            appendLine(line, day: day)
        }
    }

    private static func encode(_ record: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(record),
              let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return nil }
        return data
    }

    private func headerRecord(_ now: Date) -> [String: Any] {
        let info = Bundle.main.infoDictionary ?? [:]
        var sys = utsname()
        uname(&sys)
        let machine = withUnsafeBytes(of: &sys.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let base: [String: Any] = [
            "t": Self.timeFormatter.string(from: now),
            "session": Self.sessionID,
            "event": "session_start",
            "app_version": info["CFBundleShortVersionString"] as? String ?? "",
            "app_build": info["CFBundleVersion"] as? String ?? "",
            "device_model": machine,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        return base.merging(headerFields.mapValues(Self.sanitize)) { old, _ in old }
    }

    private func appendLine(_ data: Data, day: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(prefix)-\(day).jsonl")
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data("\n".utf8))
    }

    private func pruneOldFiles() {
        guard let keepDays else { return }
        let cutoff = Date().addingTimeInterval(-Double(keepDays) * 86400)
        for f in files() {
            let name = f.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "\(prefix)-", with: "")
            if let d = Self.dayFormatter.date(from: name), d < cutoff { try? FileManager.default.removeItem(at: f) }
        }
    }

    /// 转成 JSON 能表示的值：CGFloat/Double 保留 3 位小数，非有限数记为字符串
    private static func sanitize(_ v: Any) -> Any {
        switch v {
        case let d as Double: return d.isFinite ? (d * 1000).rounded() / 1000 : String(describing: d)
        case let c as CGFloat: return sanitize(Double(c))
        case let f as Float: return sanitize(Double(f))
        case let i as Int: return i
        case let b as Bool: return b
        case let s as String: return s
        case let s as Substring: return String(s)
        case let a as [Any]: return a.map(sanitize)
        case let m as [String: Any]: return m.mapValues(sanitize)
        case let r as CGRect: return [sanitize(r.minX), sanitize(r.minY), sanitize(r.width), sanitize(r.height)]
        case let p as CGPoint: return [sanitize(p.x), sanitize(p.y)]
        case let s as CGSize: return [sanitize(s.width), sanitize(s.height)]
        default: return String(describing: v)
        }
    }

    // MARK: - 设置页用

    /// 日志文件，新的在前
    func files() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func totalSize() -> Int {
        files().reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func clear() {
        queue.sync {
            for f in files() { try? FileManager.default.removeItem(at: f) }
            headerWritten = false
        }
    }
}

/// 操作日志：App 前后台切换、切换标签页、题目和讲解的停留、AI 请求与重试、状态标注等，
/// 用来事后还原学习过程、分析学习状态。存在 Documents/ActivityLogs/，不自动删除。
/// 笔迹、手势、画布等书写细节记在 InkLog。
nonisolated enum ActivityLog {
    private static let log = JSONLLog(folder: "ActivityLogs", prefix: "activity", keepDays: nil, enabledKey: nil)

    static func write(_ event: String, _ fields: [String: Any] = [:]) { log.write(event, fields) }

    /// 把 AI 请求诊断（LLMClient 的 diagnostics）写进操作日志；context（题号、用途等）附在每条 llm_* 事件上，便于和业务事件对上
    static func llmSink(_ context: [String: Any]) -> (String, [String: Any]) -> Void {
        { event, fields in write(event, context.merging(fields) { _, new in new }) }
    }

    static func logFiles() -> [URL] { log.files() }
    static func totalSize() -> Int { log.totalSize() }
}

/// 一段停留（题目或讲解在屏幕上、App 在前台）：结束时写一条带时长的事件。
/// fields 在开始和结束时各取一次：结束时的直接写进事件，开始时的放在 start 下，
/// 用来看这段时间里有没有提交、看答案等（例如打开题目、没提交就离开）
final class ActivitySpan {
    private let event: String
    private var startedAt: Date?
    private var atStart: [String: Any] = [:]

    init(_ event: String) {
        self.event = event
    }

    /// 可以重复调用同一个值，只在开始、结束时生效
    func update(active: Bool, _ fields: @autoclosure () -> [String: Any]) {
        if active, startedAt == nil {
            startedAt = .now
            atStart = fields()
        } else if !active, let start = startedAt {
            startedAt = nil
            var f = fields()
            f["seconds"] = Date.now.timeIntervalSince(start)
            f["start"] = atStart
            ActivityLog.write(event, f)
        }
    }
}
