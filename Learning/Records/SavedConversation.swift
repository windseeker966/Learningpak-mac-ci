import Foundation

/// 保存展示文字和发给模型的完整上下文，恢复后仍可沿着原对话追问。
nonisolated struct SavedConversation: Codable {
    struct Turn: Codable {
        var role: String
        var text: String
    }

    struct Quote: Codable {
        var text: String
        var source: String
        var paragraph: String
    }

    struct Message: Codable {
        var role: String
        var text: String
        var shown: String
        var quote: Quote?
        var incomplete: Bool?
        var usage: LLMUsage? = nil
        /// App 自动发送的消息（见 ChatSession.Message.auto）
        var auto: Bool? = nil
    }

    var system: String
    var context: [Turn]
    var messages: [Message]
    var draft: String
    var pendingQuote: Quote?
    /// 未完成的流式回答单独保存，不作为完整回答发给模型。
    var partialText: String
    var error: String?
    var partialUsage: LLMUsage? = nil
}

