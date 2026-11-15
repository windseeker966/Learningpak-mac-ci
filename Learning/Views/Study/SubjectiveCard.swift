import PencilKit
import SwiftData
import SwiftUI

/// 草稿画布所在页面的坐标空间：主观题书写区的位置按它记录，与笔迹坐标一致
let draftPageSpace = "draftPage"

/// 一道主观题（综合应用题）的一次作答：题面 → 空白书写区（可追加）→ 标把握程度并展示答案 → 逐问自评。
/// 书写用的就是页面上的草稿画布（涂抹即擦除、缩放、工具栏都相同）；学习页挂有详细笔迹记录。
/// 每次作答一条 SubjectiveAttempt：自评结果进复习队列、计入知识点掌握度；AI 批改按作答保存，只作自评参考。
/// 重做（学习页）或下次复习时，上一次的页面笔迹存进那次作答，页面清空重写。
/// AI 改编题也用它作答（见 SubjectiveVariantCard）：记 VariantAttempt，笔迹在页面的改编区里
struct SubjectiveCard: View {
    typealias Mode = SubjectiveAttemptSession.Mode

    let pack: StudyPack
    let question: SubjectiveQuestion
    let sectionID: String
    var mode: Mode = .study
    /// 在页面草稿画布上手写；单独的主观题窗口里没有画布，改为贴图片作答（见 SubjectiveWindow）
    var inkInput = true
    /// 「单独窗口作答」：到主观题窗口里作答，和 GoodNotes 并排；nil 时不显示
    var onDetach: (() -> Void)? = nil
    var nextLabel: String
    /// 改编题：复习页逐题改编时要有了结果才能下一题，没提交自评的按预选的结论记下
    var requireResult = false
    /// 提交自评后调用（复习、错题本据此显示「回到最开始学这道题的地方」）
    var onAssessed: (() -> Void)? = nil
    /// 复习页：题目下方展开的 AI 改编和 AI 改编复习一样，有了结果就能直接下一题（这道题用改编题复习了）
    var variantAdvances = false
    var onNext: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.renderScale) private var renderScale
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: SubjectiveAttemptSession
    /// session 是这里自己建的：卡片离开时按表单记下没提交的自评（见 SubjectiveAttemptSession.leave）
    private var ownsSession = true
    @State private var areaFrames: [Int: CGRect] = [:]
    @State private var onScreen = false
    /// App 是否在前台。存成状态：异步任务里捕获的视图副本读到的 scenePhase 可能已过时
    @State private var appActive = true
    /// 这张卡片在作答流程里的标识（改编题的作答流程可能同时显示在两个窗口里）
    @State private var viewerID = UUID()
    /// 题目下方展开的 AI 改编。可以由外面传入，主窗口和单独窗口共用同一道改编题（见 DetachableSubjectiveCard）
    @State private var variantSlot: VariantSlot
    /// variantSlot 是这里自己建的：卡片离开时停止改编
    private var ownsVariantSlot = true
    /// 页面上点了「图片作答」，在书写区下面展开贴图片作答
    @State private var showPaste = false

    init(pack: StudyPack, question: SubjectiveQuestion, sectionID: String, mode: Mode = .study, inkInput: Bool = true,
         onDetach: (() -> Void)? = nil, session: SubjectiveAttemptSession? = nil,
         variantSlot: VariantSlot? = nil, nextLabel: String,
         onAssessed: (() -> Void)? = nil, variantAdvances: Bool = false, onNext: @escaping () -> Void) {
        self.pack = pack
        self.question = question
        self.sectionID = sectionID
        self.mode = mode
        self.inkInput = inkInput
        self.onDetach = onDetach
        self.nextLabel = nextLabel
        self.onAssessed = onAssessed
        self.variantAdvances = variantAdvances
        self.onNext = onNext
        _session = State(initialValue: session ?? SubjectiveAttemptSession(pack: pack, question: question,
                                                                           sectionID: sectionID, mode: mode))
        ownsSession = session == nil
        _variantSlot = State(initialValue: variantSlot ?? VariantSlot())
        ownsVariantSlot = variantSlot == nil
    }

    /// AI 改编题：作答流程由 SubjectiveVariantGeneration 建好传进来；onDetach：AI 改编复习里可以转到单独窗口
    init(session: SubjectiveAttemptSession, inkInput: Bool = true, onDetach: (() -> Void)? = nil, requireResult: Bool,
         nextLabel: String, onNext: @escaping () -> Void) {
        self.pack = session.pack
        self.question = session.question
        self.sectionID = session.sectionID
        self.mode = session.mode
        self.inkInput = inkInput
        self.onDetach = onDetach
        self.requireResult = requireResult
        self.nextLabel = nextLabel
        self.onNext = onNext
        _session = State(initialValue: session)
        ownsSession = false
        _variantSlot = State(initialValue: VariantSlot())
    }

    private var ai: Bool { question.aiAuthored == true }
    private var variant: SubjectiveAttemptSession.Variant? { session.variant }
    private var parts: [SubjectiveQuestion.Part] { session.parts }
    private var attempt: (any SubjectiveAttemptRecord)? { session.attempt }
    private var revealed: Bool { session.revealed }
    private var assessed: Bool { session.assessed }
    private var typed: Bool { session.typed }
    private var draftKey: String { session.draftKey }

    /// 报给草稿画布的书写区锚点。单独窗口里没有画布，不报，免得挪动主窗口这一页的笔迹
    private var anchorKey: String { inkInput ? draftKey : "" }
    /// 改编题的书写部分是改编区里的另一个锚点（改编区可能在原题那一页上）
    private var anchorName: String { variant == nil ? DraftAnchors.writing : SubjectiveVariantCard.anchorNames[1] }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            questionCard
            navigationRow

            // 答案放在题目下方，和选择题的解析一致；展开后书写区被推下去，笔迹跟着走（见 DraftAnchors）
            if revealed && !session.answerHidden { answerCard }

            VStack(alignment: .leading, spacing: 20) {
                if typed { blankInputCard }
                if inkInput {
                    WritingAreaList(count: session.pageCount, ctx: mode == .study ? session.recordContext : nil,
                                    frames: $areaFrames)
                }
                if !inkInput || showPaste || !session.pasted.isEmpty {
                    PastedAnswerCard(images: session.pasted, revealedAt: attempt?.revealedAt,
                                     onAdd: session.addPasted, onDelete: session.deletePasted)
                        .draftTappable(inkInput)
                }
                buttonRow
                if !revealed { revealRow }
                if session.grader.isRunning || !session.gradingHistory.isEmpty || session.grader.error != nil
                    || session.gradeError != nil || session.gradeSaveError != nil {
                    gradingCard
                }
                if revealed {
                    if assessed && !session.editingAssessment {
                        assessmentSummary
                        markControls
                    } else {
                        assessmentForm
                    }
                    reviewCard
                }
                // 复习、重做时，以往作答（当时的结果、错因、笔迹和讲评）等看过答案再显示，免得作答前就看到
                if !session.others.isEmpty && (mode != .review || revealed) { otherAttempts }
                if revealed && variant == nil {
                    VariantHistoryCard(pack: pack, originalID: question.id)
                    SavedVariantsCard(pack: pack, originalID: question.id)
                }
            }
            .draftInkAnchor(anchorKey, name: anchorName)

            // 点题目卡片底部「AI改编」后在这里展开
            if let generation = variantSlot.generation, variant == nil {
                // 学习页（第一次做这道题的地方）只做练习，不计入复习安排；复习、错题本里的改编照常计入。
                // 复习页做完改编题可以直接下一题
                SubjectiveVariantCard(generation: generation,
                                      title: mode == .study ? "AI 改编练习 · 作答和笔迹都保存，不计入复习安排"
                                          : "AI 改编 · 改编自本题，按原题的规则计入复习安排",
                                      closeLabel: variantAdvances ? nextLabel : "收起",
                                      requireResult: variantAdvances,
                                      inkInput: inkInput,
                                      onRegenerate: { startVariant(useBackup: $0, reuse: false) },
                                      onClose: { variantSlot.drop() },
                                      onFinish: variantAdvances ? onNext : nil)
                    .id(ObjectIdentifier(generation))
            }
        }
        .onAppear {
            session.onAssessed = onAssessed
            session.load(in: context)
            onScreen = true
            appActive = scenePhase == .active
            session.setActive(onScreen && appActive, viewer: viewerID)
        }
        .onChange(of: scenePhase) { _, phase in
            appActive = phase == .active
            if phase != .active { session.review.save() }
            session.setActive(onScreen && appActive, viewer: viewerID)
        }
        .onDisappear {
            onScreen = false
            session.disappear(viewer: viewerID)
            if ownsVariantSlot { variantSlot.generation?.cancel() }
            if ownsSession { session.leave() }
        }
        #if DEBUG
        .task { await debugActions() }
        #endif
    }

    /// 展开（或重新）改编一道。改编题的笔迹记在原题这一页（单独窗口里没有画布，也按这一页记）。
    /// reuse：展开时先用上次改编好、还没做的题；重新改编时不用
    private func startVariant(useBackup: Bool, reuse: Bool = true) {
        variantSlot.replace(with: SubjectiveVariantGeneration(pack: pack, original: question, sectionID: sectionID,
                                                              draftKey: draftKey, practice: mode == .study,
                                                              useBackup: useBackup, reuse: reuse))
    }

    /// 题目下方展开的 AI 改编：值为 nil 表示没展开。由持有题目的视图建，可以让两个窗口里的卡片共用
    @MainActor
    @Observable
    final class VariantSlot {
        private(set) var generation: SubjectiveVariantGeneration?

        func replace(with generation: SubjectiveVariantGeneration) {
            self.generation?.cancel()
            self.generation = generation
        }

        /// 收起：不再要这道改编题
        func drop() {
            generation?.cancel()
            generation = nil
        }
    }

    // MARK: - 题面与答案

    @ViewBuilder
    private var questionCard: some View {
        if let variant {
            Card {
                HStack(alignment: .firstTextBaseline) {
                    Text("改编题").font(.headline)
                    kindBadge
                    Spacer()
                    QuestionFaultBadge(packID: pack.id, questionID: variant.id)
                }
                QuestionFaultBanner(packID: pack.id, questionID: variant.id, variant: true)
                if let stem = question.stem {
                    SelectableText(attributed: RichText.plain(stem, style: .title3, unescape: true, scale: renderScale),
                                   source: "AI 改编题题面", onAction: nil)
                }
                QuestionToolsRow(packID: pack.id, questionID: variant.id, onAIVariant: nil,
                                 originalID: variant.original.id)
            }
        } else {
            originalQuestionCard
        }
    }

    private var kindBadge: some View {
        let tint: Color = question.isBlank ? .teal : .purple
        return Text(question.isBlank ? "填空题" : "综合应用题").font(.caption.bold())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
    }

    private var originalQuestionCard: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text("第 \(question.num) 题").font(.headline)
                kindBadge
                if let w = question.aiWritten {
                    Text(w.label).font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                        .foregroundStyle(.orange)
                }
                if ai {
                    Label("AI 出题", systemImage: "sparkles").font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.purple.opacity(0.12), in: Capsule())
                        .foregroundStyle(.purple)
                }
                Spacer()
                Text(pack.questionSource(page: question.page ?? [], requires: question.requires, aiAuthored: ai, source: question.source))
                    .font(.caption).foregroundStyle(.secondary)
                QuestionFaultBadge(packID: pack.id, questionID: question.id)
            }
            QuestionFaultBanner(packID: pack.id, questionID: question.id)
            if let stem = question.stem {
                SelectableText(attributed: RichText.plain(stem, style: .title3, unescape: true, scale: renderScale),
                               source: "题面", onAction: nil)
            }
            if let path = question.questionImage {
                OriginalPageImage(url: pack.root.appending(path: path), title: "原题")
            }
            if !session.skippable.isEmpty && !revealed {
                Label("上次已做对：\(parts.map(\.label).filter(session.skippable.contains).joined(separator: "、"))。这次可以只做其余小问，自评时这几问记为跳过。",
                      systemImage: "forward")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            QuestionToolsRow(packID: pack.id, questionID: question.id,
                             onAIVariant: pack.allowsAIVariant ? { startVariant(useBackup: false) } : nil,
                             aiAvailable: LLMConfig.hasAvailableProvider(.subjectiveVariant))
        }
    }

    private var answerCard: some View {
        Card {
            Text(pack.isSupplementBased(question.requires) ? "参考答案（AI 编写，书外补充）"
                 : ai ? "参考答案（AI 编写，请对照\(pack.sourceLabel)核对）"
                 : question.aiWritten == .answer ? "参考答案（AI 编写）"
                 : (question.answerPage ?? question.page).map { "\(pack.sourceLabel)答案（第 \(pageText($0)) 页）" } ?? "答案").font(.headline)
            if let answer = question.answer {
                MarkdownView(text: answer, pack: pack)
            }
            ForEach(question.answerImages ?? [], id: \.self) { path in
                OriginalPageImage(url: pack.root.appending(path: path), title: "\(pack.sourceLabel)答案")
            }
            if let qp = question.parts, qp.contains(where: { $0.shownAnswer != nil || $0.points != nil }) {
                if question.answer != nil || question.answerImages != nil { Divider() }
                ForEach(qp, id: \.label) { p in
                    VStack(alignment: .leading, spacing: 4) {
                        if let a = question.isBlank ? p.shownAnswer : p.answer {
                            MarkdownView(text: "**\(p.label)** \(a)", pack: pack)
                        } else {
                            Text(p.label).bold()
                        }
                        if let pts = p.points, !pts.isEmpty {
                            Text("得分点：" + pts.joined(separator: "；")).font(.callout).foregroundStyle(.secondary)
                        }
                        if let acc = p.accept, acc.count > 1 {
                            Text("也算对：" + acc.dropFirst().joined(separator: "、")).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let explanation = question.explanation {
                Divider()
                Text(question.aiWritten != nil ? "解析（AI 编写）" : "解析").font(.headline)
                MarkdownView(text: explanation, pack: pack)
            }
        }
    }

    // MARK: - 按钮

    /// 题目下方靠右：单独窗口作答、下一题（自评后才有，与选择题提交后相同）
    @ViewBuilder
    private var navigationRow: some View {
        if onDetach != nil || variant != nil || assessed {
            HStack(spacing: 12) {
                Spacer()
                if let onDetach {
                    Button("单独窗口作答", systemImage: "rectangle.split.1x2") { onDetach() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .draftTappable()
                }
                if variant != nil {
                    variantNextButton
                } else if assessed {
                    Button(nextLabel) { onNext() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .draftTappable()
                }
            }
        }
    }

    @ViewBuilder
    private var buttonRow: some View {
        HStack {
            if inkInput {
                Button("添加书写区", systemImage: "plus.rectangle.on.rectangle") { session.addArea() }
                    .draftTappable()
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                DeleteAreaMenu(count: session.pageCount) { session.deleteArea($0, frames: areaFrames) }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .draftTappable()
                if !showPaste && session.pasted.isEmpty {
                    Button("图片作答", systemImage: "photo.on.rectangle") { showPaste = true }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .draftTappable()
                }
            }
            // 键盘输入的填空题提交后才有可判断的内容；提交时自动比对没对上的空会自动请 AI 判断
            if !typed || revealed {
                Button(typed ? "AI 判断" : "AI 批改", systemImage: "sparkles") { session.runGrading(frames: areaFrames) }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(session.grader.isRunning)
                    .draftTappable()
            }
            Spacer()
            if revealed {
                if session.answerHidden {
                    Button("展开答案", systemImage: "eye") { session.showAnswerAgain() }
                        .buttonStyle(.bordered).controlSize(.large).draftTappable()
                } else {
                    Button("收起答案", systemImage: "eye.slash") { session.hideAnswer() }
                        .buttonStyle(.bordered).controlSize(.large).draftTappable()
                }
            }
            if assessed && mode != .review {
                Button(variant == nil ? "重做这道题" : "重做", systemImage: "arrow.counterclockwise") { session.redo() }
                    .buttonStyle(.bordered).controlSize(.large).draftTappable()
            }
        }
    }

    private var variantNextButton: some View {
        VariantNextButton(session: session, requireResult: requireResult, label: nextLabel, onNext: onNext)
    }

    /// 看答案前先标把握程度
    private var revealRow: some View {
        HStack(spacing: 12) {
            Text(typed ? "填完后标记把握程度，提交并查看答案：" : "写完后标记把握程度，查看答案：").foregroundStyle(.secondary)
            Spacer()
            revealButton(.sure, .green)
            revealButton(.unsure, .orange)
            revealButton(.gaveUp, .gray)
        }
    }

    private func revealButton(_ c: SubjectiveConfidence, _ color: Color) -> some View {
        Button(c == .gaveUp ? "不会做，直接看答案" : c.label) { session.reveal(c) }
            .buttonStyle(.borderedProminent)
            .tint(color)
            .controlSize(.large)
            .draftTappable()
    }

    // MARK: - 自评

    @ViewBuilder
    private var assessmentForm: some View {
        let verdicts = session.aiVerdicts
        Card {
            Text("对照答案，自评这次作答").font(.headline)
            Text(verdicts.isEmpty ? (typed && !session.autoMatched.isEmpty ? "与答案一致的空已自动判对，其余逐空对照答案自评。"
                                        : "逐问选择结果。自评结果决定复习安排，并计入知识点掌握度。")
                 : "已按 AI 的结论预选，请对照答案核对后再提交。")
                .font(.caption).foregroundStyle(.secondary)
            if let c = attempt?.confidenceValue {
                Text("看答案前：\(c.label)").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(parts, id: \.label) { p in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        Text(p.label).bold().frame(minWidth: 44, alignment: .leading)
                        if session.autoMatched.contains(p.label) {
                            Label("对 · 与答案一致", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            let options = question.assessmentOptions + (session.skippable.contains(p.label) ? [.skipped] : [])
                            CapsuleSwitcher(items: options.map { r in
                                .init(title: r.label, selected: session.form.results[p.label] == r) {
                                    session.form.results[p.label] = r
                                }
                            })
                        }
                        Spacer(minLength: 0)
                        if let v = verdicts[p.label] {
                            Text("AI：\(v.partResult?.label ?? "无法判断")")
                                .font(.caption).foregroundStyle(.purple)
                        }
                    }
                    if let missing = verdicts[p.label]?.missing, !missing.isEmpty {
                        Text("AI 认为没写出：" + missing.joined(separator: "；")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            // 没做对的每一问分别选错误类型、写原因
            SubjectiveCauseForm(labels: session.causeParts.map(\.label), single: parts.count == 1,
                                options: SubjectiveErrorType.options(blank: question.isBlank), pack: pack,
                                confusionCandidates: confusionCandidates, form: Bindable(session).form)
            HStack {
                if session.editingAssessment {
                    Button("取消") { session.cancelEditing() }
                        .buttonStyle(.borderless)
                        .draftTappable()
                }
                Spacer()
                Button("提交自评") { session.submitAssessment() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!session.canSubmitAssessment)
                    .draftTappable()
            }
        }
    }

    /// 「混淆」可能涉及的知识点：这一问考查的在前，再是其他小问的和本节引入的
    private func confusionCandidates(_ label: String) -> [String] {
        guard let p = parts.first(where: { $0.label == label }) else { return [] }
        var ids = question.testedPoints(of: p) + parts.flatMap(question.testedPoints(of:))
        ids += pack.knowledgePoints.values.filter { $0.introducedIn == sectionID && $0.deprecated != true }
            .map(\.id).sorted()
        var seen = Set<String>()
        return ids.filter { pack.knowledgePoints[$0] != nil && seen.insert($0).inserted }
    }


    @ViewBuilder
    private var assessmentSummary: some View {
        if let a = attempt, let r = a.resultValue {
            Card {
                HStack(alignment: .firstTextBaseline) {
                    Label("自评：\(r.label)", systemImage: Self.icon(r))
                        .font(.headline)
                        .foregroundStyle(Self.color(r))
                    Spacer()
                    Button("修改") { session.beginEditing() }
                    .buttonStyle(.borderless)
                    .draftTappable()
                }
                Text(Self.detailLine(a)).font(.callout).foregroundStyle(.secondary)
                let causes = a.causeLines(pack.pointTitle)
                if !causes.isEmpty {
                    Text("错因：" + causes.joined(separator: "\n"))
                }
                if !a.aiDisagreements.isEmpty {
                    Label("与 AI 批改结论不一致：\(a.aiDisagreements.joined(separator: "、"))", systemImage: "exclamationmark.bubble")
                        .font(.callout).foregroundStyle(.purple)
                }
                if !a.weakPoints.isEmpty {
                    Text("计入薄弱知识点：" + a.weakPoints.map(pack.pointTitle).joined(separator: "、"))
                        .font(.callout).foregroundStyle(.orange)
                }
                if let v = a as? VariantAttempt {
                    Text(v.practice ? "改编练习：不计入复习安排和统计。" : "结果按原题的规则计入原题的复习安排和知识点掌握度。")
                        .font(.caption).foregroundStyle(.secondary)
                } else if r != .correct || a.confidenceValue != .sure {
                    Text(a.isImmediateRedo ? "看答案后不久的重做：不改变复习安排。" : "已加入复习队列。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 自评后可以标为重点、已掌握（AI 改编题没有）
    @ViewBuilder
    private var markControls: some View {
        if variant == nil, attempt?.resultValue != nil {
            QuestionMarkControls(packID: pack.id, questionID: question.id)
        }
    }

    static func icon(_ r: PartResult) -> String {
        switch r {
        case .correct: "checkmark.circle.fill"
        case .partial: "circle.lefthalf.filled"
        case .wrong, .blank: "xmark.circle.fill"
        case .skipped: "forward.circle"
        }
    }

    static func color(_ r: PartResult) -> Color {
        switch r {
        case .correct: .green
        case .partial: .orange
        case .wrong, .blank: .red
        case .skipped: .secondary
        }
    }

    /// 一次作答的概要：各问结果、把握程度、用时、看答案前后的笔画数
    static func detailLine(_ a: any SubjectiveAttemptRecord) -> String {
        var items: [String] = []
        if a.partLabels.count > 1 || a.partLabels.first != "全题" {
            items.append(zip(a.partLabels, a.parts).map { "\($0) \($1.label)" }.joined(separator: "，"))
        }
        if let c = a.confidenceValue { items.append("看答案前\(c.label)") }
        if !a.typedAnswers.isEmpty {
            // 键盘输入的填空题：写出填的内容，不计笔画
            let labels = a.partLabels.count == a.typedAnswers.count ? a.partLabels : a.typedAnswers.indices.map { "第\($0 + 1)空" }
            let empty = a.pastedBeforeReveal.isEmpty ? "（没填）" : "（见图片）"
            items.append("填写：" + zip(labels, a.typedAnswers).map { "\($0) \(BlankMatcher.isEmpty($1) ? empty : $1)" }
                .joined(separator: "；"))
            items.append("用时 \(Self.durationText(a.writingSeconds))")
            return items.joined(separator: " · ")
        }
        items.append("书写 \(max(Int(a.writingSeconds / 60), a.writingSeconds > 0 ? 1 : 0)) 分钟")
        items.append("看答案前 \(a.strokesBeforeReveal) 笔" + (a.strokesAfterReveal > 0 ? "，之后补写 \(a.strokesAfterReveal) 笔" : ""))
        return items.joined(separator: " · ")
    }

    private static func durationText(_ seconds: Double) -> String {
        seconds < 60 ? "\(max(Int(seconds), 1)) 秒" : "\(Int(seconds / 60)) 分 \(Int(seconds) % 60) 秒"
    }

    // MARK: - 以往作答

    private var otherAttempts: some View {
        Card {
            Text("以往作答").font(.headline)
            ForEach(Array(session.others.enumerated()), id: \.element.persistentModelID) { i, a in
                if i > 0 { Divider() }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let r = a.resultValue {
                            Image(systemName: Self.icon(r)).foregroundStyle(Self.color(r))
                        } else {
                            Image(systemName: "pencil.circle").foregroundStyle(.secondary)
                        }
                        let kind = a.modeLabel
                        Text("\((a.revealedAt ?? a.createdAt).formatted(date: .abbreviated, time: .shortened)) · \(kind) · \(a.resultValue?.label ?? (a.revealedAt == nil ? "未完成" : "未自评"))")
                        if a.isImmediateRedo {
                            Text("看答案后不久重做").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(Self.detailLine(a)).font(.caption).foregroundStyle(.secondary)
                    ForEach(a.causeLines(pack.pointTitle), id: \.self) { Text($0).font(.caption) }
                    if let note = a.correctionNote, !note.isEmpty {
                        Label(note, systemImage: "square.and.pencil").font(.callout)
                    }
                    CorrectionHistoryView(entries: a.correctionHistory)
                    if let data = a.reviewConversationData,
                       let conversation = try? JSONDecoder().decode(SavedConversation.self, from: data) {
                        DisclosureGroup("AI 讲评") {
                            SavedChatThreadView(conversation: conversation, pack: pack).padding(.top, 8)
                        }
                        .draftTappable()
                    }
                    if a.inkData != nil || a.pastedImagesData != nil || !a.gradings.isEmpty {
                        DisclosureGroup("查看当时的笔迹和 AI 批改") {
                            AttemptInkView(attempt: a, pack: pack).padding(.top, 8)
                        }
                        .draftTappable()
                    }
                }
            }
        }
    }

    // MARK: - 键盘输入的填空题

    private var blankInputCard: some View {
        Card {
            Text(revealed ? "填写的答案" : "在下面填写答案（可用 Apple Pencil 直接写进输入框）").font(.headline)
            ForEach(Array(parts.enumerated()), id: \.element.label) { i, p in
                HStack(spacing: 12) {
                    Text(p.label).bold().frame(minWidth: 44, alignment: .leading)
                    if revealed {
                        let input = i < session.typedInputs.count ? session.typedInputs[i] : ""
                        Text(BlankMatcher.isEmpty(input) ? (attempt?.pastedBeforeReveal.isEmpty ?? true ? "（没填）" : "（见图片）") : input)
                            .foregroundStyle(BlankMatcher.isEmpty(input) ? .secondary : .primary)
                        if session.autoMatched.contains(p.label) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                        Spacer(minLength: 0)
                    } else {
                        TextField("第 \(i + 1) 空", text: Binding(
                            get: { i < session.typedInputs.count ? session.typedInputs[i] : "" },
                            set: { session.setTypedInput(i, $0) }))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(10)
                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                            .draftTappable()
                    }
                }
            }
        }
    }

    #if DEBUG
    /// 调试：-debugTyped "PCB,奇" 键盘填空题按空填写（配合 -debugShowAnswer 提交）；-debugShowAnswer YES 打开即看答案；-debugAssess correct,wrong 随后按小问自评；
    /// -debugAIAdaptAfter 2 打开 2 秒后展开 AI 改编；-debugAddArea YES 加一个书写区；
    /// -debugDeleteAreaAfter 4 打开 4 秒后删除书写区 1；-debugRevealAfter 3 打开 3 秒后看答案；-debugGrade YES 3 秒后 AI 批改
    private func debugActions() async {
        let d = UserDefaults.standard
        // 调试：-debugCycleAnswer 6 打开 6 秒后收起、展开答案共 6 次，打印每次后的最长卡顿帧（没看过答案的先看答案）
        let toggles = d.integer(forKey: "debugCycleAnswer")
        if toggles > 0, variant == nil {
            let monitor = FrameMonitor()
            if !revealed { session.reveal(.unsure) }
            try? await Task.sleep(for: .seconds(6))
            for i in 0..<toggles {
                monitor.reset()
                let start = ProcessInfo.processInfo.systemUptime
                if i % 2 == 0 { session.hideAnswer() } else { session.showAnswerAgain() }
                try? await Task.sleep(for: .seconds(3))
                print(String(format: "[answer] uptime %.2f %@答案：第一帧 %.0f ms，最长一帧 %.0f ms", start,
                             i % 2 == 0 ? "收起" : "展开", monitor.firstGap * 1000, monitor.maxGap * 1000))
            }
            print("[answer] done")
        }
        if d.bool(forKey: "debugSubjectiveReviewChecks"), variant == nil {
            do { try SubjectiveReviewChecks.run(pack: pack, question: question) }
            catch { preconditionFailure("综合题讲评回归失败：\(error)") }
        }
        if let raw = d.string(forKey: "debugTyped"), typed, !revealed {
            session.debugFillTyped(raw.components(separatedBy: ","))
        }
        if d.bool(forKey: "debugShowAnswer"), !revealed {
            session.reveal(SubjectiveConfidence(rawValue: d.string(forKey: "debugConfidence") ?? "") ?? .unsure)
        }
        if let raw = d.string(forKey: "debugAssess"), revealed, !assessed {
            for (p, r) in zip(parts, raw.components(separatedBy: ",")) { session.form.results[p.label] = PartResult(rawValue: r) }
            if let e = d.string(forKey: "debugSubjectiveError") {
                for p in session.causeParts { session.form.causes[p.label] = [e] }
            }
            session.submitAssessment()
        }
        let adaptDelay = d.double(forKey: "debugAIAdaptAfter")
        if adaptDelay > 0, variant == nil {
            Task {
                try? await Task.sleep(for: .seconds(adaptDelay))
                startVariant(useBackup: false)
            }
        }
        if d.bool(forKey: "debugAddArea") { session.addArea() }
        let deleteDelay = d.double(forKey: "debugDeleteAreaAfter")
        if deleteDelay > 0 {
            try? await Task.sleep(for: .seconds(deleteDelay))
            session.deleteArea(0, frames: areaFrames)
        }
        let delay = d.double(forKey: "debugRevealAfter")
        if delay > 0 {
            try? await Task.sleep(for: .seconds(delay))
            session.reveal(.unsure)
        }
        guard d.bool(forKey: "debugGrade") else { return }
        try? await Task.sleep(for: .seconds(3))
        session.runGrading(frames: areaFrames)
    }
    #endif


    // MARK: - AI 讲评与批改

    // MARK: - AI 批改

    private var reviewCard: some View {
        Card {
            HStack {
                Text("AI 讲评").font(.headline)
                Spacer()
                if !session.showReview {
                    Button(session.showReview ? "重试" : "请 AI 讲评这道题", systemImage: "sparkles") {
                        session.runReview(frames: areaFrames)
                    }
                        .buttonStyle(.bordered)
                        .disabled(session.review.isBusy || !LLMConfig.hasAvailableProvider(.subjectiveReview))
                        .draftTappable()
                }
            }
            if session.showReview {
                ChatThreadView(session: session.review, placeholder: "对解题步骤还有疑问？继续问，也可以划选文字提问",
                               showsInput: !session.review.messages.isEmpty, pack: pack)
            } else {
                Text("结合参考答案、自评和已有批改解释思路，讲评和后续提问随这次作答保存。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let reviewSaveError = session.reviewSaveError {
                Label(reviewSaveError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
    }

    private var gradingCard: some View {
        Card {
            HStack {
                Label("AI 批改", systemImage: "sparkles").font(.headline)
                Spacer()
                if !session.grader.isRunning && (!session.gradingHistory.isEmpty || session.grader.error != nil) {
                    Menu {
                        Button("重新批改", systemImage: "arrow.clockwise") { session.runGrading(frames: areaFrames) }
                        if LLMConfig.backup() != nil {
                            Button("用备用模型重新批改", systemImage: "arrow.triangle.swap") {
                                session.runGrading(frames: areaFrames, useBackup: true)
                            }
                        }
                    } label: {
                        Label("重新批改", systemImage: "arrow.clockwise")
                    } primaryAction: {
                        session.runGrading(frames: areaFrames)
                    }
                    .draftTappable()
                }
            }
            Text(typed ? "AI 只判断没有与答案逐字一致的空；看答案前贴的图片会一起发送，键盘没填的空按图片判断。结论随这次作答保存，只作自评参考。"
                 : "批改内容随这次作答保存，重新批改会保留之前的结果。看过答案后再批改，只发送看答案前写的笔迹。AI 的结论只作自评参考，请核对它是否正确识别了你的笔迹。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !session.gradeImages.isEmpty {
                Text("发给 AI 的手写图片").font(.subheadline.bold())
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(Array(session.gradeImages.enumerated()), id: \.offset) { _, img in
                            Image(uiImage: img).resizable().scaledToFit().frame(height: 120)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                        }
                    }
                }
            }
            if let gradeError = session.gradeError {
                Label(gradeError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let gradeSaveError = session.gradeSaveError {
                Label(gradeSaveError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if session.grader.isRunning || session.grader.error != nil {
                StreamStatusView(runner: session.grader) { session.runGrading(frames: areaFrames, useBackup: $0) }
            }
            if let latest = session.gradingHistory.last {
                Text(latest.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
                if session.activeGradingID == latest.id {
                    StreamTextView(runner: session.grader, pack: pack, transform: GradingVerdict.displayText)
                } else {
                    Self.gradingResult(latest, pack: pack)
                }
            }
            ForEach(session.gradingHistory.dropLast().reversed()) { saved in
                DisclosureGroup("以往批改 · \(saved.createdAt.formatted(date: .abbreviated, time: .shortened))") {
                    Self.gradingResult(saved, pack: pack).padding(.top, 8)
                }
                .draftTappable()
            }
        }
    }

    @ViewBuilder
    static func gradingResult(_ saved: SavedGrading, pack: StudyPack) -> some View {
        ModelBadge(usage: saved.usage, legacyModel: saved.model)
        if !saved.completed {
            Label(saved.error ?? "这次批改未完成，已保留生成的内容，可重新批改。", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
        if let n = saved.excludedStrokes, n > 0 {
            Text("看答案后补写的 \(n) 笔没有发给 AI。").font(.caption).foregroundStyle(.secondary)
        }
        if !saved.text.isEmpty { MarkdownView(text: GradingVerdict.displayText(saved.text), pack: pack) }
    }
}
/// 改编题的下一题、收起：随时可以收起；复习页逐题改编要有了结果（或标记了题目有错）才能下一题，
/// 没提交自评的按预选的结论记下
private struct VariantNextButton: View {
    let session: SubjectiveAttemptSession
    let requireResult: Bool
    let label: String
    let onNext: () -> Void
    @Query private var marks: [QuestionMark]

    init(session: SubjectiveAttemptSession, requireResult: Bool, label: String, onNext: @escaping () -> Void) {
        self.session = session
        self.requireResult = requireResult
        self.label = label
        self.onNext = onNext
        let key = "\(session.pack.id)|\(session.variant?.id ?? "")"
        _marks = Query(filter: #Predicate<QuestionMark> { $0.key == key })
    }

    var body: some View {
        let blocker = requireResult ? session.advanceBlocker(faulty: marks.first?.faulty == true) : nil
        if let blocker {
            Text(blocker).font(.caption).foregroundStyle(.secondary)
        }
        let button = Button(label) {
            session.finishVariant(autoAssess: requireResult)
            onNext()
        }
        Group {
            if requireResult { button.buttonStyle(.borderedProminent) } else { button.buttonStyle(.bordered) }
        }
        .controlSize(.large)
        .disabled(blocker != nil)
        .draftTappable()
    }
}

/// 以往一次作答的笔迹（看答案后补写的用浅色标出）和 AI 批改
struct AttemptInkView: View {
    let attempt: any SubjectiveAttemptRecord
    let pack: StudyPack

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let data = attempt.inkData {
                InkSnapshotView(data: data, fadeAfter: attempt.revealedAt)
            } else if attempt.pastedImagesData == nil {
                Text("这次作答的笔迹还在页面上，或没有书写。").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(attempt.pastedImages) { img in
                if let ui = UIImage(data: img.data) {
                    let late = attempt.revealedAt.map { img.at >= $0 } ?? false
                    if late { Text("看答案后补贴").font(.caption).foregroundStyle(.orange) }
                    Image(uiImage: ui).resizable().scaledToFit().frame(maxHeight: 360)
                        .opacity(late ? 0.6 : 1)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                }
            }
            ForEach(attempt.gradings) { g in
                DisclosureGroup("AI 批改 · \(g.createdAt.formatted(date: .abbreviated, time: .shortened))") {
                    SubjectiveCard.gradingResult(g, pack: pack).padding(.top, 8)
                }
                .draftTappable()
            }
        }
    }
}

/// 存档的笔迹（PKDrawing 数据）渲染成图片；fadeAfter 之后落笔的（看答案后补写的）用浅色标出
struct InkSnapshotView: View {
    let data: Data
    let fadeAfter: Date?
    @State private var image: UIImage?
    @State private var faded = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxWidth: 820, maxHeight: 600)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                if faded > 0 {
                    Text("浅色的是看答案后补写的笔迹。").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear(perform: renderInk)
    }

    private func renderInk() {
        guard image == nil, let drawing = try? PKDrawing(data: data), !drawing.strokes.isEmpty else { return }
        var count = 0
        let strokes = drawing.strokes.map { s -> PKStroke in
            guard let fadeAfter, s.path.creationDate >= fadeAfter else { return s }
            count += 1
            var faded = s
            faded.ink = PKInk(s.ink.inkType, color: s.ink.color.withAlphaComponent(0.3))
            return faded
        }
        faded = count
        let d = PKDrawing(strokes: strokes)
        image = HandwritingExport.render(d, in: d.bounds.insetBy(dx: -16, dy: -16), scale: 1)
    }
}

/// 资料裁剪图：点击放大
struct OriginalPageImage: View {
    let url: URL
    let title: String
    @State private var zoomed = false

    var body: some View {
        if let image = FigureImageCache.image(at: url) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 820)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .onTapGesture { zoomed = true }
                .sheet(isPresented: $zoomed) {
                    NavigationStack {
                        ScrollView([.horizontal, .vertical]) {
                            Image(uiImage: image).resizable().scaledToFit()
                                .frame(width: max(image.size.width, 1000))
                                .background(.white)
                        }
                        .navigationTitle(title)
                        .toolbar { Button("完成") { zoomed = false } }
                    }
                }
        } else {
            Label("找不到资料图片：\(url.lastPathComponent)", systemImage: "photo.badge.exclamationmark")
                .foregroundStyle(.orange)
        }
    }
}
