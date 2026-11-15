import Foundation
import SwiftData

/// 一次回译：手写的笔迹截图和/或键盘输入的英文，以及 AI 点评
@Model
final class BackTranslationAttempt {
    /// packID|passageID|英文原句（BackTranslationAttempt.key）
    @Attribute(originalName: "cardKey") var sentenceKey: String
    var packID: String
    var passageID: String
    /// 键盘输入的英文；手写时可为空
    var answer: String
    /// 书写区的笔迹截图（JPEG 的 JSON 数组），发给 AI 的就是这些
    var inkImagesData: Data?
    var mode: String
    var feedback: String?
    /// 点评没有生成完（出错或中途离开）
    var feedbackIncomplete = false
    var usageData: Data?
    var createdAt: Date

    var usage: LLMUsage? {
        get { usageData.flatMap { try? JSONDecoder().decode(LLMUsage.self, from: $0) } }
        set { usageData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    var inkImages: [Data] {
        get { inkImagesData.flatMap { try? JSONDecoder().decode([Data].self, from: $0) } ?? [] }
        set { inkImagesData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    init(sentenceKey: String, packID: String, passageID: String, answer: String, inkImages: [Data]) {
        self.sentenceKey = sentenceKey
        self.packID = packID
        self.passageID = passageID
        self.answer = answer
        mode = AttemptMode.learn.rawValue
        createdAt = .now
        self.inkImages = inkImages
    }

    static func key(packID: String, passageID: String, english: String) -> String {
        "\(packID)|\(passageID)|\(english)"
    }
}

/// 一次文章概括：手写的笔迹截图和/或键盘输入的概括，以及 AI 点评
@Model
final class PassageSummaryAttempt {
    var packID: String
    var passageID: String
    /// 键盘输入的概括；手写时可为空
    var typedText: String = ""
    var inkImagesData: Data?
    var feedback: String?
    var feedbackIncomplete = false
    var usageData: Data?
    var createdAt: Date

    var usage: LLMUsage? {
        get { usageData.flatMap { try? JSONDecoder().decode(LLMUsage.self, from: $0) } }
        set { usageData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    var inkImages: [Data] {
        get { inkImagesData.flatMap { try? JSONDecoder().decode([Data].self, from: $0) } ?? [] }
        set { inkImagesData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    init(packID: String, passageID: String, typedText: String, inkImages: [Data]) {
        self.packID = packID
        self.passageID = passageID
        self.typedText = typedText
        createdAt = .now
        self.inkImages = inkImages
    }
}
