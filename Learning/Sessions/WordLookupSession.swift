import Foundation
import Observation
import SwiftData

/// 划词悬浮窗的流程（文章和网页共用）：单词或短语请 AI 查在这句里的意思，可以加入或移出生词本；
/// 更长的片段请 AI 翻译。悬浮窗关掉时生词还没查完，释义改在后台补上
@MainActor
@Observable
final class WordLookupSession {
    let selection: VocabSelection
    /// 单词或短语（不超过几个词）：查意思、可以加入生词本；否则翻译
    let isWord: Bool
    let runner = StreamRunner()
    @ObservationIgnored private var context: ModelContext?

    init(selection: VocabSelection, isWord: Bool) {
        self.selection = selection
        self.isWord = isWord
    }

    var configured: Bool { LLMConfig.hasAvailableProvider(.vocab) }

    /// 从数据库现取这条生词（回调里不能用视图里可能过时的查询结果）
    func savedEntry() -> VocabEntry? {
        guard let context else { return nil }
        let key = selection.key
        return try? context.fetch(FetchDescriptor<VocabEntry>(predicate: #Predicate { $0.key == key })).first
    }

    /// 打开时：addOnOpen（菜单里选了「加入生词本」）就加入生词本；已有释义的生词直接显示；其余请 AI 查词或翻译
    func start(addOnOpen: Bool, in context: ModelContext) {
        self.context = context
        let entry = savedEntry()
        if addOnOpen && entry == nil && isWord {
            add()
            return
        }
        if let entry {
            if entry.meaning == nil, !runner.isRunning { query() }
            return
        }
        query()
    }

    func retry() { query() }

    /// 加入生词本：刚才已经查到释义就直接用，否则一边查一边等
    func add() {
        guard let context, isWord else { return }
        let done = !runner.isRunning && runner.error == nil && !runner.text.isEmpty
        let preset = done ? VocabAI.Meaning(runner.text) : nil
        guard Vocab.add(selection, preset: preset, startLookup: false, in: context) != nil else { return }
        if preset == nil && !runner.isRunning { query() }
    }

    func remove() {
        guard let context, let e = savedEntry() else { return }
        Vocab.remove(e, in: context)
    }

    /// 悬浮窗关掉：没等查完的，生词的释义改在后台补上
    func finish() {
        let unfinished = runner.isRunning
        runner.cancel()
        if unfinished, let context, let e = savedEntry(), e.meaning == nil { Vocab.fillMeaning(e, in: context) }
    }

    private func query() {
        guard configured else { return }
        if isWord {
            runner.run(system: VocabAI.meaningSystem,
                       messages: [ChatTurn(role: .user, text: VocabAI.meaningUser(word: selection.text,
                                                                                  sentence: selection.sentence))],
                       config: .current(.vocab), onFinish: { [weak self] text in
                // 生词在等释义时，查到的结果直接存进生词本
                guard let self, let e = self.savedEntry(), e.meaning == nil else { return }
                VocabAI.Meaning(text).apply(to: e)
                try? self.context?.save()
            })
        } else {
            runner.run(system: VocabAI.translateSystem,
                       messages: [ChatTurn(role: .user, text: VocabAI.translateUser(
                           selection: selection.text, paragraph: selection.contextParagraph))],
                       config: .current(.vocab))
        }
    }
}
