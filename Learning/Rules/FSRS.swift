import Foundation

// FSRS 记忆模型（FSRS-5，默认参数）和「作答情况 → 评分」的规则。只依赖 Foundation，可以单独编译测试（见 Tests/FSRSTests.swift）。
// 每道题的复习安排由它的全部作答（含改编题、手动标记已掌握）按时间顺序重放算出，所以修改自评、错因或标记后重算即可。

/// FSRS 的四档评分
nonisolated enum FSRSRating: Int, Sendable {
    case again = 1, hard, good, easy

    var label: String {
        switch self {
        case .again: "重来"
        case .hard: "困难"
        case .good: "良好"
        case .easy: "简单"
        }
    }
}

/// 一道题的记忆状态
nonisolated struct FSRSCard: Equatable, Sendable {
    /// 稳定性（天）：隔这么多天，还记得的概率是 90%
    var stability: Double
    /// 难度 1…10
    var difficulty: Double
    var lastReview: Date
    var reps: Int
    var lapses: Int
}

nonisolated enum FSRS {
    /// FSRS-5 默认参数
    static let w: [Double] = [0.40255, 1.18385, 3.173, 15.69105, 7.1949, 0.5345, 1.4604, 0.0046, 1.54575, 0.1192,
                              1.01925, 1.9395, 0.11, 0.29605, 2.2698, 0.2315, 2.9898, 0.51655, 0.6621]
    static let decay = -0.5
    static let factor = 19.0 / 81.0
    static let maxInterval = 365
    /// 手动标记已掌握：稳定性至少放大这么多倍，且不少于 masteredMinStability 天
    static let masteredBoost = 4.0
    static let masteredMinStability = 60.0

    /// 隔 days 天后还记得的概率
    static func retrievability(elapsedDays days: Double, stability: Double) -> Double {
        pow(1 + factor * max(days, 0) / max(stability, 0.01), decay)
    }

    /// 让下次复习时记得的概率等于 retention 的间隔（天）
    static func interval(stability: Double, retention: Double) -> Int {
        let days = stability / factor * (pow(retention, 1 / decay) - 1)
        return min(max(Int(days.rounded()), 1), maxInterval)
    }

    static func elapsedDays(from: Date, to: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: to)).day ?? 0
    }

    private static func initialDifficulty(_ r: FSRSRating) -> Double {
        w[4] - exp(w[5] * Double(r.rawValue - 1)) + 1
    }

    private static func clampD(_ d: Double) -> Double { min(max(d, 1), 10) }

    /// 按一次评分更新记忆状态；card 为 nil 表示第一次
    static func review(_ card: FSRSCard?, rating r: FSRSRating, at date: Date, calendar: Calendar = .current) -> FSRSCard {
        guard let card else {
            return FSRSCard(stability: w[r.rawValue - 1], difficulty: clampD(initialDifficulty(r)), lastReview: date,
                            reps: 1, lapses: r == .again ? 1 : 0)
        }
        let g = Double(r.rawValue)
        let elapsed = elapsedDays(from: card.lastReview, to: date, calendar: calendar)
        let s = card.stability, d = card.difficulty
        // 难度：评分越低越难，并向「简单」的初始难度略微回归
        let next = d + (-w[6] * (g - 3)) * (10 - d) / 9
        let newD = clampD(w[7] * initialDifficulty(.easy) + (1 - w[7]) * next)
        let newS: Double
        if elapsed == 0 {
            // 同一天内再次作答：短期记忆公式
            newS = s * exp(w[17] * (g - 3 + w[18]))
        } else {
            let rr = retrievability(elapsedDays: Double(elapsed), stability: s)
            if r == .again {
                let longTerm = w[11] * pow(d, -w[12]) * (pow(s + 1, w[13]) - 1) * exp(w[14] * (1 - rr))
                newS = min(longTerm, s / exp(w[17] * w[18]))
            } else {
                let hard = r == .hard ? w[15] : 1
                let easy = r == .easy ? w[16] : 1
                newS = s * (exp(w[8]) * (11 - d) * pow(s, -w[9]) * (exp(w[10] * (1 - rr)) - 1) * hard * easy + 1)
            }
        }
        return FSRSCard(stability: max(newS, 0.01), difficulty: newD, lastReview: date, reps: card.reps + 1,
                        lapses: card.lapses + (r == .again ? 1 : 0))
    }

    /// 手动标记已掌握：大幅提高稳定性，从标记时起算
    static func markMastered(_ card: FSRSCard?, at date: Date) -> FSRSCard {
        var c = card ?? FSRSCard(stability: 0, difficulty: 5, lastReview: date, reps: 0, lapses: 0)
        c.stability = max(c.stability * masteredBoost, masteredMinStability)
        c.lastReview = date
        return c
    }
}

