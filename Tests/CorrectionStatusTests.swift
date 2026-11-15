import Foundation

// 错题订正状态的判定：
// swiftc -swift-version 6 -parse-as-library -default-isolation MainActor Learning/Rules/CorrectionStatus.swift Tests/CorrectionStatusTests.swift -o /tmp/correction-status-tests
// /tmp/correction-status-tests
@main
private enum CorrectionStatusTests {
    static let hour: TimeInterval = 3600
    static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func at(_ hours: Double, correct: Bool, sure: Bool = true, seen: Double? = nil,
                   variant: Bool = false) -> AttemptOutcome {
        var o = AttemptOutcome(at: t0.addingTimeInterval(hours * hour), correct: correct, sure: sure,
                               sinceAnswerSeen: seen.map { $0 * hour })
        o.variant = variant
        return o
    }

    static func main() {
        precondition(WrongBook.status([at(0, correct: true)], masteredAt: nil) == nil, "没答错过的题不进错题本")
        precondition(WrongBook.status([at(0, correct: false)], masteredAt: nil) == .unresolved)

        // 看答案 10 分钟后重做答对：立即重做不算
        let immediate = [at(0, correct: false), at(0.2, correct: true, seen: 0.17)]
        precondition(WrongBook.status(immediate, masteredAt: nil) == .unresolved, "立即重做答对不算订正")

        // 隔 3 小时有把握答对：待巩固
        let sameDay = [at(0, correct: false), at(3, correct: true, seen: 3)]
        precondition(WrongBook.status(sameDay, masteredAt: nil) == .consolidating, "不满一天的答对是待巩固")

        // 犹豫答对不算
        let unsure = [at(0, correct: false), at(30, correct: true, sure: false, seen: 30)]
        precondition(WrongBook.status(unsure, masteredAt: nil) == .unresolved, "没把握的答对不算订正")

        // 隔天有把握答对：已订正（输入顺序无关）
        let nextDay = [at(30, correct: true, seen: 30), at(0, correct: false)]
        precondition(WrongBook.status(nextDay, masteredAt: nil) == .resolved, "隔天有把握答对算订正")

        // 订正后又答错：回到未订正
        let relapse = nextDay + [at(60, correct: false, seen: 30)]
        precondition(WrongBook.status(relapse, masteredAt: nil) == .unresolved, "再答错要重新订正")

        // 手动标记已掌握：只在最近一次答错之后才算
        let markAfter = t0.addingTimeInterval(1 * hour)
        precondition(WrongBook.status([at(0, correct: false)], masteredAt: markAfter) == .markedMastered)
        precondition(WrongBook.status(relapse, masteredAt: markAfter) == .unresolved, "标记之后再答错，标记失效")
        precondition(CorrectionStatus.markedMastered.isResolved && !CorrectionStatus.consolidating.isResolved)

        // 改编题答错：原题从没答错过也进错题本；已订正的退回未订正
        precondition(WrongBook.status([at(0, correct: true, seen: nil), at(2, correct: false, variant: true)],
                                      masteredAt: nil) == .unresolved, "改编题答错算原题没掌握")
        precondition(WrongBook.status(nextDay + [at(40, correct: false, seen: 10, variant: true)], masteredAt: nil)
                     == .unresolved, "改编题答错让已订正的退回")
        precondition(WrongBook.lastWrongIsVariant(nextDay + [at(40, correct: false, seen: 10, variant: true)]))
        precondition(!WrongBook.lastWrongIsVariant(relapse))

        // 改编题答对：只能把待巩固升为已订正
        let variantOnly = [at(0, correct: false), at(30, correct: true, seen: 30, variant: true)]
        precondition(WrongBook.status(variantOnly, masteredAt: nil) == .unresolved, "只有改编题答对不算订正")
        precondition(WrongBook.status(sameDay + [at(5, correct: true, seen: 2, variant: true)], masteredAt: nil)
                     == .resolved, "原题待巩固 + 改编题确定答对 = 已订正")
        precondition(WrongBook.status(sameDay + [at(4, correct: true, seen: 0.5, variant: true)], masteredAt: nil)
                     == .consolidating, "看原题答案后不久做的改编题不算")
        precondition(WrongBook.status(sameDay + [at(5, correct: true, sure: false, seen: 2, variant: true)],
                                      masteredAt: nil) == .consolidating, "改编题没把握答对不算")
        print("CorrectionStatusTests passed")
    }
}
