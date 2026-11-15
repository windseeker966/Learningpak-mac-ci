import Foundation

// 说法卡按原题放进来、退出复习队列和回来抽查（依赖 Learning/Rules/PhraseUnlock.swift）：
// swiftc -swift-version 6 -parse-as-library -default-isolation MainActor Learning/Rules/PhraseUnlock.swift Tests/PhraseUnlockTests.swift -o /tmp/phrase-unlock-tests
// /tmp/phrase-unlock-tests
@main
private enum PhraseUnlockTests {
    static let day: TimeInterval = 86400
    static var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }
    static let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 20))!
    static let today = cal.startOfDay(for: now)

    static func q(_ id: String, sec: Int, num: Int, _ phrases: [String], daysAgo: Double,
                  starred: Bool = false, wrong: Int = 0, lastWrongDaysAgo: Double? = nil) -> PhraseUnlock.Candidate {
        var c = PhraseUnlock.Candidate(questionID: id, sectionIndex: sec, num: num, phrases: phrases,
                                       firstAnswered: today.addingTimeInterval(-daysAgo * day + 3600))
        c.starred = starred
        c.wrongCount = wrong
        c.lastWrong = lastWrongDaysAgo.map { now.addingTimeInterval(-$0 * day) }
        return c
    }

    static func main() {
        // 排队：今天才做的不放；全都放过的不排；刚学的（后面的节在前）→ 重点和错得多的（最近错的在前）→ 其余按节和题号
        let all = [
            q("1.1-Q02", sec: 0, num: 2, ["a", "b"], daysAgo: 20),
            q("1.1-Q01", sec: 0, num: 1, ["c"], daysAgo: 20),
            q("1.2-Q05", sec: 1, num: 5, ["d"], daysAgo: 15, wrong: 3, lastWrongDaysAgo: 5),
            q("1.2-Q06", sec: 1, num: 6, ["e"], daysAgo: 15, starred: true, lastWrongDaysAgo: 1),
            q("1.3-Q01", sec: 2, num: 1, ["f"], daysAgo: 1),
            q("1.4-Q01", sec: 3, num: 1, ["g"], daysAgo: 2),
            q("1.4-Q02", sec: 3, num: 2, ["h"], daysAgo: 0),
            q("1.1-Q03", sec: 0, num: 3, ["x"], daysAgo: 20),
        ]
        let order = PhraseUnlock.queue(all, introduced: ["x"], now: now, calendar: cal).map(\.questionID)
        precondition(order == ["1.4-Q01", "1.3-Q01", "1.2-Q06", "1.2-Q05", "1.1-Q01", "1.1-Q02"], "\(order)")

        // 挑题：一次放整道题；放过的卡跳过；超过名额就停
        let queue = [
            q("A", sec: 0, num: 1, ["p1", "p2", "p3", "p4"], daysAgo: 5),
            q("B", sec: 0, num: 2, ["p4", "p5", "p6"], daysAgo: 5),
            q("C", sec: 0, num: 3, ["p7", "p8", "p9", "p10", "p11"], daysAgo: 5),
            q("D", sec: 0, num: 4, ["p1"], daysAgo: 5),
        ]
        let picked = PhraseUnlock.pick(queue, introduced: [], limit: 10, introducedToday: 0)
        precondition(picked.map(\.questionID) == ["A", "B"], "A 4 张、B 新 2 张，加上 C 会到 11 张，今天不放")
        precondition(picked[1].phrases == ["p5", "p6"], "A 放过的 p4 不再放")
        // 今天一张都没放时，第一道题超过名额也照放；放过一些后就不再超
        let big = [q("big", sec: 0, num: 1, (1...12).map { "b\($0)" }, daysAgo: 5)]
        precondition(PhraseUnlock.pick(big, introduced: [], limit: 10, introducedToday: 0).count == 1)
        precondition(PhraseUnlock.pick(big, introduced: [], limit: 10, introducedToday: 3).isEmpty)
        precondition(PhraseUnlock.pick(queue, introduced: [], limit: 10, introducedToday: 10).isEmpty)
        precondition(PhraseUnlock.pick(queue, introduced: [], limit: 0, introducedToday: 0).isEmpty, "名额设成 0 时不放")

        // 选错的选项：选了不该选的、漏了该选的；"-" 下的不算
        let options = ["A": ["pa"], "B": ["pb"], "C": ["pc"], "D": ["pd"], "-": ["ps"]]
        precondition(PhraseUnlock.missed(selected: ["D"], answer: ["B"], options: options) == ["pb", "pd"])
        precondition(PhraseUnlock.missed(selected: ["A", "B", "C", "D"], answer: ["A", "B", "C"], options: options) == ["pd"])
        precondition(PhraseUnlock.missed(selected: ["A", "B"], answer: ["A", "B", "C"], options: options) == ["pc"])
        precondition(PhraseUnlock.missed(selected: ["B"], answer: ["B"], options: options).isEmpty)

        // 退出复习队列：卡都放进来、都自评过才退出
        let fresh = PhraseUnlock.CardState(selfRated: true, intervalDays: 3)
        let stable = PhraseUnlock.CardState(selfRated: true, intervalDays: 45)
        let unrated = PhraseUnlock.CardState(selfRated: false, intervalDays: 1)
        let recent = now.addingTimeInterval(-5 * day)
        let long = now.addingTimeInterval(-40 * day)
        precondition(PhraseUnlock.isRetired(cards: [fresh, fresh], lastAnswered: recent, now: now))
        precondition(!PhraseUnlock.isRetired(cards: [fresh, nil], lastAnswered: recent, now: now), "还有卡没放进来")
        precondition(!PhraseUnlock.isRetired(cards: [fresh, unrated], lastAnswered: recent, now: now), "还有卡没自评")
        precondition(!PhraseUnlock.isRetired(cards: [], lastAnswered: recent, now: now))
        // 回来抽查：卡都背牢、原题也很久没做
        precondition(!PhraseUnlock.isRetired(cards: [stable, stable], lastAnswered: long, now: now))
        precondition(PhraseUnlock.isRetired(cards: [stable, stable], lastAnswered: recent, now: now), "刚抽查过，又退出")
        precondition(PhraseUnlock.isRetired(cards: [stable, fresh], lastAnswered: long, now: now), "还有卡没背牢")

        print("PhraseUnlockTests 全部通过")
    }
}
