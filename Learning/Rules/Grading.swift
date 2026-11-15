import CryptoKit
import Foundation

/// 用户的作答
nonisolated enum Selection: Equatable, Sendable {
    case option(String)
    case blanks([String?])

    /// 多选题的 option 是选中字母按字母序连在一起（如 "ABD"）
    var isComplete: Bool {
        switch self {
        case .option(let k): !k.isEmpty
        case .blanks(let b): b.allSatisfy { $0 != nil }
        }
    }

    /// 存储用编码："B"；多选题 "ABD"；判断题 "正确"；多空题 "B,A,C,D"（未填为 "_"）
    var encoded: String {
        switch self {
        case .option(let k): k
        case .blanks(let b): b.map { $0 ?? "_" }.joined(separator: ",")
        }
    }

    /// 从作答记录还原
    static func decode(_ s: String, for q: Question) -> Selection {
        guard q.type == .multiBlank else { return .option(s) }
        return .blanks(s.components(separatedBy: ",").map { $0 == "_" ? nil : $0 })
    }
}

nonisolated struct GradeResult: Sendable {
    let isCorrect: Bool
    /// 多空题每空对错；其他题型为空
    let blankResults: [Bool]
    /// 根据所选选项推算出的薄弱知识点（去重、保序），答对时为空
    let weakPoints: [String]
    /// 组合题中判断错的陈述键
    let misjudgedStatements: [String]
    /// 是否是选「错误 / 不属于」的反问题
    let negative: Bool
}

nonisolated enum Grader {
    static func grade(_ q: Question, _ sel: Selection) -> GradeResult {
        let negative = q.polarity == .negative
        switch (q.type, sel) {
        case (.single, .option(let k)), (.judge, .option(let k)):
            let correct = k == q.answer
            let weak = correct ? [] : q.exposed(q.distractors?[k]) + q.exposed(q.ifMissed)
            return GradeResult(isCorrect: correct, blankResults: [], weakPoints: dedup(weak),
                               misjudgedStatements: [], negative: negative)

        case (.combo, .option(let k)):
            let correct = k == q.answer
            let chosen = Set(q.comboOptions?[k] ?? [])
            let right = Set(q.answer.flatMap { q.comboOptions?[$0] } ?? [])
            let misjudged = chosen.symmetricDifference(right).sorted { Roman.order($0) < Roman.order($1) }
            let weak = misjudged.flatMap { q.exposed(q.statements?[$0]?.ifMisjudged) }
            return GradeResult(isCorrect: correct, blankResults: [], weakPoints: correct ? [] : dedup(weak),
                               misjudgedStatements: correct ? [] : misjudged, negative: negative)

        case (.multi, .option(let k)):
            // 逐个选项看：该选的选了、不该选的没选算这一项对（用于部分得分）
            let chosen = Set(k.map(String.init)), right = q.answerSet
            let results = q.optionKeys.map { chosen.contains($0) == right.contains($0) }
            let correct = chosen == right
            let wrongPicks = chosen.subtracting(right).sorted()
            let weak = wrongPicks.flatMap { q.exposed(q.distractors?[$0]) }
                + (right.isSubset(of: chosen) ? [] : q.exposed(q.ifMissed))
            return GradeResult(isCorrect: correct, blankResults: results, weakPoints: correct ? [] : dedup(weak),
                               misjudgedStatements: [], negative: negative)

        case (.multiBlank, .blanks(let picks)):
            let blanks = q.blanks ?? []
            let results = blanks.enumerated().map { i, b in i < picks.count && picks[i] == b.answer }
            let weak = blanks.enumerated().flatMap { i, b in results[i] ? [] : q.exposed(b.ifWrong) }
            let correct = !results.isEmpty && results.allSatisfy { $0 }
            return GradeResult(isCorrect: correct, blankResults: results, weakPoints: dedup(weak),
                               misjudgedStatements: [], negative: negative)

        default:
            return GradeResult(isCorrect: false, blankResults: [], weakPoints: [],
                               misjudgedStatements: [], negative: negative)
        }
    }

    /// 判分内容哈希：题干、选项/陈述/共享选项、各空答案、答案。重新导入后若变化，历史作答需要重新判分。
    static func contentHash(_ q: Question) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: gradingContent(q), options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 作答时的题目快照：判分内容加题型、正反问、解析和考查的知识点
    static func snapshot(_ q: Question) -> Data? {
        var dict = gradingContent(q)
        dict["type"] = q.type.rawValue
        dict["polarity"] = q.polarity.rawValue
        dict["explanation"] = q.explanation
        if let t = q.tests { dict["tests"] = t }
        if let t = q.alsoTests { dict["also_tests"] = t }
        if let d = q.distractors { dict["distractors"] = d }
        if let f = q.figures, !f.isEmpty { dict["figures"] = f }
        return try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    }

    private static func gradingContent(_ q: Question) -> [String: Any] {
        var dict: [String: Any] = ["stem": q.stem]
        if let o = q.options, q.type != .judge { dict["options"] = o }
        if let o = q.comboOptions { dict["options"] = o }
        if let s = q.statements {
            dict["statements"] = s.mapValues { ["text": $0.text, "truth": $0.truth] as [String: Any] }
        }
        if let s = q.sharedOptions { dict["shared_options"] = s }
        if let b = q.blanks { dict["blanks"] = b.map(\.answer) }
        if let a = q.answer { dict["answer"] = a }
        return dict
    }

    private static func dedup(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}
