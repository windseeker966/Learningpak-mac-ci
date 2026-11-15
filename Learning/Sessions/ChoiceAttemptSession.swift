import Foundation
import Observation
import SwiftData

/// 一道选择题的一次作答流程：选择 → 标把握程度提交（判分、写记录、重算复习安排、收集草稿笔迹）→ 错因 → AI 讲评；
/// 也可以从以往的作答还原，或重新作答。界面见 QuestionCard
@MainActor
@Observable
final class ChoiceAttemptSession {
    let pack: StudyPack
    let question: Question
    let mode: AttemptMode
    let roundNum: Int
    /// 学习页里展开的重做答题卡
    let isNestedRedo: Bool
    /// 作答笔迹所在的草稿页；AI 改编和没有书写区的页面为 nil，不收集
    let inkKey: String?
    /// 复习原题时打乱选项（复习页、错题本重做页）
    let shuffleOptions: Bool

    private(set) var selection: Selection?
    private(set) var hintShown = false
    private(set) var result: GradeResult?
    private(set) var attempt: AttemptRecord?
    /// AI 改编题的结果记录（只记结果，见 VariantAttempt）
    private(set) var variantRecord: VariantAttempt?
    /// 从历史记录还原时，那次作答的时间
    private(set) var restoredAt: Date?
    /// 这次作答的选项显示顺序
    private(set) var optionOrder: OptionOrder

    /// 已提交的错误原因（答对但没把握时是没把握的原因），可多选
    private(set) var errorTypes: [ErrorType] = []
    /// 自评「混淆」时指出的知识点（已提交的）
    private(set) var confusedPoints: [String] = []
    /// 正在填写（未提交）的错误原因、原因说明、混淆的知识点
    var pendingErrorTypes: Set<ErrorType> = []
    var errorNote = ""
    var pendingConfused: [String] = []
    private(set) var editingCause = false
    /// 答错后错因表单默认选中的原因；没改过就离开这道题时按它提交（见 leave）
    private static let defaultCause: Set<ErrorType> = [.notLearned]

    let review = ChatSession()
    private(set) var showReview = false
    private(set) var reviewSaveError: String?

    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var history: [String] = []
    /// 与 history 对应：每次选择时的作答用时
    @ObservationIgnored private var selectionTimes: [Double] = []
    /// 作答用时（提交前）和提交后看答案、解析、讲评的时间，都只计 App 在前台、题目在屏幕上的时间
    @ObservationIgnored private let answerClock = ActiveClock()
    @ObservationIgnored private var feedbackClock = ActiveClock()
    @ObservationIgnored private var active = false
    @ObservationIgnored private var redoOpen = false
    @ObservationIgnored private var viewers: [UUID: (active: Bool, redoOpen: Bool)] = [:]
    @ObservationIgnored private var reviewAttemptID: PersistentIdentifier?
    /// 本卡这次提交的作答从什么时候起的笔迹算它的；nil 表示不再收集（还没提交、从历史还原或已开始下一次作答）
    @ObservationIgnored private var inkSince: Date?
    @ObservationIgnored private var openedAt = Date.now
    /// 题目在屏幕上的每一段停留，写进操作日志
    @ObservationIgnored private let viewSpan = ActivitySpan("question_view")

