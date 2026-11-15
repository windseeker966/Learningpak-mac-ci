import Foundation
import Observation
import SwiftData

/// AI 改编复习：逐题让 AI 在原题上改编出一道新题。做当前题时在后台改编后两道题；改编失败可重试或跳过。
/// 界面见 AIVariantRunner；作答和结果记录由各题的 ChoiceAttemptSession、SubjectiveAttemptSession 负责
@MainActor
@Observable
final class VariantSession {
    enum Entry {
        case choice(StudyPack, Question)
        case subjective(StudyPack, SubjectiveQuestion)
    }

    let entries: [Entry]
    private(set) var index = 0
    private(set) var results: [Int: Result<QuestionVariant.Generated, Error>] = [:]
    private(set) var subjectiveResults: [Int: Result<QuestionVariant.SubjectiveGenerated, Error>] = [:]
    /// 主观题改编好的题的标识（每次改编一个新的）
    private(set) var subjectiveIDs: [Int: String] = [:]

    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var running: Set<Int> = []
    @ObservationIgnored private var tasks: [Int: Task<Void, Never>] = [:]
    /// 除当前题外提前改编几道
    private static let lookahead = 2

    init(entries: [Entry]) {
        self.entries = entries
    }

    var isFinished: Bool { index >= entries.count }

    /// 当前选择题改编好的题
    var current: QuestionVariant.Generated? {
        if case .success(let g) = results[index] { return g }
        return nil
    }

    /// 当前主观题改编好了的标识（重新改编时换成新的）
    var subjectiveReady: String? {
        if case .success = subjectiveResults[index] { return subjectiveIDs[index] }
        return nil
    }

    /// 当前变式题的 id；nil 表示正在改编或已做完
    var currentVariantID: String? {
        guard index < entries.count else { return nil }
        if case .subjective = entries[index] { return subjectiveReady }
        return current?.question.id
    }

    func start(in context: ModelContext) {
        self.context = context
        prepareAhead()
    }

    /// 下一题；做完最后一题返回 false
    func advance() -> Bool {
        if index >= entries.count - 1 { return false }
        index += 1
        prepareAhead()
        return true
    }

    func cancel() {
        tasks.values.forEach { $0.cancel() }
    }

    /// 重新改编当前题
    func regenerate(useBackup: Bool) {
        prepare(index, force: true, useBackup: useBackup)
    }

    /// 改编用的模型存进 PendingVariant
    static func encode(_ usage: LLMUsage?) -> Data? { usage.flatMap { try? JSONEncoder().encode($0) } }

    /// 改编当前题和之后几道
    private func prepareAhead() {
        for i in index...(index + Self.lookahead) { prepare(i) }
    }

    /// 改编第 i 题（已有结果或正在改编时不重复）
    private func prepare(_ i: Int, force: Bool = false, useBackup: Bool = false) {
        guard let context, i < entries.count,
              force || (results[i] == nil && subjectiveResults[i] == nil && !running.contains(i))
        else { return }
        tasks[i]?.cancel()
        running.insert(i)
        switch entries[i] {
        case .choice(let pack, let original):
            // 上次改编好、还没做的题直接用；重新改编时不要它
            if !force, let p = PendingVariant.usable(packID: pack.id, originalID: original.id, kind: "choice", in: context),
               let g = QuestionVariant.restore(p, original: original) {
                results[i] = .success(g)
                running.remove(i)
                return
            }
            if force { PendingVariant.discard(packID: pack.id, originalID: original.id, in: context) }
            // 只读以往在书里作答的记录，交给 AI 参考
            let history = AttemptRecord.all(packID: pack.id, questionID: original.id, in: context)
            let variants = VariantAttempt.all(packID: pack.id, originalID: original.id, in: context)
            let faults = QuestionMark.rated(packID: pack.id, in: context)
            results[i] = nil
            tasks[i] = Task {
                do {
                    let g = try await QuestionVariant.generate(pack: pack, original: original, attempts: history,
                                                               variants: variants, faults: faults, useBackup: useBackup)
                    guard !Task.isCancelled else { return }
                    results[i] = .success(g)
                    PendingVariant.save(packID: pack.id, sectionID: pack.questionSection[original.id] ?? "",
                                        originalID: original.id, variantID: g.question.id, kind: "choice",
                                        content: Data(g.json.utf8), usageData: Self.encode(g.usage), in: context)
                } catch {
                    guard !Task.isCancelled else { return }
                    results[i] = .failure(error)
                }
                running.remove(i)
            }
        case .subjective(let pack, let original):
            let packID = pack.id, originalID = original.id
            if !force, let p = PendingVariant.usable(packID: packID, originalID: originalID, kind: "subjective", in: context),
               let g = QuestionVariant.restoreSubjective(p) {
                subjectiveIDs[i] = p.variantID
                subjectiveResults[i] = .success(g)
                running.remove(i)
                return
            }
            if force { PendingVariant.discard(packID: packID, originalID: originalID, in: context) }
            let attempts = SubjectiveRecords.attempts(packID: packID, questionID: originalID, in: context)
            let variants = VariantAttempt.all(packID: packID, originalID: originalID, in: context)
            let faults = QuestionMark.rated(packID: packID, in: context)
            subjectiveResults[i] = nil
            tasks[i] = Task {
                do {
                    let g = try await QuestionVariant.generateSubjective(pack: pack, original: original, attempts: attempts,
                                                                         variants: variants, faults: faults, useBackup: useBackup)
                    guard !Task.isCancelled else { return }
                    let id = QuestionVariant.newID(originalID: originalID)
                    subjectiveIDs[i] = id
                    subjectiveResults[i] = .success(g)
                    if let content = g.content {
                        PendingVariant.save(packID: packID, sectionID: pack.questionSection[originalID] ?? "",
                                            originalID: originalID, variantID: id, kind: "subjective",
                                            content: content, usageData: Self.encode(g.usage), in: context)
                    }
                    ActivityLog.write("ai_adapt_subjective", ["question": originalID, "model": g.usage?.model ?? "",
                                                         "stem": String(g.stem.prefix(300)), "answer_chars": g.answer.count])
                } catch {
                    guard !Task.isCancelled else { return }
                    subjectiveResults[i] = .failure(error)
                    ActivityLog.write("ai_adapt_subjective_error", ["question": originalID, "error": error.localizedDescription])
                }
                running.remove(i)
            }
        }
    }
}

