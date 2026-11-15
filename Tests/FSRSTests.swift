import Foundation

// FSRS 记忆模型与评分规则：
// swiftc -swift-version 6 -parse-as-library -default-isolation MainActor Learning/Rules/FSRS.swift Tests/FSRSTests.swift -o /tmp/fsrs-tests
// /tmp/fsrs-tests
@main
private enum FSRSTests {
    static let day: TimeInterval = 86400
    static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func e(_ days: Double, correct: Bool, _ c: ReviewEvidence.Confidence = .sure, score: Double? = nil,
                  configure: (inout ReviewEvidence) -> Void = { _ in }) -> ReviewEvidence {
        var x = ReviewEvidence(at: t0.addingTimeInterval(days * day), correct: correct,
                               score: score ?? (correct ? 1 : 0), confidence: c)
        configure(&x)
        return x
    }

    static func main() {
        // 评分规则
        precondition(ReviewRating.rating(e(0, correct: false)) == .again)
        precondition(ReviewRating.rating(e(0, correct: true)) == .good)
        precondition(ReviewRating.rating(e(0, correct: true, .unsure)) == .hard)
        precondition(ReviewRating.rating(e(0, correct: true, .guess)) == .again, "蒙对不算记住")
        precondition(ReviewRating.rating(e(0, correct: true) { $0.hintShown = true }) == .hard, "看了提示降为困难")
        precondition(ReviewRating.rating(e(0, correct: true) { $0.changedAnswer = true }) == .hard, "改过选择降为困难")
        precondition(ReviewRating.rating(e(0, correct: true) { $0.slowness = 3.5 }) == .hard, "比以前慢 3 倍以上降为困难")
        precondition(ReviewRating.rating(e(0, correct: true) { $0.slowness = 2.5 }) == .good, "慢一些但不到 3 倍仍是良好")
        precondition(ReviewRating.rating(e(0, correct: true) { $0.slowness = 0.3 }) == .easy, "又快又有把握是简单")
        precondition(ReviewRating.rating(e(0, correct: true) { $0.addedAfterReveal = 0.5 }) == .hard)
        precondition(ReviewRating.rating(e(0, correct: true) { $0.immediate = true }) == nil, "立即重做答对不计")
        precondition(ReviewRating.rating(e(0, correct: false) { $0.immediate = true }) == .again, "立即重做答错照样计")
        precondition(ReviewRating.rating(e(0, correct: false, score: 0.75) { $0.slipOnly = true }) == .hard, "会但失误")
        precondition(ReviewRating.rating(e(0, correct: false, score: 0) { $0.slipOnly = true }) == .again)
        precondition(ReviewRating.rating(e(0, correct: false, .guess, score: 0.75) { $0.slipOnly = true }) == .again)

        // 记忆模型：保持率 90% 时间隔约等于稳定性
        precondition(FSRS.interval(stability: 10, retention: 0.9) == 10)
        precondition(FSRS.interval(stability: 10, retention: 0.95) < 10)
        precondition(FSRS.interval(stability: 10_000, retention: 0.9) == FSRS.maxInterval)
        precondition(abs(FSRS.retrievability(elapsedDays: 10, stability: 10) - 0.9) < 1e-9)

        let first = FSRS.review(nil, rating: .again, at: t0)
        precondition(first.stability < 1 && first.lapses == 1)
        let good = FSRS.review(first, rating: .good, at: t0.addingTimeInterval(1 * day))
        let hard = FSRS.review(first, rating: .hard, at: t0.addingTimeInterval(1 * day))
        let easy = FSRS.review(first, rating: .easy, at: t0.addingTimeInterval(1 * day))
        precondition(hard.stability < good.stability && good.stability < easy.stability, "评分越高稳定性越大")
        precondition(good.difficulty < first.difficulty, "答好后难度下降")
        let lapse = FSRS.review(good, rating: .again, at: t0.addingTimeInterval(5 * day))
        precondition(lapse.stability < good.stability && lapse.lapses == 2, "遗忘后稳定性下降")
        // 隔得越久答对，稳定性涨得越多
        let later = FSRS.review(good, rating: .good, at: t0.addingTimeInterval(20 * day))
        let sooner = FSRS.review(good, rating: .good, at: t0.addingTimeInterval(3 * day))
        precondition(later.stability > sooner.stability)

        // 重放：一直有把握答对的题也进复习，首次间隔比答错长
        let goodFirst = ReviewRating.replay([e(0, correct: true)])!
        let againFirst = ReviewRating.replay([e(0, correct: false)])!
        precondition(FSRS.interval(stability: goodFirst.stability, retention: 0.9) == 3)
        precondition(FSRS.interval(stability: againFirst.stability, retention: 0.9) == 1)
        precondition(ReviewRating.replay([e(0, correct: true), e(3, correct: true)]) != nil)
        // 没有计入评分的作答（只有看答案后不久的重做答对）不进复习
        precondition(ReviewRating.replay([e(0, correct: true) { $0.immediate = true }]) == nil)
        let card = ReviewRating.replay([e(3, correct: true), e(0, correct: false)])
        precondition(card != nil && card!.reps == 2 && card!.lastReview == t0.addingTimeInterval(3 * day), "输入顺序无关")

        // 看完答案马上又做错：上一次已记「重来」，不重复计入；隔了一段时间再错照常计入
        let again = [e(0, correct: false), e(0.01, correct: false) { $0.immediate = true }]
        precondition(ReviewRating.replay(again)!.lapses == 1, "马上又做错不重复计入")
        precondition(ReviewRating.replay(again + [e(2, correct: false)])!.lapses == 2)
        // 上一次答对后，看答案不久做错仍要计入
        let slip = [e(0, correct: false), e(2, correct: true), e(2.01, correct: false) { $0.immediate = true }]
        precondition(ReviewRating.replay(slip)!.lapses == 2)

        // 标记已掌握：稳定性大幅提高，从标记时起算
        let mastered = ReviewRating.replay([e(0, correct: false), e(1, correct: true),
                                            e(2, correct: true) { $0.masteredMark = true }])!
        precondition(mastered.stability >= FSRS.masteredMinStability && mastered.lastReview == t0.addingTimeInterval(2 * day))
        // 标记后再答错：照常遗忘
        let relapse = ReviewRating.replay([e(0, correct: false), e(2, correct: true) { $0.masteredMark = true },
                                           e(30, correct: false)])!
        precondition(relapse.stability < 10)
        // 改过选择
        precondition(!ReviewRating.changedAnswer(["B"]))
        precondition(ReviewRating.changedAnswer(["B", "C"]), "单选换了选项")
        precondition(!ReviewRating.changedAnswer(["A", "AB", "ABD"]), "多选陆续勾选不算改")
        precondition(ReviewRating.changedAnswer(["AB", "A"]), "多选取消已选的选项")
        precondition(!ReviewRating.changedAnswer(["B,_,_", "B,A,_", "B,A,C"]), "多空题依次填空不算改")
        precondition(ReviewRating.changedAnswer(["B,_", "C,A"]), "多空题改了已填的空")
        precondition(!ReviewRating.changedAnswer(["B,A", "B,_"]), "清空一个空不算改")

        // 中位数
        precondition(ReviewRating.median([]) == nil)
        precondition(ReviewRating.median([3, 1, 2]) == 2)
        precondition(ReviewRating.median([4, 1, 2, 3]) == 2.5)

        print("FSRSTests passed")
    }
}
