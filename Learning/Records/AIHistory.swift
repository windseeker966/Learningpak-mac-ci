import Foundation

/// 每次重新批改追加一条，保留之前的批改内容。
nonisolated struct SavedGrading: Codable, Identifiable {
    var id = UUID()
    var createdAt = Date.now
    var model: String
    var text = ""
    var completed = false
    var error: String?
    var usage: LLMUsage? = nil
    /// 从批改末尾的 JSON 解析出的各问结论
    var verdicts: [GradingVerdict]? = nil
    /// 发给 AI 的笔画数、最晚一笔的落笔时间；看答案后补写、未发给 AI 的笔画数
    var strokeCount: Int? = nil
    var latestStroke: Date? = nil
    var excludedStrokes: Int? = nil
}

/// AI 批改对一问的结论
nonisolated struct GradingVerdict: Codable {
    var label: String
    /// correct | partial | wrong | blank | unclear
    var result: String
    /// 没写出或写错的得分点
    var missing: [String]?
    var note: String?

    var partResult: PartResult? { result == "skipped" ? nil : PartResult(rawValue: result) }

    private static let fence = "```json"

    /// 批改正文去掉末尾的 JSON 块（生成中未写完的也去掉），供显示
    static func displayText(_ text: String) -> String {
        guard let r = text.range(of: fence, options: .backwards) else { return text }
        var shown = String(text[..<r.lowerBound])
        if let h = shown.range(of: "## 结构化结果", options: .backwards) { shown = String(shown[..<h.lowerBound]) }
        return shown.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 解析批改末尾 ```json … ``` 中的 {"parts": [...]}
    static func parse(_ text: String) -> [GradingVerdict]? {
        struct Wrapper: Decodable { let parts: [GradingVerdict] }
        return TrailingJSON.decode(Wrapper.self, from: text)?.parts
    }
}

/// AI 回答末尾供程序读取的 ```json … ``` 块（显示时用 GradingVerdict.displayText 去掉）
nonisolated enum TrailingJSON {
    static func decode<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        guard let r = text.range(of: "```json", options: .backwards) else { return nil }
        let rest = text[r.upperBound...]
        let body = rest.range(of: "```").map { rest[..<$0.lowerBound] } ?? rest
        return try? JSONDecoder().decode(T.self, from: Data(body.utf8))
    }
}