    /// existing：这道题之前的作答。传入时直接展示当时的作答与解析，可「重新作答」
    init(pack: StudyPack, question: Question, mode: AttemptMode, roundNum: Int, existing: AttemptRecord?,
         isNestedRedo: Bool, inkKey: String?, shuffleOptions: Bool) {
        self.pack = pack
        self.question = question
        self.mode = mode
        self.roundNum = roundNum
        self.isNestedRedo = isNestedRedo
        self.inkKey = inkKey
        self.shuffleOptions = shuffleOptions
        optionOrder = Self.optionOrder(for: question, shuffle: shuffleOptions)
        // 上次没提交的作答（重新作答后没提交的也算）接着做；比已有的作答晚才算，题目内容变了不算
        if !mode.isAI, let p = PendingAnswers.load(PendingAnswers.Choice.self, key: choiceKey),
           p.value.contentHash == Grader.contentHash(question), existing.map({ p.savedAt > $0.createdAt }) ?? true {
            let d = p.value
            optionOrder = OptionOrder(displayed: d.optionOrder, original: question.optionKeys)
            selection = d.selection.map { Selection.decode($0, for: question) }
            history = d.history
            selectionTimes = d.selectionTimes
            hintShown = d.hintShown
            answerClock.reset(to: d.answerSeconds)
        } else if let e = existing {
            optionOrder = OptionOrder(displayed: e.optionOrder, original: question.optionKeys)
            let sel = Selection.decode(e.selection, for: question)
            selection = sel
            history = e.selectionHistory
            selectionTimes = e.selectionTimes
            feedbackClock = ActiveClock(e.feedbackSeconds)
            confusedPoints = e.confusedPoints
            pendingConfused = e.confusedPoints
            hintShown = e.hintShown
            result = Grader.grade(question, sel)
            attempt = e
            errorTypes = e.causeTypes
            pendingErrorTypes = Set(e.causeTypes)
            errorNote = e.errorNote ?? ""
            restoredAt = e.createdAt
            // 上次改了没提交的错因
            if !mode.isAI, let c = PendingAnswers.load(PendingAnswers.Cause.self, key: causeKey)?.value,
               abs(c.attemptAt.timeIntervalSince(e.createdAt)) < 0.001 {
                pendingErrorTypes = Set(c.errorTypes.compactMap(ErrorType.init(rawValue:)))
                errorNote = c.note
                pendingConfused = c.confusedPoints
                editingCause = c.editing
            }
        }
    }

    private var choiceKey: String { PendingAnswers.choiceKey(pack: pack.id, mode: mode, questionID: question.id) }
    private var causeKey: String { PendingAnswers.causeKey(pack: pack.id, mode: mode, questionID: question.id) }

    private var q: Question { question }

    /// 单选、多选、组合题可以打乱选项；判断题、多空题保持原顺序
    private static func optionOrder(for q: Question, shuffle: Bool) -> OptionOrder {
        guard shuffle, [.single, .multi, .combo].contains(q.type) else { return OptionOrder(identity: q.optionKeys) }
        let texts = q.options ?? (q.comboOptions ?? [:]).mapValues { $0.joined(separator: "、") }
        var rng = SystemRandomNumberGenerator()
        return OptionOrder.shuffled(keys: q.optionKeys, texts: texts, stem: q.stem, using: &rng)
    }

    /// 所在节；AI 变式题不在包里，取原题所在的节
    private var sectionID: String {
        pack.questionSection[q.id] ?? pack.questionSection[QuestionVariant.originalID(of: q.id)] ?? ""
    }

    /// 和本卡共用同一页笔迹的作答方式：复习页只有复习，学习页是学习和重做
    private var inkPageModes: Set<String> {
        mode == .review ? [AttemptMode.review.rawValue] : [AttemptMode.learn.rawValue, AttemptMode.redo.rawValue]
    }

    // MARK: - 打开、计时、笔迹

    func load(in context: ModelContext) {
        self.context = context
        loadReview()
    }

    /// 计时只在 App 在前台、题目在屏幕上时进行；学习页展开重做答题卡（redoOpen）时，本卡的答后时间暂停。
    /// 答后计时暂停时，把停留时间和最后看到答案的时间写回作答记录。
    /// viewer 是显示这次作答的卡片：转到单独窗口、转回来时主窗口和单独窗口的卡片共用一个作答流程，有一张在前台、在屏幕上就算
    func setActive(_ active: Bool, redoOpen: Bool = false, viewer: UUID) {
        viewers[viewer] = (active, redoOpen)
        applyActive()
    }

    /// 卡片离开页面
    func disappear(viewer: UUID) {
        viewers[viewer] = nil
        applyActive()
    }

    private func applyActive() {
        active = viewers.values.contains { $0.active }
        redoOpen = viewers.values.contains { $0.active && $0.redoOpen }
        updateClocks()
        viewSpan.update(active: active, viewFields)
    }

