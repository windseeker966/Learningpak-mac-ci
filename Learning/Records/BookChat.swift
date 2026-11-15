import Foundation
import SwiftData

/// 一本书的一段「AI 提问」对话。对话内容（含 App 自动发送的查阅结果）存在 conversationData
@Model
final class BookChat {
    var id: UUID
    var packID: String
    /// 列表里显示的标题：第一个问题的开头
    var title: String
    var createdAt: Date
    var updatedAt: Date
    /// JSON 编码的 SavedConversation
    var conversationData: Data?

    init(packID: String, title: String) {
        self.id = UUID()
        self.packID = packID
        self.title = title
        self.createdAt = .now
        self.updatedAt = .now
    }

    var conversation: SavedConversation? {
        get { conversationData.flatMap { try? JSONDecoder().decode(SavedConversation.self, from: $0) } }
        set { conversationData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }
}
