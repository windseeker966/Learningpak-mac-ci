import Foundation

// 计算基础事实的每日测速：20 以内的进位加法、退位减法，表内除法，带余除法。
// 背熟的事实看到就能答出，不用凑十、不用顺着口诀找；测速就是看每个事实答得有多快、对不对。
// 只依赖 Foundation，可以单独编译测试（见 Tests/ArithmeticFactsTests.swift）。

/// 四类事实
nonisolated enum FactKind: String, CaseIterable, Codable, Sendable {
    case add, sub, div, rem

    var label: String {
        switch self {
        case .add: "进位加法"
        case .sub: "退位减法"
        case .div: "表内除法"
        case .rem: "带余除法"
        }
    }

    /// 熟练线（秒）：从出题到点「确定」不超过这么久算答得熟。带余除法要多按「余」和余数两个键
    var fluentSeconds: Double { self == .rem ? 3 : 2 }

    /// 每日测速现在练的几类（带余除法暂时不练）；手机按 iPad 推的这个列表抽题
    static let practiced: [FactKind] = [.add, .sub, .div]
}

/// 一个事实，测速时的一张卡。
/// add：a + b（a、b 为 2…9，和不小于 11）；sub：a − b（a 为 11…18，b 和差都在 2…9）；div：a ÷ b（b 为 2…9，商为 2…9）；
/// rem：除数 a（2…9）、商 b（1…9）的「倍数区间」，被除数在 a·b+1 … a·b+a−1，每次从区间里随机出一个
nonisolated struct Fact: Hashable, Sendable {
    let kind: FactKind
    let a: Int
    let b: Int

    var key: String { "\(kind.rawValue):\(a):\(b)" }

    /// 从 key 还原；不是这四类里的事实时为 nil
    init?(key: String) {
        let parts = key.split(separator: ":")
        guard parts.count == 3, let kind = FactKind(rawValue: String(parts[0])),
              let a = Int(parts[1]), let b = Int(parts[2]) else { return nil }
        let fact = Fact(kind: kind, a: a, b: b)
        guard ArithmeticFacts.facts(kind).contains(fact) else { return nil }
        self = fact
    }

    init(kind: FactKind, a: Int, b: Int) {
        self.kind = kind
        self.a = a
        self.b = b
    }

    /// 列表里显示的式子和答案，如「13 − 7 = 6」；带余除法显示整个区间，如「50…55 ÷ 7 = 7余…」
    var display: String {
        switch kind {
        case .add: "\(a) + \(b) = \(a + b)"
        case .sub: "\(a) − \(b) = \(a - b)"
        case .div: "\(a) ÷ \(b) = \(a / b)"
        case .rem:
            // 除数是 2 时区间只有一个数
            a == 2 ? "\(a * b + 1) ÷ 2 = \(b)余1" : "\(a * b + 1)…\(a * b + a - 1) ÷ \(a) = \(b)余…"
        }
    }
}

