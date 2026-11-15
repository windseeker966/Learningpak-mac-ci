import Foundation
import Observation
import PencilKit
import SwiftData
import UIKit

/// 一道主观题的一次作答流程：打开或接着上次的作答、看答案、键盘填空比对、贴图片、自评、AI 批改、AI 讲评、重做。
/// 原题记 SubjectiveAttempt；AI 改编题走同一套流程，记 VariantAttempt，按原题的规则计入原题的复习安排。
/// 界面见 SubjectiveCard；书写区位置由界面在需要时传入（笔迹切图）
@MainActor
@Observable
final class SubjectiveAttemptSession {
    enum Mode {
        /// 学习页：页面笔迹用 DraftKey.question，挂详细笔迹记录，可重做
        case study
        /// 复习页：页面笔迹用 DraftKey.review；上次做对的小问可以跳过
        case review
        /// AI 改编题（见 Variant）：笔迹在页面的改编区里，收起、重做、自评时存进作答记录
        case variant
    }

    /// AI 改编出的一道主观题
    struct Variant {
        let original: SubjectiveQuestion
        let generated: QuestionVariant.SubjectiveGenerated
        /// 这道改编题的标识，重做时沿用
        let id: String
        /// 学习页的改编练习：作答照存，不计入复习安排和统计
        let practice: Bool
        /// 改编区所在页面的草稿键：复习页逐题改编时是改编题自己那一页，学习页、错题本里是原题那一页
        let draftKey: String
    }

    let pack: StudyPack
    let question: SubjectiveQuestion
    let sectionID: String
    let mode: Mode
    let variant: Variant?

    /// 提交自评后回调（含键盘填空全部对上、离开时按表单自动提交）
    @ObservationIgnored var onAssessed: (() -> Void)?

    /// 原题的书写状态（书写区数量等）；改编题记在作答里
    private(set) var progress: SubjectiveProgress?
    private(set) var attempt: (any SubjectiveAttemptRecord)?
    /// 这道题（改编题：这道改编题）其他的作答（不含当前），新的在前
    private(set) var others: [any SubjectiveAttemptRecord] = []
    /// 收起答案：只影响显示，已看过答案的记录不变
    private(set) var answerHidden = false
    /// 自评表单
    var form = SubjectiveAssessmentRules.Form()
    var editingAssessment = false
    /// 复习时上次已做对、可以跳过的小问
    private(set) var skippable: Set<String> = []
    /// 键盘输入的填空题：各空正在填的内容，按小问顺序
    private(set) var typedInputs: [String] = []
    /// 当前作答贴进来的图片
    private(set) var pasted: [PastedImage] = []

    /// AI 批改及历次结果（属于当前作答）
    let grader = StreamRunner()
    private(set) var gradeImages: [UIImage] = []
    private(set) var gradeError: String?
    private(set) var gradeSaveError: String?
    private(set) var gradingHistory: [SavedGrading] = []
    private(set) var activeGradingID: UUID?

    let review = ChatSession()
    private(set) var showReview = false
    private(set) var reviewSaveError: String?

    @ObservationIgnored private var context: ModelContext?
    /// 只加载一次：复习页每次加载都可能开始新的作答
    @ObservationIgnored private var loaded = false
    /// 接着做的改编题作答以前存下的笔迹：画布上已经没有了，存笔迹时加在前面，不丢
    @ObservationIgnored private var earlierVariantStrokes: [PKStroke] = []
    /// 看答案前的书写用时、看答案后的停留时间
    @ObservationIgnored private let writingClock = ActiveClock()
    @ObservationIgnored private let feedbackClock = ActiveClock()
    /// 题目在屏幕上的每一段停留，写进操作日志
    @ObservationIgnored private let viewSpan = ActivitySpan("question_view")
    /// 批改生成中上次写库的时间
    @ObservationIgnored private var lastGradingSave = Date.distantPast

    init(pack: StudyPack, question: SubjectiveQuestion, sectionID: String, mode: Mode) {
        self.pack = pack
        self.question = question
        self.sectionID = sectionID
        self.mode = mode
        self.variant = nil
    }

    init(pack: StudyPack, variant: Variant, sectionID: String) {
        self.pack = pack
        self.question = variant.generated.question(from: variant.original)
        self.sectionID = sectionID
        self.mode = .variant
        self.variant = variant
    }

