import SwiftData
import SwiftUI

/// 分析页第一层：按书列出，点进一本书看它的统计
struct AnalysisView: View {
    @Environment(PackStore.self) private var store
    @Environment(\.modelContext) private var context
    /// 每本书的作答次数、涉及题数、答对次数；页面出现时统计（不用 @Query，见 Notification.insertsOrDeletes）
    @State private var stats: [String: (count: Int, questions: Int, correct: Int)] = [:]
    /// 调试：-debugAnalysisPack <book.id> 直接打开这本书的分析
    @State private var debugPack = UserDefaults.standard.string(forKey: "debugAnalysisPack")

    var body: some View {
        NavigationStack {
            List {
                if store.packs.isEmpty {
                    Text("还没有教辅包。").foregroundStyle(.secondary)
                }
                ForEach(store.packs) { pack in
                    NavigationLink {
                        BookAnalysisView(pack: pack)
                    } label: {
                        bookRow(pack)
                    }
                }
            }
            .navigationTitle("分析")
            .onAppear(perform: refreshStats)
            .onChange(of: store.packs.map(\.id)) { refreshStats() }
            .navigationDestination(isPresented: Binding(get: { debugPack.flatMap(store.pack) != nil },
                                                        set: { if !$0 { debugPack = nil } })) {
                if let pack = debugPack.flatMap(store.pack) { BookAnalysisView(pack: pack) }
            }
        }
    }

    private func refreshStats() {
        let attempts = (try? context.fetch(FetchDescriptor<AttemptRecord>())) ?? []
        var out: [String: (count: Int, questions: Int, correct: Int)] = [:]
        for pack in store.packs {
            let list = attempts.filter { $0.packID == pack.id && pack.questions[$0.questionID] != nil }
            out[pack.id] = (list.count, Set(list.map(\.questionID)).count, list.filter(\.isCorrect).count)
        }
        stats = out
    }

