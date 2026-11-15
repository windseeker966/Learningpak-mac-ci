import Foundation
import SwiftData

/// 生词本的收词流程：加入生词本、请 AI 写出语境释义并存进记录
extension Vocab {
    /// 加入生词本。preset 是刚才划词翻译得到的释义；没有时 startLookup 为真就在后台请 AI 写出语境释义
    /// （悬浮窗里会自己查并实时显示，传 false）
    @discardableResult
    static func add(_ selection: VocabSelection,
                    preset: VocabAI.Meaning? = nil, startLookup: Bool = true, in context: ModelContext) -> VocabEntry? {
        guard selection.isValid else { return nil }
        let word = selection.text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !word.isEmpty else { return nil }
        let key = selection.key
        if let existing = try? context.fetch(FetchDescriptor<VocabEntry>(predicate: #Predicate { $0.key == key })).first {
            return existing
        }
        let entry = VocabEntry(packID: selection.packID, passageID: selection.passageID, paragraph: selection.paragraph,
                               location: selection.range.location, length: selection.range.length, word: word,
                               sentence: selection.sentence)
        entry.sourceTitle = selection.sourceTitle
        context.insert(entry)
        if let preset, preset.meaning != nil {
            preset.apply(to: entry)
        } else if startLookup {
            fillMeaning(entry, in: context)
        }
        try? context.save()
        return entry
    }

    /// 请 AI 写出这个词在原句里的意思；没配置模型或失败时留空，可以稍后重试
    static func fillMeaning(_ entry: VocabEntry, in context: ModelContext) {
        guard LLMConfig.hasAvailableProvider(.vocab) else { return }
        let word = entry.word, sentence = entry.sentence
        Task {
            guard let result = try? await LLMClient(config: .current(.vocab))
                .complete(system: VocabAI.meaningSystem, messages: [ChatTurn(role: .user, text: VocabAI.meaningUser(word: word, sentence: sentence))],
                          maxTokens: 400) else { return }
            VocabAI.Meaning(result.text).apply(to: entry)
            try? context.save()
        }
    }
}

extension VocabAI.Meaning {
    /// 把释义存进生词
    func apply(to entry: VocabEntry) {
        entry.meaning = meaning
        entry.form = form
        entry.note = note
        entry.phonetic = phonetic
    }
}