    /// 改编题的作答记录
    private var variantRecord: VariantAttempt? { attempt as? VariantAttempt }
    /// 复习安排、看答案时间按这道题算：改编题按原题
    private var scheduleID: String { variant?.original.id ?? question.id }

    var parts: [SubjectiveQuestion.Part] { question.effectiveParts }
    var labels: [String] { parts.map(\.label) }
    var revealed: Bool { attempt?.revealedAt != nil }
    var assessed: Bool { attempt?.assessedAt != nil }
    var typed: Bool { question.typed }
    /// 一开始的书写区数量：都不给，需要时手动添加
    let initialAreas = 0
    var pageCount: Int { progress?.pageCount ?? variantRecord?.areaCount ?? initialAreas }
    /// 提交时与答案一致、自动判对的空
    var autoMatched: Set<String> { Set(attempt?.autoMatched ?? []) }

    var draftKey: String {
        switch mode {
        case .study: DraftKey.question(pack: pack.id, questionID: question.id)
        case .review: DraftKey.review(pack: pack.id, questionID: question.id)
        case .variant: variant?.draftKey ?? ""
        }
    }

    var recordContext: SubjectiveRecordContext {
        SubjectiveRecordContext(packID: pack.id, sectionID: sectionID, questionID: question.id)
    }

    /// 详细笔迹记录只在学习页写
    func log(_ event: String, _ payload: SimplePayload) {
        if mode == .study { SubjectiveInkLog.write(event, recordContext, payload) }
    }

    // MARK: - 打开、计时

    /// resume：接着用这次作答（主窗口和单独窗口之间转来转去时用同一次，复习页不另开新的作答）
    func load(in context: ModelContext) {
        guard !loaded else { return }
        loaded = true
        self.context = context
        if let variant {
            // 存下的改编题再打开（PendingVariant）：接着用上次没自评的那次作答，看过的答案、贴的图片、AI 批改都在
            if !variant.practice, let open = VariantAttempt.attempts(variantID: variant.id, in: context)
                .last(where: { !$0.isAssessed && !$0.isRedo }) {
                earlierVariantStrokes = open.inkData.flatMap { try? PKDrawing(data: $0) }?.strokes ?? []
                setCurrent(open)
                return
            }
            setCurrent(VariantAttempt.startSubjective(
                packID: pack.id, sectionID: sectionID, originalID: variant.original.id, variantID: variant.id,
                stem: variant.generated.stem, content: variant.generated.content, practice: variant.practice,
                redo: false, in: context))
            return
        }
        let p = SubjectiveProgress.fetchOrCreate(packID: pack.id, sectionID: sectionID, questionID: question.id,
                                                 initialPages: initialAreas, in: context)
        progress = p
        let a = mode == .study
            ? SubjectiveRecords.currentForStudy(pack: pack, question: question, sectionID: sectionID, in: context)
            : SubjectiveRecords.currentForReview(pack: pack, question: question, sectionID: sectionID,
                                                 draftKey: draftKey, in: context)
        try? context.save()
        setCurrent(a)
        log("question_open", SimplePayload(page_count: p.pageCount, note: a.revealedAt == nil ? nil : "answer_already_revealed"))
    }

    private func setCurrent(_ a: any SubjectiveAttemptRecord) {
        guard let context else { return }
        attempt = a
        if let variant {
            others = VariantAttempt.attempts(variantID: variant.id, in: context).filter { $0 !== a }.reversed()
        } else {
            others = SubjectiveRecords.attempts(packID: pack.id, questionID: question.id, in: context)
                .filter { $0 !== a }.reversed()
        }
        typedInputs = parts.indices.map { $0 < a.typedAnswers.count ? a.typedAnswers[$0] : "" }
        pasted = a.pastedImages
        // 键盘填空题每空都很快，复习时不跳过
        skippable = mode == .review && !typed
            ? SubjectiveRecords.lastCorrectParts(packID: pack.id, questionID: question.id, excluding: a, in: context)
                .intersection(labels)
            : []
        gradingHistory = a.gradings
        writingClock.reset(to: a.writingSeconds)
        feedbackClock.reset(to: a.feedbackSeconds)
        answerHidden = a.answerHidden
        editingAssessment = false
        fillForm(from: a)
        bindReview(to: a)
    }

    @ObservationIgnored private var active = false
    /// 正在显示这次作答的卡片及其是否在前台、在屏幕上。改编题可能同时显示在主窗口和单独窗口里（转过去、转回来的一瞬间）
    @ObservationIgnored private var viewers: [UUID: Bool] = [:]