    private var viewFields: [String: Any] {
        ["pack": pack.id, "question": q.id, "kind": "choice", "mode": mode.rawValue,
         "answered": result != nil, "restored": restoredAt != nil]
    }

    private func updateClocks() {
        answerClock.setRunning(active && result == nil)
        let wasViewing = feedbackClock.isRunning
        feedbackClock.setRunning(active && result != nil && !redoOpen)
        if wasViewing && !feedbackClock.isRunning { saveFeedbackTime() }
    }

    private func saveFeedbackTime() {
        guard let attempt else { return }
        attempt.feedbackSeconds = feedbackClock.elapsed
        attempt.lastViewedAt = .now
        if !mode.isAI { try? context?.save() }
    }

    /// 把本次作答到目前为止的书写区笔迹存进记录
    func captureInk() {
        guard let context, let since = inkSince, let key = inkKey, let attempt else { return }
        ChoiceInk.save(attempt, pageKey: key, since: since, in: context)
    }

    /// 离开页面或 App 退到后台：保存讲评、笔迹和还没提交的作答、错因
    func persist() {
        review.save()
        captureInk()
        savePending()
    }

    /// 还没提交的作答、错因存下来，下次打开这道题时接着用（见 PendingAnswers）；AI 改编题不存
    private func savePending() {
        guard !mode.isAI else { return }
        if result == nil {
            guard selection != nil || hintShown else { return }
            PendingAnswers.save(PendingAnswers.Choice(
                selection: selection?.encoded, history: history, selectionTimes: selectionTimes,
                hintShown: hintShown, answerSeconds: answerClock.elapsed, optionOrder: optionOrder.keys,
                contentHash: Grader.contentHash(q)), key: choiceKey)
        } else if let attempt, errorTypes.isEmpty || editingCause {
            let changed = pendingErrorTypes != Set(errorTypes) || pendingConfused != confusedPoints
                || errorNote != (attempt.errorNote ?? "")
            guard changed else { PendingAnswers.remove(key: causeKey); return }
            PendingAnswers.save(PendingAnswers.Cause(
                attemptAt: attempt.createdAt, errorTypes: ErrorType.allCases.filter(pendingErrorTypes.contains).map(\.rawValue),
                note: errorNote, confusedPoints: pendingConfused, editing: editingCause), key: causeKey)
        }
    }

    // MARK: - 作答、提交

    func choose(_ sel: Selection) {
        selection = sel
        history.append(sel.encoded)
        selectionTimes.append(answerClock.elapsed)
        savePending()
    }

    func showHint() {
        hintShown = true
        savePending()
    }