/// 一次作答里和「记得多牢」有关的信息（选择题、主观题、改编题都整理成这个样子）
nonisolated struct ReviewEvidence: Sendable {
    enum Confidence: Sendable { case sure, unsure, guess }

    var at: Date
    /// 整题做对
    var correct: Bool
    /// 0…1：选择题对 1、错 0，多空题按答对的空；主观题按各问得分（对 1、部分对 0.5）
    var score: Double
    var confidence: Confidence
    /// 看答案后不久的重做（答对不算记住）
    var immediate = false
    var hintShown = false
    /// 提交前改过选择
    var changedAnswer = false
    /// 用时 ÷ 这道题以前有把握答对的中位用时；以前没有这样的作答时为 nil
    var slowness: Double?
    /// 主观题看答案后补写的笔画占比
    var addedAfterReveal: Double?
    /// 自评的错因只有失误类（粗心、审题、计算、画图、表达不完整），没有知识类
    var slipOnly = false
    /// 手动标记已掌握（不是作答）
    var masteredMark = false

    /// 吃力的迹象：看了提示、改过选择、用时明显偏长、看答案后补写较多。主观题只看提交的自评，不参考 AI 批改
    var struggled: Bool {
        hintShown || changedAnswer || (slowness ?? 0) > ReviewRating.slowRatio
            || (addedAfterReveal ?? 0) > ReviewRating.addedRatio
    }
}

nonisolated enum ReviewRating {
    /// 用时超过这道题以前的用时这么多倍算偏慢；低于 fastRatio 倍算快
    static let slowRatio = 3.0
    static let fastRatio = 0.5
    /// 看答案后补写超过这个比例算吃力
    static let addedRatio = 0.3

    /// 作答情况 → 评分；不计入（看答案后不久的重做答对、标记已掌握）时为 nil
    static func rating(_ e: ReviewEvidence) -> FSRSRating? {
        if e.masteredMark { return nil }
        guard e.correct else {
            // 会但失误：错因只有失误类、至少做对一半、不是蒙的 → 困难；其余都是重来
            return e.slipOnly && e.score >= 0.5 && e.confidence != .guess ? .hard : .again
        }
        if e.immediate { return nil }
        switch e.confidence {
        case .guess: return .again
        case .unsure: return .hard
        case .sure:
            if e.struggled { return .hard }
            if let s = e.slowness, s < fastRatio { return .easy }
            return .good
        }
    }


    /// 按时间顺序依次给出评分（不计入的为 nil）。看完答案马上又做错时，上一次已经记过「重来」，不再重复计入
    static func ratings(_ evidence: [ReviewEvidence]) -> [(ReviewEvidence, FSRSRating?)] {
        var last: FSRSRating?
        return evidence.sorted { $0.at < $1.at }.map { e in
            guard !e.masteredMark else { return (e, nil) }
            var r = rating(e)
            if e.immediate && !e.correct && last == .again { r = nil }
            if let r { last = r }
            return (e, r)
        }
    }

    /// 按时间顺序重放全部作答。没有一次计入评分的作答时返回 nil。
    /// 一直有把握答对的题也进复习：FSRS 按「良好 / 简单」给出较长的首次间隔（目标记住率 90% 时约 3 天 / 16 天）
    static func replay(_ evidence: [ReviewEvidence], calendar: Calendar = .current) -> FSRSCard? {
        var counted: [FSRSRating] = []
        var card: FSRSCard?
        for (e, r) in ratings(evidence) {
            if e.masteredMark {
                card = FSRS.markMastered(card, at: e.at)
            } else if let r {
                counted.append(r)
                card = FSRS.review(card, rating: r, at: e.at, calendar: calendar)
            }
        }
        return counted.isEmpty ? nil : card
    }

    // MARK: - 从作答记录整理评分依据时用到的规则

    /// 中位数（用来和这道题以前有把握答对的用时比快慢）；没有数据为 nil
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// 提交前改过选择：某个位置先选了一个值，后来换成别的（多空题逐空看，第一次填空不算改）；
    /// 单选、判断、多选看有没有取消过已选的选项（多选题陆续勾选不算改）
    static func changedAnswer(_ history: [String]) -> Bool {
        if !history.contains(where: { $0.contains(",") }) {
            return zip(history, history.dropFirst()).contains { prev, next in !Set(prev).isSubset(of: Set(next)) }
        }
        var current: [String] = []
        for step in history {
            let picks = step.components(separatedBy: ",")
            for (i, v) in picks.enumerated() {
                if i < current.count {
                    if current[i] != "_" && v != "_" && v != current[i] { return true }
                    if v != "_" { current[i] = v }
                } else {
                    current.append(v)
                }
            }
        }
        return false
    }
}