    /// 只在 App 在前台、题目在屏幕上时计时（有一张卡片是这样就算）；暂停时写回作答记录
    func setActive(_ active: Bool, viewer: UUID) {
        viewers[viewer] = active
        applyActive()
    }

    private func applyActive() {
        active = viewers.values.contains(true)
        updateClocks()
        viewSpan.update(active: active, viewFields)
    }

    private var viewFields: [String: Any] {
        var f: [String: Any] = ["pack": pack.id, "question": question.id, "kind": "subjective",
                                "mode": "\(mode)", "revealed": revealed, "assessed": assessed]
        if let variant { f["original"] = variant.original.id }
        return f
    }

    private func updateClocks() {
        let wasWriting = writingClock.isRunning, wasViewing = feedbackClock.isRunning
        writingClock.setRunning(active && !revealed)
        feedbackClock.setRunning(active && revealed)
        guard let a = attempt else { return }
        if wasWriting && !writingClock.isRunning && !revealed {
            a.writingSeconds = writingClock.elapsed
            try? context?.save()
        }
        if wasViewing && !feedbackClock.isRunning {
            a.feedbackSeconds = feedbackClock.elapsed
            a.lastViewedAt = .now
            try? context?.save()
        }
    }

    /// 卡片离开页面：保存讲评、停止计时，生成中的批改立即保存；改编题的笔迹存进作答。
    /// 改编题还显示在另一个窗口里时不收起（收起会删掉什么都没做的作答）
    func disappear(viewer: UUID) {
        viewers[viewer] = nil
        applyActive()
        review.save()
        if let id = activeGradingID {
            updateGrading(id: id, text: grader.text, completed: false, error: grader.error)
        }
        guard variant != nil else { return }
        if viewers.isEmpty { closeVariant() } else { archiveVariantInk() }
    }

    /// 改编区要清掉之前，先把里面的笔迹存进作答
    func archiveInk() {
        archiveVariantInk()
    }

    // MARK: - 改编题收起

    /// 复习页逐题改编：还不能下一题的原因；nil 表示可以（已自评、点了不会做、各问都已有自动判对或 AI 的结论，
    /// 或这道改编题标记了有错）。faulty 由界面按 QuestionMark 传入，标记后立即刷新
    func advanceBlocker(faulty: Bool) -> String? {
        guard let variant, !variant.practice, !faulty, let a = attempt, !a.isAssessed else { return nil }
        if !revealed { return "先作答，标把握程度看答案" }
        if a.confidenceValue == .gaveUp { return nil }
        if grader.isRunning { return "等 AI 批改完" }
        if labels.allSatisfy({ form.results[$0] != nil }) { return nil }
        return typed ? "AI 没给出结论，请提交自评" : "点 AI 批改，或提交自评"
    }

    /// 改编题下一题或收起。autoAssess（复习页逐题改编）：没提交自评的按预选的结论（自动判对、AI 批改）记下；
    /// 标记了题目有错的不记
    func finishVariant(autoAssess: Bool) {
        guard let context, let variant, let a = attempt else { return }
        let faulty = QuestionMark.fetch(packID: pack.id, questionID: variant.id, in: context)?.faulty == true
        if autoAssess, !variant.practice, !faulty, revealed, !a.isAssessed { autoSubmitAssessment("ai_variant_auto_assess") }
        closeVariant()
    }

    /// 离开原题（下一题、跳到别的题、返回、切换标签页）：看了答案没提交自评的，有 AI 批改结论或选了结果时按表单记下；
    /// 标记了题目有错、AI 还在批改的不记。改编题见 finishVariant
    func leave() {
        guard variant == nil, let context, let a = attempt, revealed, !a.isAssessed, !grader.isRunning,
              QuestionMark.fetch(packID: pack.id, questionID: question.id, in: context)?.faulty != true,
              !aiVerdicts.isEmpty || form != prefilledForm(a) else { return }
        autoSubmitAssessment("auto_assess_on_leave")
    }

    /// 笔迹存进作答；什么都没做的作答删掉（再次显示时重新开始）
    private func closeVariant() {
        guard let context, let v = variantRecord else { return }
        archiveVariantInk()
        for k in viewers.keys { viewers[k] = false }
        applyActive()
        if VariantAttempt.discardIfEmpty(v, in: context) {
            attempt = nil
            loaded = false
        }
    }