    /// 提交并判分，返回这次的作答记录（AI 改编题的只在内存里）
    @discardableResult
    func submit(confidence: ChoiceConfidence) -> AttemptRecord? {
        guard let context, let selection, selection.isComplete else { return nil }
        PendingAnswers.remove(key: choiceKey)
        let r = Grader.grade(q, selection)
        let duration = answerClock.elapsed
        let record = AttemptRecord(
            packID: pack.id,
            sectionID: sectionID,
            questionID: q.id,
            mode: mode.rawValue,
            roundNum: roundNum,
            durationSeconds: duration,
            selection: selection.encoded,
            selectionHistory: history,
            selectionTimes: selectionTimes,
            isCorrect: r.isCorrect,
            blankResults: r.blankResults,
            confidence: confidence.rawValue,
            hintShown: hintShown,
            weakPoints: r.weakPoints,
            contentHash: Grader.contentHash(q),
            questionSnapshot: Grader.snapshot(q)
        )
        if optionOrder.isShuffled { record.optionOrder = optionOrder.keys }
        // AI 改编：作答记录只留在内存里，供错因和讲评使用；复习页的改编另记一条改编题结果，按原题的规则计入原题的复习安排。
        // 学习页的改编只做练习，什么都不记
        if mode == .aiReview {
            let originalID = QuestionVariant.originalID(of: q.id)
            let v = VariantAttempt(packID: pack.id, sectionID: sectionID, originalID: originalID,
                                   kind: "choice", stem: q.stem, content: Grader.snapshot(q),
                                   selection: selection.encoded,
                                   result: (r.isCorrect ? PartResult.correct : .wrong).rawValue,
                                   confidence: confidence.rawValue, durationSeconds: duration)
            v.variantID = q.id
            v.selectionHistory = history
            v.weakPoints = r.weakPoints
            v.sinceAnswerSeen = AttemptRecord.answerLastSeen(packID: pack.id, questionID: originalID, in: context)
                .map { Date.now.timeIntervalSince($0) }
            context.insert(v)
            ReviewScheduler.refresh(packID: pack.id, questionID: originalID, in: context)
            variantRecord = v
        } else if !mode.isAI {
            // 先定下这次作答笔迹的起点，再写入新记录
            var since: Date? = inkKey == nil ? nil
                : ChoiceInk.workStart(packID: pack.id, questionID: q.id, modes: inkPageModes, in: context)
            if isNestedRedo, let s = since { since = max(s, openedAt) }
            // 学习页的重做答题卡就在原作答（含答案）下方，视为刚看过答案
            record.sinceAnswerSeen = isNestedRedo ? 0
                : AttemptRecord.answerLastSeen(packID: pack.id, questionID: q.id, in: context)
                    .map { Date.now.timeIntervalSince($0) }
            let session = StudySession.assign(workStarted: Date.now.addingTimeInterval(-duration), in: context)
            record.sessionID = session.id
            record.sessionIndex = session.index
            context.insert(record)
            // 全由说法卡复习的题回来抽查时做错了：选错的选项对应的卡退回重来
            if mode == .review, !r.isCorrect {
                PhraseDeck.recordMiss(packID: pack.id, question: q, selection: record.selection, at: record.createdAt,
                                      in: context)
            }
            ReviewScheduler.refresh(packID: pack.id, questionID: q.id, in: context)
            if let since, let key = inkKey {
                ChoiceInk.save(record, pageKey: key, since: since, in: context)
                inkSince = since
            }
        }
        attempt = record
        result = r
        // 答错后错因默认选「知识点没掌握」；学习页的改编练习不填错因
        if !r.isCorrect && mode != .aiPractice { pendingErrorTypes = Self.defaultCause }
        feedbackClock.reset()
        updateClocks()
        loadReview()
        return record
    }

    /// 学习页「重做这道题」：之后写下的笔迹属于重做
    func handOffInkToRedo() {
        captureInk()
        inkSince = nil
    }

    /// 离开这道题（下一题、跳到别的题、返回、切换标签页、重新作答；转到单独窗口、转回来不算，两边共用这个作答流程）：这次答错后还没提交错因、
    /// 表单仍是默认的「知识点没掌握」且没写原因时，按它提交；改过没提交的不记，从以往作答还原的也不记
    func leave() {
        guard restoredAt == nil, result?.isCorrect == false, errorTypes.isEmpty,
              pendingErrorTypes == Self.defaultCause,
              errorNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        ActivityLog.write("auto_cause_on_leave", ["pack": pack.id, "question": q.id, "mode": mode.rawValue])
        submitCause()
    }

    /// 「重新作答」：清空这次作答，重新打乱选项
    func resetForRetry() {
        leave()
        captureInk()
        PendingAnswers.remove(key: choiceKey)
        PendingAnswers.remove(key: causeKey)
        inkSince = nil
        openedAt = .now
        review.save()
        review.onSave = nil
        feedbackClock.setRunning(false)
        saveFeedbackTime()
        reviewAttemptID = nil
        reviewSaveError = nil
        selection = nil
        history = []
        selectionTimes = []
        answerClock.reset()
        feedbackClock.reset()
        hintShown = false
        result = nil
        attempt = nil
        variantRecord = nil
        errorTypes = []
        pendingErrorTypes = []
        errorNote = ""
        confusedPoints = []
        pendingConfused = []
        editingCause = false
        restoredAt = nil
        optionOrder = Self.optionOrder(for: q, shuffle: shuffleOptions)
        review.reset()
        showReview = false
        updateClocks()
    }

    // MARK: - 错因

