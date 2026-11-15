import Foundation

/// 随每次回答保存，避免日后修改设置导致旧回答的模型标记改变。
nonisolated struct LLMUsage: Codable, Equatable, Sendable {
    var model: String
    var provider: String
    var isBackup: Bool
    var reportedByServer = false
    var previousModels: [String]? = nil
    /// 供应商返回的原始结束原因；旧记录没有此字段。
    var finishReason: String? = nil

    mutating func report(model: String, afterText: Bool) {
        guard !model.isEmpty else { return }
        if model != self.model, reportedByServer, afterText {
            previousModels = (previousModels ?? []) + [self.model]
        }
        self.model = model
        reportedByServer = true
    }

    var label: String {
        let models = (previousModels ?? []) + [model]
        return (isBackup ? "备用供应商 · " : "") + provider + " · "
            + (reportedByServer ? "" : "请求模型：") + models.joined(separator: " → ")
    }
}

nonisolated enum LLMStreamEvent: Sendable {
    /// 新供应商从头开始回答，清掉失败供应商的部分输出。
    case started(LLMUsage)
    case model(String)
    case text(String)
    case stopped(String)
}

nonisolated struct LLMCompletion: Sendable {
    var text: String
    var usage: LLMUsage
}