    /// 改编区里的笔迹存进这次作答；画布已不在、或区域里没有笔迹时保留原来存的
    private func archiveVariantInk() {
        guard variant != nil, let a = attempt, let strokes = pageStrokes(), !strokes.isEmpty else { return }
        a.inkData = PKDrawing(strokes: earlierVariantStrokes + strokes).dataRepresentation()
        try? context?.save()
    }

    /// 页面上这次作答的笔迹：原题从数据库读（先让画布保存）；改编题从画布上读改编区里的
    private func pageStrokes() -> [PKStroke]? {
        if variant != nil { return DraftAnchors.transientStrokes(draftKey) }
        guard let context else { return nil }
        return SubjectiveRecords.pageDrawing(draftKey, in: context)?.strokes
    }

    /// 上次看到答案的时间：原题按原题的全部作答；改编题再算上这道改编题以前的作答
    private func answerLastSeen(in context: ModelContext) -> Date? {
        let original = SubjectiveRecords.answerLastSeen(packID: pack.id, questionID: scheduleID, in: context)
        guard variant != nil else { return original }
        let same = others.compactMap { a in a.revealedAt.map { max($0, a.lastViewedAt ?? $0) } }.max()
        return [original, same].compactMap { $0 }.max()
    }

    // MARK: - 看答案、键盘填空

    func reveal(_ confidence: SubjectiveConfidence) {
        guard let context, let a = attempt, a.revealedAt == nil else { return }
        writingClock.setRunning(false)
        let now = Date.now
        a.writingSeconds = writingClock.elapsed
        a.sinceAnswerSeen = answerLastSeen(in: context).map { now.timeIntervalSince($0) }
        a.strokesBeforeReveal = pageStrokes()?.count ?? 0
        if let a = a as? SubjectiveAttempt {
            let session = StudySession.assign(workStarted: now.addingTimeInterval(-a.writingSeconds), in: context)
            a.sessionID = session.id
            a.sessionIndex = session.index
        }
        variantRecord?.durationSeconds = a.writingSeconds
        a.confidenceValue = confidence
        a.revealedAt = now
        if typed {
            typedInputs = typedInputs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            a.typedAnswers = typedInputs
            a.autoMatched = zip(parts, typedInputs).filter { p, input in BlankMatcher.matches(input, accept: p.accept ?? []) }
                .map(\.0.label)
        }
        feedbackClock.reset()
        if let p = progress {
            if p.answerRevealedAt == nil { p.answerRevealedAt = now }
            p.updatedAt = now
        }
        try? context.save()
        log("answer_revealed", SimplePayload(page_count: pageCount, note: confidence.rawValue))
        fillForm(from: a)
        updateClocks()
        if typed { judgeTypedAnswers(a) }
    }

    /// 键盘填空题提交后：全部与答案一致就直接记为做对；有填了但对不上的空，或看答案前贴了图片，
    /// 自动请 AI 判断，结论用来预选自评
    private func judgeTypedAnswers(_ a: any SubjectiveAttemptRecord) {
        let matched = Set(a.autoMatched)
        if parts.allSatisfy({ matched.contains($0.label) }) {
            submitAssessment()
            return
        }
        let unmatchedFilled = zip(parts, a.typedAnswers).contains { p, input in
            !matched.contains(p.label) && !BlankMatcher.isEmpty(input)
        }
        let hasPasted = !a.pastedBeforeReveal.isEmpty
        if (unmatchedFilled || hasPasted) && LLMConfig.hasAvailableProvider(.grading) { runGrading(frames: [:]) }
    }

    func setTypedInput(_ i: Int, _ value: String) {
        guard i < typedInputs.count else { return }
        typedInputs[i] = value
        attempt?.typedAnswers = typedInputs
    }

    func showAnswerAgain() {
        answerHidden = false
        attempt?.answerHidden = false
        try? context?.save()
        log("answer_shown_again", SimplePayload(page_count: progress?.pageCount))
    }

    func hideAnswer() {
        answerHidden = true
        attempt?.answerHidden = true
        try? context?.save()
        log("answer_hidden", SimplePayload(page_count: progress?.pageCount))
    }

    // MARK: - 贴图片、书写区、重做