    private func bookRow(_ pack: StudyPack) -> some View {
        let s = stats[pack.id] ?? (0, 0, 0)
        return HStack(spacing: 16) {
            Image(systemName: "chart.bar.xaxis").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(pack.title).font(.body.bold())
                Text(s.count == 0 ? "还没有作答记录" : "作答 \(s.count) 次 · 涉及 \(s.questions) 题")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if s.count > 0 {
                Text("正确率 \(Int(Double(s.correct) / Double(s.count) * 100))%")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

/// 一本书的分析：正确率、把握程度、知识点掌握度、错误类型、错题本
struct BookAnalysisView: View {
    let pack: StudyPack
    @Environment(PackStore.self) private var store
    /// 作答、改编题作答（新的在前）和题目标记。不用 @Query：分析页留在后台时，@Query 会在学习页每次保存后重新取全部记录、
    /// 重算整页统计（见 Notification.insertsOrDeletes）。这里只在这几类记录有增删时重新取；已有记录的字段变化照常刷新
    @State private var attempts: [AttemptRecord] = []
    @State private var allSubjective: [SubjectiveAttempt] = []
    @State private var allVariants: [VariantAttempt] = []
    @State private var allMarks: [QuestionMark] = []
    @Environment(\.modelContext) private var context
    @State private var filter = WrongFilter.unresolved
    /// 知识点、错题本在分析页上直接列出的条数，其余点「查看全部」
    static let previewLimit = 8

    enum WrongFilter: String, CaseIterable {
        case unresolved = "未订正"
        case all = "全部错题"
        case starred = "重点"
        case confidentWrong = "确定却答错"
        case luckyRight = "蒙对 / 犹豫答对"
        case faulty = "标记有错"
    }

    /// 只统计本书中仍存在的题（AI 改编复习的变式题不在书里，不计入）
    /// 标记了题目有错的题：统计、错题本都不再使用（错题本的「标记有错」里可以找到）
    private var faultyIDs: Set<String> {
        Set(allMarks.filter { $0.packID == pack.id && $0.faultyAt != nil }.map(\.questionID))
    }

    private var valid: [AttemptRecord] { choiceAttempts(faulty: false) }
    private var subjective: [SubjectiveAttempt] { subjectiveAttempts(faulty: false) }
    private var variants: [VariantAttempt] { variantAttempts(faulty: false) }

    /// faulty：只要标记有错的题（true）或只要没标记的（false）
    private func choiceAttempts(faulty: Bool) -> [AttemptRecord] {
        let ids = faultyIDs
        return attempts.filter {
            $0.packID == pack.id && pack.questions[$0.questionID] != nil && ids.contains($0.questionID) == faulty
        }
    }

    /// 本书已自评的主观题作答（新 → 旧）
    private func subjectiveAttempts(faulty: Bool) -> [SubjectiveAttempt] {
        let ids = faultyIDs
        return allSubjective.filter {
            $0.packID == pack.id && $0.assessedAt != nil && pack.subjective[$0.questionID] != nil
                && ids.contains($0.questionID) == faulty
        }
    }

    /// 本书已自评的改编题作答（练习不算；含改编题本身标记有错的，用 isFaulty 区分）
    private func variantAttempts(faulty: Bool) -> [VariantAttempt] {
        let ids = faultyIDs
        return allVariants.filter {
            $0.packID == pack.id && $0.isAssessed && !$0.practice && ids.contains($0.originalID) == faulty
        }
    }

    var body: some View {
        List {
            if valid.isEmpty && subjective.isEmpty && variants.isEmpty {
                Text("还没有作答记录。学完一轮后，这里会显示正确率、知识点掌握度和错误类型分布。")
                    .foregroundStyle(.secondary)
            } else {
                if !valid.isEmpty || !subjective.isEmpty { overview }
                if !valid.isEmpty { confidenceMatrix }
                knowledgePointMastery
                errorCategoryDistribution
                if !valid.isEmpty { errorTypeDistribution }
                if !valid.isEmpty || !subjective.isEmpty { wrongQuestions }
                if !subjective.isEmpty { subjectiveSection }
                if !variants.isEmpty { variantSection }
            }
        }
        .navigationTitle(pack.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadRecords)
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { note in
            if note.insertsOrDeletes([AttemptRecord.self, SubjectiveAttempt.self, VariantAttempt.self, QuestionMark.self]) {
                loadRecords()
            }
        }
    }

    private func loadRecords() {
        attempts = (try? context.fetch(FetchDescriptor<AttemptRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
        allSubjective = (try? context.fetch(FetchDescriptor<SubjectiveAttempt>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
        allVariants = (try? context.fetch(FetchDescriptor<VariantAttempt>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
        allMarks = (try? context.fetch(FetchDescriptor<QuestionMark>())) ?? []
    }

    // MARK: - 概览

    /// 一种题型的概览：第一次作答和之后复习（含 AI 改编题，不算看答案后不久的重做）分开算正确率
    private struct OverviewStats {
        var attempts = 0
        var questions = 0
        var firstCorrect = 0
        var reviews = 0
        var reviewCorrect = 0
        var firstDurations: [Double] = []
    }

    /// items：(题目 id, 时间, 对不对, 是不是看答案后不久的重做, 用时)；variants：改编题的 (对不对, 是不是立即重做)
    private func overviewStats(_ items: [(id: String, at: Date, correct: Bool, immediate: Bool, duration: Double?)],
                               variants: [(correct: Bool, immediate: Bool)]) -> OverviewStats {
        var stats = OverviewStats()
        var seen = Set<String>()
        for a in items.sorted(by: { $0.at < $1.at }) {
            if seen.insert(a.id).inserted {
                if a.correct { stats.firstCorrect += 1 }
                if let d = a.duration, d > 0 { stats.firstDurations.append(d) }
            } else if !a.immediate {
                stats.reviews += 1
                if a.correct { stats.reviewCorrect += 1 }
            }
        }
        for v in variants where !v.immediate {
            stats.reviews += 1
            if v.correct { stats.reviewCorrect += 1 }
        }
        stats.attempts = items.count + variants.count
        stats.questions = seen.count
        return stats
    }

    private func percent(_ n: Int, _ total: Int) -> String {
        total == 0 ? "–" : "\(Int((Double(n) / Double(total) * 100).rounded()))%"
    }

    private func overviewRow(_ title: String, _ st: OverviewStats, durations: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.bold()).foregroundStyle(.secondary)
            HStack(spacing: 32) {
                stat("作答次数", "\(st.attempts)")
                stat("涉及题目", "\(st.questions)")
                stat("首次正确率", percent(st.firstCorrect, st.questions))
                stat("复习正确率（\(st.reviews) 次）", percent(st.reviewCorrect, st.reviews))
                if durations {
                    stat("首次平均用时", st.firstDurations.isEmpty ? "–"
                         : "\(Int((st.firstDurations.reduce(0, +) / Double(st.firstDurations.count)).rounded())) 秒")
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var overview: some View {
        let faulty = faultyIDs
        let counted = variants.filter { !$0.isFaulty(faulty) }
        let choice = overviewStats(valid.map { ($0.questionID, $0.createdAt, $0.isCorrect, $0.isImmediateRedo, $0.durationSeconds) },
                                   variants: counted.filter { $0.kind == "choice" }.map { ($0.isCorrect, $0.isImmediate) })
        let subj = overviewStats(subjective.map { ($0.questionID, $0.revealedAt ?? $0.createdAt, $0.resultValue == .correct,
                                                   $0.isImmediateRedo, nil) },
                                 variants: counted.filter { $0.kind != "choice" }.map { ($0.isCorrect, $0.isImmediate) })
        return Section {
            if !valid.isEmpty { overviewRow("选择题", choice, durations: true) }
            if !subjective.isEmpty { overviewRow("主观题（按自评）", subj, durations: false) }
        } header: {
            Text("概览")
        } footer: {
            Text("「首次正确率」按每道题第一次作答算。「复习正确率」算之后的每次作答，包括 AI 改编题（改编题标记有错的不算），不算看答案后 1 小时内的重做。作答次数包括这些重做和改编题。")
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.bold().monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - 把握程度 × 对错

    private var confidenceMatrix: some View {
        func count(_ sure: Bool, _ correct: Bool) -> Int {
            valid.filter { ($0.confidence == ChoiceConfidence.sure.rawValue) == sure && $0.isCorrect == correct }.count
        }
        return Section {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow {
                    Text("")
                    Text("答对").bold()
                    Text("答错").bold()
                }
                GridRow {
                    Text("确定").bold()
                    matrixCell(count(true, true), "真正掌握", .green)
                    matrixCell(count(true, false), "确定却答错，优先处理", .red)
                }
                GridRow {
                    Text("犹豫 / 蒙的").bold()
                    matrixCell(count(false, true), "隐藏的薄弱点", .orange)
                    matrixCell(count(false, false), "尚未学会", .secondary)
                }
            }
            .padding(.vertical, 6)
        } header: {
            Text("把握程度 × 对错")
        }
    }

    private func matrixCell(_ n: Int, _ note: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(n)").font(.title3.bold().monospacedDigit()).foregroundStyle(color)
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - 知识点掌握度

    struct PointStat: Identifiable {
        let pack: StudyPack
        let point: KnowledgePoint
        let stat: Mastery.Stat
        var id: String { "\(pack.id)|\(point.id)" }
        var evidence: [Mastery.Evidence] { stat.evidence }
        var mastery: Double { stat.mastery }
        var questionCount: Int { stat.questionCount }
        var wrongCount: Int { stat.wrongCount }
    }

    /// 规则见 Mastery
    private var pointStats: [PointStat] {
        let choice = valid.compactMap { a -> Mastery.ChoiceAnswer? in
            guard let q = pack.questions[a.questionID] else { return nil }
            return .init(questionID: a.questionID, isCorrect: a.isCorrect, confidence: .init(stored: a.confidence),
                         weakPoints: a.weakPoints, isImmediateRedo: a.isImmediateRedo, mainPoint: q.tests,
                         testedPoints: q.testedPoints)
        }
        let items = pack.subjective.values.filter { $0.deprecated != true }.map { q in
            Mastery.SubjectiveItem(questionID: q.id,
                                   parts: q.effectiveParts.map { ($0.label, q.testedPoints(of: $0)) })
        }
        let answers = subjective.map { a in
            Mastery.SubjectiveAnswer(questionID: a.questionID, confidence: .init(stored: a.confidence),
                                     isImmediateRedo: a.isImmediateRedo, results: a.resultsByPart)
        }
        let faulty = faultyIDs
        let tried = variants.map { v in
            Mastery.VariantAnswer(originalID: v.originalID, flagged: v.isFaulty(faulty), score: v.resultValue?.score,
                                  confidence: .init(stored: v.confidence),
                                  testedPoints: pack.questions[v.originalID]?.testedPoints
                                      ?? pack.subjective[v.originalID]?.testedPoints ?? [])
        }
        return Mastery.stats(choice: choice, subjectiveItems: items, subjective: answers, variants: tried,
                             knownPoints: Set(pack.knowledgePoints.keys))
            .compactMap { s in pack.knowledgePoints[s.pointID].map { PointStat(pack: pack, point: $0, stat: s) } }
    }

    private var knowledgePointMastery: some View {
        let list = pointStats
        return Section {
            if list.isEmpty {
                Text("暂无：题目还没有标注知识点。").foregroundStyle(.secondary)
            }
            ForEach(list.prefix(Self.previewLimit)) { masteryRow($0) }
            if list.count > Self.previewLimit {
                NavigationLink {
                    List { ForEach(list) { masteryRow($0) } }
                        .navigationTitle("知识点掌握度")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Text("查看全部 \(list.count) 个知识点").foregroundStyle(.tint)
                }
            }
        } header: {
            Text("知识点掌握度")
        } footer: {
            Text("按每道题最近一次作答计算，主考权重高于兼考。确定答对算掌握，犹豫或蒙对打折扣；选择题答错时只计入选项暴露出的知识点。主观题按每一问最近一次自评计入，部分对算一半；AI 改编题按原题最近一次改编题的结果计入（改编题标记有错的不算）。看答案后不久的重做不算。薄弱的排在前面。")
        }
    }

    private func masteryRow(_ s: PointStat) -> some View {
        NavigationLink {
            KnowledgePointDetailView(pack: s.pack, point: s.point, evidence: s.evidence, variants: variants,
                                     faultyIDs: faultyIDs)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(s.point.title).font(.body.bold())
                    Spacer()
                    masteryBadge(s.mastery)
                }
                ProgressView(value: s.mastery).tint(masteryColor(s.mastery))
                HStack(spacing: 12) {
                    Text("\(s.point.introducedIn) 节")
                    Text("做过 \(s.questionCount) 道题")
                    if s.wrongCount > 0 { Text("最近答错 \(s.wrongCount) 道").foregroundStyle(.red) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    private func masteryColor(_ m: Double) -> Color {
        m < 0.5 ? .red : (m < 0.8 ? .orange : .green)
    }

    private func masteryBadge(_ m: Double) -> some View {
        let text = m < 0.5 ? "薄弱" : (m < 0.8 ? "一般" : "掌握")
        return Text("\(text) \(Int(m * 100))%")
            .font(.caption.bold().monospacedDigit())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(masteryColor(m).opacity(0.15), in: Capsule())
            .foregroundStyle(masteryColor(m))
    }

    // MARK: - 错误类型分布

    /// 选择题、主观题合并，按错误大类统计
    @ViewBuilder
    private var errorCategoryDistribution: some View {
        let wrong = valid.filter { !$0.isCorrect }
        let notCorrect = subjective.filter { $0.resultValue != .correct }
        let total = wrong.count + notCorrect.count
        if total > 0 {
            Section {
                ForEach(ErrorCategory.allCases, id: \.self) { c in
                    let n = wrong.filter { $0.causeTypes.contains { $0.category == c } }.count
                        + notCorrect.filter { a in
                            a.errorTypes.contains { SubjectiveErrorType(rawValue: $0)?.category == c }
                        }.count
                    causeRow(c.label, n, total, .red)
                }
                causeRow("未选择", wrong.filter { $0.causeTypes.isEmpty }.count
                         + notCorrect.filter { $0.errorTypes.isEmpty }.count, total, .secondary)
            } header: {
                Text("错误大类（选择题 + 主观题，共 \(total) 次没做对）")
            } footer: {
                Text("两类题的细分错误类型归入同一组大类后合并统计；错误类型可多选，一次作答可能涉及多个大类。"
                     + ErrorCategory.allCases.map { "\($0.label)：\($0.members)" }.joined(separator: "；") + "。")
            }
        }
    }

    private var errorTypeDistribution: some View {
        let wrong = valid.filter { !$0.isCorrect }
        return Section {
            ForEach(ErrorType.allCases, id: \.self) { t in
                let n = wrong.filter { $0.causeTypes.contains(t) }.count
                // 「蒙的」不再供选择，只在旧记录里有时显示
                if t != .guessed || n > 0 { causeRow(t.label, n, wrong.count, .red) }
            }
            causeRow("未选择", wrong.filter { $0.causeTypes.isEmpty }.count, wrong.count, .secondary)
        } header: {
            Text("选择题错误类型（共 \(wrong.count) 次答错，可多选）")
        } footer: {
            Text("答错后你自评的错误类型。答对但没把握时填的原因不计入。")
        }
    }

    private func causeRow(_ title: String, _ n: Int, _ total: Int, _ color: Color) -> some View {
        HStack {
            Text(title).frame(width: 120, alignment: .leading)
            ProgressView(value: Double(n), total: Double(max(total, 1))).tint(color)
            Text("\(n)").monospacedDigit().frame(width: 36, alignment: .trailing)
        }
    }

    // MARK: - 主观题

    private var subjectiveSection: some View {
        // 每道题最近一次（不算立即重做）的自评
        var latest: [String: SubjectiveAttempt] = [:]
        for a in subjective where !a.isImmediateRedo && latest[a.questionID] == nil { latest[a.questionID] = a }
        let notCorrect = subjective.filter { $0.resultValue != .correct }
        let disagreements = subjective.filter { !$0.aiDisagreements.isEmpty }.count
        let compared = subjective.filter(\.aiCompared).count
        return Group {
            Section {
                HStack(spacing: 32) {
                    stat("自评次数", "\(subjective.count)")
                    stat("涉及题目", "\(latest.count)")
                    stat("最近一次做对", "\(latest.values.filter { $0.resultValue == .correct }.count)")
                    stat("与 AI 不一致", compared == 0 ? "–" : "\(disagreements) / \(compared)")
                }
                .padding(.vertical, 6)
                ForEach([PartResult.correct, .partial, .wrong, .blank], id: \.self) { r in
                    causeRow(r.label, latest.values.filter { $0.resultValue == r }.count, latest.count, SubjectiveCard.color(r))
                }
            } header: {
                Text("主观题")
            } footer: {
                Text("按每道题最近一次自评统计（看答案后不久的重做不算）。「与 AI 不一致」：自评时有 AI 批改可对照的作答中，至少一问与 AI 结论不同的次数。")
            }
            if !notCorrect.isEmpty {
                Section {
                    ForEach(SubjectiveErrorType.allCases, id: \.self) { t in
                        causeRow(t.label, notCorrect.filter { $0.errorTypes.contains(t.rawValue) }.count, notCorrect.count, .red)
                    }
                    causeRow("未选择", notCorrect.filter { $0.errorTypes.isEmpty }.count, notCorrect.count, .secondary)
                } header: {
                    Text("主观题错误类型（共 \(notCorrect.count) 次没做对，可多选）")
                }
            }
        }
    }

    // MARK: - AI 改编题

    private var variantSection: some View {
        let faulty = faultyIDs
        let counted = variants.filter { !$0.isFaulty(faulty) }
        let correct = counted.filter { $0.resultValue == .correct }.count
        let originals = Set(counted.map(\.originalID)).count
        return Section {
            HStack(spacing: 32) {
                stat("改编题作答", "\(counted.count)")
                stat("涉及原题", "\(originals)")
                stat("做对", "\(correct)")
                stat("正确率", percent(correct, counted.count))
                stat("题目有错", "\(variants.count - counted.count)")
            }
            .padding(.vertical, 6)
        } header: {
            Text("AI 改编题")
        } footer: {
            Text("改编题的结果按原题的规则计入原题的复习安排、订正状态和知识点掌握度，并交给下一次改编参考：答错算原题没掌握；答对只能把「待巩固」升为「已订正」。改编题标记有错的不计入（统计里也不算）。")
        }
    }

    // MARK: - 错题本（选择题 + 主观题）

    struct WrongItem: Identifiable {
        enum Kind {
            case choice(Question, [AttemptRecord])
            case subjective(SubjectiveQuestion, [SubjectiveAttempt])
            /// 已从教辅包移除的题：只能凭作答时的题目快照查看
            case removedChoice([AttemptRecord])
            case removedSubjective([SubjectiveAttempt])
        }

        let questionID: String
        let kind: Kind
        /// 作答结果，新 → 旧
        let outcomes: [AttemptOutcome]
        let status: CorrectionStatus?
        let starred: Bool
        /// 标记了题目有错（只在「标记有错」里出现）
        var faultyNote: String?? = nil
        var id: String { questionID }
        var latest: Date { outcomes.first?.at ?? .distantPast }
        var confidentWrong: Bool { outcomes.contains { !$0.correct && $0.sure } }
        /// 最近一次答错的是改编题
        var variantWrong: Bool { WrongBook.lastWrongIsVariant(outcomes) }
        var luckyRight: Bool { outcomes.contains { $0.correct && !$0.sure } }
    }

    private var wrongItems: [WrongItem] { wrongItems(for: filter) }

    private func wrongItems(for filter: WrongFilter) -> [WrongItem] {
        var marks: [String: QuestionMark] = [:]
        for m in allMarks where m.packID == pack.id { marks[m.questionID] = m }
        func item(_ id: String, _ kind: WrongItem.Kind, _ outcomes: [AttemptOutcome]) -> WrongItem {
            WrongItem(questionID: id, kind: kind, outcomes: outcomes,
                      status: WrongBook.status(outcomes, masteredAt: marks[id]?.masteredAt),
                      starred: marks[id]?.starred == true,
                      faultyNote: marks[id]?.faultyAt == nil ? nil : .some(marks[id]?.faultyNote))
        }
        // 「标记有错」只列标记了的题，其余筛选不含它们
        let showFaulty = filter == .faulty
        let faultyIDs = faultyIDs
        var choice: [String: [AttemptRecord]] = [:]
        for a in choiceAttempts(faulty: showFaulty) { choice[a.questionID, default: []].append(a) }
        var subj: [String: [SubjectiveAttempt]] = [:]
        for a in subjectiveAttempts(faulty: showFaulty) { subj[a.questionID, default: []].append(a) }
        // 改编题的结果算作原题的作答（改编题标记有错的不算）；只做过改编题的原题也要列出
        var byOriginal: [String: [AttemptOutcome]] = [:]
        for v in variantAttempts(faulty: showFaulty) where !v.isFaulty(faultyIDs) { if let o = AttemptOutcome(v) { byOriginal[v.originalID, default: []].append(o) } }
        func merged(_ id: String, _ own: [AttemptOutcome]) -> [AttemptOutcome] {
            (own + (byOriginal[id] ?? [])).sorted { $0.at > $1.at }
        }
        let choiceIDs = Set(choice.keys).union(byOriginal.keys.filter { pack.questions[$0] != nil })
        let subjIDs = Set(subj.keys).union(byOriginal.keys.filter { pack.subjective[$0] != nil })
        var items: [WrongItem] = choiceIDs.compactMap { id in
            let list = choice[id] ?? []
            return pack.questions[id].map { item(id, .choice($0, list), merged(id, list.map(AttemptOutcome.init))) }
        }
        items += subjIDs.compactMap { id in
            let list = subj[id] ?? []
            return pack.subjective[id].map { item(id, .subjective($0, list), merged(id, list.compactMap(AttemptOutcome.init))) }
        }
        // 已从教辅包移除的题（AI 改编的变式题不算）
        var removedChoice: [String: [AttemptRecord]] = [:]
        for a in attempts where a.packID == pack.id && pack.questions[a.questionID] == nil && !a.questionID.contains("~ai-")
            && faultyIDs.contains(a.questionID) == showFaulty {
            removedChoice[a.questionID, default: []].append(a)
        }
        items += removedChoice.map { id, list in item(id, .removedChoice(list), list.map(AttemptOutcome.init)) }
        var removedSubj: [String: [SubjectiveAttempt]] = [:]
        for a in allSubjective where a.packID == pack.id && a.assessedAt != nil && pack.subjective[a.questionID] == nil
            && !a.questionID.contains("~ai-") && faultyIDs.contains(a.questionID) == showFaulty {
            removedSubj[a.questionID, default: []].append(a)
        }
        items += removedSubj.map { id, list in
            item(id, .removedSubjective(list), list.compactMap(AttemptOutcome.init))
        }
        // 标记有错但还没作答过的题也列出来，方便取消标记
        if showFaulty {
            let listed = Set(items.map(\.questionID))
            for id in faultyIDs where !listed.contains(id) {
                if let q = pack.questions[id] { items.append(item(id, .choice(q, []), [])) }
                else if let q = pack.subjective[id] { items.append(item(id, .subjective(q, []), [])) }
            }
        }
        return items.filter {
            switch filter {
            case .all: $0.status != nil
            case .unresolved: $0.status.map { !$0.isResolved } ?? false
            case .starred: $0.starred
            case .confidentWrong: $0.confidentWrong
            case .luckyRight: $0.luckyRight
            case .faulty: true
            }
        }
        .sorted { $0.latest > $1.latest }
    }

    /// 错题本平时用不上（复习页已按记忆安排重做），这里只留一个入口，点进去再查阅
    private var wrongQuestions: some View {
        let unresolved = wrongItems(for: .unresolved).count
        let total = wrongItems(for: .all).count
        return Section {
            NavigationLink {
                wrongBookPage
            } label: {
                HStack {
                    Label("错题本", systemImage: "book.closed")
                    Spacer()
                    Text(total == 0 ? "暂无" : "未订正 \(unresolved) · 共 \(total) 道")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("按状态查阅答错过的题、订正笔记和以往作答；标记了「题目有错」的题也在里面。")
        }
    }

    private var wrongBookPage: some View {
        List {
            Section {
                Picker("筛选", selection: $filter) {
                    ForEach(WrongFilter.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                let list = wrongItems
                if list.isEmpty { Text("暂无").foregroundStyle(.secondary) }
                ForEach(list) { wrongRow($0) }
            } footer: {
                Text("选择题和主观题都在这里。答错之后，隔天以上（距上次看答案满 24 小时）有把握地答对才算「已订正」；不满 24 小时的显示「待巩固」，看答案后不久的重做不算。AI 改编题答错也算这道题答错；原题待巩固时，改编题有把握地答对可以升为「已订正」。左滑可以标为重点，或手动标为已掌握（之后再答错会自动取消）。在题目上标记「题目有错」的题不再出现在错题本和统计里，可在「标记有错」中找到。")
            }
        }
        .navigationTitle("错题本 · \(pack.title)")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func wrongRow(_ item: WrongItem) -> some View {
        wrongLink(item)
            .swipeActions(edge: .trailing) {
                Button(item.starred ? "取消重点" : "重点", systemImage: item.starred ? "star.slash" : "star") {
                    QuestionMark.update(packID: pack.id, questionID: item.questionID, in: context) { $0.starred.toggle() }
                }
                .tint(.yellow)
                if item.status != nil {
                    let mastered = item.status == .markedMastered
                    Button(mastered ? "取消已掌握" : "已掌握", systemImage: "checkmark.seal") {
                        QuestionMark.update(packID: pack.id, questionID: item.questionID, in: context) {
                            $0.masteredAt = mastered ? nil : .now
                        }
                    }
                    .tint(.green)
                }
            }
    }

    @ViewBuilder
    private func wrongLink(_ item: WrongItem) -> some View {
        switch item.kind {
        case .choice(let q, let attempts):
            NavigationLink {
                RedoView(pack: pack, question: q)
            } label: {
                choiceRow(item, q, attempts)
            }
        case .subjective(let q, let attempts):
            NavigationLink {
                SubjectiveRedoView(pack: pack, question: q)
            } label: {
                subjectiveRow(item, q, attempts)
            }
        case .removedChoice(let attempts):
            NavigationLink {
                RemovedQuestionView(pack: pack, questionID: item.questionID, choice: attempts, subjective: [])
            } label: {
                removedRow(item, snapshot: attempts.first?.questionSnapshot, sectionID: attempts.first?.sectionID,
                           count: attempts.count, wrong: attempts.filter { !$0.isCorrect }.count,
                           note: attempts.first { !($0.correctionNote ?? "").isEmpty }?.correctionNote)
            }
        case .removedSubjective(let attempts):
            NavigationLink {
                RemovedQuestionView(pack: pack, questionID: item.questionID, choice: [], subjective: attempts)
            } label: {
                removedRow(item, snapshot: attempts.first?.questionSnapshot, sectionID: attempts.first?.sectionID,
                           count: attempts.count, wrong: attempts.filter { $0.resultValue != .correct }.count,
                           note: attempts.first { !($0.correctionNote ?? "").isEmpty }?.correctionNote)
            }
        }
    }

    private func removedRow(_ item: WrongItem, snapshot: Data?, sectionID: String?, count: Int, wrong: Int,
                            note: String?) -> some View {
        let stem = snapshot.flatMap(QuestionSnapshot.init)?.stem ?? item.questionID
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(sectionID ?? "") \(item.questionID)").font(.body.bold())
                rowBadges(item)
                Text("已从教辅包移除").font(.caption2.bold()).foregroundStyle(.orange)
            }
            Text(stem).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Text("作答 \(count) 次，没做对 \(wrong) 次").font(.caption2).foregroundStyle(.secondary)
            if let note {
                Label(note, systemImage: "square.and.pencil").font(.caption).lineLimit(2)
            }
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule()).foregroundStyle(color)
    }

    @ViewBuilder
    private func rowBadges(_ item: WrongItem) -> some View {
        if item.starred { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption) }
        if let note = item.faultyNote { badge("有错" + (note.map { "：\($0)" } ?? ""), .red) }
        if item.confidentWrong { badge("确定却错", .red) }
        if item.variantWrong { badge("改编题答错", .purple) }
        if let status = item.status { badge(status.label, status.color) }
    }

    private func choiceRow(_ item: WrongItem, _ q: Question, _ attempts: [AttemptRecord]) -> some View {
        let wrongCount = attempts.filter { !$0.isCorrect }.count
        let note = attempts.first { !($0.correctionNote ?? "").isEmpty }?.correctionNote
        // 最近一次填了原因的作答：答错的错因，或答对但没把握的原因
        let caused = attempts.first { $0.causeLine(pack.pointTitle) != nil }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(pack.questionSection[q.id] ?? "") 第 \(q.num) 题").font(.body.bold())
                rowBadges(item)
                if let hash = attempts.first?.contentHash, hash != Grader.contentHash(q) {
                    Text("题目已更新").font(.caption2.bold()).foregroundStyle(.orange)
                }
            }
            Text(q.stem).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Group {
                if let last = attempts.first {
                    Text("作答 \(attempts.count) 次，错 \(wrongCount) 次 · 最近一次选 \(last.selection)（\(confidenceLabel(last.confidence))）")
                } else {
                    Text(item.outcomes.isEmpty ? "还没有作答" : "只做过这道题的 AI 改编题")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            if let caused, let line = caused.causeLine(pack.pointTitle) {
                Text((caused.isCorrect ? "没把握：" : "错因：") + line)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            if let note {
                Label(note, systemImage: "square.and.pencil").font(.caption).lineLimit(2)
            }
        }
    }

    private func subjectiveRow(_ item: WrongItem, _ q: SubjectiveQuestion, _ attempts: [SubjectiveAttempt]) -> some View {
        let note = attempts.first { !($0.correctionNote ?? "").isEmpty }?.correctionNote
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(pack.questionSection[q.id] ?? "") \(q.kindLabel) \(q.num)").font(.body.bold())
                if let r = attempts.first?.resultValue { badge(r.label, SubjectiveCard.color(r)) }
                rowBadges(item)
                if let hash = attempts.first?.recordedHash, hash != SubjectiveRecords.contentHash(q) {
                    Text("题目已更新").font(.caption2.bold()).foregroundStyle(.orange)
                }
            }
            Text(q.stem ?? "（题面见原图）").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if let a = attempts.first {
                Text(SubjectiveCard.detailLine(a)).font(.caption2).foregroundStyle(.secondary)
                ForEach(a.causeLines(pack.pointTitle), id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
            }
            if let note {
                Label(note, systemImage: "square.and.pencil").font(.caption).lineLimit(2)
            }
        }
    }
}

/// 某个知识点的详情：讲授位置、考点追踪、涉及的题目与最近一次作答
struct KnowledgePointDetailView: View {
    let pack: StudyPack
    let point: KnowledgePoint
    /// 掌握度统计用的证据（与列表里「做过 / 最近答错」同一来源）
    let evidence: [Mastery.Evidence]
    /// 本书复习时做的 AI 改编题（新 → 旧），在原题下面单列一行
    let variants: [VariantAttempt]
    /// 本书标记了题目有错的题（含改编题）
    let faultyIDs: Set<String>

    private struct Item {
        let id: String
        let title: String
        let stem: String
        let main: Bool
        let section: String
        let num: Int
        let subjective: SubjectiveQuestion?
        let choice: Question?
    }

    /// 考查该知识点的题（选择题、主观题），以及选错时暴露了该知识点的题：主考在前，按节和题号
    private var related: [Item] {
        var items: [String: Item] = [:]
        func addChoice(_ q: Question) {
            items[q.id] = Item(id: q.id, title: "第 \(q.num) 题", stem: q.stem, main: q.tests == point.id,
                               section: pack.questionSection[q.id] ?? "", num: q.num, subjective: nil, choice: q)
        }
        func addSubjective(_ q: SubjectiveQuestion) {
            items[q.id] = Item(id: q.id, title: "\(q.kindLabel) \(q.num)", stem: q.stem ?? "（题面见原图）",
                               main: q.tests == point.id || q.effectiveParts.contains { $0.tests == point.id },
                               section: pack.questionSection[q.id] ?? "", num: q.num, subjective: q, choice: nil)
        }
        for q in pack.questions.values where q.deprecated != true && q.testedPoints.contains(point.id) { addChoice(q) }
        for q in pack.subjective.values where q.deprecated != true
            && (q.testedPoints.contains(point.id) || q.effectiveParts.contains { q.testedPoints(of: $0).contains(point.id) }) {
            addSubjective(q)
        }
        for e in evidence where items[e.questionKey] == nil {
            if let q = pack.questions[e.questionKey] { addChoice(q) }
            else if let q = pack.subjective[e.questionKey] { addSubjective(q) }
        }
        return items.values.sorted { ($0.main ? 0 : 1, $0.section, $0.num) < ($1.main ? 0 : 1, $1.section, $1.num) }
    }

    var body: some View {
        List {
            Section("讲授位置") {
                ForEach(point.taughtIn, id: \.self) { id in
                    if let c = pack.chunks[id] {
                        let label = VStack(alignment: .leading, spacing: 2) {
                            Text(c.title)
                            Text("\(id) · \(c.location(sourceLabel: pack.sourceLabel))").font(.caption).foregroundStyle(.secondary)
                        }
                        if let loc = pack.lectureLocation(ofChunk: id) {
                            NavigationLink {
                                StudySessionView(pack: pack, section: loc.section,
                                                 start: StudyPosition(roundIndex: loc.roundIndex, page: .lecture))
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    label
                                    Text("\(loc.section.section.id) \(loc.section.section.title) · 第 \(loc.roundIndex + 1) 轮讲解")
                                        .font(.caption).foregroundStyle(.tint)
                                }
                            }
                        } else {
                            label
                        }
                    }
                }
            }
            if let topics = point.examTopics, !topics.isEmpty {
                Section("考点追踪") {
                    ForEach(topics, id: \.self) { Text($0) }
                }
            }
            Section {
                ForEach(related, id: \.id) { item in
                    // 原题这一行只看原题自己的作答，改编题的结果在下一行
                    let mine = evidence.filter { $0.questionKey == item.id && !$0.variant }
                    let wrong = mine.filter(\.wrong)
                    NavigationLink {
                        // 跳到第一次学这道题的位置（讲解 + 题目）；不在任何一轮里的题仍是重做
                        if let loc = pack.questionLocation(item.id) {
                            StudySessionView(pack: pack, section: loc.section,
                                             start: StudyPosition(roundIndex: loc.roundIndex,
                                                                  page: .question(loc.questionIndex)))
                        } else if let q = item.subjective {
                            SubjectiveRedoView(pack: pack, question: q)
                        } else if let q = item.choice {
                            RedoView(pack: pack, question: q)
                        }
                    } label: {
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: mine.isEmpty ? "circle"
                                  : (wrong.isEmpty ? "checkmark.circle.fill" : "xmark.circle.fill"))
                                .foregroundStyle(mine.isEmpty ? Color.secondary : (wrong.isEmpty ? .green : .red))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(item.section) \(item.title)\(item.main ? "" : "（兼考）")")
                                    .font(.body.bold())
                                Text(item.stem).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                    let tries = variants.filter { $0.originalID == item.id }
                    if !tries.isEmpty { variantRow(item, tries) }
                }
            } header: {
                Text("相关题目")
            } footer: {
                Text("对错按每道题最近一次作答；复习时做的 AI 改编题单列在原题下面。知识点列表中的「最近答错」包括原题或其最近一次 AI 改编题答错；选择题答错时只有选项暴露出这个知识点才算答错。")
            }
        }
        .navigationTitle(point.title)
    }

    /// 原题下面一行：这道题的 AI 改编题做过几道、对错几道、最近一次的结果；点进去查看每一道
    private func variantRow(_ item: Item, _ tries: [VariantAttempt]) -> some View {
        let faulty = faultyIDs
        let counted = tries.filter { !$0.isFaulty(faulty) }
        let correct = counted.filter(\.isCorrect).count
        let latest = counted.first
        return NavigationLink {
            ScrollView {
                VariantHistoryCard(pack: pack, originalID: item.id).padding(24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("\(item.section) \(item.title) · AI 改编题")
            .navigationBarTitleDisplayMode(.inline)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                // AI 相关内容统一用紫色
                Image(systemName: "wand.and.stars").foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(item.section) \(item.title)的 AI 改编题").font(.body.bold()).foregroundStyle(.purple)
                    Text("做过 \(counted.count) 道，对 \(correct) 道、错 \(counted.count - correct) 道")
                        .font(.caption).foregroundStyle(.secondary)
                    if let latest {
                        Text("最近一次：" + VariantHistoryCard.summary(latest)).font(.caption)
                            .foregroundStyle(latest.isCorrect ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    }
                    if tries.count > counted.count {
                        Text("另有 \(tries.count - counted.count) 次作答的题目标记有错，不计入").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// 错题重做：上面重新作答；提交后，下面列出以往每次作答（错因、订正笔记、当时的草稿和讲评）
struct RedoView: View {
    let pack: StudyPack
    let question: Question
    @Environment(\.dismiss) private var dismiss
    @Query private var attempts: [AttemptRecord]
    /// 提交前不显示以往作答，免得看到之前选的选项和讲评
    @State private var submitted = false
    @State private var backTo: BackToStudyTarget?

    init(pack: StudyPack, question: Question) {
        self.pack = pack
        self.question = question
        let packID = pack.id, questionID = question.id
        _attempts = Query(filter: #Predicate<AttemptRecord> { $0.packID == packID && $0.questionID == questionID },
                          sort: \.createdAt, order: .reverse)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                QuestionCard(pack: pack, question: question, mode: .redo, onSubmitted: { _ in submitted = true },
                             shuffleOptions: true, nextLabel: "返回") { dismiss() }
                if submitted { BackToStudyButton(pack: pack, questionID: question.id) { backTo = $0 } }
                if submitted && !attempts.isEmpty { history }
                if submitted {
                    VariantHistoryCard(pack: pack, originalID: question.id)
                    SavedVariantsCard(pack: pack, originalID: question.id)
                }
            }
            .padding(24)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("重做")
        .navigationBarTitleDisplayMode(.inline)
        .backToStudyDestination($backTo)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                QuestionMarkControls(packID: pack.id, questionID: question.id)
            }
        }
    }

    private var history: some View {
        Card {
            Text("以往作答").font(.headline)
            ForEach(Array(attempts.enumerated()), id: \.element.persistentModelID) { i, a in
                if i > 0 { Divider() }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: a.isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(a.isCorrect ? .green : .red)
                        let kind = AttemptMode.label(of: a.mode)
                        Text("\(a.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(kind) · 选 \(a.selection.replacingOccurrences(of: ",", with: "、")) · \(confidenceLabel(a.confidence))")
                    }
                    if let line = a.causeLine(pack.pointTitle) {
                        Text((a.isCorrect ? "没把握：" : "错因：") + line).font(.callout).foregroundStyle(.secondary)
                    }
                    QuestionCard.attemptExtras(a, pack: pack)
                }
            }
        }
    }
}

/// 主观题错题重做：在复习用的草稿页上新开一次作答（与复习页共用），看过答案后才列出以往作答
struct SubjectiveRedoView: View {
    let pack: StudyPack
    let question: SubjectiveQuestion
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage("draft.enabled") private var draftEnabled = true
    @State private var resetZoomRequest = 0
    @State private var tapTargets = DraftTapTargets()
    @State private var assessed = false
    @State private var backTo: BackToStudyTarget?

    private var draftKey: String { DraftKey.review(pack: pack.id, questionID: question.id) }

    var body: some View {
        ZoomablePageScrollView(draftEnabled: draftEnabled, resetZoomRequest: resetZoomRequest) {
            VStack(spacing: 20) {
                SubjectiveCard(pack: pack, question: question, sectionID: pack.questionSection[question.id] ?? "",
                               mode: .review, nextLabel: "返回", onAssessed: { assessed = true }) { dismiss() }
                if assessed { BackToStudyButton(pack: pack, questionID: question.id) { backTo = $0 } }
                if draftEnabled { Color.clear.frame(height: 360) }
            }
            .padding(24)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
            .coordinateSpace(.named(draftPageSpace))
            .environment(\.draftTapTargets, tapTargets)
            .overlay {
                DraftCanvas(key: draftKey, enabled: draftEnabled, tapTargets: tapTargets).id(draftKey)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("重做")
        .navigationBarTitleDisplayMode(.inline)
        .backToStudyDestination($backTo)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                QuestionMarkControls(packID: pack.id, questionID: question.id)
                Menu {
                    Button(draftEnabled ? "关闭草稿模式" : "开启草稿模式",
                           systemImage: draftEnabled ? "pencil.slash" : "pencil.tip") { draftEnabled.toggle() }
                    Button("恢复原大小", systemImage: "arrow.down.right.and.arrow.up.left") { resetZoomRequest += 1 }
                    Button("清除本页草稿", systemImage: "trash", role: .destructive) {
                        DraftStore.delete(draftKey, reason: "user_clear", in: context)
                    }
                } label: {
                    Label("草稿", systemImage: draftEnabled ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
                } primaryAction: {
                    draftEnabled.toggle()
                }
            }
        }
    }
}