/// 答案：商（或和、差）和余数；没有余数时 remainder 为 nil
nonisolated struct FactAnswer: Equatable, Sendable {
    let value: Int
    var remainder: Int? = nil

    var text: String { remainder.map { "\(value)余\($0)" } ?? "\(value)" }

    /// 解析键盘输入：「6」「7余1」。「余」后面没写数、写了多个「余」、或有别的字符时为 nil
    static func parse(_ s: String) -> FactAnswer? {
        let parts = s.split(separator: "余", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let value = Int(parts[0]) else { return nil }
        guard parts.count == 2 else { return FactAnswer(value: value) }
        guard let r = Int(parts[1]) else { return nil }
        return FactAnswer(value: value, remainder: r)
    }
}

/// 出给学生的一道题
nonisolated struct FactQuestion: Equatable, Sendable {
    let fact: Fact
    let left: Int
    let right: Int
    let answer: FactAnswer

    var symbol: String {
        switch fact.kind {
        case .add: "+"
        case .sub: "−"
        case .div, .rem: "÷"
        }
    }

    var prompt: String { "\(left) \(symbol) \(right)" }

    /// 判对错：余数为 0 和不写余数算一样
    func isCorrect(_ given: FactAnswer?) -> Bool {
        guard let given else { return false }
        return given.value == answer.value && (given.remainder ?? 0) == (answer.remainder ?? 0)
    }
}

/// 一题的作答，存在每轮测速的记录里
nonisolated struct FactResult: Codable, Equatable, Sendable {
    /// Fact.key
    var key: String
    /// FactKind 原始值
    var kind: String
    /// 题面，如「13 − 7」
    var prompt: String
    /// 正确答案，如「6」「7余1」
    var answer: String
    /// 写的答案
    var given: String
    var correct: Bool
    /// 出题到点「确定」
    var seconds: Double
    /// 出题到按下第一个键：想的时间，不含按键
    var thinkSeconds: Double?
    /// 本轮答错后在最后重出的一次：不计入平均用时，也不算这个事实的最近一次成绩
    var retry: Bool = false
    var answeredAt: Date

    var factKind: FactKind? { FactKind(rawValue: kind) }

    /// 答对、且不超过熟练线
    var isFluent: Bool { correct && seconds <= (factKind?.fluentSeconds ?? 2) }
}

/// 一个事实最近一次的成绩（不算重出的那次）
nonisolated struct FactStat: Equatable, Sendable {
    var seconds: Double
    var correct: Bool
    var answeredAt: Date
    /// 一共测过几次
    var count: Int
}

/// 一组作答的汇总（不算重出的那次）
nonisolated struct FactSummary: Equatable, Sendable {
    var count: Int
    var correct: Int
    /// 答对的题的平均用时；没有答对的题时为 nil
    var averageSeconds: Double?
    /// 答对且不超过熟练线的题数
    var fluent: Int

    var accuracy: Double { count == 0 ? 0 : Double(correct) / Double(count) }
}

nonisolated enum ArithmeticFacts {
    /// 某一类的全部事实
    static func facts(_ kind: FactKind) -> [Fact] {
        switch kind {
        case .add:
            (2...9).flatMap { a in (2...9).filter { a + $0 >= 11 }.map { Fact(kind: .add, a: a, b: $0) } }
        case .sub:
            (11...18).flatMap { a in (2...9).filter { (2...9).contains(a - $0) }.map { Fact(kind: .sub, a: a, b: $0) } }
        case .div:
            (2...9).flatMap { d in (2...9).map { Fact(kind: .div, a: d * $0, b: d) } }
        case .rem:
            (2...9).flatMap { d in (1...9).map { Fact(kind: .rem, a: d, b: $0) } }
        }
    }

    static var all: [Fact] { FactKind.allCases.flatMap(facts) }

    /// 背诵表：和为 11…18 的进位加法，交换顺序算同一组（共 20 组）。每组加法同时管着两个退位减法
    static var additionBySum: [(sum: Int, pairs: [(Int, Int)])] {
        (11...18).map { sum in (sum, (2...9).filter { $0 <= sum - $0 && sum - $0 <= 9 }.map { ($0, sum - $0) }) }
    }

    /// 出题。带余除法从倍数区间里随机挑余数
    static func question(_ fact: Fact, using rng: inout some RandomNumberGenerator) -> FactQuestion {
        switch fact.kind {
        case .add: return FactQuestion(fact: fact, left: fact.a, right: fact.b, answer: FactAnswer(value: fact.a + fact.b))
        case .sub: return FactQuestion(fact: fact, left: fact.a, right: fact.b, answer: FactAnswer(value: fact.a - fact.b))
        case .div: return FactQuestion(fact: fact, left: fact.a, right: fact.b, answer: FactAnswer(value: fact.a / fact.b))
        case .rem:
            let r = Int.random(in: 1...(fact.a - 1), using: &rng)
            return FactQuestion(fact: fact, left: fact.a * fact.b + r, right: fact.a,
                                answer: FactAnswer(value: fact.b, remainder: r))
        }
    }

    /// 按事实和左边的数（带余除法是被除数）还原一道题，用来重新判别处（手机复习 App）的作答；数不在这个事实里时为 nil
    static func question(_ fact: Fact, left: Int) -> FactQuestion? {
        guard fact.kind == .rem else { return left == fact.a ? question(fact) : nil }
        let r = left - fact.a * fact.b
        guard (1..<fact.a).contains(r) else { return nil }
        return FactQuestion(fact: fact, left: left, right: fact.a, answer: FactAnswer(value: fact.b, remainder: r))
    }

    /// 加减和表内除法的题（不用随机数）
    private static func question(_ fact: Fact) -> FactQuestion {
        var rng = SystemRandomNumberGenerator()
        return question(fact, using: &rng)
    }

    /// 抽题的权重：没测过的先多抽，上次答错的最多，上次答得慢的按慢的程度加，答得熟的最少
    static func weight(_ stat: FactStat?, kind: FactKind) -> Double {
        guard let stat else { return 2 }
        if !stat.correct { return 4 }
        return 1 + min(max(stat.seconds / kind.fluentSeconds - 1, 0), 2)
    }

    /// 每日测速的题：现在练的每类（FactKind.practiced）各 perKind 题，同一类里不重复，打乱顺序混在一起出。
    /// 按权重不放回地抽（Efraimidis–Spirakis：每个事实取 u^(1/权重)，取最大的几个）
    static func dailyTest(kinds: [FactKind] = FactKind.practiced, perKind: Int, stats: [String: FactStat],
                          using rng: inout some RandomNumberGenerator) -> [FactQuestion] {
        var picked: [Fact] = []
        for kind in kinds {
            let keyed = facts(kind).map { fact -> (Double, Fact) in
                let u = Double.random(in: Double.leastNonzeroMagnitude..<1, using: &rng)
                return (pow(u, 1 / weight(stats[fact.key], kind: kind)), fact)
            }
            picked += keyed.sorted { $0.0 > $1.0 }.prefix(perKind).map(\.1)
        }
        picked.shuffle(using: &rng)
        return picked.map { question($0, using: &rng) }
    }

    /// 每个事实最近一次的成绩；results 按作答时间排好，重出的那次不算
    static func latestStats(_ results: [FactResult]) -> [String: FactStat] {
        var out: [String: FactStat] = [:]
        for r in results where !r.retry {
            out[r.key] = FactStat(seconds: r.seconds, correct: r.correct, answeredAt: r.answeredAt,
                                  count: (out[r.key]?.count ?? 0) + 1)
        }
        return out
    }

    static func summary(_ results: [FactResult]) -> FactSummary {
        let firsts = results.filter { !$0.retry }
        let right = firsts.filter(\.correct)
        return FactSummary(count: firsts.count, correct: right.count,
                           averageSeconds: right.isEmpty ? nil : right.map(\.seconds).reduce(0, +) / Double(right.count),
                           fluent: firsts.filter(\.isFluent).count)
    }
}