    func addPasted(_ datas: [Data]) {
        guard let a = attempt else { return }
        pasted += datas.map { PastedImage(data: $0) }
        a.pastedImages = pasted
        try? context?.save()
        log("image_pasted", SimplePayload(page_count: progress?.pageCount, note: "\(datas.count) of \(pasted.count)"))
    }

    func deletePasted(_ id: UUID) {
        guard let a = attempt else { return }
        pasted.removeAll { $0.id == id }
        a.pastedImages = pasted
        try? context?.save()
        log("image_deleted", SimplePayload(page_count: progress?.pageCount, note: "\(pasted.count) left"))
    }

    func addArea() {
        guard let context else { return }
        if let v = variantRecord {
            v.areaCount += 1
            try? context.save()
            return
        }
        guard let p = progress else { return }
        if mode == .study {
            WritingAreaList.addArea(p, ctx: recordContext, in: context)
        } else {
            p.pageCount += 1
            p.updatedAt = .now
            try? context.save()
        }
    }

    /// 删除一个书写区，它上面的笔迹从页面移走（存档在草稿记录里，详细笔迹记录不删）
    func deleteArea(_ i: Int, frames: [Int: CGRect]) {
        guard WritingAreaList.deleteArea(i, frames: frames, draftKey: draftKey) else { return }
        if let v = variantRecord {
            v.areaCount = max(v.areaCount - 1, 0)
            try? context?.save()
            return
        }
        guard let progress else { return }
        progress.pageCount = max(progress.pageCount - 1, 0)
        progress.updatedAt = .now
        try? context?.save()
        log("area_deleted", SimplePayload(page_count: progress.pageCount, note: "area \(i + 1)"))
    }

    /// 学习页、改编题重做：当前作答连同笔迹存档，页面（改编区）清空，开始新的一次
    func redo() {
        guard let context, let a = attempt, !grader.isRunning else { return }
        feedbackClock.setRunning(false)
        a.feedbackSeconds = feedbackClock.elapsed
        a.lastViewedAt = .now
        let next: any SubjectiveAttemptRecord
        if let variant {
            archiveVariantInk()
            DraftAnchors.clearTransientInk(draftKey)
            next = VariantAttempt.startSubjective(
                packID: pack.id, sectionID: sectionID, originalID: variant.original.id, variantID: variant.id,
                stem: variant.generated.stem, content: variant.generated.content, practice: variant.practice,
                redo: true, in: context)
        } else if let a = a as? SubjectiveAttempt {
            next = SubjectiveRecords.startRedo(pack: pack, question: question, sectionID: sectionID, previous: a,
                                               draftKey: draftKey, in: context)
        } else {
            return
        }
        gradeImages = []
        gradeError = nil
        setCurrent(next)
        log("redo_started", SimplePayload(page_count: progress?.pageCount))
        updateClocks()
    }

    // MARK: - 自评

    /// 最近一次完成的 AI 批改的各问结论
    var aiVerdicts: [String: GradingVerdict] {
        guard let g = gradingHistory.last(where: { $0.completed && $0.verdicts != nil }) else { return [:] }
        var map: [String: GradingVerdict] = [:]
        for v in g.verdicts ?? [] { map[v.label] = v }
        // 只有一问时，AI 写的编号可能与「全题」不同
        if parts.count == 1, map[parts[0].label] == nil, let only = g.verdicts?.first { map[parts[0].label] = only }
        return map
    }

    /// 要写错因的小问：部分对、错、没做出来
    var causeParts: [SubjectiveQuestion.Part] {
        parts.filter { SubjectiveAssessmentRules.needsCause(form.results[$0.label]) }
    }

    var canSubmitAssessment: Bool { form.canSubmit(labels: labels) }

    func beginEditing() {
        fillForm(from: attempt)
        editingAssessment = true
    }

    func cancelEditing() {
        fillForm(from: attempt)
        editingAssessment = false
    }

    private func fillForm(from a: (any SubjectiveAttemptRecord)?) {
        if let a, a.isAssessed {
            form = .init(restoring: a.partLabels, results: a.parts, causes: a.partCauses,
                         legacyErrorTypes: a.errorTypes, legacyNote: a.errorNote)
            return
        }
        form = prefilledForm(a)
    }