/// 原题下方展开的一道选择题 AI 改编。界面见 InlineAIVariant；作答和结果记录由 ChoiceAttemptSession 负责。
/// practice（学习页）：只做练习，改编出的题目另存为 SavedVariant 供之后查看，作答什么都不记；
/// 否则（复习页）和 AI 改编复习一样，作答记 VariantAttempt，按原题的规则计入
@MainActor
@Observable
final class ChoiceVariantGeneration {
    let pack: StudyPack
    let original: Question
    let practice: Bool
    /// 改用备用供应商的默认模型改编
    let useBackup: Bool
    /// 复习页：先用上次改编好、还没做的题（PendingVariant）；重新改编时为 false
    let reuse: Bool
    private(set) var result: Result<QuestionVariant.Generated, Error>?

    @ObservationIgnored private var task: Task<Void, Never>?

    init(pack: StudyPack, original: Question, practice: Bool, useBackup: Bool, reuse: Bool = false) {
        self.pack = pack
        self.original = original
        self.practice = practice
        self.useBackup = useBackup
        self.reuse = reuse
    }

    /// 打开时改编一道；复习页有上次改编好、还没做的题就直接用
    func start(in context: ModelContext) {
        task?.cancel()
        if !practice {
            if reuse, let p = PendingVariant.usable(packID: pack.id, originalID: original.id, kind: "choice", in: context),
               let g = QuestionVariant.restore(p, original: original) {
                result = .success(g)
                return
            }
            PendingVariant.discard(packID: pack.id, originalID: original.id, in: context)
        }
        let history = AttemptRecord.all(packID: pack.id, questionID: original.id, in: context)
        let variants = VariantAttempt.all(packID: pack.id, originalID: original.id, in: context)
        let faults = QuestionMark.rated(packID: pack.id, in: context)
        let pack = pack, original = original, practice = practice, useBackup = useBackup
        task = Task {
            do {
                let g = try await QuestionVariant.generate(pack: pack, original: original, attempts: history,
                                                           variants: variants, faults: faults, useBackup: useBackup)
                guard !Task.isCancelled else { return }
                result = .success(g)
                if !practice {
                    PendingVariant.save(packID: pack.id, sectionID: pack.questionSection[original.id] ?? "",
                                        originalID: original.id, variantID: g.question.id, kind: "choice",
                                        content: Data(g.json.utf8), usageData: VariantSession.encode(g.usage),
                                        in: context)
                }
                // 练习只保存题目，供之后查看
                if practice {
                    context.insert(SavedVariant(packID: pack.id, sectionID: pack.questionSection[original.id] ?? "",
                                                originalID: original.id, kind: "choice", stem: g.question.stem,
                                                content: Grader.snapshot(g.question), model: g.usage?.model))
                    try? context.save()
                }
            } catch {
                guard !Task.isCancelled else { return }
                result = .failure(error)
            }
        }
    }

