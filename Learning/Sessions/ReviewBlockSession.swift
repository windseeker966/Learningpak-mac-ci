import Foundation
import Observation
import SwiftData

/// 一组一组地复习：从今天还没做的题里每次挑一组（ReviewPlan.block），做完一组再决定要不要再来一组、来几道。
/// 当前这组、今天跳过的题、做完的组数和复习用时存在 UserDefaults（ReviewScheduler.DayBlocks），
/// 中途关掉或退出 App 回来接着做。由 ReviewView 创建并持有，ReviewSessionView 做题时调用。
@MainActor
@Observable
final class ReviewBlockSession {
    /// 今天的进度（见 ReviewScheduler.dayBlocks）
    private(set) var day = ReviewScheduler.dayBlocks()
    /// 今天的计划里仍到期的题，由 ReviewView 在队列变化时传入
    private(set) var planned: [ReviewItem] = []
    /// 今天还没做的题：计划里仍到期、今天没跳过的
    private(set) var remaining: [ReviewItem] = []
    /// 接下来可选的各种题数的一组（按做题顺序）。页面每次刷新都要显示，挑一组要给全部题排序、估用时，
    /// 所以在题或进度变化时挑好存起来（见 recompute），不在 body 里现挑
    private(set) var nextBlocks: [Int: [ReviewItem]] = [:]
    /// 预计用时（秒），按队列里的全部题估
    private(set) var cost: [String: Double] = [:]
    @ObservationIgnored private var kind: (ReviewItem) -> ReviewPlan.Kind = { _ in .choice }
    /// 这组开着的时间（只计 App 在前台）
    @ObservationIgnored private let clock = ActiveClock()

    func update(planned: [ReviewItem], all: [ReviewItem], kind: @escaping (ReviewItem) -> ReviewPlan.Kind) {
        // 跨过 0 点后换成新一天的
        day = ReviewScheduler.dayBlocks()
        self.planned = planned
        self.kind = kind
        cost = ReviewScheduler.estimatedSeconds(all, kind: kind)
        recompute()
    }

    /// 正在进行的一组里还没做的题，按做题顺序；空表示没有进行中的组
    var currentBlock: [ReviewItem] { items(day.current) }

    /// 今天的题都做完了
    var isDone: Bool { remaining.isEmpty }

    /// 今天做过复习：做完过一组，或有一组正在进行
    var startedToday: Bool { day.finished > 0 || !day.current.isEmpty }

    /// 接下来会挑出的一组（还没开始，用来显示「做 N 道 · 约 M 分钟」）；size 为 nil 用上次选的题数
    func nextBlock(size: Int? = nil) -> [ReviewItem] { nextBlocks[size ?? defaultSize] ?? [] }

    /// 下一组可选的题数（做完两组后有 10、15、20 道，见 ReviewPlan.blockSizes），挑出来一样多的只留小的
    var sizeOptions: [Int] {
        var seen = Set<Int>()
        return ReviewPlan.blockSizes(finished: day.finished).filter { seen.insert(nextBlock(size: $0).count).inserted }
    }

    /// 默认的题数：上次选的，还不能选时为 5 道
    var defaultSize: Int {
        ReviewPlan.blockSizes(finished: day.finished).contains(day.size) ? day.size : ReviewPlan.blockSize
    }

    /// 今天复习用了几分钟（含正在进行的这组）
    var minutesToday: Int { Int(((day.seconds + clock.elapsed) / 60).rounded()) }

    /// 热身题：第一组开头的几道，不开画布
    func isWarmup(_ item: ReviewItem) -> Bool {
        day.finished == 0 && day.current.prefix(ReviewPlan.warmupCount).contains(item.key)
    }

    // MARK: - 开始、做题、结束

    /// 挑出一组开始做；size 为 nil 用上次选的题数
    func startBlock(size: Int? = nil) -> [ReviewItem] {
        let size = size ?? defaultSize
        let block = nextBlock(size: size)
        day.current = block.map(\.key)
        day.size = size
        save()
        clock.setRunning(true)
        ActivityLog.write("review_block_start", ["index": day.finished, "count": block.count, "size": size])
        return block
    }

    /// 接着做没做完的这组
    func resume() -> [ReviewItem] {
        clock.setRunning(true)
        ActivityLog.write("review_block_resume", ["index": day.finished, "left": currentBlock.count])
        return currentBlock
    }

    /// App 退到后台、页面关掉时停表（用时记下来），回来接着计
    func setActive(_ active: Bool) {
        if active { clock.setRunning(true) } else { flush() }
    }

    /// 跳过一道：今天不再出现，仍然到期，明天照常
    func skip(_ item: ReviewItem) {
        day.skipped.insert(item.key)
        save()
        recompute()
    }

    /// 答完一道。是这组最后一道又没做对时，补一道短而熟的选择题接在后面，让这组以做对收尾；
    /// 主观题按最近一次自评的结果判断（correct 传 nil）。返回要补的题
    func answered(_ item: ReviewItem, correct: Bool?, isLast: Bool, in context: ModelContext) -> ReviewItem? {
        let ok = correct ?? (SubjectiveRecords.attempts(packID: item.packID, questionID: item.questionID, in: context)
            .max { $0.createdAt < $1.createdAt }?.resultValue == .correct)
        guard isLast, !ok else { return nil }
        let excluding = Set(day.current).union(day.skipped).union([item.key])
        guard let key = ReviewPlan.closer(cards(remaining), cost: cost, excluding: excluding),
              let closer = remaining.first(where: { $0.key == key }) else { return nil }
        day.current.append(key)
        save()
        ActivityLog.write("review_block_closer", ["pack": closer.packID, "question": closer.questionID])
        return closer
    }

    /// 这组做完：记用时和组数，清掉这组。返回是不是今天的第一组（做完第一组后问一句状态）
    @discardableResult
    func finishBlock() -> Bool {
        flush()
        let first = day.finished == 0
        ActivityLog.write("review_block_end", ["index": day.finished, "count": day.current.count,
                                               "today_seconds": day.seconds])
        day.finished += 1
        day.current = []
        save()
        recompute()
        return first
    }

    // MARK: -

    /// 题或进度（跳过、做完一组）变了：重算还没做的题，挑好接下来各种题数的一组
    private func recompute() {
        remaining = planned.filter { !day.skipped.contains($0.key) }
        let cards = cards(remaining)
        var blocks: [Int: [ReviewItem]] = [:]
        for size in ReviewPlan.blockSizes(finished: day.finished) {
            blocks[size] = items(ReviewPlan.block(cards, index: day.finished, size: size, cost: cost,
                                                  skipped: day.skipped))
        }
        nextBlocks = blocks
    }

    private func cards(_ list: [ReviewItem]) -> [ReviewPlan.Card] {
        ReviewScheduler.cards(list, kind: kind)
    }

    private func items(_ keys: [String]) -> [ReviewItem] {
        let byKey = Dictionary(remaining.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        return keys.compactMap { byKey[$0] }
    }

    /// 停表，把这段时间记进今天的用时
    private func flush() {
        clock.setRunning(false)
        guard clock.elapsed > 0 else { return }
        day.seconds += clock.elapsed
        clock.reset()
        save()
    }

    private func save() { ReviewScheduler.save(day) }
}
