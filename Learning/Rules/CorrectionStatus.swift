import Foundation

// 错题订正状态的判定规则。只依赖 Foundation，可以单独编译测试（见 Tests/CorrectionStatusTests.swift）

/// 错题的订正状态
nonisolated enum CorrectionStatus {
    /// 最近一次答错之后，还没有确定地答对过（看答案后不久的重做不算）
    case unresolved
    /// 答错之后确定地答对了，但距上次看答案不到一天，可能还记得答案
    case consolidating
    /// 答错之后，隔天以上确定地答对；或确定地答对原题之后，改编题也确定地答对
    case resolved
    /// 最近一次答错之后手动标为已掌握
    case markedMastered

    var label: String {
        switch self {
        case .unresolved: "未订正"
        case .consolidating: "待巩固"
        case .resolved: "已订正"
        case .markedMastered: "已掌握（手动）"
        }
    }

    var isResolved: Bool { self == .resolved || self == .markedMastered }
}

/// 判断订正状态用到的一次作答结果
nonisolated struct AttemptOutcome {
    let at: Date
    let correct: Bool
    /// 作答时标的把握程度是「确定 / 有把握」
    let sure: Bool
    /// 距上次看到这道题答案的秒数；第一次作答为 nil
    let sinceAnswerSeen: Double?
    /// AI 改编题的结果（算作原题的作答，但答对时不能单独让原题算订正）
    var variant = false

    var immediate: Bool { (sinceAnswerSeen ?? .infinity) < WrongBook.immediateRedoInterval }
}

nonisolated enum WrongBook {
    /// 看到答案后不到这么久的重做多半凭刚看过的答案，不算掌握的证据
    static let immediateRedoInterval: TimeInterval = 3600
    /// 答错后要隔这么久（距上次看答案）再确定地答对，才算订正
    static let consolidateInterval: TimeInterval = 24 * 3600

    /// outcomes 不限顺序，可以包含改编题的结果（改编题标记有错的不要传入）。从没答错过返回 nil。
    /// 改编题答错和原题答错一样；改编题答对只能把「待巩固」升为「已订正」：原题本身至少要确定地答对过一次
    static func status(_ outcomes: [AttemptOutcome], masteredAt: Date?) -> CorrectionStatus? {
        guard let lastWrong = outcomes.filter({ !$0.correct }).map(\.at).max() else { return nil }
        if let masteredAt, masteredAt > lastWrong { return .markedMastered }
        let later = outcomes.filter { $0.at > lastWrong && $0.correct && $0.sure && !$0.immediate }
        let original = later.filter { !$0.variant }
        if original.contains(where: { ($0.sinceAnswerSeen ?? .infinity) >= consolidateInterval }) { return .resolved }
        if original.isEmpty { return .unresolved }
        return later.contains(where: \.variant) ? .resolved : .consolidating
    }

    /// 最近一次答错是不是改编题
    static func lastWrongIsVariant(_ outcomes: [AttemptOutcome]) -> Bool {
        outcomes.filter { !$0.correct }.max { $0.at < $1.at }?.variant ?? false
    }
}