    func toggleErrorType(_ type: ErrorType) {
        if pendingErrorTypes.contains(type) { pendingErrorTypes.remove(type) } else { pendingErrorTypes.insert(type) }
    }

    func toggleConfused(_ id: String) {
        if pendingConfused.contains(id) { pendingConfused.removeAll { $0 == id } } else { pendingConfused.append(id) }
    }

    func beginEditingCause() {
        pendingErrorTypes = Set(errorTypes)
        editingCause = true
    }

    func cancelEditingCause() {
        pendingErrorTypes = Set(errorTypes)
        pendingConfused = confusedPoints
        errorNote = attempt?.errorNote ?? ""
        editingCause = false
        PendingAnswers.remove(key: causeKey)
    }

    var canSubmitCause: Bool {
        guard !pendingErrorTypes.isEmpty else { return false }
        return !pendingErrorTypes.contains(.other) || !errorNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func submitCause() {
        guard let context, canSubmitCause else { return }
        if !mode.isAI { PendingAnswers.remove(key: causeKey) }
        let types = ErrorType.allCases.filter(pendingErrorTypes.contains)
        let raws = types.map(\.rawValue)
        let note = errorNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let confused = types.contains(.confused) ? pendingConfused : []
        errorTypes = types
        errorNote = note
        confusedPoints = confused
        attempt?.errorType = raws.first
        attempt?.errorTypes = raws
        attempt?.errorNote = note.isEmpty ? nil : note
        attempt?.confusedPoints = confused
        attempt?.causeHistory.append(CauseEntry(at: .now, type: raws[0], note: note.isEmpty ? nil : note,
                                                confusedPoints: confused.isEmpty ? nil : confused, types: raws))
        if let variantRecord {
            variantRecord.errorType = raws.first
            variantRecord.errorTypes = raws
            variantRecord.errorNote = note.isEmpty ? nil : note
            variantRecord.confusedPoints = confused
            variantRecord.causeHistory.append(CauseEntry(at: .now, type: raws[0], note: note.isEmpty ? nil : note,
                                                         confusedPoints: confused.isEmpty ? nil : confused, types: raws))
            try? context.save()
        }
        if !mode.isAI { try? context.save() }
        // 错因参与评分（会但失误的错按「困难」计），提交或修改后重算复习安排
        if attempt != nil || variantRecord != nil {
            ReviewScheduler.refresh(packID: pack.id, questionID: QuestionVariant.originalID(of: q.id), in: context)
        }
        editingCause = false
    }

    // MARK: - AI 讲评

    func runReview() {
        guard let selection, let result else { return }
        loadReview()
        showReview = true
        let (system, messages) = Prompts.review(pack: pack, question: q, selection: selection,
                                                 result: result, errorTypes: errorTypes,
                                                 errorNote: attempt?.errorNote,
                                                 confusedPoints: confusedPoints,
                                                 correctionNote: attempt?.correctionNote,
                                                 optionOrder: optionOrder)
        review.start(system: system, hidden: messages)
    }

    private func loadReview() {
        guard let record = attempt, reviewAttemptID != record.persistentModelID else { return }
        reviewAttemptID = record.persistentModelID
        if let data = record.reviewConversationData {
            do {
                review.restore(try JSONDecoder().decode(SavedConversation.self, from: data))
                showReview = true
            } catch {
                reviewSaveError = "无法读取已保存的 AI 讲评：\(error.localizedDescription)"
            }
        }
        review.onSave = { [weak self] saved in
            guard let self else { return }
            // AI 改编题的讲评存在改编题结果上；学习页的改编练习不保存
            if self.mode.isAI {
                guard let v = self.variantRecord else { return }
                v.reviewConversationData = try? JSONEncoder().encode(saved)
                try? self.context?.save()
                return
            }
            do {
                record.reviewConversationData = try JSONEncoder().encode(saved)
                record.followUpCount = saved.messages.filter { $0.role == ChatTurn.Role.user.rawValue }.count
                try self.context?.save()
                self.reviewSaveError = nil
            } catch {
                self.reviewSaveError = "AI 讲评保存失败：\(error.localizedDescription)"
            }
        }
    }
}
