import Foundation
import SwiftData

/// 自评安排复习的 FSRS 卡片（生词、表达）：每次自评直接更新记忆状态，评分历史另存一份
nonisolated protocol SelfRatedCard: AnyObject {
    var dueAt: Date { get set }
    var stability: Double { get set }
    var difficulty: Double { get set }
    var lastReviewAt: Date? { get set }
    var reps: Int { get set }
    var lapses: Int { get set }
    var ratings: [Int] { get set }
    var ratedAt: [Date] { get set }
}

extension SelfRatedCard {
    /// 还没复习过
    var isNew: Bool { reps == 0 }
    var isDue: Bool { dueAt <= .now }

    /// 自评一次，更新记忆状态和下次复习的日期；retention 为目标记住率（同题目复习的设置）
    func rate(_ rating: FSRSRating, at date: Date = .now, retention: Double) {
        let card = lastReviewAt.map {
            FSRSCard(stability: stability, difficulty: difficulty, lastReview: $0, reps: reps, lapses: lapses)
        }
        let next = FSRS.review(card, rating: rating, at: date)
        stability = next.stability
        difficulty = next.difficulty
        lastReviewAt = next.lastReview
        reps = next.reps
        lapses = next.lapses
        ratings.append(rating.rawValue)
        ratedAt.append(date)
        let cal = Calendar.current
        if rating == .again {
            // 重来：明天再复习（背单词时本次结束前还会再出现一次）
            dueAt = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: date) ?? date)
        } else {
            let days = FSRS.interval(stability: next.stability, retention: retention)
            dueAt = cal.startOfDay(for: cal.date(byAdding: .day, value: days, to: date) ?? date)
        }
    }

    /// 计入另一台设备（手机复习 App）上的一次自评：同一时刻已经记过的不再记；比已有的自评都晚的直接接着算，
    /// 否则按时间插进评分历史，从头重算记忆状态。返回是否记下了
    @discardableResult
    func merge(_ rating: FSRSRating, at date: Date, retention: Double, createdAt: Date) -> Bool {
        guard !ratedAt.contains(where: { abs($0.timeIntervalSince(date)) < 0.001 }) else { return false }
        guard let last = ratedAt.last, date < last else {
            rate(rating, at: date, retention: retention)
            return true
        }
        let history = (zip(ratedAt, ratings).map { ($0, $1) } + [(date, rating.rawValue)]).sorted { $0.0 < $1.0 }
        stability = 0
        difficulty = 0
        lastReviewAt = nil
        reps = 0
        lapses = 0
        ratings = []
        ratedAt = []
        dueAt = createdAt
        for (at, raw) in history {
            guard let r = FSRSRating(rawValue: raw) else { continue }
            rate(r, at: at, retention: retention)
        }
        return true
    }
}

/// 表达本里的一个表达（句式、搭配）：回译时原句里值得学、却没写出来或写错的表达。
/// 复习时不重复原句，而是由 AI 用这个表达另编一句中文来翻译，按 FSRS 自评安排
@Model
final class ExpressionEntry: SelfRatedCard {
    /// packID|passageID|表达
    @Attribute(.unique) var key: String
    var packID: String
    var passageID: String
    /// 表达原文，如「Rare is the household in which」
    var expression: String
    /// 出处：回译的原句及译文
    var english: String
    var chinese: String
    /// 第一次回译时的情况：wrong（用了但写错）/ missing（没写出来）
    var firstResult: String
    /// AI 对这次没写对的说明
    var note: String?
    var createdAt: Date

    // FSRS 记忆状态
    var dueAt: Date
    var stability: Double = 0
    var difficulty: Double = 0
    var lastReviewAt: Date?
    var reps: Int = 0
    var lapses: Int = 0
    var ratings: [Int] = []
    var ratedAt: [Date] = []

