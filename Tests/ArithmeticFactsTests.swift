import Foundation

// 计算基础事实的每日测速（ArithmeticFacts）：
// swiftc -swift-version 6 -parse-as-library -default-isolation MainActor Learning/Rules/ArithmeticFacts.swift Tests/ArithmeticFactsTests.swift -o /tmp/arithmetic-facts-tests
// /tmp/arithmetic-facts-tests
@main
private enum ArithmeticFactsTests {
    /// 固定种子的随机数，结果可重复
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static func main() {
        typealias A = ArithmeticFacts
        var rng = SplitMix(state: 42)

        // 四类各有多少个事实，key 不重复
        precondition(A.facts(.add).count == 36, "20 以内进位加法 36 个")
        precondition(A.facts(.sub).count == 36, "十几减几的退位减法 36 个")
        precondition(A.facts(.div).count == 64, "2…9 的口诀倒过来 64 个")
        precondition(A.facts(.rem).count == 72, "除数 2…9、商 1…9 的倍数区间 72 个")
        precondition(Set(A.all.map(\.key)).count == A.all.count)
        precondition(A.all.allSatisfy { Fact(key: $0.key) == $0 }, "key 能还原")
        precondition(Fact(key: "sub:13:2") == nil && Fact(key: "mul:7:8") == nil && Fact(key: "add:9") == nil)
        precondition(Fact(kind: .sub, a: 13, b: 7).display == "13 − 7 = 6")
        precondition(Fact(kind: .rem, a: 7, b: 7).display == "50…55 ÷ 7 = 7余…")
        precondition(Fact(kind: .rem, a: 2, b: 4).display == "9 ÷ 2 = 4余1")
        // 背诵表：20 组，和 11 的有 2+9、3+8、4+7、5+6
        precondition(A.additionBySum.reduce(0) { $0 + $1.pairs.count } == 20)
        precondition(A.additionBySum.first!.sum == 11 && A.additionBySum.first!.pairs.map { "\($0.0)+\($0.1)" } == ["2+9", "3+8", "4+7", "5+6"])

        // 出的题答案都对：加减在范围内，带余除法的余数在 1…除数−1
        for _ in 0..<5 {
            for f in A.all {
                let q = A.question(f, using: &rng)
                switch f.kind {
                case .add:
                    precondition(q.answer.value == q.left + q.right && q.answer.value >= 11 && q.answer.value <= 18)
                case .sub:
                    precondition(q.answer.value == q.left - q.right && (2...9).contains(q.answer.value) && q.left >= 11)
                case .div:
                    precondition(q.left == q.right * q.answer.value && q.answer.remainder == nil)
                case .rem:
                    let r = q.answer.remainder!
                    precondition(q.left == q.right * q.answer.value + r && (1..<q.right).contains(r))
                }
            }
        }

        // 还原题目（重新判手机上的作答）
        precondition(A.question(Fact(kind: .rem, a: 7, b: 7), left: 50)?.answer == FactAnswer(value: 7, remainder: 1))
        precondition(A.question(Fact(kind: .rem, a: 7, b: 7), left: 49) == nil && A.question(Fact(kind: .rem, a: 7, b: 7), left: 56) == nil)
        precondition(A.question(Fact(kind: .sub, a: 13, b: 7), left: 13)?.answer == FactAnswer(value: 6))
        precondition(A.question(Fact(kind: .sub, a: 13, b: 7), left: 14) == nil)

        // 解析键盘输入
        precondition(FactAnswer.parse("6") == FactAnswer(value: 6))
        precondition(FactAnswer.parse("7余1") == FactAnswer(value: 7, remainder: 1))
        precondition(FactAnswer.parse("12") == FactAnswer(value: 12))
        precondition(FactAnswer.parse("") == nil && FactAnswer.parse("7余") == nil && FactAnswer.parse("余1") == nil)
        precondition(FactAnswer.parse("7余1余2") == nil)
        precondition(FactAnswer(value: 7, remainder: 1).text == "7余1" && FactAnswer(value: 6).text == "6")

        // 判对错：余数要对上；整除时写「余0」也算对；带余的只写商不算对
        let fifty = FactQuestion(fact: Fact(kind: .rem, a: 7, b: 7), left: 50, right: 7,
                                 answer: FactAnswer(value: 7, remainder: 1))
        precondition(fifty.prompt == "50 ÷ 7")
        precondition(fifty.isCorrect(FactAnswer.parse("7余1")))
        precondition(!fifty.isCorrect(FactAnswer.parse("7")) && !fifty.isCorrect(FactAnswer.parse("7余2")))
        precondition(!fifty.isCorrect(nil))
        let div = FactQuestion(fact: Fact(kind: .div, a: 56, b: 7), left: 56, right: 7, answer: FactAnswer(value: 8))
        precondition(div.isCorrect(FactAnswer.parse("8")) && div.isCorrect(FactAnswer.parse("8余0")))
        precondition(!div.isCorrect(FactAnswer.parse("7")))

        // 每日测速：现在练的每类各 perKind 题，同一类不重复；不练的类不出
        let test = A.dailyTest(perKind: 10, stats: [:], using: &rng)
        precondition(test.count == 10 * FactKind.practiced.count)
        for kind in FactKind.allCases {
            let keys = test.filter { $0.fact.kind == kind }.map(\.fact.key)
            precondition(keys.count == (FactKind.practiced.contains(kind) ? 10 : 0) && Set(keys).count == keys.count)
        }
        precondition(A.dailyTest(kinds: FactKind.allCases, perKind: 10, stats: [:], using: &rng).count == 40)
        precondition(A.dailyTest(kinds: [.sub], perKind: 50, stats: [:], using: &rng).count == 36, "不够时全出")

        // 权重：答错的 > 没测过的 ≥ 答得慢的 > 答得熟的
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let wrong = FactStat(seconds: 1, correct: false, answeredAt: now, count: 1)
        let slow = FactStat(seconds: 4, correct: true, answeredAt: now, count: 1)
        let fluent = FactStat(seconds: 1, correct: true, answeredAt: now, count: 1)
        precondition(A.weight(wrong, kind: .sub) > A.weight(nil, kind: .sub))
        precondition(A.weight(nil, kind: .sub) >= A.weight(slow, kind: .sub))
        precondition(A.weight(slow, kind: .sub) > A.weight(fluent, kind: .sub))
        precondition(A.weight(FactStat(seconds: 2.9, correct: true, answeredAt: now, count: 1), kind: .rem) == 1,
                     "带余除法 3 秒内算熟")

        // 上次答错的那个事实，抽中的次数明显多于答得熟的
        var stats: [String: FactStat] = [:]
        for f in A.facts(.sub) { stats[f.key] = fluent }
        let target = Fact(kind: .sub, a: 13, b: 7).key
        stats[target] = wrong
        var hits = 0
        for _ in 0..<400 where A.dailyTest(kinds: [.sub], perKind: 5, stats: stats, using: &rng)
            .contains(where: { $0.fact.key == target }) { hits += 1 }
        // 36 个里抽 5 个：权重都一样时约 14%（56 次）；答错的权重是 4 倍，应明显更多
        precondition(hits > 120, "答错的事实抽中 \(hits) 次")

        // 最近一次成绩和汇总都不算重出的那次
        func result(_ key: String, _ correct: Bool, _ s: Double, retry: Bool = false, at t: Double) -> FactResult {
            FactResult(key: key, kind: "sub", prompt: "", answer: "", given: "", correct: correct, seconds: s,
                       thinkSeconds: nil, retry: retry, answeredAt: now.addingTimeInterval(t))
        }
        let results = [result("sub:13:7", false, 3, at: 0), result("sub:14:6", true, 1.5, at: 1),
                       result("sub:13:7", true, 1.2, retry: true, at: 2), result("sub:14:6", true, 2.5, at: 3)]
        let latest = A.latestStats(results)
        precondition(latest["sub:13:7"] == FactStat(seconds: 3, correct: false, answeredAt: now, count: 1))
        precondition(latest["sub:14:6"]?.seconds == 2.5 && latest["sub:14:6"]?.count == 2)
        let sum = A.summary(results)
        precondition(sum.count == 3 && sum.correct == 2 && sum.fluent == 1)
        precondition(sum.averageSeconds == 2.0 && abs(sum.accuracy - 2.0 / 3) < 1e-9)
        precondition(A.summary([]).averageSeconds == nil && A.summary([]).accuracy == 0)

        print("ArithmeticFactsTests passed")
    }
}
