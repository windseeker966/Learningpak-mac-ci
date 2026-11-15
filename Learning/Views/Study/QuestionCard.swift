import SwiftData
import SwiftUI

/// 一道题的完整作答流程：作答 → 标把握程度并提交 → 原书答案与解析 → 薄弱知识点与错误类型 → AI 讲评。
/// 学习页里做过的题保留第一次的作答，「重做这道题」在下方另开一张答题卡，结果记为重做记录。
struct QuestionCard: View {
    let pack: StudyPack
    let question: Question
    let mode: AttemptMode
    var roundNum: Int
    /// 学习页：这道题第一次学习作答之外的作答（重做、复习），按时间先后
    var redoRecords: [AttemptRecord]
    /// 学习页里展开的重做答题卡
    var isNestedRedo: Bool
    var onSubmitted: ((AttemptRecord) -> Void)?
    /// 传入时题目卡片底部显示「AI改编」
    var onAIVariant: (() -> Void)?
    /// 传入时在题目（和解析）下方显示书写区，重做、下一题按钮和书写区按钮排成一行
    var writing: WritingSpec?
    /// 学习页的重做答题卡没有自己的书写区，用宿主所在草稿页的书写区收集笔迹
    var inkPageKey: String?
    /// 复习原题时打乱选项（复习页、错题本重做页）
    var shuffleOptions: Bool
    /// 「单独窗口作答」：题目下方显示按钮，到单独窗口里作答；nil 时不显示
    var onDetach: (() -> Void)?
    var nextLabel: String
    var onNext: () -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.renderScale) private var renderScale
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: ChoiceAttemptSession
    /// 作答流程是外面传进来的（和单独窗口共用，见 DetachableQuestionCard）：离开时由外面调 leave
    private var ownsSession = true
    @State private var viewerID = UUID()
    @State private var onScreen = false
    /// 正在进行的一次重做（学习页）
    @State private var redoSession: UUID?
    /// 重做答题卡刚提交的记录：答题卡还展开时不在重做记录里重复显示
    @State private var activeRedoID: PersistentIdentifier?

    /// - Parameter existing: 这道题之前的作答。传入时直接展示当时的作答与解析，可「重新作答」
    init(pack: StudyPack, question: Question, mode: AttemptMode, roundNum: Int = 0,
         existing: AttemptRecord? = nil, redoRecords: [AttemptRecord] = [], isNestedRedo: Bool = false,
         onSubmitted: ((AttemptRecord) -> Void)? = nil, onAIVariant: (() -> Void)? = nil,
         writing: WritingSpec? = nil, inkPageKey: String? = nil, shuffleOptions: Bool = false,
         onDetach: (() -> Void)? = nil, session: ChoiceAttemptSession? = nil,
         nextLabel: String = "下一题", onNext: @escaping () -> Void) {
        self.pack = pack
        self.question = question
        self.mode = mode
        self.roundNum = roundNum
        self.redoRecords = redoRecords
        self.isNestedRedo = isNestedRedo
        self.onSubmitted = onSubmitted
        self.onAIVariant = onAIVariant
        self.writing = writing
        self.inkPageKey = inkPageKey
        self.shuffleOptions = shuffleOptions
        self.onDetach = onDetach
        self.nextLabel = nextLabel
        self.onNext = onNext
        ownsSession = session == nil
        _session = State(initialValue: session ?? Self.makeSession(
            pack: pack, question: question, mode: mode, roundNum: roundNum, existing: existing,
            isNestedRedo: isNestedRedo, writing: writing, inkPageKey: inkPageKey, shuffleOptions: shuffleOptions))
    }

    /// 这张卡片自己的作答流程；DetachableQuestionCard 用它建好主窗口和单独窗口共用的那个
    static func makeSession(pack: StudyPack, question: Question, mode: AttemptMode, roundNum: Int = 0,
                            existing: AttemptRecord? = nil, isNestedRedo: Bool = false, writing: WritingSpec? = nil,
                            inkPageKey: String? = nil, shuffleOptions: Bool = false) -> ChoiceAttemptSession {
        ChoiceAttemptSession(
            pack: pack, question: question, mode: mode, roundNum: roundNum, existing: existing,
            isNestedRedo: isNestedRedo,
            inkKey: inkKey(pack: pack, question: question, mode: mode, writing: writing, inkPageKey: inkPageKey),
            shuffleOptions: shuffleOptions)
    }

    private var q: Question { question }
    private var selection: Selection? { session.selection }
    private var result: GradeResult? { session.result }
    private var attempt: AttemptRecord? { session.attempt }
    private var optionOrder: OptionOrder { session.optionOrder }

    /// 作答笔迹所在的草稿页；AI 改编和没有书写区的页面不收集
    private static func inkKey(pack: StudyPack, question q: Question, mode: AttemptMode, writing: WritingSpec?,
                               inkPageKey: String?) -> String? {
        guard !mode.isAI else { return nil }
        guard let writing else { return inkPageKey }
        return writing.storage == .memory ? nil : writing.draftKey ?? DraftKey.question(pack: pack.id, questionID: q.id)
    }


    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card {
                header
                // 改编练习什么都不记，没有有错标记
                if mode != .aiPractice { QuestionFaultBanner(packID: pack.id, questionID: q.id, variant: mode.isAI) }
                SelectableText(attributed: RichText.plain(displayStem, style: .title3, unescape: true, scale: renderScale),
                               source: "题面", onAction: nil)
                ForEach(q.figures ?? [], id: \.self) { id in
                    if let f = pack.figures[id] { FigureView(pack: pack, figure: f) }
                }
                if q.type == .combo { statementsView }
                optionsView
                if result == nil { hintAndSubmit }
                if !mode.isAI {
                    QuestionToolsRow(packID: pack.id, questionID: q.id, onAIVariant: pack.allowsAIVariant ? onAIVariant : nil,
                                     aiAvailable: LLMConfig.hasAvailableProvider(.choiceVariant))
                } else if mode == .aiReview {
                    // 改编题不能再改编，只能标记有错
                    QuestionToolsRow(packID: pack.id, questionID: q.id, onAIVariant: nil,
                                     originalID: QuestionVariant.originalID(of: q.id))
                }
            }
            // 与主观题一致，单独窗口作答和下一题（提交后）放在题目下方靠右
            if onDetach != nil || result != nil {
                HStack(spacing: 12) {
                    Spacer()
                    if let onDetach {
                        Button("单独窗口作答", systemImage: "rectangle.split.1x2") { onDetach() }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .draftTappable()
                    }
                    if result != nil {
                        Button(nextLabel) { onNext() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .draftTappable()
                    }
                }
            }
            if let result { feedback(result) }
            if let writing {
                ChoiceWritingSection(pack: pack, sectionID: writing.sectionID, questionID: q.id,
                                     draftKey: writing.draftKey, storage: writing.storage,
                                     anchorName: writing.anchorName,
                                     accessory: result == nil ? nil : AnyView(actionButtons))
            } else if result != nil {
                HStack { actionButtons }
            }
            if hostsRedo && result != nil { redoArea }
        }
        .onAppear {
            onScreen = true
            session.load(in: context)
            updateClocks()
        }
        .onChange(of: scenePhase) {
            if scenePhase != .active { session.persist() }
            updateClocks()
        }
        .onChange(of: redoSession) { updateClocks() }
        .onDisappear {
            if ownsSession { session.leave() }
            session.persist()
            onScreen = false
            session.disappear(viewer: viewerID)
        }
        #if DEBUG
        // 调试：启动参数 -debugAnswer D -debugConfidence sure -debugErrorType confused,careless 模拟作答
        .onAppear {
            let d = UserDefaults.standard
            guard result == nil, let answer = d.string(forKey: "debugAnswer") else { return }
            session.choose(q.type == .multiBlank ? .blanks(answer.components(separatedBy: ",").map { Optional($0) })
                           : .option(answer))
            submit(confidence: ChoiceConfidence(rawValue: d.string(forKey: "debugConfidence") ?? "") ?? .sure)
            if let raw = d.string(forKey: "debugErrorType") {
                session.pendingErrorTypes = Set(raw.components(separatedBy: ",").compactMap(ErrorType.init(rawValue:)))
                session.errorNote = d.string(forKey: "debugErrorNote") ?? ""
                session.submitCause()
            }
        }
        #endif
    }

    // MARK: - 题面

    private var header: some View {
        HStack(spacing: 8) {
            Text("第 \(q.num) 题").font(.headline)
            if q.type == .multi || q.type == .judge {
                Text(q.type == .multi ? "多选题" : "判断题").font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.teal.opacity(0.12), in: Capsule()).foregroundStyle(.teal)
            }
            if let w = q.aiWritten {
                Text(w.label).font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.orange.opacity(0.15), in: Capsule()).foregroundStyle(.orange)
            }
            if q.aiAuthored {
                Label("AI 出题", systemImage: "sparkles").font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.purple.opacity(0.12), in: Capsule()).foregroundStyle(.purple)
            }
            Spacer()
            Text(pack.questionSource(page: q.page, requires: q.requires, aiAuthored: q.aiAuthored, source: q.source))
                .font(.caption).foregroundStyle(.secondary)
            if mode != .aiPractice { QuestionFaultBadge(packID: pack.id, questionID: q.id) }
        }
    }

    private static let circled = ["①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨", "⑩"]

    /// 多空题把（ ）依次编号，其余原样
    private var displayStem: String {
        guard q.type == .multiBlank else { return q.stem }
        var s = q.stem
        var i = 0
        while let r = s.range(of: "（ ）") {
            s.replaceSubrange(r, with: "（\(Self.circled[min(i, Self.circled.count - 1)])）")
            i += 1
        }
        return s
    }

    private var statementsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(q.statementKeys, id: \.self) { k in
                let st = q.statements?[k]
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Roman.glyph(k) + ".").bold().frame(width: 28, alignment: .leading)
                    MathText.text(st?.text ?? "", font: .preferredFont(forTextStyle: .body), scale: renderScale)
                    Spacer(minLength: 0)
                    if result != nil, let st {
                        Label(st.truth ? "正确" : "错误", systemImage: st.truth ? "checkmark" : "xmark")
                            .font(.caption.bold())
                            .foregroundStyle(st.truth ? .green : .red)
                    }
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var optionsView: some View {
        if q.type == .multiBlank {
            blanksView
        } else {
            VStack(spacing: 10) {
                ForEach(optionOrder.keys, id: \.self) { k in
                    optionRow(k)
                }
            }
        }
    }

    private func optionText(_ k: String) -> String {
        switch q.type {
        case .single, .multi, .judge: q.options?[k] ?? ""
        case .combo: (q.comboOptions?[k] ?? []).map(Roman.glyph).joined(separator: "、")
        case .multiBlank: q.sharedOptions?[k] ?? ""
        }
    }

    /// 已选的选项：多选题可以有多个
    private var picked: Set<String> {
        guard case .option(let s) = selection else { return [] }
        return q.type == .multi ? Set(s.map(String.init)) : [s]
    }

    private func isAnswer(_ k: String) -> Bool {
        q.type == .multi ? q.answerSet.contains(k) : k == q.answer
    }

    private func optionRow(_ k: String) -> some View {
        let chosen = picked.contains(k)
        let multi = q.type == .multi
        var tint: Color = chosen ? .accentColor : .secondary
        var icon = multi ? (chosen ? "checkmark.square.fill" : "square") : (chosen ? "largecircle.fill.circle" : "circle")
        // 多选题漏选的正确选项用橙色，和选对的绿色区分
        let missed = result != nil && multi && !chosen && isAnswer(k)
        if result != nil {
            if missed { tint = .orange; icon = "exclamationmark.square.fill" }
            else if isAnswer(k) { tint = .green; icon = multi ? "checkmark.square.fill" : "checkmark.circle.fill" }
            else if chosen { tint = .red; icon = multi ? "xmark.square.fill" : "xmark.circle.fill" }
            else { tint = .secondary }
        }
        return Button {
            guard result == nil else { return }
            if multi {
                // 多选：点一下勾选或取消，按字母序存
                var keys = picked
                if keys.contains(k) { keys.remove(k) } else { keys.insert(k) }
                session.choose(.option(keys.sorted().joined()))
            } else {
                session.choose(.option(k))
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: icon).foregroundStyle(tint)
                // 判断题只显示「正确」「错误」
                if q.type != .judge { Text("\(optionOrder.label(of: k)).").bold() }
                MathText.text(optionText(k), font: .preferredFont(forTextStyle: .body), scale: renderScale)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if missed { Text("漏选").font(.caption.bold()).foregroundStyle(.orange) }
                // 打乱过选项：答后标出原题字母，对照解析
                if result != nil, optionOrder.isShuffled {
                    Text("原 \(k)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.body)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(chosen || (result != nil && isAnswer(k)) ? 0.12 : 0.04),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(chosen ? 0.6 : 0.2)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .draftTappable(result == nil)
    }

    private var blankPicks: [String?] {
        if case .blanks(let b) = selection { return b }
        return Array(repeating: nil, count: q.blanks?.count ?? 0)
    }

    private var blanksView: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(q.optionKeys, id: \.self) { k in
                    MathText.text("\(k). \(optionText(k))", font: .preferredFont(forTextStyle: .body), scale: renderScale)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(Array((q.blanks ?? []).enumerated()), id: \.offset) { i, blank in
                HStack(spacing: 10) {
                    Text("第\(Self.circled[min(i, Self.circled.count - 1)])空").frame(width: 60, alignment: .leading)
                    ForEach(q.optionKeys, id: \.self) { k in
                        blankButton(index: i, key: k, answer: blank.answer)
                    }
                    if result != nil, i < (result?.blankResults.count ?? 0) {
                        Image(systemName: result!.blankResults[i] ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result!.blankResults[i] ? .green : .red)
                    }
                }
            }
        }
    }

    private func blankButton(index i: Int, key k: String, answer: String) -> some View {
        let picked = blankPicks[i] == k
        var tint: Color = picked ? .accentColor : .secondary
        if result != nil {
            tint = k == answer ? .green : (picked ? .red : .secondary)
        }
        return Button {
            guard result == nil else { return }
            var picks = blankPicks
            picks[i] = k
            session.choose(.blanks(picks))
        } label: {
            Text(k).bold().frame(width: 44, height: 36)
                .background(tint.opacity(picked || (result != nil && k == answer) ? 0.18 : 0.05),
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.5)))
        }
        .buttonStyle(.plain)
        .draftTappable(result == nil)
    }


    // MARK: - 提示与提交

    private var hintAndSubmit: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let hint = q.hint {
                if session.hintShown {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            MathText.text(hint, font: .preferredFont(forTextStyle: .body), scale: renderScale)
                            if optionOrder.isShuffled, OptionOrder.mentionsLetters(hint) {
                                Text("选项已打乱，提示里的字母是原书的字母").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "lightbulb")
                    }
                    .foregroundStyle(.orange)
                } else {
                    Button("看提示", systemImage: "lightbulb") { session.showHint() }
                        .buttonStyle(.borderless)
                        .draftTappable()
                }
            }
            Divider()
            HStack(spacing: 12) {
                Text("提交，并标记把握程度：").foregroundStyle(.secondary)
                Spacer()
                submitButton(.sure, .green)
                submitButton(.unsure, .orange)
                submitButton(.guess, .gray)
            }
        }
    }

    private func submitButton(_ confidence: ChoiceConfidence, _ color: Color) -> some View {
        Button(confidence.label) { submit(confidence: confidence) }
            .buttonStyle(.borderedProminent)
            .tint(color)
            .controlSize(.large)
            .disabled(!(selection?.isComplete ?? false))
            .draftTappable()
    }

    /// 计时只在 App 在前台、题目在屏幕上时进行；学习页展开重做答题卡时，本卡的答后时间暂停
    private func updateClocks() {
        session.setActive(onScreen && scenePhase == .active, redoOpen: redoSession != nil, viewer: viewerID)
    }

    private func submit(confidence: ChoiceConfidence) {
        // 不加动画：解析、错因等卡片一起出现时，整页跟着动画抖动
        if let record = session.submit(confidence: confidence) { onSubmitted?(record) }
    }

    // MARK: - 答后反馈

    // MARK: - 答后反馈

    @ViewBuilder
    private func feedback(_ r: GradeResult) -> some View {
        Card {
            resultBanner(r)
            VStack(alignment: .leading, spacing: 8) {
                Text(q.aiAuthored
                     ? "解析（AI 编写，依据\(pack.sourceLabel)第 \(pageText(q.explanationPage)) 页）"
                     : q.aiWritten != nil ? "解析（AI 编写）"
                     : q.explanationPage.isEmpty ? "解析"
                     : "\(pack.sourceLabel)解析（第 \(pageText(q.explanationPage)) 页）").font(.headline)
                if optionOrder.isShuffled, OptionOrder.mentionsLetters(q.explanation) {
                    Text("解析里的选项字母是原书的字母，见各选项右侧的「原 X」").font(.caption).foregroundStyle(.secondary)
                }
                MarkdownView(text: q.explanation, pack: pack)
            }
            if let adds = q.explanationAdds, !adds.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("解析里出现的新知识").font(.subheadline.bold()).foregroundStyle(.secondary)
                    ForEach(adds, id: \.self) { added in
                        Label {
                            MathText.text(added, font: .preferredFont(forTextStyle: .callout), scale: renderScale)
                        } icon: {
                            Image(systemName: "plus.circle")
                        }
                        .font(.callout)
                    }
                }
            }
        }
        if mode != .aiPractice, !r.isCorrect || attempt.map({ $0.confidence != ChoiceConfidence.sure.rawValue }) == true { causePicker(r) }
        if !mode.isAI, attempt != nil {
            QuestionMarkControls(packID: pack.id, questionID: q.id)
        }
        Card {
            HStack {
                Text("AI 讲评").font(.headline)
                Spacer()
                if !session.showReview {
                    Button("请 AI 讲评这道题", systemImage: "sparkles") { session.runReview() }
                        .buttonStyle(.bordered)
                        .draftTappable()
                }
            }
            if session.showReview {
                ChatThreadView(session: session.review, placeholder: "对这道题还有疑问？继续问（也可以划选讲评中的文字）",
                               showsInput: !session.review.messages.isEmpty, pack: pack)
            }
            if let reviewSaveError = session.reviewSaveError {
                Label(reviewSaveError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
    }

    /// 重做 / 重新作答；有书写区时接在书写区按钮后面（下一题在题目下方）
    @ViewBuilder
    private var actionButtons: some View {
        if hostsRedo {
            // 学习页：保留第一次的作答，在下方另开一张答题卡
            Button("重做这道题", systemImage: "arrow.counterclockwise") {
                // 之后写下的笔迹属于重做
                session.handOffInkToRedo()
                activeRedoID = nil
                redoSession = UUID()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .draftTappable()
        } else if !isNestedRedo {
            Button("重新作答", systemImage: "arrow.counterclockwise") { session.resetForRetry() }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .draftTappable()
        }
    }

    // MARK: - 重做记录（学习页）

    /// 学习页的题目卡片：第一次作答保持不变，重做记在下方
    private var hostsRedo: Bool { mode == .learn && !isNestedRedo }

    @ViewBuilder
    private var redoArea: some View {
        let shown = redoRecords.filter { redoSession == nil || $0.persistentModelID != activeRedoID }
        if !shown.isEmpty {
            Card {
                Text("重做记录").font(.headline)
                ForEach(Array(shown.enumerated()), id: \.element.persistentModelID) { i, a in
                    if i > 0 { Divider() }
                    redoRow(index: i + 1, a)
                }
            }
        }
        if let id = redoSession {
            VStack(alignment: .leading, spacing: 12) {
                Label("第 \(shown.count + 1) 次重做", systemImage: "arrow.counterclockwise")
                    .font(.headline)
                    .foregroundStyle(.tint)
                QuestionCard(pack: pack, question: q, mode: .redo, roundNum: roundNum, isNestedRedo: true,
                             onSubmitted: { activeRedoID = $0.persistentModelID },
                             inkPageKey: session.inkKey,
                             nextLabel: "完成重做") {
                    redoSession = nil
                    activeRedoID = nil
                }
            }
            .id(id)
        }
    }

    private func redoRow(index: Int, _ a: AttemptRecord) -> some View {
        let kind = a.mode == AttemptMode.review.rawValue ? "复习" : "重做"
        let picked = a.selection.replacingOccurrences(of: ",", with: "、")
        var details = [a.createdAt.formatted(date: .abbreviated, time: .shortened)]
        if a.isImmediateRedo {
            details.append("看答案后 \(Int((a.sinceAnswerSeen ?? 0) / 60)) 分钟内重做，不计入掌握")
        }
        if let cause = a.causeLine(pack.pointTitle) {
            details.append(a.isCorrect ? "没把握：\(cause)" : cause)
        }
        if !a.isCorrect && !a.weakPoints.isEmpty {
            details.append("暴露：" + a.weakPoints.map(pack.pointTitle).joined(separator: "、"))
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: a.isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(a.isCorrect ? .green : .red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("第 \(index) 次\(kind) · 选 \(picked) · \(a.isCorrect ? "正确" : "错误") · \(confidenceLabel(a.confidence))")
                    Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Self.attemptExtras(a, pack: pack)
        }
    }

    /// 一次作答的订正笔记、当时的草稿和 AI 讲评（重做记录、错题本里用）
    @ViewBuilder
    static func attemptExtras(_ a: AttemptRecord, pack: StudyPack) -> some View {
        if let note = a.correctionNote, !note.isEmpty {
            Label(note, systemImage: "square.and.pencil").font(.callout)
        }
        CorrectionHistoryView(entries: a.correctionHistory)
        if let data = a.inkData {
            DisclosureGroup("当时的草稿（提交前 \(a.inkStrokesBefore) 笔\(a.inkStrokesAfter > 0 ? "，看答案后 \(a.inkStrokesAfter) 笔" : "")）") {
                InkSnapshotView(data: data, fadeAfter: a.createdAt).padding(.top, 8)
            }
            .draftTappable()
        }
        if let data = a.reviewConversationData,
           let saved = try? JSONDecoder().decode(SavedConversation.self, from: data) {
            DisclosureGroup("AI 讲评") {
                SavedChatThreadView(conversation: saved, pack: pack).padding(.top, 8)
            }
            .draftTappable()
        }
    }


    private func resultBanner(_ r: GradeResult) -> some View {
        // 打乱过选项时按这次显示的字母，字母变了的注明原书字母
        let shown = q.type == .multi ? optionOrder.labels(of: q.answerSet).joined(separator: "、")
            : optionOrder.label(of: q.answer ?? "")
        let answerText = shown == q.answerText ? q.answerText : "\(shown)（原书 \(q.answerText)）"
        return HStack(spacing: 10) {
            Image(systemName: r.isCorrect ? "checkmark.seal.fill" : "xmark.octagon.fill")
                .font(.title)
                .foregroundStyle(r.isCorrect ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.isCorrect ? "回答正确" : "回答错误").font(.title3.bold())
                Text("正确答案：\(answerText)").foregroundStyle(.secondary)
                if let a = attempt {
                    Group {
                        if let restoredAt = session.restoredAt {
                            Text("上次作答：\(restoredAt.formatted(date: .abbreviated, time: .shortened)) · 把握：\(confidenceLabel(a.confidence)) · 用时 \(Int(a.durationSeconds)) 秒")
                        } else {
                            Text("把握：\(confidenceLabel(a.confidence)) · 用时 \(Int(a.durationSeconds)) 秒")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func causePicker(_ r: GradeResult) -> some View {
        Card {
            if !r.weakPoints.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("这道题暴露的知识点").font(.headline)
                    Text("根据你选的选项推算，会计入知识点掌握度。").font(.caption).foregroundStyle(.secondary)
                    ForEach(r.weakPoints, id: \.self) { id in
                        Label(pack.pointTitle(id), systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                    }
                }
                Divider()
            }
            if !session.errorTypes.isEmpty, !session.editingCause {
                submittedCause(r)
            } else {
                causeForm(r)
            }
        }
    }

    private func submittedCause(_ r: GradeResult) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(r.isCorrect ? "没把握的原因" : "错误原因")：\(session.errorTypes.map(\.label).joined(separator: "、"))")
                        .font(.headline)
                    if session.errorTypes.contains(.confused) && !session.confusedPoints.isEmpty {
                        Text("混淆：" + session.confusedPoints.map(pack.pointTitle).joined(separator: " ↔ "))
                            .foregroundStyle(.secondary)
                    }
                    let note = session.errorNote.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !note.isEmpty { Text(note).foregroundStyle(.secondary) }
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Spacer()
            Button("修改") { session.beginEditingCause() }
            .buttonStyle(.borderless)
            .draftTappable()
        }
    }

    @ViewBuilder
    private func causeForm(_ r: GradeResult) -> some View {
        Text(r.isCorrect ? "答对了，但哪里没把握？（选填）" : "这道题错在哪？").font(.headline)
        Text(r.isCorrect ? "可多选，也可以写下具体哪里拿不准，然后提交。" : "可多选，也可以写下具体原因，然后提交。")
            .font(.caption).foregroundStyle(.secondary)
        VStack(spacing: 8) {
            ForEach(r.isCorrect ? ErrorType.unsureOptions : ErrorType.ordered(negative: r.negative), id: \.self) {
                errorTypeButton($0)
            }
        }
        if session.pendingErrorTypes.contains(.confused) {
            confusionPicker(r)
        }
        TextField(session.pendingErrorTypes.contains(.other) ? "写下原因（必填）" : "写下具体原因（选填）",
                  text: Bindable(session).errorNote, axis: .vertical)
            .lineLimit(2...5)
            .padding(12)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            .draftTappable()
        HStack {
            if session.editingCause {
                Button("取消") { session.cancelEditingCause() }
                .buttonStyle(.borderless)
                .draftTappable()
            }
            Spacer()
            Button("提交错误原因") { session.submitCause() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!session.canSubmitCause)
                .draftTappable()
        }
    }

    /// 「混淆」可能涉及的知识点：所选选项暴露的在前，再是本题考查的和其他选项、陈述、空标注的
    private func confusionCandidates(_ r: GradeResult) -> [String] {
        var ids = r.weakPoints + q.testedPoints
        ids += q.optionKeys.flatMap { q.distractors?[$0] ?? [] }
        ids += q.statementKeys.flatMap { q.statements?[$0]?.ifMisjudged ?? [] }
        ids += (q.blanks ?? []).flatMap { $0.ifWrong ?? [] }
        ids += q.ifMissed ?? []
        var seen = Set<String>()
        return ids.filter { pack.knowledgePoints[$0] != nil && seen.insert($0).inserted }
    }

    @ViewBuilder
    private func confusionPicker(_ r: GradeResult) -> some View {
        let candidates = confusionCandidates(r)
        if !candidates.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("把哪些知识点弄混了？（可多选，选填）").font(.subheadline.bold())
                ForEach(candidates, id: \.self) { id in
                    let picked = session.pendingConfused.contains(id)
                    Button {
                        session.toggleConfused(id)
                    } label: {
                        Label(pack.pointTitle(id), systemImage: picked ? "checkmark.square.fill" : "square")
                            .foregroundStyle(picked ? Color.accentColor : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .draftTappable()
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func errorTypeButton(_ type: ErrorType) -> some View {
        let picked = session.pendingErrorTypes.contains(type)
        return Button {
            session.toggleErrorType(type)
        } label: {
            HStack {
                Image(systemName: picked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(picked ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(type.label)
                    Text(type.detail).font(.caption).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background((picked ? Color.accentColor : .secondary).opacity(picked ? 0.12 : 0.05),
                        in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .draftTappable()
    }
}
