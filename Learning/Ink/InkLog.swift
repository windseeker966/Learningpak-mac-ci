import Foundation

/// 笔迹日志：每行一个 JSON（JSONL），按天分文件，存在 Documents/InkLogs/，保留 14 天。
/// 只记书写细节：笔画、手势、画布、缩放、防误触等；学习过程（停留、AI 请求、状态标注）记在 ActivityLog。
/// 在「文件」App › LearningPack › InkLogs 可见，也可以用 devicectl 从 Mac 拉取。
/// 字段命名尽量沿用 Saber DiagnosticLog 的 input_* 事件，便于对照原来的分析方法。
nonisolated enum InkLog {
    private static let log = JSONLLog(folder: "InkLogs", prefix: "ink", keepDays: 14, enabledKey: "ink.logEnabled",
                                      headerFields: ["recognizer_version": ScribbleEraseRecognizer.version])

    /// 写一条事件。fields 里的数值、字符串、布尔、数组、字典都可以
    static func write(_ event: String, _ fields: [String: Any] = [:]) { log.write(event, fields) }

    // MARK: - 设置页用

    static func logFiles() -> [URL] { log.files() }
    static func totalSize() -> Int { log.totalSize() }
    static func clear() { log.clear() }
}