    init(packID: String, passageID: String, expression: String, english: String, chinese: String,
         firstResult: String, note: String?) {
        key = Self.key(packID: packID, passageID: passageID, expression: expression)
        self.packID = packID
        self.passageID = passageID
        self.expression = expression
        self.english = english
        self.chinese = chinese
        self.firstResult = firstResult
        self.note = note
        createdAt = .now
        dueAt = .now
    }

    static func key(packID: String, passageID: String, expression: String) -> String {
        "\(packID)|\(passageID)|\(expression)"
    }
}

/// 一次表达复习：AI 新编的中文句、学生的翻译（手写截图和/或键盘输入）、点评和自评
@Model
final class ExpressionAttempt {
    /// 对应 ExpressionEntry.key
    var entryKey: String
    var chinese: String
    /// AI 出题时给的参考译文
    var reference: String
    /// 作答前看了要用的表达
    var usedHint: Bool
    var answer: String
    var inkImagesData: Data?
    var feedback: String?
    var feedbackIncomplete = false
    /// 点评末尾 JSON 给出的结论：correct / wrong / missing
    var verdict: String?
    var usageData: Data?
    /// 自评（FSRSRating 原始值）
    var rating: Int?
    var createdAt: Date

    var usage: LLMUsage? {
        get { usageData.flatMap { try? JSONDecoder().decode(LLMUsage.self, from: $0) } }
        set { usageData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    var inkImages: [Data] {
        get { inkImagesData.flatMap { try? JSONDecoder().decode([Data].self, from: $0) } ?? [] }
        set { inkImagesData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    init(entryKey: String, chinese: String, reference: String, usedHint: Bool, answer: String, inkImages: [Data]) {
        self.entryKey = entryKey
        self.chinese = chinese
        self.reference = reference
        self.usedHint = usedHint
        self.answer = answer
        createdAt = .now
        self.inkImages = inkImages
    }
}

@MainActor
enum ExpressionBook {
    /// 今天要复习的表达：到期的（新加入的当天就到期），先到期的在前
    static func dueToday(_ entries: [ExpressionEntry]) -> [ExpressionEntry] {
        entries.filter(\.isDue).sorted { $0.dueAt < $1.dueAt }
    }

    /// 回译点评末尾的 JSON：原句各重点表达的使用情况
    nonisolated struct BackTranslationVerdict: Decodable {
        struct Item: Decodable {
            let text: String
            /// correct / wrong / missing
            let result: String
            let note: String?
        }
        let expressions: [Item]
    }

    /// 回译点评生成完后：没用对的重点表达加入表达本（已有的不重复加），返回新加入的表达
    @discardableResult
    static func addFromBackTranslation(feedback: String, packID: String, passageID: String,
                                       drill: BackTranslationDrill, in context: ModelContext) -> [String] {
        guard let verdict = TrailingJSON.decode(BackTranslationVerdict.self, from: feedback) else { return [] }
        let focus = drill.focus ?? []
        var added: [String] = []
        for item in verdict.expressions where item.result != "correct" {
            // 只收原句里标出的重点表达，AI 改写过的按原文对上
            guard let text = focus.first(where: { $0.caseInsensitiveCompare(item.text) == .orderedSame }) else { continue }
            let key = ExpressionEntry.key(packID: packID, passageID: passageID, expression: text)
            if (try? context.fetch(FetchDescriptor<ExpressionEntry>(predicate: #Predicate { $0.key == key })).first) != nil {
                continue
            }
            context.insert(ExpressionEntry(packID: packID, passageID: passageID, expression: text, english: drill.en,
                                           chinese: drill.zh, firstResult: item.result, note: item.note))
            added.append(text)
        }
        try? context.save()
        return added
    }

    static func attempts(of entry: ExpressionEntry, in context: ModelContext) -> [ExpressionAttempt] {
        let key = entry.key
        return (try? context.fetch(FetchDescriptor<ExpressionAttempt>(
            predicate: #Predicate { $0.entryKey == key }, sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }
}