    /// 还没自评时的表单：与答案一致的空判对，上次做对的小问预选跳过，其余按 AI 结论预选；
    /// 没填的空预选没做出来（看答案前贴了图片的不预选：答案可能写在图片里）
    private func prefilledForm(_ a: (any SubjectiveAttemptRecord)?) -> SubjectiveAssessmentRules.Form {
        var form = SubjectiveAssessmentRules.Form()
        for label in a?.autoMatched ?? [] { form.results[label] = .correct }
        for label in skippable { form.results[label] = .skipped }
        for (label, v) in aiVerdicts where form.results[label] == nil {
            if let r = v.partResult { form.results[label] = r }
        }
        if typed, let a, a.revealedAt != nil, a.pastedBeforeReveal.isEmpty {
            for (p, input) in zip(parts, a.typedAnswers) where form.results[p.label] == nil && BlankMatcher.isEmpty(input) {
                form.results[p.label] = .blank
            }
        }
        return form
    }

    /// 没提交自评就离开（原题离开、改编题下一题）时按表单记下：没有结论的小问记没做出来，选了「其他」却没写原因的去掉「其他」
    private func autoSubmitAssessment(_ event: String) {
        for label in labels where form.results[label] == nil { form.results[label] = .blank }
        for label in causeParts.map(\.label) where form.note(label).isEmpty {
            form.causes[label]?.remove(SubjectiveErrorType.other.rawValue)
        }
        ActivityLog.write(event, ["question": scheduleID, "mode": "\(mode)",
                                  "confidence": attempt?.confidenceValue?.rawValue ?? "",
                                  "ai_graded": !aiVerdicts.isEmpty,
                                  "parts": labels.map { form.results[$0]?.rawValue ?? "" }])
        submitAssessment()
    }

    func submitAssessment() {
        guard let context, canSubmitAssessment, let a = attempt,
              let summary = SubjectiveAssessmentRules.summarize(labels: labels, form: form) else { return }
        a.partLabels = labels
        a.partResults = summary.results.map(\.rawValue)
        a.overallResult = summary.overall
        a.partCauses = summary.causes
        a.confusedPoints = summary.confusedPoints
        a.errorTypes = summary.errorTypes
        a.errorNote = summary.errorNote
        variantRecord?.errorType = summary.errorTypes.first
        a.weakPoints = SubjectiveAssessmentRules.weakPoints(
            parts: parts.map { ($0.label, question.testedPoints(of: $0)) }, results: summary.results)
        let verdicts = aiVerdicts
        a.aiCompared = !verdicts.isEmpty
        a.aiDisagreements = SubjectiveAssessmentRules.aiDisagreements(
            labels: labels, results: summary.results, ai: verdicts.compactMapValues(\.partResult))
        if let revealedAt = a.revealedAt, let strokes = pageStrokes() {
            a.strokesAfterReveal = strokes.filter { $0.path.creationDate >= revealedAt }.count
        }
        a.assessedAt = .now
        a.assessmentHistory.append(SubjectiveAssessment(at: .now, parts: a.partResults, result: summary.overall.rawValue,
                                                        errorTypes: a.errorTypes, note: a.errorNote,
                                                        partCauses: summary.causes))
        archiveVariantInk()
        ReviewScheduler.refresh(packID: pack.id, questionID: scheduleID, in: context)
        try? context.save()
        log("self_assessed", SimplePayload(page_count: progress?.pageCount, note: "\(summary.overall.rawValue) \(a.partResults)"))
        editingAssessment = false
        onAssessed?()
    }

    // MARK: - AI 讲评

    func runReview(frames: [Int: CGRect]) {
        guard let context, let attempt, revealed, !review.isBusy else { return }
        let written = handwritingImages(before: attempt.revealedAt, frames: frames)
        let handwriting = (written?.images.all ?? []) + attempt.pastedBeforeReveal.map(\.data)
        let references = ((question.questionImage.map { [$0] } ?? []) + (question.answerImages ?? []))
            .compactMap { HandwritingExport.jpeg(contentsOf: pack.root.appending(path: $0)) }
        let images = handwriting + references
        do {
            // 图片快照只在开始讲评时编码一次，追问草稿的保存只处理文字。
            attempt.reviewImagesData = images.isEmpty ? nil : try JSONEncoder().encode(images)
            try context.save()
            reviewSaveError = nil
        } catch {
            reviewSaveError = "讲评图片保存失败：\(error.localizedDescription)"
        }
        let (system, messages) = Prompts.subjectiveReview(pack: pack, question: question, attempt: attempt,
                                                         handwritingCount: handwriting.count, images: images)
        showReview = true
        review.start(system: system, hidden: messages, purpose: .subjectiveReview)
    }

