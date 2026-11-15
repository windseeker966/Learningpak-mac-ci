import Foundation
import SwiftData

extension BookChatProgress {
    /// 查出这本书的作答、进度和复习记录，整理成全书 AI 提问用的进度
    @MainActor
    static func load(pack: StudyPack, in context: ModelContext) -> BookChatProgress {
        let packID = pack.id
        func fetch<T: PersistentModel>(_ predicate: Predicate<T>) -> [T] {
            (try? context.fetch(FetchDescriptor<T>(predicate: predicate))) ?? []
        }
        return BookChatProgress(
            pack: pack,
            attempts: fetch(#Predicate<AttemptRecord> { $0.packID == packID }),
            subjective: fetch(#Predicate<SubjectiveAttempt> { $0.packID == packID }),
            summaries: fetch(#Predicate<PassageSummaryAttempt> { $0.packID == packID }),
            translations: fetch(#Predicate<BackTranslationAttempt> { $0.packID == packID }),
            progresses: fetch(#Predicate<SectionProgress> { $0.packID == packID }),
            reviews: fetch(#Predicate<ReviewItem> { $0.packID == packID }))
    }
}
