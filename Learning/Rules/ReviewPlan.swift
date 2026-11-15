import Foundation

// 每天的复习量、一组一组地复习，以及按用时调整的目标记住率。只依赖 Foundation 和 Rules/FSRS.swift（FSRSRating），
// 测试见 Tests/ReviewPlanTests.swift。
//
// 到期的题按每天的复习时长挑出今天要做的，其余顺延；积压时先做还记得、又花时间少的题
// （单位时间能救回的最多），已经顺延了好几天的题排到最前，不会一直被挤掉。
// 做一遍要很久的题（综合题）用更低的目标记住率，间隔拉长，不至于动不动占掉一天的大半时间。
// 复习时一组一组地做（block）：一组 5 道或 2 分钟；第一组开头是几道短而熟的热身题，组末总是短题，
// 大题从第三组起才出现。开始是最难的一步，把它缩到两分钟。做完两组后可以选更大的组（10、15、20 道）。

nonisolated enum ReviewPlan {
    /// 题的类型。估计没复习过的题的用时按同类题：主观题里的填空题几秒、十几秒，综合题要几分钟到二十几分钟，
    /// 混在一起取中位数，没复习过的综合题会被估成十几秒
    enum Kind: Sendable {
        case choice, blank, composite

        /// 同类题都没有复习用时时的估计（秒）
        var defaultSeconds: Double {
            switch self {
            case .choice: 30
            case .blank: 60
            case .composite: 600
            }
        }
    }

    /// 一道到期的题
    struct Card: Sendable {
        var key: String
        var dueAt: Date
        /// 现在还记得的概率
        var retrievability: Double
        /// 预计用时（秒）；没有以往复习的用时为 nil，按同类题估
        var seconds: Double?
        var kind: Kind
        /// 所在的书；估计没复习过的题时先看同一本书的同类题，热身题也只从一本书里挑
        var book = ""
        /// 最近一次计入的评分；没有为 nil。热身题偏向复习里做过、上次良好或简单的
        var lastRating: FSRSRating? = nil

        /// 复习里做过（seconds 只取复习的用时）。只在学习时做过的题，刚看完讲解答得又对又快，不说明记住了
        var reviewed: Bool { seconds != nil }

        /// 主观题（填空题或综合题）
        var isSubjective: Bool { kind != .choice }
    }
    /// 顺延了这么多天的题优先
    static let overdueFirstDays = 3

    /// 每道题的预计用时：有自己的用时就用自己的；没有的取同一本书同类题（选择题 / 填空题 / 综合题，见 Kind）的中位数，
    /// 这本书没有再取全部书的同类题，都没有用这类题的默认值
    static func estimates(_ cards: [Card]) -> [String: Double] {
        var byBook: [String: Double] = [:]
        var byKind: [Kind: Double] = [:]
        func fallback(_ c: Card) -> Double {
            let bookKey = "\(c.kind)|\(c.book)"
            if let v = byBook[bookKey] { return v }
            let v = median(cards.filter { $0.kind == c.kind && $0.book == c.book }.compactMap(\.seconds))
                ?? byKind[c.kind] ?? {
                    let k = median(cards.filter { $0.kind == c.kind }.compactMap(\.seconds)) ?? c.kind.defaultSeconds
                    byKind[c.kind] = k
                    return k
                }()
            byBook[bookKey] = v
            return v
        }
        return Dictionary(cards.map { ($0.key, $0.seconds ?? fallback($0)) }, uniquingKeysWith: { first, _ in first })
    }

    /// 从到期的题里挑出今天要做的，按做题顺序返回 key。budget 是今天的时长（秒），0 表示不限，全部都做。
    /// 顺序：顺延 overdueFirstDays 天以上的在前（先到期的先做），其余按「记得的概率 ÷ 预计用时」从高到低；
    /// 放不进剩余时长的跳过、接着看后面更短的。至少安排一道
    /// cost 是各题的预计用时（见 estimates，可以按更多的题估出）；缺的按这些到期题估
    static func select(_ cards: [Card], budget: Double, now: Date, calendar: Calendar = .current,
                       cost given: [String: Double]? = nil) -> [String] {
        let own = estimates(cards)
        let cost = own.merging(given ?? [:]) { _, g in g }
        let today = calendar.startOfDay(for: now)
        func overdue(_ c: Card) -> Int {
            calendar.dateComponents([.day], from: calendar.startOfDay(for: c.dueAt), to: today).day ?? 0
        }
        let late = cards.filter { overdue($0) >= overdueFirstDays }.sorted { $0.dueAt < $1.dueAt }
        let rest = cards.filter { overdue($0) < overdueFirstDays }.sorted {
            let a = $0.retrievability / cost[$0.key]!, b = $1.retrievability / cost[$1.key]!
            return a != b ? a > b : $0.dueAt < $1.dueAt
        }
        let ordered = late + rest
        guard budget > 0 else { return ordered.map(\.key) }
        var left = budget
        var picked: [String] = []
        for c in ordered where cost[c.key]! <= left {
            picked.append(c.key)
            left -= cost[c.key]!
        }
        if picked.isEmpty, let first = ordered.first { picked = [first.key] }
        return picked
    }

    // MARK: - 一组一组地复习

    /// 一组的题数和预计时长（秒）：5 道或 2 分钟，先到为准
    static let blockSize = 5
    static let blockSeconds = 120.0
    /// 预计用时超过这个值的算大题
    static let heavySeconds = 300.0
    /// 第一组开头的热身题数
    static let warmupCount = 3
    /// 大题从第几组起出现（从 0 数）
    static let heavyFromBlock = 2
    /// 做完几组后可以选更大的组，以及可选的题数
    static let largerFromBlock = 2
    static let largerSizes = [10, 15, 20]

    /// 做完 finished 组后，下一组可选的题数
    static func blockSizes(finished: Int) -> [Int] {
        finished >= largerFromBlock ? [blockSize] + largerSizes : [blockSize]
    }

    /// 从今天还没做的题里挑出接下来的一组，按做题顺序返回 key。index 是今天的第几组（从 0 起），
    /// size 是这组的题数（时长按 blockSize 道 blockSeconds 等比放大），skipped 是今天跳过过的题，cost 同 select。
    /// 顺序：第一组开头是 warmupCount 道热身题（见 warmup）；其余按「记得的概率 ÷ 预计用时」从高到低，
    /// 跳过过的排最后；大题从第 heavyFromBlock 组起才出现，每 blockSize 道最多一道、放在开头（不计入这组的时长），
    /// 所以组末总是短题。放不进剩余时长的题跳过、接着看后面的；至少安排一道
    static func block(_ cards: [Card], index: Int, size: Int = blockSize, cost given: [String: Double]? = nil,
                      skipped: Set<String> = []) -> [String] {
        let cost = estimates(cards).merging(given ?? [:]) { _, g in g }
        let ordered = cards.sorted { a, b in
            let sa = skipped.contains(a.key), sb = skipped.contains(b.key)
            if sa != sb { return !sa }
            let ra = a.retrievability / cost[a.key]!, rb = b.retrievability / cost[b.key]!
            return ra != rb ? ra > rb : a.dueAt < b.dueAt
        }
        let light = ordered.filter { cost[$0.key]! <= heavySeconds }
        var picked: [String] = []
        var seconds = 0.0
        if index >= heavyFromBlock {
            picked += ordered.filter { cost[$0.key]! > heavySeconds }.prefix(max(size / blockSize, 1)).map(\.key)
        }
        if index == 0 {
            for key in warmup(light.filter { !skipped.contains($0.key) }, cost: cost) {
                picked.append(key)
                seconds += cost[key]!
            }
        }
        for c in light where !picked.contains(c.key) {
            guard picked.count < size else { break }
            let s = cost[c.key]!
            // 第一道短题不管多长都排进来，之后放不下的跳过、接着看后面更短的
            guard seconds == 0 || seconds + s <= blockSeconds * Double(size) / Double(blockSize) else { continue }
            picked.append(c.key)
            seconds += s
        }
        if picked.isEmpty, let first = ordered.first { picked = [first.key] }
        return picked
    }

    /// 热身题：短而熟的选择题，同一本书连做几道。先选书：复习里做过、上次良好或简单的选择题最多的那本
    /// （一样多时看记得的概率），书里不够再从别的书补。排序见 ranked
    static func warmup(_ cards: [Card], cost given: [String: Double]? = nil) -> [String] {
        let cost = estimates(cards).merging(given ?? [:]) { _, g in g }
        let order = ranked(cards, cost: cost)
        let byBook = Dictionary(grouping: order.filter { !$0.isSubjective }, by: \.book)
        let book = byBook.max { x, y in
            let fx = x.value.filter(proven).count, fy = y.value.filter(proven).count
            if fx != fy { return fx < fy }
            let rx = x.value.first?.retrievability ?? 0, ry = y.value.first?.retrievability ?? 0
            return rx != ry ? rx < ry : x.key > y.key
        }?.key ?? order.first?.book
        var picked = order.filter { $0.book == book }.prefix(warmupCount).map(\.key)
        if picked.count < warmupCount {
            picked += order.filter { !picked.contains($0.key) }.prefix(warmupCount - picked.count).map(\.key)
        }
        return picked
    }

    /// 收尾的题：这组最后一道没做对时，从还没做的题里补一道最熟、最短的选择题，让这组以做对结束；没有合适的为 nil
    static func closer(_ cards: [Card], cost given: [String: Double]? = nil, excluding: Set<String> = []) -> String? {
        let cost = estimates(cards).merging(given ?? [:]) { _, g in g }
        let pool = cards.filter { !excluding.contains($0.key) && !$0.isSubjective && cost[$0.key]! <= heavySeconds }
        return ranked(pool, cost: cost).first?.key
    }

    /// 复习里做过、上次良好或简单
    private static func proven(_ c: Card) -> Bool { c.reviewed && (c.lastRating == .good || c.lastRating == .easy) }

    /// 热身和收尾用的排序：选择题在前，复习里做过、上次良好或简单的在前，再按记得的概率从高到低、预计用时从短到长
    private static func ranked(_ cards: [Card], cost: [String: Double]) -> [Card] {
        cards.sorted { a, b in
            if a.isSubjective != b.isSubjective { return !a.isSubjective }
            if proven(a) != proven(b) { return proven(a) }
            if a.retrievability != b.retrievability { return a.retrievability > b.retrievability }
            let ca = cost[a.key]!, cb = cost[b.key]!
            return ca != cb ? ca < cb : a.key < b.key
        }
    }

    // MARK: - 按用时调整的目标记住率

    /// 预计用时不超过 cheapSeconds 的题用设定的目标记住率；到 slowSeconds 及以上的低 maxDrop；
    /// 中间按用时的对数线性过渡。不低于 minRetention
    static let cheapSeconds = 120.0
    static let slowSeconds = 900.0
    static let maxDrop = 0.10
    static let minRetention = 0.7

    static func retention(base: Double, seconds: Double) -> Double {
        guard seconds > cheapSeconds else { return base }
        let t = min(log(seconds / cheapSeconds) / log(slowSeconds / cheapSeconds), 1)
        return max(base - maxDrop * t, min(base, minRetention))
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
