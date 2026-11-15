import Foundation
import SwiftData

/// 复习安排：按 FSRS 记忆模型，由一道题的全部作答（选择题或主观题、它的改编题、手动标记已掌握）重放算出。
/// 作答、修改错因或自评、标记题目有错、标记已掌握之后调用 refresh 重算这道题。
@MainActor
enum ReviewScheduler {
    static let retentionKey = "review.retention"
    /// 目标记住率：下次复习时还记得的概率
    static var retention: Double {
        let v = UserDefaults.standard.double(forKey: retentionKey)
        return v > 0 ? v : 0.9
    }

    static func isDue(_ item: ReviewItem) -> Bool { item.dueAt <= .now }

    /// 这道题用的目标记住率：做一遍要很久的题低一些（见 ReviewPlan.retention）
    static func retention(for item: ReviewItem) -> Double {
        item.reviewSeconds.map { ReviewPlan.retention(base: retention, seconds: $0) } ?? retention
    }

    // MARK: - 每天的复习量

    static let dailyMinutesKey = "review.dailyMinutes"
    /// 每天复习的时长（分钟），0 为不限
    static var dailyMinutes: Int {
        UserDefaults.standard.object(forKey: dailyMinutesKey) as? Int ?? 30
    }

    private static let planDateKey = "review.plan.date"
    private static let planKeysKey = "review.plan.keys"
    private static let planMinutesKey = "review.plan.minutes"

    /// 今天要做的题（ReviewItem.key），按做题顺序。每天第一次调用时从到期的题里按时长挑出并记下，当天不再变；
    /// 做完的题到期日推后，不再算到期。改了每天的时长后重新挑。
    /// due 为空（如教辅包还没加载）时不记，免得记下一个空的计划。all 是队列里的全部题，用来估计没复习过的题的用时
    static func todayPlan(_ due: [ReviewItem], all: [ReviewItem], kind: (ReviewItem) -> ReviewPlan.Kind,
                          now: Date = .now) -> [String] {
        let defaults = UserDefaults.standard
        if let date = defaults.object(forKey: planDateKey) as? Date, Calendar.current.isDate(date, inSameDayAs: now),
           defaults.integer(forKey: planMinutesKey) == dailyMinutes,
           let keys = defaults.stringArray(forKey: planKeysKey), !keys.isEmpty {
            return keys
        }
        let keys = select(due, all: all, kind: kind, now: now)
        if !keys.isEmpty { savePlan(keys, now: now) }
        return keys
    }

    /// 今天的题做完后再挑一批：从顺延的题里按同样的时长挑，接在今天的计划后面
    @discardableResult
    static func extendPlan(_ due: [ReviewItem], all: [ReviewItem], kind: (ReviewItem) -> ReviewPlan.Kind,
                           now: Date = .now) -> [String] {
        let current = todayPlan(due, all: all, kind: kind, now: now)
        let more = select(due.filter { !current.contains($0.key) }, all: all, kind: kind, now: now)
        let keys = current + more
        savePlan(keys, now: now)
        return keys
    }

    private static func select(_ due: [ReviewItem], all: [ReviewItem], kind: (ReviewItem) -> ReviewPlan.Kind,
                               now: Date) -> [String] {
        ReviewPlan.select(cards(due, kind: kind), budget: Double(dailyMinutes) * 60, now: now,
                          cost: estimatedSeconds(all, kind: kind))
    }

    /// 题 → 挑题用的卡片（ReviewPlan 只认值）
    static func cards(_ items: [ReviewItem], kind: (ReviewItem) -> ReviewPlan.Kind) -> [ReviewPlan.Card] {
        items.map {
            ReviewPlan.Card(key: $0.key, dueAt: $0.dueAt, retrievability: $0.retrievability ?? 0,
                            seconds: $0.reviewSeconds, kind: kind($0), book: $0.packID,
                            lastRating: FSRSRating(rawValue: $0.lastRating))
        }
    }

