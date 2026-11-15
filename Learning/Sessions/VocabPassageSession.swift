import Foundation
import Observation
import SwiftData

/// 生词本的 AI 短文复习：从背过的词里随机挑一些，请 AI 写一篇用上它们的英文短文；学生写出标出的词在文中的意思，
/// AI 逐词判断，按结论建议每个词的自评（可以改），确认后写进各词的 FSRS 记忆状态。每篇记一条 VocabPassageAttempt
@MainActor
@Observable
final class VocabPassageSession {
    enum Phase {
        /// AI 正在写短文
        case generating
        case answering
        /// AI 正在批改
        case grading
        /// 批改完（或批改失败），等确认自评
        case rating
        /// 已计入复习
        case confirmed
    }

    /// 一篇放这么多个词
    static let wordCount = 12

    private(set) var phase = Phase.generating
    private(set) var passage: VocabPassage?
    /// 这篇短文的编号：在短文里划词加入的生词记在它下面（VocabSelection.init(aiPassageID:)）
    private(set) var passageID = UUID().uuidString
    /// 挑出的词，编号从 1 起：words[id - 1]
    private(set) var words: [VocabEntry] = []
    var answers: [Int: String] = [:]
    /// AI 的结论和说明
    private(set) var grades: [Int: (result: VocabPassageResult, note: String?)] = [:]
    /// 自评：批改完填上建议的一档，可以改
    var ratings: [Int: FSRSRating] = [:]
    private(set) var error: String?
    /// 一小时内背过的词都挑过了（或背过的词太少），这次挑不出一篇
    private(set) var notEnoughWords = false
    /// 这次复习了几篇
    private(set) var finishedCount = 0

    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var attempt: VocabPassageAttempt?

    var configured: Bool { LLMConfig.hasAvailableProvider(.vocabPassage) }

    func entry(_ id: Int) -> VocabEntry? { words.indices.contains(id - 1) ? words[id - 1] : nil }

    /// 短文里用到的词都选好自评了
    var canConfirm: Bool {
        guard phase == .rating, let passage else { return false }
        return passage.usedIDs.allSatisfy { ratings[$0] != nil }
    }

    /// 打开时：挑词、请 AI 写短文
    func start(in context: ModelContext) {
        guard self.context == nil else { return }
        self.context = context
        next()
    }

    /// 再来一篇：重新挑词
    func next() {
        guard let context else { return }
        let all = (try? context.fetch(FetchDescriptor<VocabEntry>())) ?? []
        words = Vocab.passageWords(all, count: Self.wordCount, excluding: Vocab.recentPassageKeys(in: context))
        notEnoughWords = words.count < Vocab.passageMinimum
        if notEnoughWords {
            task?.cancel()
            passage = nil
            error = nil
            return
        }
        generate()
    }

    func generate(useBackup: Bool = false) {
        task?.cancel()
        passage = nil
        passageID = UUID().uuidString
        answers = [:]
        grades = [:]
        ratings = [:]
        attempt = nil
        error = nil
        phase = .generating
        let numbered = words.enumerated().map { (id: $0.offset + 1, entry: $0.element) }
        let user = VocabPassageAI.passageUser(words: numbered)
        let validIDs = Set(numbered.map(\.id))
        let config = useBackup ? (LLMConfig.backup() ?? .current(.vocabPassage)) : .current(.vocabPassage)
        ActivityLog.write("vocab_passage_generate", ["words": words.count, "backup": useBackup])
        task = Task {
            do {
                guard self.configured else { throw LLMError.notConfigured }
                let result = try await LLMClient(config: config, backup: useBackup ? nil : .backup())
                    .complete(system: VocabPassageAI.passageSystem,
                              messages: [ChatTurn(role: .user, text: user)], maxTokens: 1500)
                guard !Task.isCancelled else { return }
                let passage = try VocabPassage(json: result.text, validIDs: validIDs)
                self.passage = passage
                self.save(passage, usage: result.usage)
                self.phase = .answering
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }

    /// 短文写好就存一条记录，之后批改、自评都写进它
    private func save(_ passage: VocabPassage, usage: LLMUsage) {
        guard let context else { return }
        let items = passage.usedIDs.compactMap { id in
            entry(id).map { VocabPassageAttempt.Item(id: id, entryKey: $0.key, word: $0.word, answer: "") }
        }
        let a = VocabPassageAttempt(title: passage.title, passage: passage.text, items: items)
        a.usage = [usage]
        context.insert(a)
        try? context.save()
        attempt = a
    }

    /// 提交作答，请 AI 批改
    func submit(useBackup: Bool = false) {
        guard let passage, phase == .answering || phase == .rating else { return }
        task?.cancel()
        error = nil
        phase = .grading
        updateAttempt { item in item.answer = self.answers[item.id, default: ""] }
        let items = passage.usedIDs.compactMap { id in entry(id).map { (id: id, entry: $0, answer: answers[id, default: ""]) } }
        let user = VocabPassageAI.gradingUser(passage: passage, items: items)
        let config = useBackup ? (LLMConfig.backup() ?? .current(.vocabPassage)) : .current(.vocabPassage)
        ActivityLog.write("vocab_passage_submit", [
            "words": items.count, "blank": items.filter { $0.answer.trimmingCharacters(in: .whitespaces).isEmpty }.count,
        ])
        task = Task {
            do {
                guard self.configured else { throw LLMError.notConfigured }
                let result = try await LLMClient(config: config, backup: useBackup ? nil : .backup())
                    .complete(system: VocabPassageAI.gradingSystem,
                              messages: [ChatTurn(role: .user, text: user)], maxTokens: 1500)
                guard !Task.isCancelled else { return }
                let grades = try VocabPassageAI.parseGrades(result.text)
                self.grades = grades
                for id in passage.usedIDs {
                    // 没写的词 AI 漏判时也按错算
                    let blank = self.answers[id, default: ""].trimmingCharacters(in: .whitespaces).isEmpty
                    if let g = grades[id] { self.ratings[id] = g.result.suggestedRating }
                    else if blank { self.ratings[id] = .again }
                }
                self.attempt?.usage.append(result.usage)
                self.updateAttempt { item in
                    item.result = grades[item.id]?.result.rawValue
                    item.note = grades[item.id]?.note
                }
                self.phase = .rating
            } catch {
                guard !Task.isCancelled else { return }
                // 批改失败也可以自己对照释义自评
                self.error = error.localizedDescription
                self.phase = .rating
            }
        }
    }

    /// 确认自评：写进各词的 FSRS 记忆状态
    func confirm() {
        guard canConfirm, let context else { return }
        let now = Date.now
        for (id, rating) in ratings {
            entry(id)?.rate(rating, at: now, retention: ReviewScheduler.retention)
        }
        updateAttempt { item in item.rating = self.ratings[item.id]?.rawValue }
        attempt?.confirmedAt = now
        try? context.save()
        finishedCount += 1
        phase = .confirmed
        ActivityLog.write("vocab_passage_confirm", [
            "words": ratings.count,
            "correct": grades.values.filter { $0.result == .correct }.count,
            "ratings": ratings.sorted { $0.key < $1.key }.map(\.value.rawValue),
        ])
    }

    func cancel() { task?.cancel() }

    private func updateAttempt(_ change: (inout VocabPassageAttempt.Item) -> Void) {
        guard let attempt else { return }
        var items = attempt.items
        for i in items.indices { change(&items[i]) }
        attempt.items = items
        try? context?.save()
    }
}
