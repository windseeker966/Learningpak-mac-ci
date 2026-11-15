import Foundation
import SwiftData

/// 学习页「笔记」里自己添加的笔记，按书：文字，加上笔记页上的书写区（笔迹存在笔记页的草稿里）
@Model
final class BookNote {
    var id: UUID
    var packID: String
    var text: String
    var areaCount: Int = 0
    var createdAt: Date
    var updatedAt: Date

    init(packID: String, text: String) {
        self.id = UUID()
        self.packID = packID
        self.text = text
        self.createdAt = .now
        self.updatedAt = .now
    }
}

/// 按题的手动标记：「重点」「已掌握」和「题目有错」。选择题、主观题、AI 改编题共用，只通过 id 引用题目
/// （改编题的 id 是「原题 id~ai-xxxx」，见 VariantAttempt.variantID；改编题只用「题目有错」）
@Model
final class QuestionMark {
    @Attribute(.unique) var key: String
    var packID: String
    var questionID: String
    var starred: Bool = false
    /// 手动标为已掌握的时间；之后再答错，这个标记就不再算数
    var masteredAt: Date?
    /// 标记「题目有错」的时间和说明：之后复习、错题本和统计都不再使用这道题；
    /// 改编题有错时，这道改编题的作答都不计入原题，并告诉下次改编避开
    var faultyAt: Date?
    var faultyNote: String?
    /// 哪里有错（FaultReason.rawValue），选填
    var faultyReasons: [String] = []
    /// AI 改编题被评价「出得好」的时间：作答照常计入原题，下次改编同一道原题时作为好的例子附给 AI。
    /// 和 faultyAt 互斥，评价「出得不好」就是标记有错
    var ratedGoodAt: Date?
    var updatedAt: Date

    init(packID: String, questionID: String) {
        self.key = "\(packID)|\(questionID)"
        self.packID = packID
        self.questionID = questionID
        self.updatedAt = .now
    }

    static func fetch(packID: String, questionID: String, in context: ModelContext) -> QuestionMark? {
        let key = "\(packID)|\(questionID)"
        return try? context.fetch(FetchDescriptor<QuestionMark>(predicate: #Predicate { $0.key == key })).first
    }

    /// 本书标记了题目有错的题，按题目 id
    static func faulty(packID: String, in context: ModelContext) -> [String: QuestionMark] {
        let marks = (try? context.fetch(FetchDescriptor<QuestionMark>(
            predicate: #Predicate { $0.packID == packID && $0.faultyAt != nil }))) ?? []
        return Dictionary(marks.map { ($0.questionID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// 本书评价过的改编题（标记有错、评价出得好），按题目 id：交给下次改编参考
    static func rated(packID: String, in context: ModelContext) -> [String: QuestionMark] {
        let marks = (try? context.fetch(FetchDescriptor<QuestionMark>(
            predicate: #Predicate { $0.packID == packID && ($0.faultyAt != nil || $0.ratedGoodAt != nil) }))) ?? []
        return Dictionary(marks.map { ($0.questionID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var faulty: Bool { faultyAt != nil }
    var ratedGood: Bool { faultyAt == nil && ratedGoodAt != nil }

    /// 「答案或解析错误、题意不清：说明」；都没写为 nil
    var faultyDescription: String? {
        let reasons = faultyReasons.compactMap(FaultReason.init(rawValue:)).map(\.label).joined(separator: "、")
        let line = [reasons.isEmpty ? nil : reasons, faultyNote].compactMap { $0 }.joined(separator: "：")
        return line.isEmpty ? nil : line
    }

    /// scheduleID：要重算复习安排的题，默认就是这道题；改编题传原题
    @MainActor
    static func update(packID: String, questionID: String, scheduleID: String? = nil, in context: ModelContext,
                       _ change: (QuestionMark) -> Void) {
        let mark = fetch(packID: packID, questionID: questionID, in: context) ?? {
            let m = QuestionMark(packID: packID, questionID: questionID)
            context.insert(m)
            return m
        }()
        change(mark)
        mark.updatedAt = .now
        try? context.save()
        // 标记已掌握会提高这道题的记忆稳定性
        ReviewScheduler.refresh(packID: packID, questionID: scheduleID ?? questionID, in: context)
    }
}

extension AttemptOutcome {
    init(_ a: AttemptRecord) {
        self.init(at: a.createdAt, correct: a.isCorrect, sure: a.confidence == ChoiceConfidence.sure.rawValue, sinceAnswerSeen: a.sinceAnswerSeen)
    }

    /// 主观题只算已自评的作答
    init?(_ a: SubjectiveAttempt) {
        guard let r = a.resultValue else { return nil }
        self.init(at: a.revealedAt ?? a.createdAt, correct: r == .correct,
                  sure: a.confidence == SubjectiveConfidence.sure.rawValue, sinceAnswerSeen: a.sinceAnswerSeen)
    }

    /// 改编题算作原题的作答（只传 VariantAttempt.counted 里的）
    init?(_ v: VariantAttempt) {
        guard v.resultValue != nil else { return nil }
        self.init(at: v.answeredAt, correct: v.isCorrect, sure: v.sure, sinceAnswerSeen: v.sinceAnswerSeen, variant: true)
    }
}

extension WrongBook {
    /// 这道题（选择题或主观题，包括它的改编题）的全部作答结果
    @MainActor
    static func outcomes(packID: String, questionID: String, in context: ModelContext) -> [AttemptOutcome] {
        let choice = (try? context.fetch(FetchDescriptor<AttemptRecord>(
            predicate: #Predicate { $0.packID == packID && $0.questionID == questionID }))) ?? []
        return choice.map(AttemptOutcome.init)
            + SubjectiveRecords.attempts(packID: packID, questionID: questionID, in: context).compactMap(AttemptOutcome.init)
            + VariantAttempt.counted(packID: packID, originalID: questionID, in: context).compactMap(AttemptOutcome.init)
    }

    /// 这道题最近一次答错的时间
    @MainActor
    static func lastWrongAt(packID: String, questionID: String, in context: ModelContext) -> Date? {
        outcomes(packID: packID, questionID: questionID, in: context).filter { !$0.correct }.map(\.at).max()
    }

    /// 「已掌握」标记还算数：标过，且之后没再答错
    @MainActor
    static func isMastered(_ mark: QuestionMark?, in context: ModelContext) -> Bool {
        guard let mark, let at = mark.masteredAt else { return false }
        return lastWrongAt(packID: mark.packID, questionID: mark.questionID, in: context).map { at > $0 } ?? true
    }
}