    private func bindReview(to record: any SubjectiveAttemptRecord) {
        review.save()
        review.onSave = nil
        review.reset()
        review.startPurpose = .subjectiveReview
        showReview = false
        reviewSaveError = nil
        if let data = record.reviewConversationData {
            do {
                review.restore(try JSONDecoder().decode(SavedConversation.self, from: data))
                if let data = record.reviewImagesData,
                   let index = review.context.firstIndex(where: { $0.role == .user }) {
                    review.context[index].images = try JSONDecoder().decode([Data].self, from: data)
                }
                showReview = true
            } catch {
                reviewSaveError = "无法读取已保存的综合题讲评：\(error.localizedDescription)"
            }
        }
        review.onSave = { [weak self] saved in
            guard let self else { return }
            do {
                record.reviewConversationData = try JSONEncoder().encode(saved)
                try self.context?.save()
                self.reviewSaveError = nil
            } catch {
                self.reviewSaveError = "综合题讲评保存失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - AI 批改

    /// useBackup：改用备用供应商的默认模型（需支持图片），不再回退
    func runGrading(frames: [Int: CGRect], useBackup: Bool = false) {
        guard !grader.isRunning, let attempt else { return }
        gradeError = nil
        if typed {
            runTypedGrading(attempt, useBackup: useBackup)
            return
        }
        let written = handwritingImages(before: attempt.revealedAt, frames: frames)
        let pastedBefore = attempt.pastedBeforeReveal
        guard written != nil || !pastedBefore.isEmpty else {
            gradeError = attempt.revealedAt == nil ? "还没有作答内容。先在书写区作答或贴上图片，再请 AI 批改。"
                : "看答案前没有写下内容或贴上图片，没有可批改的作答。"
            gradeImages = []
            return
        }
        gradeImages = (written?.images.previews ?? []) + pastedBefore.compactMap { UIImage(data: $0.data) }
        guard LLMConfig.hasAvailableProvider(.grading) else {
            gradeError = LLMError.notConfigured.localizedDescription
            return
        }
        let questionImages = question.questionImage.map { [pack.root.appending(path: $0)] } ?? []
        let answerImages = (question.answerImages ?? []).map { pack.root.appending(path: $0) }
        let extra = (questionImages + answerImages).compactMap { HandwritingExport.jpeg(contentsOf: $0) }
        let (system, user) = Prompts.subjectiveGrading(
            pack: pack, question: question, areaCount: written?.images.areas.count ?? 0,
            hasOutsideInk: written?.images.outside != nil, pastedCount: pastedBefore.count,
            answerImageCount: answerImages.count, questionImageCount: questionImages.count,
            excludedStrokes: written?.excluded ?? 0,
            excludedPasted: attempt.pastedImages.count - pastedBefore.count)
        let images = (written?.images.all ?? []) + pastedBefore.map(\.data) + extra
        let backup = useBackup ? LLMConfig.backup() : nil
        let config = backup ?? LLMConfig.current(.grading)
        var saved = SavedGrading(model: config.model)
        saved.strokeCount = written?.strokeCount
        saved.latestStroke = written?.latest
        saved.excludedStrokes = written?.excluded
        gradingHistory.append(saved)
        activeGradingID = saved.id
        saveGradingHistory()
        let diagnosticContext: [String: Any] = ["question": question.id, "grading_id": saved.id.uuidString,
                                                "purpose": LLMPurpose.grading.rawValue]
        ActivityLog.write("subjective_ai_grade_request", diagnosticContext.merging(["areas": written?.images.areas.count ?? 0,
                                                     "outside": written?.images.outside != nil, "images": images.count,
                                                     "pasted": pastedBefore.count,
                                                     "excluded": written?.excluded ?? 0,
                                                     "bytes": images.reduce(0) { $0 + $1.count }]) { _, new in new })
        startGrading(saved.id, attempt: attempt, system: system,
                     turn: ChatTurn(role: .user, text: user, images: images), config: config, backup: backup,
                     diagnostics: ActivityLog.llmSink(diagnosticContext))
    }

    /// 键盘填空题：判断没自动对上的空是否与答案等价；看答案前贴的图片一起发送（没用键盘填的空可能写在图片里）
    private func runTypedGrading(_ attempt: any SubjectiveAttemptRecord, useBackup: Bool) {
        guard attempt.revealedAt != nil else {
            gradeError = "先提交答案，再请 AI 判断。"
            return
        }
        guard LLMConfig.hasAvailableProvider(.grading) else {
            gradeError = LLMError.notConfigured.localizedDescription
            return
        }
        let pastedBefore = attempt.pastedBeforeReveal
        gradeImages = pastedBefore.compactMap { UIImage(data: $0.data) }
        let (system, user) = Prompts.blankTextGrading(pack: pack, question: question, typed: attempt.typedAnswers,
                                                      matched: Set(attempt.autoMatched), pastedCount: pastedBefore.count,
                                                      excludedPasted: attempt.pastedImages.count - pastedBefore.count)
        let backup = useBackup ? LLMConfig.backup() : nil
        let config = backup ?? LLMConfig.current(.grading)
        let saved = SavedGrading(model: config.model)
        gradingHistory.append(saved)
        activeGradingID = saved.id
        saveGradingHistory()
        startGrading(saved.id, attempt: attempt, system: system,
                     turn: ChatTurn(role: .user, text: user, images: pastedBefore.map(\.data)),
                     config: config, backup: backup, diagnostics: nil)
    }

    private func startGrading(_ id: UUID, attempt: any SubjectiveAttemptRecord, system: String, turn: ChatTurn,
                              config: LLMConfig, backup: LLMConfig?, diagnostics: LLMDiagnosticSink?) {
        grader.run(system: system, messages: [turn], config: config,
                   backup: backup == nil ? .backup() : nil,
                   diagnostics: diagnostics,
                   onUpdate: { [weak self] text in
            guard let self else { return }
            self.updateGrading(id: id, text: text, completed: false, error: self.grader.error,
                               throttled: self.grader.isRunning)
        }) { [weak self] text in
            guard let self else { return }
            self.updateGrading(id: id, text: text, completed: true, error: nil)
            self.activeGradingID = nil
            // 还没提交自评时，按新的批改结论预选
            if self.revealed && !self.assessed { self.fillForm(from: attempt) }
        }
    }

    /// throttled：生成中的中途进度，最多每 5 秒写一次（编码全部历史并写库在主线程上，逐秒做会让滚动卡顿）；
    /// 结束、出错、取消、离开页面时照常立即保存
    private func updateGrading(id: UUID, text: String, completed: Bool, error: String?, throttled: Bool = false) {
        if throttled {
            guard Date.now.timeIntervalSince(lastGradingSave) >= 5 else { return }
        }
        lastGradingSave = .now
        guard let index = gradingHistory.firstIndex(where: { $0.id == id }) else { return }
        gradingHistory[index].text = text
        gradingHistory[index].completed = completed
        gradingHistory[index].error = error
        gradingHistory[index].usage = grader.usage
        gradingHistory[index].model = grader.usage?.model ?? gradingHistory[index].model
        if completed { gradingHistory[index].verdicts = GradingVerdict.parse(text) }
        saveGradingHistory()
    }

    private func saveGradingHistory() {
        guard let attempt else { return }
        do {
            attempt.gradingHistoryData = try JSONEncoder().encode(gradingHistory)
            try context?.save()
            gradeSaveError = nil
        } catch {
            gradeSaveError = "AI 批改保存失败：\(error.localizedDescription)"
        }
    }

    /// 把各书写区里的笔迹渲染成白底图片；书写区外的笔迹另成一张。
    /// before 不为 nil 时只取这之前落笔的笔画（看答案后补写的不算作答）。没有笔迹时返回 nil
    private func handwritingImages(before: Date?, frames: [Int: CGRect])
        -> (images: HandwritingExport.Images, strokeCount: Int, latest: Date?, excluded: Int)? {
        guard let strokes = pageStrokes() else { return nil }
        let kept = before.map { t in strokes.filter { $0.path.creationDate < t } } ?? strokes
        guard !kept.isEmpty else { return nil }
        return (HandwritingExport.images(PKDrawing(strokes: kept), areas: frames), kept.count,
                kept.map(\.path.creationDate).max(), strokes.count - kept.count)
    }

    #if DEBUG
    /// 调试：按小问依次填写键盘填空题
    func debugFillTyped(_ values: [String]) {
        for (i, v) in values.enumerated() where i < typedInputs.count { typedInputs[i] = v }
        attempt?.typedAnswers = typedInputs
    }
    #endif
}
