import Foundation
import SwiftData

/// 状态标注：自评当时的学习状态（好 / 一般 / 累 / 烦）。
/// 用来校验从作答记录和操作日志推断学习状态的方法；询问时机见 StateCheckPolicy，流程见 StateCheckSession
@Model
final class StateCheck {
    var createdAt: Date
    /// StudyState.rawValue
    var state: String
    /// StateCheckTrigger.rawValue
    var trigger: String
    /// 从出现询问到点选的秒数
    var responseSeconds: Double

    init(state: StudyState, trigger: StateCheckTrigger, responseSeconds: Double, createdAt: Date = .now) {
        self.createdAt = createdAt
        self.state = state.rawValue
        self.trigger = trigger.rawValue
        self.responseSeconds = responseSeconds
    }

    var stateValue: StudyState? { StudyState(rawValue: state) }
    var triggerValue: StateCheckTrigger? { StateCheckTrigger(rawValue: trigger) }

    @discardableResult
    static func record(_ state: StudyState, trigger: StateCheckTrigger, responseSeconds: Double,
                       in context: ModelContext) -> StateCheck {
        let check = StateCheck(state: state, trigger: trigger, responseSeconds: responseSeconds)
        context.insert(check)
        try? context.save()
        return check
    }
}
