#if DEBUG
import Foundation
import SwiftData

/// 综合题讲评的图片顺序、提示词边界及按作答保存的回归，只使用内存记录。
enum SubjectiveReviewChecks {
    static func run(pack: StudyPack, question: SubjectiveQuestion) throws {
        let container = try ModelContainer(for: SubjectiveAttempt.self,
                                            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let record = SubjectiveAttempt(packID: "fixture", sectionID: "fixture", questionID: question.id, mode: AttemptMode.learn.rawValue)
        record.partLabels = question.effectiveParts.map(\.label)
        record.partResults = question.effectiveParts.map { _ in PartResult.partial.rawValue }
        record.result = PartResult.partial.rawValue
        record.errorTypes = [SubjectiveErrorType.method.rawValue]
        record.errorNote = "关键步骤不确定"
        record.gradings = [SavedGrading(model: "fixture", text: "需要检查第二步。", completed: true)]
        let images = [Data("handwriting".utf8), Data("answer".utf8)]
        let (system, messages) = Prompts.subjectiveReview(pack: pack, question: question, attempt: record,
                                                        handwritingCount: 1, images: images)
        precondition(system.contains("不得虚构") && messages[0].text.contains("关键步骤不确定"))
        precondition(messages[0].text.contains("需要检查第二步") && messages[0].images == images)
        let conversation = SavedConversation(system: system,
            context: messages.map { .init(role: $0.role.rawValue, text: $0.text) },
            messages: [.init(role: "assistant", text: "先核对条件。", shown: "先核对条件。")],
            draft: "为什么先判断条件？", pendingQuote: nil, partialText: "", error: nil)
        record.reviewConversationData = try JSONEncoder().encode(conversation)
        record.reviewImagesData = try JSONEncoder().encode(images)
        container.mainContext.insert(record)
        try container.mainContext.save()
        let otherContext = ModelContext(container)
        let reloaded = try otherContext.fetch(FetchDescriptor<SubjectiveAttempt>()).first!
        let restored = ChatSession()
        restored.restore(try JSONDecoder().decode(SavedConversation.self, from: reloaded.reviewConversationData!))
        restored.context[0].images = try JSONDecoder().decode([Data].self, from: reloaded.reviewImagesData!)
        precondition(restored.draft == conversation.draft && restored.messages[0].text == "先核对条件。")
        precondition(restored.context[0].images == images)
        let redo = SubjectiveAttempt(packID: "fixture", sectionID: "fixture", questionID: question.id, mode: AttemptMode.redo.rawValue)
        precondition(redo.reviewConversationData == nil && redo.reviewImagesData == nil)
        print("Subjective review prompt, image snapshot, persistence, restore and redo checks passed")
    }
}
#endif
