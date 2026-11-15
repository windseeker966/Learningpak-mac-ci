import PencilKit
import SwiftData

/// 选择题每次作答的笔迹：同一页从这次作答开始后、落在书写区里的笔画（书写区外的不存）。
/// 选择题的页面笔迹不随作答清空，所以按落笔时间区分各次作答：上一次作答最后收集笔迹之后落笔的才属于这一次。
@MainActor
enum ChoiceInk {
    /// 这一页上，这次作答之前那次作答的笔迹收集到什么时候（早期记录用提交时间）；之后落笔的属于这次作答
    /// 在新作答记录写入数据库之前调用
    static func workStart(packID: String, questionID: String, modes: Set<String>, in context: ModelContext) -> Date {
        let all = (try? context.fetch(FetchDescriptor<AttemptRecord>(
            predicate: #Predicate { $0.packID == packID && $0.questionID == questionID }))) ?? []
        return all.filter { modes.contains($0.mode) }
            .map { $0.inkUpdatedAt ?? $0.createdAt }
            .max() ?? .distantPast
    }

    /// 把 since 之后落在书写区里的笔画存进作答记录。没有书写区位置时不改动
    static func save(_ record: AttemptRecord, pageKey: String, since: Date, in context: ModelContext) {
        guard let frames = WritingAreaFrames.frames[pageKey].map({ Array($0.values) }), !frames.isEmpty else { return }
        let page = SubjectiveRecords.pageDrawing(pageKey, in: context)?.strokes ?? []
        let kept = page.filter { s in
            s.path.creationDate >= since && frames.contains { $0.intersects(s.renderBounds) }
        }
        let after = kept.filter { $0.path.creationDate >= record.createdAt }.count
        record.inkData = kept.isEmpty ? nil : PKDrawing(strokes: kept).dataRepresentation()
        record.inkStrokesBefore = kept.count - after
        record.inkStrokesAfter = after
        record.inkUpdatedAt = .now
        try? context.save()
    }
}
