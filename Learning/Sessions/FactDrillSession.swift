import Foundation
import SwiftData

/// 一轮计算测速：按 ArithmeticFacts.dailyTest 抽题，用屏幕键盘作答，从出题到点「确定」计时，自动判对错。
/// 答错的先显示正确答案，点「继续」后接着做；这道题在本轮最后再出一次（同一道题，记为重出，不计入平均用时）。
/// 每答一题就写进 FactDrill 存一次（连同还没做的题），中途关掉也不丢；当天再打开时接着做剩下的题
@MainActor @Observable
final class FactDrillSession {
    enum Phase { case answering, showingAnswer, finished }

    private struct Item {
        let question: FactQuestion
        let retry: Bool
    }

    private var items: [Item]
    private(set) var index = 0
    private(set) var phase = Phase.answering
    /// 正在输入的答案，如「7余1」
    private(set) var input = ""
    /// 刚答完的一题：显示在下一题上方，答错时就是正在显示答案的这题
    private(set) var last: FactResult?

    private var context: ModelContext?
    private var drill: FactDrill?
    /// 接着做的那一轮（start 时用它，不新建）
    private var resuming: FactDrill?
    private var shownAt: TimeInterval = 0
    private var firstKeyAt: TimeInterval?
    private var pausedAt: TimeInterval?

    /// 今天有没做完的一轮就接着做剩下的题，否则抽新的一轮：每类 FactDrill.perKind 题，以前答错、答得慢的多抽
    init(drills: [FactDrill]) {
        if let d = FactDrill.unfinishedToday(drills) {
            resuming = d
            items = d.pending.compactMap { p in
                Fact(key: p.key).flatMap { ArithmeticFacts.question($0, left: p.left) }.map { Item(question: $0, retry: p.retry) }
            }
            answeredBefore = d.results.count
        } else {
            var rng = SystemRandomNumberGenerator()
            items = ArithmeticFacts.dailyTest(perKind: FactDrill.perKind, stats: FactDrill.stats(drills), using: &rng)
                .map { Item(question: $0, retry: false) }
        }
    }

    /// 接着做时，以前已经答过的题数（进度条和标题算上它们）
    private(set) var answeredBefore = 0

    /// 本轮已经抽好的题数（不含重出的）
    var total: Int { items.filter { !$0.retry }.count }
    var count: Int { items.count }
    var current: FactQuestion? { index < items.count ? items[index].question : nil }
    var isRetry: Bool { index < items.count && items[index].retry }
    /// 本轮作答（不算重出）的汇总
    var summary: FactSummary { drill?.summary ?? ArithmeticFacts.summary([]) }
    var results: [FactResult] { drill?.results ?? [] }
    var canSubmit: Bool { phase == .answering && FactAnswer.parse(input) != nil }

    func start(in context: ModelContext) {
        guard self.context == nil else { return }
        self.context = context
        if let d = resuming {
            drill = d
            ActivityLog.write("fact_drill_resume", ["remaining": items.count, "answered": answeredBefore])
            guard !items.isEmpty else { finish(); return }
        } else {
            let d = FactDrill()
            d.pending = pending(from: 0)
            context.insert(d)
            try? context.save()
            drill = d
            ActivityLog.write("fact_drill_start", ["count": items.count])
        }
        showCurrent()
    }

    /// 打开背诵表时暂停这一题的计时，关掉后接着计
    func pauseTiming() {
        if pausedAt == nil { pausedAt = ProcessInfo.processInfo.systemUptime }
    }

    func resumeTiming() {
        guard let p = pausedAt else { return }
        let paused = ProcessInfo.processInfo.systemUptime - p
        shownAt += paused
        firstKeyAt = firstKeyAt.map { $0 + paused }
        pausedAt = nil
    }

    // MARK: - 键盘

    func type(_ digit: Int) {
        guard phase == .answering, input.count < 5 else { return }
        noteKey()
        input += String(digit)
    }

    /// 「余」：前面要有商，只能按一次
    func typeRemainder() {
        guard phase == .answering, !input.isEmpty, !input.contains("余") else { return }
        noteKey()
        input += "余"
    }

    func deleteBackward() {
        guard phase == .answering, !input.isEmpty else { return }
        input.removeLast()
    }

    private func noteKey() {
        if firstKeyAt == nil { firstKeyAt = ProcessInfo.processInfo.systemUptime }
    }

    // MARK: - 提交

    func submit() {
        guard canSubmit, let q = current, let drill else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let given = FactAnswer.parse(input)
        let correct = q.isCorrect(given)
        let result = FactResult(key: q.fact.key, kind: q.fact.kind.rawValue, prompt: q.prompt, answer: q.answer.text,
                                given: input, correct: correct, seconds: now - shownAt,
                                thinkSeconds: firstKeyAt.map { $0 - shownAt }, retry: items[index].retry,
                                answeredAt: .now)
        last = result
        // 答错的在本轮最后再出一次；重出的又答错就不再加
        if !correct, !items[index].retry { items.append(Item(question: q, retry: true)) }
        drill.results.append(result)
        drill.pending = pending(from: index + 1)
        try? context?.save()
        if correct { next() } else { phase = .showingAnswer }
    }

    /// 答错后看过正确答案，接着做
    func proceed() {
        guard phase == .showingAnswer else { return }
        next()
    }

    private func next() {
        index += 1
        if index < items.count {
            phase = .answering
            showCurrent()
        } else {
            finish()
        }
    }

    /// 从第 from 题起还没做的题，存进 FactDrill 供下次接着做
    private func pending(from: Int) -> [FactDrill.Pending] {
        items[min(from, items.count)...].map { FactDrill.Pending(key: $0.question.fact.key, left: $0.question.left, retry: $0.retry) }
    }

    private func showCurrent() {
        input = ""
        firstKeyAt = nil
        shownAt = ProcessInfo.processInfo.systemUptime
    }

    private func finish() {
        phase = .finished
        input = ""
        drill?.finishedAt = .now
        drill?.pending = []
        try? context?.save()
        let s = summary
        ActivityLog.write("fact_drill_finish", ["count": s.count, "correct": s.correct, "fluent": s.fluent,
                                                "average_seconds": s.averageSeconds ?? 0])
    }
}