    func cancel() { task?.cancel() }
}

/// 一道主观题 AI 改编：改编（或接过复习页提前改编好的题），改编好后建好作答流程（SubjectiveAttemptSession 的改编题模式）。
/// 界面见 SubjectiveVariantCard
@MainActor
@Observable
final class SubjectiveVariantGeneration {
    let pack: StudyPack
    let original: SubjectiveQuestion
    let sectionID: String
    let draftKey: String
    let practice: Bool
    /// 改用备用供应商的默认模型改编
    let useBackup: Bool
    /// 复习、错题本：先用上次改编好、还没做的题（PendingVariant）；重新改编时为 false
    let reuse: Bool
    private(set) var result: Result<QuestionVariant.SubjectiveGenerated, Error>?
    /// 改编好后这道改编题的作答
    private(set) var session: SubjectiveAttemptSession?

    @ObservationIgnored private var task: Task<Void, Never>?

    init(pack: StudyPack, original: SubjectiveQuestion, sectionID: String, draftKey: String, practice: Bool,
         useBackup: Bool, reuse: Bool = false) {
        self.pack = pack
        self.original = original
        self.sectionID = sectionID
        self.draftKey = draftKey
        self.practice = practice
        self.useBackup = useBackup
        self.reuse = reuse
    }

    /// 外面已改编好的题（AI 改编复习提前改编）：建好就有作答流程，不用等打开
    convenience init(pack: StudyPack, original: SubjectiveQuestion, sectionID: String, draftKey: String,
                     prepared: (id: String, generated: QuestionVariant.SubjectiveGenerated)) {
        self.init(pack: pack, original: original, sectionID: sectionID, draftKey: draftKey, practice: false,
                  useBackup: false)
        succeed(prepared.generated, id: prepared.id)
    }

    /// prepared：外面已改编好的题及其标识（复习页提前改编）；nil 时自己改编
    func start(prepared: (id: String, generated: QuestionVariant.SubjectiveGenerated)?, in context: ModelContext) {
        guard result == nil, task == nil else { return }
        if let prepared {
            succeed(prepared.generated, id: prepared.id)
            return
        }
        let packID = pack.id, originalID = original.id
        if !practice {
            if reuse, let p = PendingVariant.usable(packID: packID, originalID: originalID, kind: "subjective", in: context),
               let g = QuestionVariant.restoreSubjective(p) {
                succeed(g, id: p.variantID)
                return
            }
            PendingVariant.discard(packID: packID, originalID: originalID, in: context)
        }
        let attempts = SubjectiveRecords.attempts(packID: packID, questionID: originalID, in: context)
        let variants = VariantAttempt.all(packID: packID, originalID: originalID, in: context)
        let faults = QuestionMark.rated(packID: packID, in: context)
        let pack = pack, original = original, useBackup = useBackup, practice = practice, sectionID = sectionID
        task = Task {
            do {
                let g = try await QuestionVariant.generateSubjective(pack: pack, original: original, attempts: attempts,
                                                                     variants: variants, faults: faults, useBackup: useBackup)
                guard !Task.isCancelled else { return }
                let id = QuestionVariant.newID(originalID: originalID)
                succeed(g, id: id)
                if !practice, let content = g.content {
                    PendingVariant.save(packID: packID, sectionID: sectionID, originalID: originalID, variantID: id,
                                        kind: "subjective", content: content, usageData: VariantSession.encode(g.usage),
                                        in: context)
                }
                ActivityLog.write("ai_adapt_subjective", ["question": originalID, "model": g.usage?.model ?? "",
                                                     "stem": String(g.stem.prefix(300)), "answer_chars": g.answer.count])
            } catch {
                guard !Task.isCancelled else { return }
                result = .failure(error)
                ActivityLog.write("ai_adapt_subjective_error", ["question": originalID, "error": error.localizedDescription])
            }
        }
    }

    private func succeed(_ g: QuestionVariant.SubjectiveGenerated, id: String) {
        session = SubjectiveAttemptSession(pack: pack, variant: .init(original: original, generated: g, id: id,
                                                                      practice: practice, draftKey: draftKey),
                                           sectionID: sectionID)
        result = .success(g)
    }

    /// 收起：停止改编，作答的笔迹存起来
    func close() {
        cancel()
        leave()
    }

    /// 离开屏幕（如转到单独窗口）：改编区的笔迹存进作答，改编照常进行，回来接着用。
    /// 计时、收起由作答卡片自己处理（SubjectiveAttemptSession.disappear）
    func leave() {
        session?.archiveInk()
    }

    /// 不再要这道改编题：停止改编
    func cancel() {
        task?.cancel()
    }
}
