import Foundation

/// 主观题看答案前标的把握程度
nonisolated enum SubjectiveConfidence: String, CaseIterable, Sendable {
    case sure, unsure
    case gaveUp = "gave_up"

    var label: String {
        switch self {
        case .sure: "有把握"
        case .unsure: "不确定"
        case .gaveUp: "不会做"
        }
    }
}

/// 选择题提交时标的把握程度（AttemptRecord.confidence，选择题改编结果也是）
nonisolated enum ChoiceConfidence: String, CaseIterable, Sendable {
    case sure, unsure, guess

    var label: String {
        switch self {
        case .sure: "确定"
        case .unsure: "犹豫"
        case .guess: "蒙的"
        }
    }
}

extension ReviewEvidence.Confidence {
    /// 记录里存的把握程度 → 三档：选择题 sure / unsure / guess，主观题和改编题 sure / unsure / gave_up；
    /// 「不会做」和蒙的一样算没把握，其余（含早期记录的空值）算犹豫
    nonisolated init(stored raw: String?) {
        switch raw {
        case ChoiceConfidence.sure.rawValue: self = .sure
        case ChoiceConfidence.guess.rawValue, SubjectiveConfidence.gaveUp.rawValue: self = .guess
        default: self = .unsure
        }
    }
}