    /// 今天还没做的题：计划里仍到期、今天没跳过的（见 dayBlocks），按计划顺序
    static func remaining(plan: [String], due: [ReviewItem], now: Date = .now) -> [ReviewItem] {
        let skipped = dayBlocks(now: now).skipped
        let byKey = Dictionary(due.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        return plan.compactMap { byKey[$0] }.filter { !skipped.contains($0.key) }
    }

    private static func savePlan(_ keys: [String], now: Date) {
        let defaults = UserDefaults.standard
        defaults.set(now, forKey: planDateKey)
        defaults.set(keys, forKey: planKeysKey)
        defaults.set(dailyMinutes, forKey: planMinutesKey)
    }

    /// 预计用时，按 ReviewPlan.estimates 补上没复习过的题
    static func estimatedSeconds(_ items: [ReviewItem], kind: (ReviewItem) -> ReviewPlan.Kind) -> [String: Double] {
        ReviewPlan.estimates(cards(items, kind: kind))
    }

    /// 题的类型（估用时按同类题，见 ReviewPlan.Kind）；包里找不到的当选择题
    static func kind(of item: ReviewItem, in store: PackStore) -> ReviewPlan.Kind {
        guard let q = store.pack(item.packID)?.subjective[item.questionID] else { return .choice }
        return q.isBlank ? .blank : .composite
    }

    // MARK: - 一组一组地复习

    /// 今天一组一组复习的进度：当前这组的题（按顺序）、今天跳过的题、做完的组数、复习用时（秒）、上次选的一组题数。
    /// 存在 UserDefaults，日期变了从头记；流程见 ReviewBlockSession
    struct DayBlocks {
        var current: [String] = []
        var skipped: Set<String> = []
        var finished = 0
        var seconds: Double = 0
        var size = ReviewPlan.blockSize
    }

    private static let blocksDateKey = "review.blocks.date"
    private static let blocksCurrentKey = "review.blocks.current"
    private static let blocksSkippedKey = "review.blocks.skipped"
    private static let blocksFinishedKey = "review.blocks.finished"
    private static let blocksSecondsKey = "review.blocks.seconds"
    private static let blocksSizeKey = "review.blocks.size"

    static func dayBlocks(now: Date = .now) -> DayBlocks {
        let defaults = UserDefaults.standard
        guard let date = defaults.object(forKey: blocksDateKey) as? Date,
              Calendar.current.isDate(date, inSameDayAs: now) else { return DayBlocks() }
        return DayBlocks(current: defaults.stringArray(forKey: blocksCurrentKey) ?? [],
                         skipped: Set(defaults.stringArray(forKey: blocksSkippedKey) ?? []),
                         finished: defaults.integer(forKey: blocksFinishedKey),
                         seconds: defaults.double(forKey: blocksSecondsKey),
                         size: defaults.object(forKey: blocksSizeKey) as? Int ?? ReviewPlan.blockSize)
    }

    /// 一组一组复习的进度存过（跳过、开始或做完一组）。复习角标据此重算：跳过一道题不写数据库，收不到 didSave
    static let blocksDidChange = Notification.Name("ReviewScheduler.blocksDidChange")

    static func save(_ blocks: DayBlocks, now: Date = .now) {
        let defaults = UserDefaults.standard
        defaults.set(now, forKey: blocksDateKey)
        defaults.set(blocks.current, forKey: blocksCurrentKey)
        defaults.set(blocks.skipped.sorted(), forKey: blocksSkippedKey)
        defaults.set(blocks.finished, forKey: blocksFinishedKey)
        defaults.set(blocks.seconds, forKey: blocksSecondsKey)
        defaults.set(blocks.size, forKey: blocksSizeKey)
        NotificationCenter.default.post(name: blocksDidChange, object: nil)
    }

    // MARK: - 今天到期过的题

    private static let todayDateKey = "review.today.date"
    private static let todayKeysKey = "review.today.keys"

    /// 今天到期过的题（ReviewItem.key）。做完后到期日推后，仍算今天的题，可以再复习或 AI 改编复习一遍；
    /// 不按「今天复习过」判断，那样会混进今天刚学、第一次进队列的题
    static func todayKeys(now: Date = .now) -> Set<String> {
        let defaults = UserDefaults.standard
        guard let date = defaults.object(forKey: todayDateKey) as? Date,
              Calendar.current.isDate(date, inSameDayAs: now) else { return [] }
        return Set(defaults.stringArray(forKey: todayKeysKey) ?? [])
    }

    /// 今天到期过、今天作答过、现在已不到期。只看「到期过、现在不到期」不够：
    /// 调低目标记住率重算后，没复习的题到期日也会推后
    static func isDoneToday(_ item: ReviewItem, todayKeys: Set<String>, now: Date = .now) -> Bool {
        guard item.dueAt > now, todayKeys.contains(item.key), let last = item.lastReviewAt else { return false }
        return Calendar.current.isDate(last, inSameDayAs: now)
    }

    /// 记下当前到期的题，返回今天到期过的全部题；日期变了从头记
    @discardableResult
    static func recordToday(_ due: [ReviewItem], now: Date = .now) -> Set<String> {
        var keys = todayKeys(now: now)
        let count = keys.count
        keys.formUnion(due.map(\.key))
        let defaults = UserDefaults.standard
        let sameDay = (defaults.object(forKey: todayDateKey) as? Date)
            .map { Calendar.current.isDate($0, inSameDayAs: now) } ?? false
        if keys.count != count || !sameDay {
            defaults.set(now, forKey: todayDateKey)
            defaults.set(keys.sorted(), forKey: todayKeysKey)
        }
        return keys
    }

    /// 重算一道题的复习安排
    static func refresh(packID: String, questionID: String, in context: ModelContext) {
        let evidence = Self.evidence(packID: packID, questionID: questionID, in: context)
        let key = "\(packID)|\(questionID)"
        let item = try? context.fetch(FetchDescriptor<ReviewItem>(predicate: #Predicate { $0.key == key })).first
        // 标记了题目有错的不再复习
        let faulty = QuestionMark.fetch(packID: packID, questionID: questionID, in: context)?.faultyAt != nil
        guard !faulty, let card = ReviewRating.replay(evidence) else {
            if let item { context.delete(item) }
            try? context.save()
            return
        }
        let it = item ?? {
            let i = ReviewItem(packID: packID, questionID: questionID, dueAt: .now)
            context.insert(i)
            return i
        }()
        let seconds = reviewSeconds(packID: packID, questionID: questionID, in: context)
        let due = dueDate(stability: card.stability, lastReview: card.lastReview, seconds: seconds)
        let last = ReviewRating.ratings(evidence).compactMap(\.1).last
        if it.dueAt != due || it.stability != card.stability || it.lastReviewAt != card.lastReview
            || it.lastRating != (last?.rawValue ?? 0) || it.reviewSeconds != seconds {
            it.dueAt = due
            it.stability = card.stability
            it.difficulty = card.difficulty
            it.lastReviewAt = card.lastReview
            it.reps = card.reps
            it.lapses = card.lapses
            it.lastRating = last?.rawValue ?? 0
            it.reviewSeconds = seconds
            it.updatedAt = .now
        }
        try? context.save()
    }

    /// 到期日：按稳定度和这道题的目标记住率算出间隔，取当天 0 点，这样「今天到期」的题一早就能复习
    private static func dueDate(stability: Double, lastReview: Date, seconds: Double?) -> Date {
        let days = FSRS.interval(stability: stability,
                                 retention: seconds.map { ReviewPlan.retention(base: retention, seconds: $0) } ?? retention)
        let cal = Calendar.current
        return cal.startOfDay(for: cal.date(byAdding: .day, value: days, to: lastReview) ?? lastReview)
    }

    /// 修改目标记住率后重算到期日。目标记住率只影响间隔，用题上存好的稳定度、上次复习时间和复习用时算，
    /// 不重放作答（refreshAll 每道题要查好几次库、各存一次，题多时要卡很久）；最后只存一次
    static func retune(in context: ModelContext) {
        for it in (try? context.fetch(FetchDescriptor<ReviewItem>())) ?? [] {
            guard let last = it.lastReviewAt else { continue }
            let due = dueDate(stability: it.stability, lastReview: last, seconds: it.reviewSeconds)
            if it.dueAt != due {
                it.dueAt = due
                it.updatedAt = .now
            }
        }
        try? context.save()
    }

    /// 重算全部题（升级到 FSRS、评分规则变化时）
    static func refreshAll(in context: ModelContext) {
        var keys = Set<String>()
        var ids: [(String, String)] = []
        func add(_ pack: String, _ q: String) {
            guard !QuestionVariant.isVariant(q), keys.insert("\(pack)|\(q)").inserted else { return }
            ids.append((pack, q))
        }
        ((try? context.fetch(FetchDescriptor<AttemptRecord>())) ?? []).forEach { add($0.packID, $0.questionID) }
        ((try? context.fetch(FetchDescriptor<SubjectiveAttempt>())) ?? []).forEach { add($0.packID, $0.questionID) }
        ((try? context.fetch(FetchDescriptor<VariantAttempt>())) ?? []).forEach { add($0.packID, $0.originalID) }
        ((try? context.fetch(FetchDescriptor<ReviewItem>())) ?? []).forEach { add($0.packID, $0.questionID) }
        for (pack, q) in ids { refresh(packID: pack, questionID: q, in: context) }
    }

    /// 评分规则的版本：改了规则就加 1，升级后首次启动时按新规则重算全部题
    /// （1：换成 FSRS；2：快慢改为和这道题以前的用时比，看完答案马上又做错不重复计入；3：一直答对的题也进复习；
    /// 4：多问主观题按小问安排（已撤销）；5：撤销 4，按整题重算；6：主观题不再因与 AI 批改不一致降为困难；
    /// 7：记下复习用时，做一遍要很久的题用更低的目标记住率）
    static let rulesVersion = 7

    static func migrateOnce(in context: ModelContext) {
        let key = "review.rulesVersion"
        guard UserDefaults.standard.integer(forKey: key) < rulesVersion else { return }
        refreshAll(in: context)
        UserDefaults.standard.set(rulesVersion, forKey: key)
    }

    /// 以往复习这道题的用时中位数（秒）：选择题作答加看解析，主观题书写加看答案；改编题是另一道题，不算
    static func reviewSeconds(packID: String, questionID: String, in context: ModelContext) -> Double? {
        let review = AttemptMode.review.rawValue
        let choice = ((try? context.fetch(FetchDescriptor<AttemptRecord>(
            predicate: #Predicate { $0.packID == packID && $0.questionID == questionID && $0.mode == review }))) ?? [])
            .map { $0.durationSeconds + $0.feedbackSeconds }
        let subjective = SubjectiveRecords.attempts(packID: packID, questionID: questionID, in: context)
            .filter { $0.mode == review && $0.assessedAt != nil }
            .map { $0.writingSeconds + $0.feedbackSeconds }
        return ReviewPlan.median((choice + subjective).filter { $0 > 0 })
    }

    // MARK: - 作答 → 评分依据

    private static let choiceSlips: Set<ErrorType> = [.careless, .misread]
    private static let subjectiveSlips = Set([SubjectiveErrorType.calculation, .diagram, .misread, .incomplete]
        .map(\.rawValue))

    static func evidence(packID: String, questionID: String, in context: ModelContext) -> [ReviewEvidence] {
        var list: [ReviewEvidence] = []
        let choice = (try? context.fetch(FetchDescriptor<AttemptRecord>(
            predicate: #Predicate { $0.packID == packID && $0.questionID == questionID },
            sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        // 快慢只和这道题之前有把握答对（不算看答案后不久）的用时比，同一份记录什么时候重算结果都一样
        var earlier: [Double] = []
        for a in choice {
            list.append(evidence(a, baseline: ReviewRating.median(earlier)))
            if a.isCorrect, a.confidence == ChoiceConfidence.sure.rawValue, !a.isImmediateRedo, a.durationSeconds > 0 {
                earlier.append(a.durationSeconds)
            }
        }
        list += SubjectiveRecords.attempts(packID: packID, questionID: questionID, in: context).compactMap(evidence)
        list += VariantAttempt.counted(packID: packID, originalID: questionID, in: context).compactMap(evidence)
        if let at = QuestionMark.fetch(packID: packID, questionID: questionID, in: context)?.masteredAt {
            var e = ReviewEvidence(at: at, correct: true, score: 1, confidence: .sure)
            e.masteredMark = true
            list.append(e)
        }
        return list
    }

    private static func evidence(_ a: AttemptRecord, baseline: Double?) -> ReviewEvidence {
        let score = a.blankResults.isEmpty ? (a.isCorrect ? 1 : 0)
            : Double(a.blankResults.filter { $0 }.count) / Double(a.blankResults.count)
        var e = ReviewEvidence(at: a.createdAt, correct: a.isCorrect, score: score, confidence: .init(stored: a.confidence))
        e.immediate = a.isImmediateRedo
        e.hintShown = a.hintShown
        e.changedAnswer = ReviewRating.changedAnswer(a.selectionHistory)
        if let baseline, a.durationSeconds > 0 { e.slowness = a.durationSeconds / baseline }
        let causes = Set(a.causeTypes)
        e.slipOnly = !causes.isEmpty && causes.isSubset(of: choiceSlips)
        return e
    }

    /// 主观题只算已自评的作答
    private static func evidence(_ a: SubjectiveAttempt) -> ReviewEvidence? {
        guard let r = a.resultValue, a.assessedAt != nil else { return nil }
        let scores = a.parts.compactMap(\.score)
        let score = scores.isEmpty ? (r.score ?? 0) : scores.reduce(0, +) / Double(scores.count)
        var e = ReviewEvidence(at: a.revealedAt ?? a.createdAt, correct: r == .correct, score: score,
                               confidence: .init(stored: a.confidence))
        e.immediate = a.isImmediateRedo
        let strokes = a.strokesBeforeReveal + a.strokesAfterReveal
        if strokes > 0 { e.addedAfterReveal = Double(a.strokesAfterReveal) / Double(strokes) }
        let types = Set(a.errorTypes)
        e.slipOnly = !types.isEmpty && types.isSubset(of: subjectiveSlips)
        return e
    }

    /// 改编题是另一道题，不比较快慢
    private static func evidence(_ v: VariantAttempt) -> ReviewEvidence? {
        guard let r = v.resultValue else { return nil }
        let scores = v.parts.compactMap(\.score)
        let score = scores.isEmpty ? (r.score ?? 0) : scores.reduce(0, +) / Double(scores.count)
        var e = ReviewEvidence(at: v.answeredAt, correct: v.isCorrect, score: score, confidence: .init(stored: v.confidence))
        e.immediate = v.isImmediate
        if v.kind == "choice" {
            e.changedAnswer = ReviewRating.changedAnswer(v.selectionHistory)
            let raws = v.errorTypes.isEmpty ? (v.errorType.map { [$0] } ?? []) : v.errorTypes
            let causes = Set(raws.compactMap(ErrorType.init(rawValue:)))
            e.slipOnly = !causes.isEmpty && causes.isSubset(of: choiceSlips)
        } else {
            let strokes = v.strokesBeforeReveal + v.strokesAfterReveal
            if strokes > 0 { e.addedAfterReveal = Double(v.strokesAfterReveal) / Double(strokes) }
            let types = Set(v.errorTypes)
            e.slipOnly = !types.isEmpty && types.isSubset(of: subjectiveSlips)
        }
        return e
    }
}
