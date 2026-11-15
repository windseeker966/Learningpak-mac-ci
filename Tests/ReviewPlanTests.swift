import Foundation

// 每天的复习量、一组一组地复习与按用时调整的目标记住率（依赖 Learning/Rules/ReviewPlan.swift、FSRS.swift）：
// swiftc -swift-version 6 -parse-as-library -default-isolation MainActor Learning/Rules/FSRS.swift Learning/Rules/ReviewPlan.swift Tests/ReviewPlanTests.swift -o /tmp/review-plan-tests
// /tmp/review-plan-tests
@main
private enum ReviewPlanTests {
    static let day: TimeInterval = 86400
    static var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }
    static let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 20))!
    static let today = cal.startOfDay(for: now)

    static func card(_ key: String, overdue: Double = 0, r: Double = 0.8, seconds: Double? = 30,
                     subjective: Bool = false) -> ReviewPlan.Card {
        .init(key: key, dueAt: today.addingTimeInterval(-overdue * day), retrievability: r, seconds: seconds,
              kind: subjective ? .composite : .choice)
    }

    static func main() {
        // 用时估计：没有自己的用时，取同类题的中位数；同类都没有用默认值
        let est = ReviewPlan.estimates([card("a", seconds: 10), card("b", seconds: 30), card("c", seconds: nil),
                                        card("s", seconds: nil, subjective: true)])
        precondition(est["c"] == 20 && est["a"] == 10)
        precondition(est["s"] == ReviewPlan.Kind.composite.defaultSeconds)

        // 先按同一本书的同类题估，这本书没有再按全部书；填空题和综合题分开估
        var typed = card("typed", seconds: 20, subjective: true); typed.book = "python"; typed.kind = .blank
        var essay = card("essay", seconds: 900, subjective: true); essay.book = "compiler"
        var newEssay = card("newEssay", seconds: nil, subjective: true); newEssay.book = "compiler"
        var other = card("other", seconds: nil, subjective: true); other.book = "os"
        var newBlank = card("newBlank", seconds: nil, subjective: true); newBlank.book = "compiler"; newBlank.kind = .blank
        let byBook = ReviewPlan.estimates([typed, essay, newEssay, other, newBlank])
        precondition(byBook["newEssay"] == 900 && byBook["other"] == 900, "没复习过的综合题不按填空题估")
        precondition(byBook["newBlank"] == 20, "填空题不按综合题估")
        var soloBlank = card("solo", seconds: nil, subjective: true); soloBlank.kind = .blank
        precondition(ReviewPlan.estimates([soloBlank])["solo"] == ReviewPlan.Kind.blank.defaultSeconds)

        // 不限时长：全部都做
        let cards = (0..<10).map { card("q\($0)") }
        precondition(ReviewPlan.select(cards, budget: 0, now: now, calendar: cal).count == 10)
        // 按时长挑：30 秒一题，2 分钟做 4 题
        precondition(ReviewPlan.select(cards, budget: 120, now: now, calendar: cal).count == 4)

        // 先做还记得、又快的题
        let mixed = [card("slow", r: 0.85, seconds: 1200, subjective: true), card("forgot", r: 0.3, seconds: 30),
                     card("fresh", r: 0.8, seconds: 30)]
        precondition(ReviewPlan.select(mixed, budget: 0, now: now, calendar: cal) == ["fresh", "forgot", "slow"])
        // 放不下的长题跳过，用剩下的时长做后面的短题
        let fit = [card("long", r: 0.9, seconds: 600, subjective: true), card("x", r: 0.5, seconds: 60),
                   card("y", r: 0.4, seconds: 60)]
        precondition(ReviewPlan.select(fit, budget: 300, now: now, calendar: cal) == ["x", "y"])
        // 一道都放不下时也至少做一道
        precondition(ReviewPlan.select([card("big", seconds: 3600, subjective: true)], budget: 600,
                                       now: now, calendar: cal) == ["big"])
        // 顺延 3 天以上的排在最前，不会一直被短题挤掉
        let starving = [card("old", overdue: 4, r: 0.5, seconds: 900, subjective: true),
                        card("new1", r: 0.9, seconds: 30), card("new2", r: 0.9, seconds: 30)]
        precondition(ReviewPlan.select(starving, budget: 960, now: now, calendar: cal) == ["old", "new1", "new2"])
        precondition(ReviewPlan.select(starving, budget: 900, now: now, calendar: cal) == ["old"])
        precondition(ReviewPlan.select([card("2days", overdue: 2, r: 0.1, seconds: 30), card("n", r: 0.9, seconds: 30)],
                                       budget: 0, now: now, calendar: cal).first == "n", "顺延不到 3 天照常排")

        // 预计用时可以由调用方按更多的题估出，挑题和显示用同一套
        precondition(ReviewPlan.select([card("u", seconds: nil), card("v", seconds: nil)], budget: 100, now: now,
                                       calendar: cal, cost: ["u": 50, "v": 50]).count == 2)
        precondition(ReviewPlan.select([card("u", seconds: nil), card("v", seconds: nil)], budget: 100, now: now,
                                       calendar: cal, cost: ["u": 80, "v": 80]).count == 1)

        // 一组一组地复习
        func rated(_ key: String, r: Double, seconds: Double, book: String, last: FSRSRating? = .good,
                   subjective: Bool = false) -> ReviewPlan.Card {
            var c = card(key, r: r, seconds: seconds, subjective: subjective)
            c.book = book
            c.lastRating = last
            return c
        }
        let os1 = rated("os1", r: 0.95, seconds: 20, book: "os")
        let os2 = rated("os2", r: 0.90, seconds: 15, book: "os", last: .easy)
        let os3 = rated("os3", r: 0.85, seconds: 25, book: "os")
        let os4 = rated("os4", r: 0.97, seconds: 10, book: "os", last: .again)
        let py = rated("py", r: 0.99, seconds: 10, book: "python")
        let big = rated("big", r: 0.5, seconds: 1200, book: "os", last: .again, subjective: true)
        let queue = [os1, os2, os3, os4, py, big]
        let first = ReviewPlan.block(queue, index: 0)
        precondition(Array(first.prefix(3)) == ["os1", "os2", "os3"],
                     "热身：良好或简单的选择题最多的那本书，按记得的概率、用时排；上次重来的不做热身")
        precondition(first == ["os1", "os2", "os3", "py", "os4"], "其余按记得的概率 ÷ 用时；大题前两组不出现")
        precondition(ReviewPlan.block(queue, index: 1) == ["py", "os4", "os2", "os1", "os3"], "第二组不热身")
        let third = ReviewPlan.block(queue, index: 2)
        precondition(third.first == "big" && third.count == 5, "大题从第三组起出现，放在开头，后面接短题")
        precondition(ReviewPlan.block(queue, index: 1, skipped: ["py"]).last == "py", "跳过过的排最后")
        precondition(!ReviewPlan.block(queue, index: 0, skipped: ["os1"]).prefix(3).contains("os1"), "跳过过的不做热身")
        let forty = (0..<5).map { card("f\($0)", seconds: 40) }
        precondition(ReviewPlan.block(forty, index: 1).count == 3, "2 分钟放不下 5 道时少排")
        precondition(ReviewPlan.block([card("long", seconds: 240, subjective: true)], index: 0) == ["long"], "至少一道")
        precondition(ReviewPlan.block([], index: 0).isEmpty)
        // 更大的组：做完两组后可选 10、15、20 道，时长等比放大，每 5 道最多一道大题
        precondition(ReviewPlan.blockSizes(finished: 1) == [5])
        precondition(ReviewPlan.blockSizes(finished: 2) == [5, 10, 15, 20])
        let many = (0..<30).map { card("m\($0)", seconds: 20) }
        precondition(ReviewPlan.block(many, index: 3, size: 10).count == 10)
        precondition(ReviewPlan.block((0..<10).map { card("g\($0)", seconds: 50) }, index: 3, size: 10).count == 4,
                     "10 道的组 4 分钟")
        let heavies = (0..<3).map { card("h\($0)", seconds: 600, subjective: true) }
        let tenWithBig = ReviewPlan.block(many + heavies, index: 3, size: 10)
        precondition(tenWithBig.prefix(2).allSatisfy { $0.hasPrefix("h") } && !tenWithBig.dropFirst(2).contains { $0.hasPrefix("h") },
                     "10 道的组最多两道大题，放在开头")
        // 热身：良好的题多的书优先，不够再从别的书补
        let lone = [rated("a", r: 0.9, seconds: 10, book: "x"), rated("b", r: 0.8, seconds: 10, book: "y"),
                    rated("c", r: 0.7, seconds: 10, book: "y")]
        precondition(ReviewPlan.warmup(lone) == ["b", "c", "a"])
        // 只在学习时做过（没有复习用时）的题，即使上次简单、记得的概率高，也排在复习里做过、上次良好的后面
        var learned = (0..<4).map { rated("l\($0)", r: 0.99, seconds: 0, book: "os", last: .easy) }
        for i in learned.indices { learned[i].seconds = nil }
        let warm = ReviewPlan.warmup(learned + [rated("p1", r: 0.9, seconds: 5, book: "py"),
                                                rated("p2", r: 0.85, seconds: 5, book: "py")])
        precondition(Array(warm.prefix(2)) == ["p1", "p2"], "热身先挑复习里做过的书和题")
        precondition(warm.count == 3 && warm[2].hasPrefix("l"), "不够再用学习时做过的补")
        precondition(ReviewPlan.closer(learned + [rated("p1", r: 0.5, seconds: 5, book: "py")]) == "p1",
                     "收尾也先挑复习里做过的")
        // 收尾：补一道最熟、最短的选择题；上次良好或简单的优先；没有合适的不补
        precondition(ReviewPlan.closer(queue, excluding: ["os1", "os2"]) == "py")
        precondition(ReviewPlan.closer(queue, excluding: ["os1", "os2", "py"]) == "os3")
        precondition(ReviewPlan.closer(queue, excluding: ["os1", "os2", "os3", "os4", "py"]) == nil, "主观题和大题不用来收尾")

        // 目标记住率：快题不变，慢题降低，最多降 10 个百分点
        precondition(ReviewPlan.retention(base: 0.85, seconds: 30) == 0.85)
        precondition(ReviewPlan.retention(base: 0.85, seconds: 120) == 0.85)
        let mid = ReviewPlan.retention(base: 0.85, seconds: 400)
        precondition(mid < 0.85 && mid > 0.75)
        precondition(abs(ReviewPlan.retention(base: 0.85, seconds: 900) - 0.75) < 1e-9)
        precondition(abs(ReviewPlan.retention(base: 0.85, seconds: 3600) - 0.75) < 1e-9)
        precondition(ReviewPlan.retention(base: 0.75, seconds: 3600) == 0.7, "不低于 70%")
        precondition(ReviewPlan.retention(base: 0.65, seconds: 3600) == 0.65, "设定本来就低于下限时不再降")
        print("ReviewPlan checks passed")
    }
}
