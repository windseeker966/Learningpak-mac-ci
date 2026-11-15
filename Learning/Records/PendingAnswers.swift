import Foundation

/// 还没提交的作答：离开页面（跳到别的题、返回、切换标签页）、关掉 App 后再打开时接着用。
/// 选择题的选项和填空、答完还没提交的错因、阅读练习和表达练习的键盘输入。
/// 每条存一个 JSON 到 UserDefaults；提交、重新作答时删掉，超过 14 天没动的在启动时清掉（purgeStale）
enum PendingAnswers {
    private static let prefix = "pendingAnswer."
    private static let maxAge: TimeInterval = 14 * 86400

    /// 选择题提交前的作答
    struct Choice: Codable {
        /// Selection.encoded；只看了提示、还没选时为 nil
        var selection: String?
        var history: [String]
        var selectionTimes: [Double]
        var hintShown: Bool
        /// 到目前为止的作答用时
        var answerSeconds: Double
        /// 选项显示顺序（原题字母），复习时打乱过的照原样还原
        var optionOrder: [String]
        /// 题目内容变了（重新导入教辅包）就不还原
        var contentHash: String
    }

    /// 选择题答完后还没提交的错因
    struct Cause: Codable {
        /// 属于哪次作答：AttemptRecord.createdAt
        var attemptAt: Date
        var errorTypes: [String]
        var note: String
        var confusedPoints: [String]
        /// 是在修改已提交的错因
        var editing: Bool
    }

    /// 阅读练习（概括、回译）的键盘输入
    struct Reading: Codable {
        var typed: String
    }

    /// 表达练习：AI 出的这一句和键盘输入（AI 每次出的句子不同，要连句子一起存）
    struct Expression: Codable {
        var chinese: String
        var reference: String
        var typed: String
        var usedHint: Bool
    }

    // MARK: - 键

    static func choiceKey(pack: String, mode: AttemptMode, questionID: String) -> String {
        "choice|\(pack)|\(mode.rawValue)|\(questionID)"
    }

    static func causeKey(pack: String, mode: AttemptMode, questionID: String) -> String {
        "cause|\(pack)|\(mode.rawValue)|\(questionID)"
    }

    static func readingKey(pack: String, itemID: String) -> String { "reading|\(pack)|\(itemID)" }

    static func expressionKey(entryKey: String) -> String { "expression|\(entryKey)" }

    // MARK: - 存取

    private struct Stored<T: Codable>: Codable {
        let savedAt: Date
        let value: T
    }

    static func load<T: Codable>(_ type: T.Type, key: String) -> (value: T, savedAt: Date)? {
        guard let data = UserDefaults.standard.data(forKey: prefix + key),
              let stored = try? JSONDecoder().decode(Stored<T>.self, from: data) else { return nil }
        return (stored.value, stored.savedAt)
    }

    static func save<T: Codable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(Stored(savedAt: .now, value: value)) else { return }
        UserDefaults.standard.set(data, forKey: prefix + key)
    }

    static func remove(key: String) {
        UserDefaults.standard.removeObject(forKey: prefix + key)
    }

    /// 清除本节记录时：这些题各种作答方式的选择题作答和错因
    static func removeChoices(pack: String, questionIDs: [String]) {
        let ids = Set(questionIDs)
        for key in allKeys() {
            let parts = key.split(separator: "|", maxSplits: 3).map(String.init)
            guard parts.count == 4, ["choice", "cause"].contains(parts[0]), parts[1] == pack,
                  ids.contains(parts[3]) else { continue }
            remove(key: key)
        }
    }

    /// 启动时：删掉超过 14 天没动的
    static func purgeStale() {
        struct Header: Decodable { let savedAt: Date }
        let cutoff = Date.now.addingTimeInterval(-maxAge)
        for key in allKeys() {
            guard let data = UserDefaults.standard.data(forKey: prefix + key),
                  let h = try? JSONDecoder().decode(Header.self, from: data), h.savedAt > cutoff else {
                remove(key: key)
                continue
            }
        }
    }

    private static func allKeys() -> [String] {
        UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }
}
