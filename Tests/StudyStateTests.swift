import Foundation

// 状态标注的询问时机、学习节奏提醒（StudyPacePolicy）、答得不对劲（StrugglePolicy）：
// swiftc -swift-version 6 -parse-as-library -default-isolation MainActor Learning/Rules/StudyState.swift Tests/StudyStateTests.swift -o /tmp/study-state-tests
// /tmp/study-state-tests
@main
private enum StudyStateTests {
    static let minute: TimeInterval = 60
    static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * minute) }

    static func main() {
        typealias P = StateCheckPolicy

        // 回到前台
        precondition(P.onActivate(away: nil, onBreak: false, lastPrompt: nil, now: now) == nil, "冷启动不问，做完第一组再问")
        precondition(P.onActivate(away: nil, onBreak: false, lastPrompt: ago(31), now: now) == nil)
        precondition(P.onActivate(away: nil, onBreak: true, lastPrompt: nil, now: now) == .afterBreak, "点了休息再冷启动也问")
        precondition(P.onActivate(away: 2 * minute, onBreak: false, lastPrompt: nil, now: now) == nil, "短暂离开不问")
        precondition(P.onActivate(away: 5 * minute, onBreak: false, lastPrompt: nil, now: now) == .returned)
        precondition(P.onActivate(away: 20 * minute, onBreak: false, lastPrompt: ago(25), now: now) == nil,
                     "离开够久但刚问过，不问")
        precondition(P.onActivate(away: 1 * minute, onBreak: true, lastPrompt: ago(1), now: now) == .afterBreak,
                     "点了休息，回来总要问")

        // 做完今天的第一组复习
        precondition(P.afterFirstBlock(lastPrompt: nil, now: now))
        precondition(!P.afterFirstBlock(lastPrompt: ago(10), now: now), "刚问过不问")
        precondition(P.afterFirstBlock(lastPrompt: ago(31), now: now))

        // 结束复习
        precondition(!P.afterReview(duration: 9 * minute, lastPrompt: nil, now: now), "复习太短不问")
        precondition(P.afterReview(duration: 10 * minute, lastPrompt: nil, now: now))
        precondition(!P.afterReview(duration: 20 * minute, lastPrompt: ago(10), now: now), "刚问过不问")

        // 学习节奏：连续学习的起点
        typealias Pace = StudyPacePolicy
        precondition(Pace.streakStart(nil, lastActive: nil, now: now) == now, "第一次从现在算")
        precondition(Pace.streakStart(ago(30), lastActive: ago(3), now: now) == ago(30), "切出去一下接着算")
        precondition(Pace.streakStart(ago(30), lastActive: ago(4.9), now: now) == ago(30), "离开不到 5 分钟接着算")
        precondition(Pace.streakStart(ago(30), lastActive: ago(5), now: now) == now, "离开 5 分钟算休息过")
        precondition(Pace.streakStart(ago(30), lastActive: nil, now: now) == now)
        precondition(Pace.streakStart(ago(30), lastActive: ago(1), now: now, scale: 0.05) == now, "调试缩短后 30 秒就算休息过")

        // 提醒休息
        precondition(!Pace.restDue(streakSince: ago(39), notBefore: nil, now: now))
        precondition(Pace.restDue(streakSince: ago(40), notBefore: nil, now: now))
        precondition(!Pace.restDue(streakSince: ago(50), notBefore: now.addingTimeInterval(60), now: now), "推迟了还没到")
        precondition(Pace.restDue(streakSince: ago(50), notBefore: ago(1), now: now))

        // 当天累计
        let hour: TimeInterval = 3600
        precondition(Pace.dayMarkDue(total: 1.9 * hour, shown: []) == nil)
        precondition(Pace.dayMarkDue(total: 2 * hour, shown: []) == .dayLight)
        precondition(Pace.dayMarkDue(total: 2.5 * hour, shown: [.dayLight]) == nil, "一档只提醒一次")
        precondition(Pace.dayMarkDue(total: 3 * hour, shown: [.dayLight]) == .dayEnough)
        precondition(Pace.dayMarkDue(total: 3.2 * hour, shown: []) == .dayEnough, "跨过两档只提醒高的")
        precondition(Pace.shownAfter(.dayEnough, shown: []) == [.dayLight, .dayEnough], "提醒过高的，低的也不再提醒")
        precondition(Pace.shownAfter(.dayLight, shown: []) == [.dayLight])
        precondition(Pace.dayMarkDue(total: 3.2 * hour, shown: Pace.shownAfter(.dayEnough, shown: [])) == nil)

        // 计时与切分日期
        precondition(Pace.accrued(since: ago(0.5), now: now) == 30)
        precondition(Pace.accrued(since: ago(30), now: now) == 120, "计时器挂起后醒来最多记 2 分钟")
        precondition(Pace.accrued(since: now.addingTimeInterval(5), now: now) == 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))!
        }
        precondition(Pace.dayKey(at(24, 9), calendar: calendar) == "2026-10-24")
        precondition(Pace.dayKey(at(25, 4, 59), calendar: calendar) == "2026-10-24", "5 点前算前一天")
        precondition(Pace.dayKey(at(25, 5), calendar: calendar) == "2026-10-25")
        for r in StudyReminder.allCases { precondition(StudyReminder(rawValue: r.rawValue) == r) }

        // 答得不对劲
        typealias S = StrugglePolicy
        func answer(_ m: Double, _ correct: Bool, seconds: Double = 20, usualWrong: Double = 0.2) -> S.Answer {
            S.Answer(at: ago(m), correct: correct, seconds: seconds, usualWrong: usualWrong, usualSeconds: 20)
        }
        let start = ago(60)
        // 平时
        precondition(S.usual(correct: Array(repeating: true, count: 19), seconds: Array(repeating: 10, count: 19)) == nil,
                     "记录不够不算平时")
        let u = S.usual(correct: Array(repeating: true, count: 15) + Array(repeating: false, count: 5),
                        seconds: (1...20).map(Double.init))!
        precondition(u.wrong == 0.25 && u.seconds == 10.5)
        // 错得多：最近 10 题错 4 道，平时约 2 道
        let fourWrong = (0..<10).map { answer(Double(10 - $0), $0 < 4 ? false : true) }
        precondition(S.check(answers: fourWrong, skips: [], since: start, now: now)?.signal == .moreWrong)
        precondition(S.check(answers: fourWrong.map { var a = $0; a.usualWrong = 0.3; return a }, skips: [], since: start, now: now) == nil,
                     "平时就常错（如政治）不算")
        let threeWrong = (0..<10).map { answer(Double(10 - $0), $0 < 3 ? false : true) }
        precondition(S.check(answers: threeWrong, skips: [], since: start, now: now) == nil)
        precondition(S.check(answers: Array(fourWrong.prefix(5)), skips: [], since: start, now: now) == nil, "不到 6 题不判断")
        precondition(S.check(answers: fourWrong, skips: [], since: ago(5), now: now) == nil, "只看这段连续学习里的")
        let old = fourWrong.map { var a = $0; a.at = a.at.addingTimeInterval(-20 * minute); return a }
        precondition(S.check(answers: old, skips: [], since: start, now: now) == nil, "只看最近 15 分钟")
        // 只看最近 10 题：前面错的不算
        let earlyWrong = (0..<14).map { answer(Double(14 - $0), $0 < 4 ? false : true) }
        precondition(S.check(answers: earlyWrong, skips: [], since: start, now: now) == nil)
        // 赶：用时不到平时一半又错 3 道
        let rushed = (0..<8).map { answer(Double(9 - $0), $0 < 3 ? false : true, seconds: 6) }
        let found = S.check(answers: rushed, skips: [], since: start, now: now)!
        precondition(found.signal == .rushing && found.wrong == 3 && found.count == 8 && found.speed == 0.3)
        precondition(S.check(answers: rushed.map { var a = $0; a.seconds = 12; return a }, skips: [], since: start, now: now) == nil,
                     "只是稍快不算")
        precondition(S.check(answers: (0..<8).map { answer(Double(8 - $0), $0 < 2 ? false : true, seconds: 6) },
                             skips: [], since: start, now: now) == nil, "快但没怎么错不算")
        // 刚答完 2 分钟内的先不算：留出标记「题目有错」的时间
        let justNow = (0..<6).map { answer(1.5 - Double($0) * 0.1, false) }
        precondition(S.check(answers: justNow, skips: [], since: start, now: now) == nil)
        precondition(S.check(answers: justNow, skips: [], since: start, now: now.addingTimeInterval(S.settle))?.signal == .moreWrong)
        // 跳过
        precondition(S.check(answers: [], skips: [ago(1), ago(3), ago(9)], since: start, now: now)?.signal == .skipping)
        precondition(S.check(answers: [], skips: [ago(1), ago(3), ago(11)], since: start, now: now) == nil, "10 分钟内才算")
        precondition(S.check(answers: [], skips: [ago(1), ago(2)], since: start, now: now) == nil)
        precondition(S.check(answers: [], skips: [ago(1), ago(3), ago(9)], since: ago(5), now: now) == nil, "休息前跳过的不算")
        precondition(S.median([3, 1, 2]) == 2 && S.median([4, 1, 2, 3]) == 2.5 && S.median([]) == nil)
        for s in StruggleSignal.allCases { precondition(StruggleSignal(rawValue: s.rawValue) == s) }

        // 存储值
        for s in StudyState.allCases { precondition(StudyState(rawValue: s.rawValue) == s) }
        precondition(StudyState.allCases.map(\.label) == ["好", "一般", "累", "烦", "低落"])
        for t in StateCheckTrigger.allCases { precondition(StateCheckTrigger(rawValue: t.rawValue) == t) }

        print("StudyStateTests 通过")
    }
}
