import Foundation
import SwiftData

/// 一张说法卡（教辅包里的 Phrase）：像背单词那样看说法、想出指的是什么，再翻面自评，按 FSRS 安排复习。
/// 学过考到它的题之后才放进来（见 PhraseUnlock、PhraseIntroduction）；同一个说法全书只有一张
@Model
final class PhraseCard: SelfRatedCard {
    /// packID|说法卡 id
    @Attribute(.unique) var key: String
    var packID: String
    var phraseID: String
    /// 放进来时随哪道题
    var questionID: String
    var createdAt: Date
    /// 放进来时原题里选错过它，先记了一次「重来」；这一次不算自评
    var seededAgain: Bool = false

    // FSRS 记忆状态
    var dueAt: Date
    var stability: Double = 0
    var difficulty: Double = 0
    var lastReviewAt: Date?
    var reps: Int = 0
    var lapses: Int = 0
    /// 评分历史（FSRSRating 原始值）及时间
    var ratings: [Int] = []
    var ratedAt: [Date] = []

    init(packID: String, phraseID: String, questionID: String) {
        key = Self.key(packID: packID, phraseID: phraseID)
        self.packID = packID
        self.phraseID = phraseID
        self.questionID = questionID
        createdAt = .now
        dueAt = .now
    }

    static func key(packID: String, phraseID: String) -> String { "\(packID)|\(phraseID)" }

    /// 自评过（放进来时先记的「重来」不算）
    var selfRated: Bool { ratings.count > (seededAgain ? 1 : 0) }

    var state: PhraseUnlock.CardState {
        PhraseUnlock.CardState(selfRated: selfRated,
                               intervalDays: lastReviewAt.map { dueAt.timeIntervalSince($0) / 86400 } ?? 0)
    }
}

@MainActor
enum PhraseDeck {
    static let dailyNewKey = "phrase.dailyNew"
    /// 每天最多放进来的新卡数
    static var dailyNew: Int {
        UserDefaults.standard.object(forKey: dailyNewKey) as? Int ?? PhraseUnlock.defaultDailyNew
    }

    static func all(in context: ModelContext) -> [PhraseCard] {
        (try? context.fetch(FetchDescriptor<PhraseCard>())) ?? []
    }

    /// 今天要背的卡：到期的旧卡，放进来还没背的新卡，最后是今天还要再背一次的卡（同 Vocab.relearnToday）
    static func dueToday(_ cards: [PhraseCard]) -> [PhraseCard] {
        let old = cards.filter { !$0.isNew && $0.isDue }.sorted { $0.dueAt < $1.dueAt }
        let new = cards.filter(\.isNew).sorted { ($0.createdAt, $0.phraseID) < ($1.createdAt, $1.phraseID) }
        let relearn = relearnToday(cards).filter { !$0.isDue }
        return old + new + relearn
    }

    /// 今天最后一次评分是「重来」的卡（含放进来时按原题先记的「重来」）：排到最后再背一次
    static func relearnToday(_ cards: [PhraseCard]) -> [PhraseCard] {
        cards.filter { c in
            c.ratings.last == FSRSRating.again.rawValue && c.ratedAt.last.map { Calendar.current.isDateInToday($0) } == true
        }
        .sorted { ($0.ratedAt.last ?? .distantPast) < ($1.ratedAt.last ?? .distantPast) }
    }

    static func rate(_ card: PhraseCard, _ rating: FSRSRating, in context: ModelContext) {
        card.rate(rating, retention: ReviewScheduler.retention)
        try? context.save()
    }

    /// 全由说法卡复习、现在退出复习队列的题（ReviewItem.key）。原题多久没做按复习安排里的上次作答算
    static func retiredKeys(_ items: [ReviewItem], cards: [PhraseCard], store: PackStore,
                            now: Date = .now) -> Set<String> {
        guard !cards.isEmpty else { return [] }
        let byKey = Dictionary(cards.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var out = Set<String>()
        for item in items {
            guard let q = store.pack(item.packID)?.questions[item.questionID], q.phraseOnly else { continue }
            let states = q.phraseIDs.map { byKey[PhraseCard.key(packID: item.packID, phraseID: $0)]?.state }
            if PhraseUnlock.isRetired(cards: states, lastAnswered: item.lastReviewAt, now: now) { out.insert(item.key) }
        }
        return out
    }

    /// 进复习页的题：能复习（见 StudyPack.isReviewable），且没有因为转成说法卡退出复习队列
    static func reviewable(_ items: [ReviewItem], store: PackStore, in context: ModelContext,
                           now: Date = .now) -> [ReviewItem] {
        let active = items.filter { store.pack($0.packID)?.isReviewable($0.questionID) == true }
        let retired = retiredKeys(active, cards: all(in: context), store: store, now: now)
        return retired.isEmpty ? active : active.filter { !retired.contains($0.key) }
    }

    /// 原题做错了（全由说法卡复习的题回来抽查时）：选错的选项对应、已经自评过的卡退回「重来」。不保存
    static func recordMiss(packID: String, question q: Question, selection: String, at date: Date,
                           in context: ModelContext) {
        guard q.phraseOnly, let options = q.phrases else { return }
        let missed = PhraseUnlock.missed(selected: Set(selection.map(String.init)), answer: q.answerSet, options: options)
        let keys = Set(missed.map { PhraseCard.key(packID: packID, phraseID: $0) })
        guard !keys.isEmpty else { return }
        for card in all(in: context) where keys.contains(card.key) && card.selfRated {
            card.rate(.again, at: date, retention: ReviewScheduler.retention)
        }
    }

    /// 排队的题：本书考到说法卡的题里做过的，带上第一次作答时间、重点标记和答错的情况
    static func candidates(_ pack: StudyPack, in context: ModelContext) -> [PhraseUnlock.Candidate] {
        let packID = pack.id
        let attempts = (try? context.fetch(FetchDescriptor<AttemptRecord>(
            predicate: #Predicate { $0.packID == packID }, sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        let byQuestion = Dictionary(grouping: attempts, by: \.questionID)
        let starred = Set(((try? context.fetch(FetchDescriptor<QuestionMark>(
            predicate: #Predicate { $0.packID == packID && $0.starred }))) ?? []).map(\.questionID))
        var out: [PhraseUnlock.Candidate] = []
        for (si, s) in pack.sections.enumerated() {
            for q in s.questions where q.deprecated != true && !(q.phrases ?? [:]).isEmpty {
                guard let list = byQuestion[q.id], let first = list.first else { continue }
                let wrong = list.filter { !$0.isCorrect && !$0.isImmediateRedo }
                var c = PhraseUnlock.Candidate(questionID: q.id, sectionIndex: si, num: q.num,
                                               phrases: q.phraseIDs.filter { pack.phrases[$0]?.deprecated != true },
                                               firstAnswered: first.createdAt)
                c.starred = starred.contains(q.id)
                c.wrongCount = wrong.count
                c.lastWrong = wrong.last?.createdAt
                out.append(c)
            }
        }
        return out
    }
}
